-- Localize globals for performance
local CreateFrame          = CreateFrame
local GetTime              = GetTime
local UnitOnTaxi           = UnitOnTaxi
local TaxiNodeGetType      = TaxiNodeGetType
local TaxiNodeName         = TaxiNodeName
local TaxiNodeCost         = TaxiNodeCost
local GetZoneText          = GetZoneText
local UnitName             = UnitName
local GetNumRaidMembers    = GetNumRaidMembers
local GetNumPartyMembers   = GetNumPartyMembers
local SendChatMessage      = SendChatMessage
local GetPlayerBuff        = GetPlayerBuff
local CancelPlayerBuff     = CancelPlayerBuff
local GetCursorPosition    = GetCursorPosition
local tinsert              = tinsert

-------------------------------------------------------------------------------
-- Frame & event setup
-------------------------------------------------------------------------------

FlightTracker = CreateFrame("Frame", "FlightTracker")
FlightTracker:SetScript("OnEvent", function()
    if FlightTracker[event] then FlightTracker[event](FlightTracker) end
end)
FlightTracker:RegisterEvent("ADDON_LOADED")
FlightTracker:RegisterEvent("PLAYER_ENTERING_WORLD")
FlightTracker:RegisterEvent("TAXIMAP_OPENED")
FlightTracker:RegisterEvent("ZONE_CHANGED_NEW_AREA")

-------------------------------------------------------------------------------
-- Constants & state
-------------------------------------------------------------------------------

local ADDON_PATH = "Interface\\AddOns\\FlightTracker\\"

local isFlying                    = false
local isPending                   = false
local pendingDestName             = nil
local pendingCost                 = 0
local startTime                   = 0
local originNode                  = nil
local destNode                    = nil
local flightTimerFrame            = nil
local isTooltipHooked             = false
local original_TaxiNodeOnButtonEnter = nil
local cachedOriginNode            = nil

-------------------------------------------------------------------------------
-- Confirm flight popup
-------------------------------------------------------------------------------

StaticPopupDialogs["FLIGHTTRACKER_CONFIRM"] = {
    text      = "Fly to %s?",
    button1   = "Yes",
    button2   = "No",
    OnAccept  = function(data)
        FlightTracker.confirming = true
        TakeTaxiNode(data.index)
        FlightTracker.confirming = false
    end,
    timeout     = 0,
    whileDead   = 1,
    hideOnEscape = 1,
}

-------------------------------------------------------------------------------
-- ADDON_LOADED
-------------------------------------------------------------------------------

function FlightTracker:ADDON_LOADED()
    if arg1 ~= "FlightTracker" then return end

    local playerName = UnitName("player")

    -- Initialise saved variable tables
    if not FlightTrackerDB                      then FlightTrackerDB = {} end
    if not FlightTrackerDB.flights              then FlightTrackerDB.flights = {} end
    if not FlightTrackerDB.routes               then FlightTrackerDB.routes = {} end
    if not FlightTrackerDB.checklistExpanded    then FlightTrackerDB.checklistExpanded = {} end

    -- Always clear estimated cache on login to avoid stale false-entries
    FlightTrackerDB.estimatedCache = {}

    -- Per-character stats
    if not FlightTrackerDB.char then FlightTrackerDB.char = {} end
    if not FlightTrackerDB.char[playerName] then FlightTrackerDB.char[playerName] = {} end
    if not FlightTrackerDB.char[playerName].stats then
        FlightTrackerDB.char[playerName].stats = {
            totalFlights  = 0,
            totalTime     = 0,
            totalGold     = 0,
            longestFlight = { duration = 0, route = "None" },
        }
    end
    self.charStats = FlightTrackerDB.char[playerName].stats

    -- Restore last known flight master
    if FlightTrackerDB.lastFlightMaster then
        FlightTracker.currentFlightMaster = FlightTrackerDB.lastFlightMaster
    else
        FlightTracker.currentFlightMaster = nil
    end

    -- Apply default settings for any missing keys
    local defaultSettings = {
        showTimer        = true,
        autoDismount     = true,
        confirmFlight    = false,
        announceFlight   = false,
        minimapPos       = 45,
        showMinimapButton = true,
        lockPosition     = false,
        hideBorder       = false,
    }
    if not FlightTrackerDB.settings then FlightTrackerDB.settings = {} end
    for key, value in pairs(defaultSettings) do
        if FlightTrackerDB.settings[key] == nil then
            FlightTrackerDB.settings[key] = value
        end
    end

    self:Print("Loaded. Type /ft or /flighttracker to show stats.")
    self:CreateTimerFrame()
    self:CreateMinimapButton()
    tinsert(UISpecialFrames, "FlightTrackerMain")
    self:UnregisterEvent("ADDON_LOADED")
end

-------------------------------------------------------------------------------
-- PLAYER_ENTERING_WORLD
-------------------------------------------------------------------------------

function FlightTracker:PLAYER_ENTERING_WORLD()
    if UnitOnTaxi("player") then
        -- Resumed mid-flight (e.g. reload UI)
        isFlying = true
        startTime = GetTime()
        destNode  = "Unknown"
        flightTimerFrame.destText:SetText("In Flight")
        flightTimerFrame.zoneText:SetText("")
        flightTimerFrame.max = 0
        flightTimerFrame:Show()
        self:StartMonitor()
    else
        -- Discard any interrupted flight (summon, BG, etc.)
        if isFlying or isPending then
            isFlying        = false
            isPending       = false
            startTime       = 0
            originNode      = nil
            destNode        = nil
            pendingDestName = nil
            flightTimerFrame:Hide()
            self:StopMonitor()
        end

        -- Update flight master for hearthstone / portal / teleport arrivals
        local currentZone = GetZoneText()
        local found = FlightTracker:FindFlightMasterInZone(currentZone)
        if found and found ~= FlightTracker.currentFlightMaster then
            FlightTracker.currentFlightMaster = found
            FlightTrackerDB.lastFlightMaster  = found
        end
        -- If not found, keep currentFlightMaster as-is (restored from login)
    end
end

-------------------------------------------------------------------------------
-- TAXIMAP_OPENED
-------------------------------------------------------------------------------

function FlightTracker:TAXIMAP_OPENED()
    cachedOriginNode = FlightTracker.Util.GetCurrentFlightNode()
    self:ScanRoutes()
    if FlightTrackerDB.settings.autoDismount then
        self:DismountPlayer()
    end
    self:HookTaxiMap()
    if FlightTracker.MapIcons then
        FlightTracker.MapIcons:RegisterCurrentFlightMaster()
    end
end

-------------------------------------------------------------------------------
-- ZONE_CHANGED_NEW_AREA
-------------------------------------------------------------------------------

function FlightTracker:ZONE_CHANGED_NEW_AREA()
    if UnitOnTaxi("player") then return end  -- ignore zone changes mid-flight

    local newZone = GetZoneText()
    local found   = FlightTracker:FindFlightMasterInZone(newZone)
    if found then
        FlightTracker.currentFlightMaster = found
        FlightTrackerDB.lastFlightMaster  = found
    end
    -- If not found, leave currentFlightMaster as-is
end

-------------------------------------------------------------------------------
-- Route scanning
-------------------------------------------------------------------------------

function FlightTracker:ScanRoutes()
    local currentNode = cachedOriginNode
    if not currentNode then return end

    local faction = UnitFactionGroup("player")
    if not faction then return end

    if not FlightTrackerDB.routes[currentNode] then
        FlightTrackerDB.routes[currentNode] = {}
    end

    local numNodes = NumTaxiNodes()
    for i = 1, numNodes do
        if TaxiNodeGetType(i) == "REACHABLE" then
            local nodeName = TaxiNodeName(i)
            local current  = FlightTrackerDB.routes[currentNode][nodeName]

            if not current or current == true then
                FlightTrackerDB.routes[currentNode][nodeName] = faction
                if not FlightTrackerDB.routes[nodeName] then
                    FlightTrackerDB.routes[nodeName] = {}
                end
                FlightTrackerDB.routes[nodeName][currentNode] = faction
            elseif current ~= faction and current ~= "Both" then
                FlightTrackerDB.routes[currentNode][nodeName] = "Both"
            end
        end
    end

    if FlightTracker.Checklist and FlightTracker.Checklist:IsOpen() then
        FlightTracker.Checklist:Refresh()
    end
end

-------------------------------------------------------------------------------
-- Estimated flight time (BFS over known routes + recorded times)
-------------------------------------------------------------------------------

function FlightTracker:GetEstimatedFlightTime(origin, destination)
    if not origin or not destination then return nil end
    if origin == destination then return 0 end

    local cacheKey = origin .. "|" .. destination
    if FlightTrackerDB.estimatedCache[cacheKey] ~= nil then
        return FlightTrackerDB.estimatedCache[cacheKey] or nil
    end

    local visited = {}
    local queue   = { { node = origin, time = 0 } }

    while table.getn(queue) > 0 do
        local current = table.remove(queue, 1)

        if current.node == destination then
            FlightTrackerDB.estimatedCache[cacheKey] = current.time
            return current.time
        end

        if not visited[current.node] then
            visited[current.node] = true
            local routes = FlightTrackerDB.routes[current.node]
            if routes then
                for nextNode in pairs(routes) do
                    if not visited[nextNode] then
                        local key        = current.node .. " -> " .. nextNode
                        local reverseKey = nextNode .. " -> " .. current.node
                        local duration   = FlightTrackerDB.flights[key]
                                       or FlightTrackerDB.flights[reverseKey]
                        if duration then
                            table.insert(queue, { node = nextNode, time = current.time + duration })
                        end
                    end
                end
            end
        end
    end

    -- No path found — cache the failure so we don't BFS again this session
    FlightTrackerDB.estimatedCache[cacheKey] = false
    return nil
end

-------------------------------------------------------------------------------
-- Taxi map hook (flight time tooltips + confirm dialog)
-------------------------------------------------------------------------------

function FlightTracker:HookTaxiMap()
    if isTooltipHooked then return end

    local original_TakeTaxiNode = TakeTaxiNode
    TakeTaxiNode = function(index)
        local nodeType = TaxiNodeGetType(index)
        if nodeType == "REACHABLE" then
            local destName = TaxiNodeName(index)

            if FlightTrackerDB.settings.confirmFlight and not FlightTracker.confirming then
                local dialog = StaticPopup_Show("FLIGHTTRACKER_CONFIRM", destName)
                if dialog then
                    dialog.data = { index = index, name = destName }
                end
                return
            end

            FlightTracker:PrepareFlight(index, destName)
        end
        original_TakeTaxiNode(index)
    end

    original_TaxiNodeOnButtonEnter = TaxiNodeOnButtonEnter
    TaxiNodeOnButtonEnter = function(button)
        original_TaxiNodeOnButtonEnter(button)

        local index = button:GetID()
        if not index then return end

        local nodeType = TaxiNodeGetType(index)
        if nodeType ~= "REACHABLE" then return end

        local destName = TaxiNodeName(index)
        local origin   = cachedOriginNode or FlightTracker.Util.GetCurrentFlightNode()

        local key        = origin .. " -> " .. destName
        local duration   = FlightTrackerDB.flights[key]

        if not duration then
            local reverseKey = destName .. " -> " .. origin
            duration = FlightTrackerDB.flights[reverseKey]
        end
        if not duration then
            duration = FlightTracker:GetEstimatedFlightTime(origin, destName)
        end

        local timeText = "--:--"
        if duration then timeText = FlightTracker.Util.FormatTime(duration) end

        GameTooltip:AddLine("Flight Time: " .. timeText, 1, 1, 1)
        GameTooltip:Show()
    end

    isTooltipHooked = true
end

-------------------------------------------------------------------------------
-- Flight lifecycle
-------------------------------------------------------------------------------

function FlightTracker:PrepareFlight(index, destName)
    isPending             = true
    pendingDestName       = destName
    pendingCost           = TaxiNodeCost(index)
    self.pendingStartTime = GetTime()
    self:StartMonitor()
end

function FlightTracker:StartMonitor()
    self.monitorTimer = 0
    self:SetScript("OnUpdate", self.OnUpdateMonitor)
end

function FlightTracker:StopMonitor()
    self:SetScript("OnUpdate", nil)
end

function FlightTracker.OnUpdateMonitor()
    local self = FlightTracker

    -- Throttle to 5 times per second
    self.monitorTimer = self.monitorTimer + arg1
    if self.monitorTimer < 0.2 then return end
    self.monitorTimer = 0

    if isPending then
        if UnitOnTaxi("player") then
            isPending = false
            self:StartFlight(pendingDestName, pendingCost)
        elseif GetTime() - self.pendingStartTime > 10 then
            isPending = false
            self:StopMonitor()
        end
    elseif isFlying then
        if not UnitOnTaxi("player") then
            self:EndFlight()
        end
    else
        self:StopMonitor()
    end
end

function FlightTracker:StartFlight(destination, cost)
    isFlying  = true
    startTime = GetTime()
    destNode  = destination

    -- Update character stats
    if self.charStats then
        self.charStats.totalGold    = self.charStats.totalGold + (cost or 0)
        self.charStats.totalFlights = self.charStats.totalFlights + 1
    end

    originNode = cachedOriginNode or FlightTracker.Util.GetCurrentFlightNode()

    -- Look up known or estimated duration for the timer
    local key          = originNode .. " -> " .. destNode
    local knownDuration = FlightTrackerDB.flights[key]

    if not knownDuration then
        local reverseKey = destNode .. " -> " .. originNode
        knownDuration = FlightTrackerDB.flights[reverseKey]
    end
    if not knownDuration then
        knownDuration = FlightTracker:GetEstimatedFlightTime(originNode, destNode)
    end

    -- Announce to party/raid if enabled
    if FlightTrackerDB.settings.announceFlight then
        local msg = "Flying to " .. destNode .. "."
        if knownDuration then
            msg = msg .. " ETA: " .. FlightTracker.Util.FormatTime(knownDuration)
        end
        if GetNumRaidMembers() > 0 then
            SendChatMessage(msg, "RAID")
        elseif GetNumPartyMembers() > 0 then
            SendChatMessage(msg, "PARTY")
        end
    end

    -- Show the in-flight timer
    if FlightTrackerDB.settings.showTimer then
        local _, _, node, zone = string.find(destNode, "^(.+), (.+)$")
        if not node then
            node = destNode
            zone = GetZoneText()
        end
        flightTimerFrame.destText:SetText(node)
        flightTimerFrame.zoneText:SetText(zone)
        flightTimerFrame.max = knownDuration or 0
        flightTimerFrame:Show()
    end

    if FlightTracker.GUI then FlightTracker.GUI:UpdateStats() end
end

function FlightTracker:EndFlight()
    isFlying = false
    flightTimerFrame:Hide()

    if startTime == 0 then return end

    local duration = GetTime() - startTime

    if originNode and destNode and duration > 10 then
        local key            = originNode .. " -> " .. destNode
        local reverseKey     = destNode   .. " -> " .. originNode
        local existing       = FlightTrackerDB.flights[key]
        local reverseExisting = FlightTrackerDB.flights[reverseKey]

        -- Only update if the new time differs by more than 1 second
        if not existing or math.abs(duration - existing) > 1 then
            FlightTrackerDB.flights[key] = duration
        end
        if not reverseExisting or math.abs(duration - reverseExisting) > 1 then
            FlightTrackerDB.flights[reverseKey] = duration
        end

        -- Clear estimated cache so newly recorded times are picked up
        if (not existing       or math.abs(duration - existing) > 1)
        or (not reverseExisting or math.abs(duration - reverseExisting) > 1) then
            FlightTrackerDB.estimatedCache = {}
        end

        -- Update per-character stats
        if self.charStats then
            self.charStats.totalTime = self.charStats.totalTime + duration

            if type(self.charStats.longestFlight) ~= "table" then
                self.charStats.longestFlight = { duration = self.charStats.longestFlight or 0, route = "" }
            end
            if duration > self.charStats.longestFlight.duration then
                self.charStats.longestFlight.duration = duration
                self.charStats.longestFlight.route    = key
            end
        end

        if FlightTracker.GUI then FlightTracker.GUI:UpdateStats() end
        if FlightTracker.Checklist and FlightTracker.Checklist:IsOpen() then
            FlightTracker.Checklist:Refresh()
        end
    end

    -- Update current flight master to where we just landed
    FlightTracker.currentFlightMaster = destNode
    FlightTrackerDB.lastFlightMaster  = destNode

    startTime  = 0
    originNode = nil
    destNode   = nil
    self:StopMonitor()
end

-------------------------------------------------------------------------------
-- Zone → flight master lookup
-------------------------------------------------------------------------------

function FlightTracker:FindFlightMasterInZone(zoneName)
    if FlightTrackerDB.flightMasters then
        for flightMasterName, data in pairs(FlightTrackerDB.flightMasters) do
            if data.zone == zoneName then
                return flightMasterName
            end
            -- Also check instanced city zones (e.g. "Stormwind City", "Ironforge")
            if data.cityZoneName and data.cityZoneName == zoneName then
                return flightMasterName
            end
        end
    end

    -- Fallback: partial match against route keys
    if FlightTrackerDB.routes then
        for flightMasterName in pairs(FlightTrackerDB.routes) do
            if string.find(flightMasterName, zoneName, 1, true) then
                return flightMasterName
            end
        end
    end

    return nil
end

-------------------------------------------------------------------------------
-- Dismount helper
-------------------------------------------------------------------------------

function FlightTracker:DismountPlayer()
    if Dismount then
        Dismount()
        return
    end

    if not self.scanner then
        self.scanner = CreateFrame("GameTooltip", "FlightTrackerScanner", nil, "GameTooltipTemplate")
        self.scanner:SetOwner(WorldFrame, "ANCHOR_NONE")
    end

    for i = 0, 31 do
        local index = GetPlayerBuff(i, "HELPFUL")
        if index > -1 then
            self.scanner:ClearLines()
            self.scanner:SetPlayerBuff(index)
            local text = FlightTrackerScannerTextLeft2:GetText()
            if text and string.find(text, "Increases speed by %d+%%") then
                CancelPlayerBuff(index)
                return
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Minimap button
-------------------------------------------------------------------------------

function FlightTracker:CreateMinimapButton()
    if self.minimapButton then return end

    local b = CreateFrame("Button", "FlightTrackerMinimapButton", Minimap)
    b:SetWidth(32)
    b:SetHeight(32)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)

    local t = b:CreateTexture(nil, "BACKGROUND")
    t:SetTexture(ADDON_PATH .. "img\\flight")
    t:SetWidth(20)
    t:SetHeight(20)
    t:SetPoint("CENTER", 0, 0)
    b.icon = t

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(52)
    border:SetHeight(52)
    border:SetPoint("TOPLEFT", 0, 0)

    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function()
        if FlightTracker.GUI then FlightTracker.GUI:Toggle() end
    end)
    b:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Flight Tracker")
        GameTooltip:AddLine("Click to open UI", 1, 1, 1)
        GameTooltip:AddLine("Shift+Drag to move", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    b:SetMovable(true)
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function()
        if IsShiftKeyDown() then
            this:LockHighlight()
            this.isDragging = true
        end
    end)
    b:SetScript("OnDragStop", function()
        this:UnlockHighlight()
        this.isDragging = false
    end)
    b:SetScript("OnUpdate", function()
        if not this.isDragging then return end
        local xpos, ypos = GetCursorPosition()
        local xmin, ymin = Minimap:GetLeft(), Minimap:GetBottom()
        xpos = xmin - xpos / UIParent:GetScale() + 70
        ypos = ypos / UIParent:GetScale() - ymin - 70
        local angle = math.deg(math.atan2(ypos, xpos))
        FlightTrackerDB.settings.minimapPos = angle
        FlightTracker:UpdateMinimapButtonPosition()
    end)

    self.minimapButton = b
    self:UpdateMinimapButtonPosition()
    self:UpdateMinimapButtonVisibility()
end

function FlightTracker:UpdateMinimapButtonVisibility()
    if not self.minimapButton then return end
    if FlightTrackerDB.settings.showMinimapButton then
        self.minimapButton:Show()
    else
        self.minimapButton:Hide()
    end
end

function FlightTracker:UpdateMinimapButtonPosition()
    if not self.minimapButton then return end
    local angle  = FlightTrackerDB.settings.minimapPos or 45
    local radius = 80
    local x      = math.cos(math.rad(angle)) * radius
    local y      = math.sin(math.rad(angle)) * radius
    self.minimapButton:ClearAllPoints()
    self.minimapButton:SetPoint("CENTER", "Minimap", "CENTER", -x, y)
end

-------------------------------------------------------------------------------
-- In-flight timer frame
-------------------------------------------------------------------------------

function FlightTracker:CreateTimerFrame()
    local f = CreateFrame("Frame", "FlightTrackerTimer", UIParent)
    f:SetWidth(180)
    f:SetHeight(64)
    f:SetPoint("TOP", 0, -50)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnMouseDown", function()
        if IsShiftKeyDown() and arg1 == "LeftButton" then this:StartMoving() end
    end)
    f:SetScript("OnMouseUp", function()
        if arg1 == "LeftButton" then this:StopMovingOrSizing() end
    end)
    f:Hide()
    f:SetResizable(true)
    f:SetMinResize(140, 64)
    f:SetMaxResize(300, 100)

    -- Resize grip
    local resizer = CreateFrame("Button", nil, f)
    resizer:SetWidth(16)
    resizer:SetHeight(16)
    resizer:SetPoint("BOTTOMRIGHT", -4, 4)
    resizer:SetNormalTexture(ADDON_PATH    .. "img\\sizegrabber-up.tga")
    resizer:SetHighlightTexture(ADDON_PATH .. "img\\sizegrabber-highlight.tga")
    resizer:SetPushedTexture(ADDON_PATH    .. "img\\sizegrabber-down.tga")
    resizer:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    resizer:SetScript("OnMouseUp",   function() f:StopMovingOrSizing() end)
    f.resizer = resizer

    -- Text elements
    f.destText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.destText:SetPoint("TOP", 0, -10)
    f.destText:SetText("Destination")
    f.destText:SetFont("Fonts\\FRIZQT__.TTF", 12)

    f.zoneText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.zoneText:SetPoint("TOP", f.destText, "BOTTOM", 0, -2)
    f.zoneText:SetText("Zone Name")
    f.zoneText:SetTextColor(0.7, 0.7, 0.7)
    f.zoneText:SetFont("Fonts\\FRIZQT__.TTF", 10)

    f.timerText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.timerText:SetPoint("BOTTOM", 0, 10)
    f.timerText:SetText("00:00")
    f.timerText:SetTextColor(1, 0.82, 0)
    f.timerText:SetFont("Fonts\\FRIZQT__.TTF", 16)

    -- Scale fonts on resize
    f:SetScript("OnSizeChanged", function()
        local scale = this:GetHeight() / 64
        if scale < 0.8 then scale = 0.8 end
        this.destText:SetFont("Fonts\\FRIZQT__.TTF",  12 * scale)
        this.zoneText:SetFont("Fonts\\FRIZQT__.TTF",  10 * scale)
        this.timerText:SetFont("Fonts\\FRIZQT__.TTF", 16 * scale)
    end)

    -- Help / drag hint
    local help = CreateFrame("Frame", nil, f)
    help:SetWidth(16)
    help:SetHeight(16)
    help:SetPoint("TOPRIGHT", -4, -4)
    help:EnableMouse(true)

    local helpText = help:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    helpText:SetPoint("CENTER", 0, 0)
    helpText:SetText("?")
    helpText:SetTextColor(0.5, 0.5, 0.5)

    help:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText("Shift+Drag to Move")
        GameTooltip:Show()
        helpText:SetTextColor(1, 1, 1)
    end)
    help:SetScript("OnLeave", function()
        GameTooltip:Hide()
        helpText:SetTextColor(0.5, 0.5, 0.5)
    end)
    f.help = help

    -- Timer tick
    f:SetScript("OnUpdate", function()
        if not isFlying then return end
        if not this.elapsed then this.elapsed = 0 end
        this.elapsed = this.elapsed + arg1
        if this.elapsed < 0.5 then return end
        this.elapsed = 0

        local current = GetTime() - startTime
        local text

        if this.max and this.max > 0 then
            local remaining = this.max - current
            if remaining < 0 then remaining = 0 end
            text = FlightTracker.Util.FormatTime(remaining)
        else
            text = FlightTracker.Util.FormatTime(current)
        end
        this.timerText:SetText(text)
    end)

    flightTimerFrame = f
    self:ApplyTimerBorderVisibility()
end

function FlightTracker:ApplyTimerBorderVisibility()
    if not flightTimerFrame then return end

    if FlightTrackerDB.settings.hideBorder then
        flightTimerFrame:SetBackdrop(nil)
        flightTimerFrame.resizer:Hide()
        flightTimerFrame.help:Hide()
    else
        flightTimerFrame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        flightTimerFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
        flightTimerFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        flightTimerFrame.resizer:Show()
        flightTimerFrame.help:Show()
    end
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

SLASH_FLIGHTTRACKER1 = "/ft"
SLASH_FLIGHTTRACKER2 = "/flighttracker"
SlashCmdList["FLIGHTTRACKER"] = function(msg)
    if msg == "routes" or msg == "checklist" then
        if FlightTracker.Checklist then
            FlightTracker.Checklist:Toggle()
        else
            FlightTracker:Print("Checklist module not loaded.")
        end
    elseif FlightTracker.GUI then
        FlightTracker.GUI:Toggle()
    else
        FlightTracker:Print("GUI module not loaded.")
    end
end

-------------------------------------------------------------------------------
-- Print helper
-------------------------------------------------------------------------------

function FlightTracker:Print(msg)
    local prefix = "|cffE0C709Flight|cffffffffTracker:|r"
    DEFAULT_CHAT_FRAME:AddMessage(prefix .. " " .. tostring(msg))
end
