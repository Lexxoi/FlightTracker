if not FlightTracker then return end

FlightTracker.MapIcons = {}
local MapIcons = FlightTracker.MapIcons

local ICON_KNOWN   = "Interface\\TaxiFrame\\UI-Taxi-Icon-Green"
local ICON_UNKNOWN = "Interface\\TaxiFrame\\UI-Taxi-Icon-Gray"
local MAX_ICONS    = 64
local MAX_LINES    = 64
local LINE_SIZE    = 256

-- NEW: Track the last flight master the player was at (used for tooltip + lines)
FlightTracker.currentFlightMaster = FlightTracker.currentFlightMaster or nil

local lLastZone       = nil
local lLastCont       = nil
local lOriginalUpdate = nil

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function GetDB()
    if not FlightTrackerDB.flightMasters then
        FlightTrackerDB.flightMasters = {}
    end
    return FlightTrackerDB.flightMasters
end

local function GetContinentName(index)
    local t = { GetMapContinents() }
    return t[index]
end

local lZoneNameCache = {}
local function EnsureZoneCache(contNum)
    if not lZoneNameCache[contNum] then
        lZoneNameCache[contNum] = { GetMapZones(contNum) }
    end
end

local function GetMapZoneName(contNum, zoneNum)
    EnsureZoneCache(contNum)
    return lZoneNameCache[contNum][zoneNum]
end

local function FindZoneIndex(contNum, zoneName)
    EnsureZoneCache(contNum)
    for i, name in pairs(lZoneNameCache[contNum]) do
        if name == zoneName then return i end
    end
    return nil
end

local function FindZoneIndexPartial(contNum, partial)
    EnsureZoneCache(contNum)
    for i, name in pairs(lZoneNameCache[contNum]) do
        if string.find(name, partial, 1, true) then return i, name end
    end
    return nil, nil
end

-- Parse "A -> B" flight key
local function ParseFlightKey(key)
    local sep = string.find(key, " -> ", 1, true)
    if not sep then return nil, nil end
    return string.sub(key, 1, sep - 1),
           string.sub(key, sep + 4)
end

-- NEW: Build direct hops using FlightTrackerDB.routes (true taxi connections only)
local function BuildDirectHops()
    local hops = {}
    local routes = FlightTrackerDB.routes or {}
    local faction = UnitFactionGroup("player")

    for src, dests in pairs(routes) do
        if not hops[src] then hops[src] = {} end
        for dest, tag in pairs(dests) do
            if tag == true or tag == faction or tag == "Both" then
                hops[src][dest] = true
                if not hops[dest] then hops[dest] = {} end
                hops[dest][src] = true
            end
        end
    end
    return hops
end

-------------------------------------------------------------------------------
-- Line drawing
-------------------------------------------------------------------------------

local function DrawLine(texture, x1, y1, x2, y2)
    texture:ClearAllPoints()

    local fw = WorldMapDetailFrame:GetWidth()
    local fh = WorldMapDetailFrame:GetHeight()
    local dx = math.abs((x1 - x2) * fw)
    local dy = math.abs((y1 - y2) * fh)

    if dx == 0 and dy == 0 then texture:Hide(); return false end

    if x1 > x2 then
        local tx, ty = x1, y1
        x1, y1 = x2, y2
        x2, y2 = tx, ty
    end

    if dy < 1 then dy = 1 end
    if dx < 1 then dx = 1 end

    local clipsize = dx
    if dy < dx then clipsize = dy end
    clipsize = clipsize / LINE_SIZE
    if clipsize > 1 then clipsize = 1 end

    local anchorPoint
    if y1 > y2 then
        texture:SetTexture("Interface\\AddOns\\FlightTracker\\img\\lineup")
        texture:SetTexCoord(0, clipsize, 1 - clipsize, 1)
        anchorPoint = "BOTTOMLEFT"
    else
        texture:SetTexture("Interface\\AddOns\\FlightTracker\\img\\linedown")
        texture:SetTexCoord(0, clipsize, 0, clipsize)
        anchorPoint = "TOPLEFT"
    end

    texture:SetPoint(anchorPoint, "WorldMapDetailFrame", "TOPLEFT", x1 * fw, -y1 * fh)
    texture:SetWidth(dx)
    texture:SetHeight(dy)
    texture:SetAlpha(0.7)
    texture:Show()
    return true
end

local function HideAllLines()
    for i = 1, MAX_LINES do
        local t = getglobal("FTMapLine" .. i)
        if t then t:Hide() end
    end
end

local function ShowLinesForNode(srcName)
    HideAllLines()

    if GetCurrentMapZone() ~= 0 then return end

    local db = GetDB()
    local src = db[srcName]
    if not src or not src.cx or not src.cy then return end

    local hops = BuildDirectHops()
    local srcHops = hops[srcName]
    if not srcHops then return end

    local lineIdx = 1
    for destName in pairs(srcHops) do
        if lineIdx > MAX_LINES then break end
        local dest = db[destName]
        if dest and dest.cx and dest.cy then
            local tex = getglobal("FTMapLine" .. lineIdx)
            if tex and DrawLine(tex, src.cx, src.cy, dest.cx, dest.cy) then
                lineIdx = lineIdx + 1
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Tooltip (CHANGED: now shows flight time from your current location)
-------------------------------------------------------------------------------

function FlightTracker_MapIcon_OnEnter(button)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    if button.nodeName then
        local comma = string.find(button.nodeName, ", ", 1, true)
        local town  = button.nodeName
        local zone  = button.nodeName
        if comma then
            town = string.sub(button.nodeName, 1, comma - 1)
            zone = string.sub(button.nodeName, comma + 2)
        end
        GameTooltip:SetText(town, 1, 0.82, 0)
        if zone ~= town then
            GameTooltip:AddLine(zone, 0.7, 0.7, 0.7)
        end

        -- NEW: Show flight time from current flight master instead of "X direct routes timed"
        local origin = FlightTracker.currentFlightMaster
        if origin and origin ~= button.nodeName then
            local key = origin .. " -> " .. button.nodeName
            local duration = FlightTrackerDB.flights[key]

            if not duration then
                local reverseKey = button.nodeName .. " -> " .. origin
                duration = FlightTrackerDB.flights[reverseKey]
            end

            local isEstimated = false
            if not duration then
                duration = FlightTracker:GetEstimatedFlightTime(origin, button.nodeName)
                if duration then isEstimated = true end
            end

            if duration then
                if isEstimated then
                    GameTooltip:AddLine("Estimated: " .. FlightTracker.Util.FormatTime(duration), 0.4, 0.8, 1)
                else
                    GameTooltip:AddLine("Flight time: " .. FlightTracker.Util.FormatTime(duration), 1, 1, 1)
                end
            else
                GameTooltip:AddLine("No flight time recorded yet", 0.5, 0.5, 0.5)
        end

        -- Draw only true direct lines (gryphon-master style)
        ShowLinesForNode(button.nodeName)
    end
    GameTooltip:Show()
end

function FlightTracker_MapIcon_OnLeave(button)
    GameTooltip:Hide()
    HideAllLines()
end

-------------------------------------------------------------------------------
-- Icon drawing (unchanged)
-------------------------------------------------------------------------------

local function PlaceIcon(idx, nodeName, px, py)
    local b = getglobal("FTMapIcon" .. idx)
    if not b then return false end
    b:ClearAllPoints()
    b:SetPoint("CENTER", "WorldMapDetailFrame", "BOTTOMLEFT", px, py)
    b.nodeName = nodeName
    if FlightTrackerDB.routes and FlightTrackerDB.routes[nodeName] then
        b:SetNormalTexture(ICON_KNOWN)
    else
        b:SetNormalTexture(ICON_UNKNOWN)
    end
    b:Show()
    return true
end

local function RefreshIcons()
    local zoneNum = GetCurrentMapZone()
    local contNum = GetCurrentMapContinent()

    if (FlightTrackerDB.settings and FlightTrackerDB.settings.showMapIcons == false)
    or contNum == 0 or contNum == -1 then
        for i = 1, MAX_ICONS do getglobal("FTMapIcon" .. i):Hide() end
        HideAllLines()
        return
    end

    local db      = GetDB()
    local fw      = WorldMapDetailFrame:GetWidth()
    local fh      = WorldMapDetailFrame:GetHeight()
    local iconIdx = 1

    HideAllLines()

    if zoneNum == 0 then
        local contName = GetContinentName(contNum)
        for nodeName, data in pairs(db) do
            if data.continent == contName and data.cx and data.cy and iconIdx <= MAX_ICONS then
                local px = data.cx * fw
                local py = (1 - data.cy) * fh
                if PlaceIcon(iconIdx, nodeName, px, py) then
                    iconIdx = iconIdx + 1
                end
            end
        end
    else
        local currentZone = GetMapZoneName(contNum, zoneNum)
        for nodeName, data in pairs(db) do
            if iconIdx > MAX_ICONS then break end
            local px, py = nil, nil

            if data.zone == currentZone and data.zx and data.zy then
                px = data.zx * fw
                py = (1 - data.zy) * fh
            elseif data.cityZoneName == currentZone and data.city_zx and data.city_zy then
                px = data.city_zx * fw
                py = (1 - data.city_zy) * fh
            end

            if px and py then
                if PlaceIcon(iconIdx, nodeName, px, py) then
                    iconIdx = iconIdx + 1
                end
            end
        end
    end

    for i = iconIdx, MAX_ICONS do getglobal("FTMapIcon" .. i):Hide() end
end

-------------------------------------------------------------------------------
-- OnLoad & Registration
-------------------------------------------------------------------------------

function FlightTracker_MapIcons_OnLoad()
    lOriginalUpdate = WorldMapButton_OnUpdate
    WorldMapButton_OnUpdate = function(arg1)
        lOriginalUpdate(arg1)
        local zoneNum = GetCurrentMapZone()
        local contNum = GetCurrentMapContinent()
        if zoneNum == lLastZone and contNum == lLastCont then return end
        lLastZone = zoneNum
        lLastCont = contNum
        RefreshIcons()
    end
end

function MapIcons:RegisterCurrentFlightMaster()
    local nodeName = FlightTracker.Util.GetCurrentFlightNode()
    if not nodeName or nodeName == "" then return end

    local ticker = CreateFrame("Frame")
    ticker:SetScript("OnUpdate", function()
        this:SetScript("OnUpdate", nil)

        local savedCont = GetCurrentMapContinent()
        local savedZone = GetCurrentMapZone()

        local townName = nodeName
        local zoneName = nodeName
        local comma = string.find(nodeName, ", ", 1, true)
        if comma then
            townName = string.sub(nodeName, 1, comma - 1)
            zoneName = string.sub(nodeName, comma + 2)
        end

        SetMapToCurrentZone()
        local contNum = GetCurrentMapContinent()

local zoneNum = FindZoneIndex(contNum, zoneName)
if not zoneNum then
    -- Taxi node zone names are sometimes shortened (e.g. "Redridge" vs "Redridge Mountains")
    -- Fall back to partial match
    local partialNum, partialName = FindZoneIndexPartial(contNum, zoneName)
    if partialNum then
        zoneNum = partialNum
        zoneName = partialName  -- use the real zone name for storage
    end
end
if not zoneNum then
    SetMapZoom(savedCont, savedZone)
    return
end

        SetMapZoom(contNum, zoneNum)
        local zx, zy = GetPlayerMapPosition("player")

        SetMapZoom(contNum, nil)
        local cx, cy = GetPlayerMapPosition("player")

        local cityZoneNum, cityZoneName = FindZoneIndexPartial(contNum, townName)
        local city_zx, city_zy = nil, nil
        if cityZoneNum and cityZoneNum ~= zoneNum then
            SetMapZoom(contNum, cityZoneNum)
            city_zx, city_zy = GetPlayerMapPosition("player")
        end

        SetMapZoom(savedCont, savedZone)

        if not zx or not zy or not cx or not cy then return end

        local contName = GetContinentName(contNum)
        if not contName then return end

        local db = GetDB()
        if not db[nodeName] then db[nodeName] = {} end

        local e     = db[nodeName]
        e.continent = contName
        e.zone      = zoneName
        e.zoneNum   = zoneNum
        e.cx        = cx
        e.cy        = cy
        e.zx        = zx
        e.zy        = zy

        if cityZoneNum and city_zx and city_zy then
            e.cityZoneName = cityZoneName
            e.cityZoneNum  = cityZoneNum
            e.city_zx      = city_zx
            e.city_zy      = city_zy
        else
            e.cityZoneName = nil
            e.cityZoneNum  = nil
            e.city_zx      = nil
            e.city_zy      = nil
        end

        -- NEW: Store current flight master so tooltip/lines know where you are
        FlightTracker.currentFlightMaster = nodeName
    end)
end

function FlightTracker.MapIcons.Refresh()
    RefreshIcons()
end
