local CreateFrame = CreateFrame
local GetTime = GetTime
local UnitOnTaxi = UnitOnTaxi
local TaxiNodeGetType = TaxiNodeGetType
local TaxiNodeName = TaxiNodeName
local TaxiNodeCost = TaxiNodeCost
local GetZoneText = GetZoneText
local UnitName = UnitName
local GetNumRaidMembers = GetNumRaidMembers
local GetNumPartyMembers = GetNumPartyMembers
local SendChatMessage = SendChatMessage
local GetPlayerBuff = GetPlayerBuff
local CancelPlayerBuff = CancelPlayerBuff
local GetCursorPosition = GetCursorPosition
local tinsert = tinsert

FlightTracker = CreateFrame("Frame", "FlightTracker")
FlightTracker:SetScript("OnEvent", function()
    if FlightTracker[event] then FlightTracker[event](FlightTracker) end
end)

FlightTracker:RegisterEvent("ADDON_LOADED")
FlightTracker:RegisterEvent("PLAYER_ENTERING_WORLD")
FlightTracker:RegisterEvent("TAXIMAP_OPENED")

local ADDON_PATH = "Interface\\AddOns\\FlightTracker\\"

local isFlying = false
local isPending = false 
local pendingDestName = nil
local pendingCost = 0

local startTime = 0
local originNode = nil
local destNode = nil
local flightTimerFrame = nil

local isTooltipHooked = false
local original_TaxiNodeOnButtonEnter = nil
local cachedOriginNode = nil

StaticPopupDialogs["FLIGHTTRACKER_CONFIRM"] = {
    text = "Fly to %s?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function(data)
        FlightTracker.confirming = true
        TakeTaxiNode(data.index)
        FlightTracker.confirming = false
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1
}

function FlightTracker:ADDON_LOADED()
    if arg1 ~= "FlightTracker" then return end

    local playerName = UnitName("player")

    if not FlightTrackerDB then FlightTrackerDB = {} end
    
    if not FlightTrackerDB.flights then FlightTrackerDB.flights = {} end
    if not FlightTrackerDB.routes then FlightTrackerDB.routes = {} end
    if not FlightTrackerDB.checklistExpanded then FlightTrackerDB.checklistExpanded = {} end

    if not FlightTrackerDB.estimatedCache then 
        FlightTrackerDB.estimatedCache = {} 
    end
    
    if not FlightTrackerDB.char then FlightTrackerDB.char = {} end
    if not FlightTrackerDB.char[playerName] then FlightTrackerDB.char[playerName] = {} end

    if not FlightTrackerDB.char[playerName].stats then 
        FlightTrackerDB.char[playerName].stats = {
            totalFlights = 0,
            totalTime = 0,
            totalGold = 0,
            longestFlight = { duration = 0, route = "None" }
        }
    end

    self.charStats = FlightTrackerDB.char[playerName].stats

    -- NEW: Just restore the raw lastFlightMaster for now
    if FlightTrackerDB.lastFlightMaster then
        FlightTracker.currentFlightMaster = FlightTrackerDB.lastFlightMaster
    else
        FlightTracker.currentFlightMaster = nil
    end

    local defaultSettings = {
        showTimer = true,
        autoDismount = true,
        confirmFlight = false,
        announceFlight = false,
        minimapPos = 45,
        showMinimapButton = true,
        lockPosition = false,
        hideBorder = false
    }

    if not FlightTrackerDB.settings then 
        FlightTrackerDB.settings = {}
    end

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

function FlightTracker:PLAYER_ENTERING_WORLD()
    if UnitOnTaxi("player") then
        isFlying = true
        startTime = GetTime()
        destNode = "Unknown"
        flightTimerFrame.destText:SetText("In Flight")
        flightTimerFrame.zoneText:SetText("")
        flightTimerFrame.max = 0
        flightTimerFrame:Show()
        self:StartMonitor()
    else
         -- If we were flying but got ported (summon, BG, etc.) discard the flight
        if isFlying or isPending then
            isFlying = false
            isPending = false
            startTime = 0
            originNode = nil
            destNode = nil
            pendingDestName = nil
            flightTimerFrame:Hide()
            self:StopMonitor()
            --self:Print("Flight interrupted — time not recorded.")
        end
        
        -- NEW: Convert zone name to actual flight master name
        local currentZone = GetZoneText()
        --self:Print("DEBUG: Current zone = " .. tostring(currentZone))
        --self:Print("DEBUG: currentFlightMaster before = " .. tostring(FlightTracker.currentFlightMaster))
        
        -- If currentFlightMaster is just a zone name, convert it to a real flight master
        if FlightTracker.currentFlightMaster then
            -- Check if it's already a valid flight master name
            if not (FlightTrackerDB.routes and FlightTrackerDB.routes[FlightTracker.currentFlightMaster]) then
                -- It's not a valid flight master, try to find one in current zone
                local foundMaster = FlightTracker:FindFlightMasterInZone(currentZone)
                if foundMaster then
                    FlightTracker.currentFlightMaster = foundMaster
                    FlightTrackerDB.lastFlightMaster = foundMaster
                end
            end
        else
            -- No currentFlightMaster set, find one in current zone
            local foundMaster = FlightTracker:FindFlightMasterInZone(currentZone)
            if foundMaster then
                FlightTracker.currentFlightMaster = foundMaster
                FlightTrackerDB.lastFlightMaster = foundMaster
            end
        end
        
        --self:Print("DEBUG: currentFlightMaster after = " .. tostring(FlightTracker.currentFlightMaster))
    end
end

function FlightTracker:TAXIMAP_OPENED()
    cachedOriginNode = FlightTracker.Util.GetCurrentFlightNode()
    self:ScanRoutes()
    if FlightTrackerDB.settings.autoDismount then
        self:DismountPlayer()
    end
    self:HookTaxiMap()

    -- NEW: Register flight master location
    if FlightTracker.MapIcons then
        FlightTracker.MapIcons:RegisterCurrentFlightMaster()
    end
end

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
            local current = FlightTrackerDB.routes[currentNode][nodeName]
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

-- Register the event at the top with the others
FlightTracker:RegisterEvent("ZONE_CHANGED_NEW_AREA")

function FlightTracker:ZONE_CHANGED_NEW_AREA()
    if UnitOnTaxi("player") then return end

    local newZone = GetZoneText()
    local found = FlightTracker:FindFlightMasterInZone(newZone)
    if found then
        FlightTracker.currentFlightMaster = found
        FlightTrackerDB.lastFlightMaster = found
        -- Clear cached estimates since our origin changed
        FlightTrackerDB.estimatedCache = {}
    end
end

function FlightTracker:GetEstimatedFlightTime(origin, destination)
    if not origin or not destination then return nil end
    if origin == destination then return 0 end

    local cacheKey = origin .. "|" .. destination
    if FlightTrackerDB.estimatedCache and FlightTrackerDB.estimatedCache[cacheKey] ~= nil then
        return FlightTrackerDB.estimatedCache[cacheKey] or nil
    end

    -- Dijkstra: always expand the lowest-cost node first
    local dist = {}
    local visited = {}
    dist[origin] = 0

    while true do
        -- Find unvisited node with lowest cost
        local current, currentDist = nil, nil
        for node, d in pairs(dist) do
            if not visited[node] then
                if currentDist == nil or d < currentDist then
                    current = node
                    currentDist = d
                end
            end
        end

        if not current then break end
        if current == destination then
            if FlightTrackerDB.estimatedCache then
                FlightTrackerDB.estimatedCache[cacheKey] = currentDist
            end
            return currentDist
        end

        visited[current] = true

        local routes = FlightTrackerDB.routes[current]
        if routes then
            for nextNode in pairs(routes) do
                if not visited[nextNode] then
                    local key = current .. " -> " .. nextNode
                    local reverseKey = nextNode .. " -> " .. current
                    local duration = FlightTrackerDB.flights[key] or FlightTrackerDB.flights[reverseKey]

                    if duration then
                        local newDist = currentDist + duration
                        if dist[nextNode] == nil or newDist < dist[nextNode] then
                            dist[nextNode] = newDist
                        end
                    end
                end
            end
        end
    end

    if FlightTrackerDB.estimatedCache then
        FlightTrackerDB.estimatedCache[cacheKey] = false
    end
    return nil
end

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
                    dialog.data = {index = index, name = destName}
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
        if index then
            local nodeType = TaxiNodeGetType(index)

            if nodeType == "REACHABLE" then
                local destName = TaxiNodeName(index)
                local origin = cachedOriginNode or FlightTracker.Util.GetCurrentFlightNode()
            
                local key = origin .. " -> " .. destName
                local duration = FlightTrackerDB.flights[key]

                -- Try reverse route
                if not duration then
                    local reverseKey = destName .. " -> " .. origin
                    duration = FlightTrackerDB.flights[reverseKey]
                end

                -- Try calculated multi-hop route
                if not duration then
                    duration = FlightTracker:GetEstimatedFlightTime(origin, destName)
                end
            
                local timeText = "--:--"
                if duration then
                    timeText = FlightTracker.Util.FormatTime(duration)
                end
                
                GameTooltip:AddLine("Flight Time: " .. timeText, 1, 1, 1)
                GameTooltip:Show()
            end
        end
    end

    isTooltipHooked = true
end


function FlightTracker:PrepareFlight(index, destName)
    isPending = true
    pendingDestName = destName
    pendingCost = TaxiNodeCost(index)
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
    
    -- Throttle the updates to 5 times a second
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
    isFlying = true
    startTime = GetTime()
    destNode = destination
    
    -- Update Character Stats
    if self.charStats then
        self.charStats.totalGold = self.charStats.totalGold + (cost or 0)
        self.charStats.totalFlights = self.charStats.totalFlights + 1
    end

    originNode = cachedOriginNode or FlightTracker.Util.GetCurrentFlightNode()

    local key = originNode .. " -> " .. destNode
    local knownDuration = FlightTrackerDB.flights[key]

    -- Try reverse
    if not knownDuration then
        local reverseKey = destNode .. " -> " .. originNode
        knownDuration = FlightTrackerDB.flights[reverseKey]
    end

    -- Try estimated multi-hop route (your function)
    if not knownDuration then
        knownDuration = FlightTracker:GetEstimatedFlightTime(originNode, destNode)
    end
    
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

    local endTime = GetTime()
    local duration = endTime - startTime
    
    if originNode and destNode and duration > 10 then
        local key = originNode .. " -> " .. destNode
            local reverseKey = destNode .. " -> " .. originNode
            local existing = FlightTrackerDB.flights[key]
            local reverseExisting = FlightTrackerDB.flights[reverseKey]

            if not existing or math.abs(duration - existing) > 1 then
                FlightTrackerDB.flights[key] = duration
            end
            if not reverseExisting or math.abs(duration - reverseExisting) > 1 then
                FlightTrackerDB.flights[reverseKey] = duration
            end
            -- clear the cache
            if (not existing or math.abs(duration - existing) > 1) or (not reverseExisting or math.abs(duration - reverseExisting) > 1) then
                FlightTrackerDB.estimatedCache = {}
            else
                -- Always invalidate estimated routes involving this destination
                for key in pairs(FlightTrackerDB.estimatedCache) do
                    if string.find(key, originNode, 1, true) or string.find(key, destNode, 1, true) then
                        FlightTrackerDB.estimatedCache[key] = nil
                    end
                end
end
        
        -- Save statistics LOCALLY (Per Character)
        if self.charStats then
            self.charStats.totalTime = self.charStats.totalTime + duration
            
            if type(self.charStats.longestFlight) ~= "table" then
                self.charStats.longestFlight = { duration = self.charStats.longestFlight or 0, route = "" }
            end

            if duration > self.charStats.longestFlight.duration then
                self.charStats.longestFlight.duration = duration
                self.charStats.longestFlight.route = key
            end
        end
        
        --self:Print("Landed at " .. destNode .. ". Time: " .. self.Util.FormatTime(duration))

        if FlightTracker.GUI then FlightTracker.GUI:UpdateStats() end
        if FlightTracker.Checklist and FlightTracker.Checklist:IsOpen() then
            FlightTracker.Checklist:Refresh()
        end
    end
    
    -- NEW: Update current flight master to the destination we just landed at
    FlightTracker.currentFlightMaster = destNode
    FlightTrackerDB.lastFlightMaster = destNode
    
    startTime = 0
    originNode = nil
    destNode = nil
    self:StopMonitor()
end

function FlightTracker:FindFlightMasterInZone(zoneName)
    -- Search through known flight masters database (from mapicons)
    if FlightTrackerDB.flightMasters then
        for flightMasterName, data in pairs(FlightTrackerDB.flightMasters) do
            if data.zone == zoneName then
                return flightMasterName
            end
        end
    end
    
    -- Search through known routes to find a flight master location in this zone
    if FlightTrackerDB.routes then
        for flightMasterName in pairs(FlightTrackerDB.routes) do
            -- Check if the flight master name contains the zone name
            -- e.g., "Stormwind, Elwynn Forest" contains "Elwynn Forest"
            if string.find(flightMasterName, zoneName, 1, true) then
                return flightMasterName
            end
        end
    end
    
    return nil
end

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

function FlightTracker:CreateMinimapButton()
    if self.minimapButton then return end

    local b = CreateFrame("Button", "FlightTrackerMinimapButton", Minimap)
    b:SetWidth(32)
    b:SetHeight(32)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)

    local iconTexture = ADDON_PATH .. "img\\flight"

    local t = b:CreateTexture(nil, "BACKGROUND")
    t:SetTexture(iconTexture)
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
    
    b:SetScript("OnDragStop", function() this:UnlockHighlight() this.isDragging = false end)
    b:SetScript("OnUpdate", function()
        if this.isDragging then
            local xpos, ypos = GetCursorPosition()
            local xmin, ymin = Minimap:GetLeft(), Minimap:GetBottom()
            xpos = xmin - xpos / UIParent:GetScale() + 70
            ypos = ypos / UIParent:GetScale() - ymin - 70
            
            local angle = math.deg(math.atan2(ypos, xpos))
            FlightTrackerDB.settings.minimapPos = angle
            FlightTracker:UpdateMinimapButtonPosition()
        end
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
    local angle = FlightTrackerDB.settings.minimapPos or 45
    local radius = 80
    local x = math.cos(math.rad(angle)) * radius
    local y = math.sin(math.rad(angle)) * radius
    
    self.minimapButton:ClearAllPoints()
    self.minimapButton:SetPoint("CENTER", "Minimap", "CENTER", -x, y)
end

function FlightTracker:CreateTimerFrame()
    local f = CreateFrame("Frame", "FlightTrackerTimer", UIParent)
    f:SetWidth(180)
    f:SetHeight(64)
    f:SetPoint("TOP", 0, -50)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", 
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    
    f:SetScript("OnMouseDown", function() 
        if IsShiftKeyDown() and arg1 == "LeftButton" then 
            this:StartMoving() 
        end 
    end)
    f:SetScript("OnMouseUp", function() 
        if arg1 == "LeftButton" then this:StopMovingOrSizing() end 
    end)
    f:Hide()

    f:SetResizable(true)
    f:SetMinResize(140, 64)
    f:SetMaxResize(300, 100)

    local resizer = CreateFrame("Button", nil, f)
    resizer:SetWidth(16)
    resizer:SetHeight(16)
    resizer:SetPoint("BOTTOMRIGHT", -4, 4)
    resizer:SetNormalTexture(ADDON_PATH .. "img\\sizegrabber-up.tga")
    resizer:SetHighlightTexture(ADDON_PATH .. "img\\sizegrabber-highlight.tga")
    resizer:SetPushedTexture(ADDON_PATH .. "img\\sizegrabber-down.tga")
    resizer:SetScript("OnMouseDown", function() 
        f:StartSizing("BOTTOMRIGHT")
    end)
    resizer:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
    end)
    f.resizer = resizer

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
    
    f:SetScript("OnSizeChanged", function()
        local h = this:GetHeight()
        local scale = h / 64
        if scale < 0.8 then scale = 0.8 end
        
        this.destText:SetFont("Fonts\\FRIZQT__.TTF", 12 * scale)
        this.zoneText:SetFont("Fonts\\FRIZQT__.TTF", 10 * scale)
        this.timerText:SetFont("Fonts\\FRIZQT__.TTF", 16 * scale)
    end)
    
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

    f:SetScript("OnUpdate", function()
        if not isFlying then return end

        if not this.elapsed then this.elapsed = 0 end
        this.elapsed = this.elapsed + arg1
        if this.elapsed < 0.5 then return end
        this.elapsed = 0
        
        local current = GetTime() - startTime
        local text = ""
        
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
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        flightTimerFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
        flightTimerFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        flightTimerFrame.resizer:Show()
        flightTimerFrame.help:Show()
    end
end

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

function FlightTracker:Print(msg)
    local prefix = "|cffE0C709Flight|cffffffffTracker:|r"
    DEFAULT_CHAT_FRAME:AddMessage(prefix .. " " .. tostring(msg))
end
