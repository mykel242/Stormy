-- MyCombatEntityMapWindow.lua
-- Real-time entity tracking window for combat analysis
-- Shows all entities appearing in combat events with counters

local addonName, addon = ...

-- =============================================================================
-- COMBAT ENTITY MAP WINDOW MODULE
-- =============================================================================

local MyCombatEntityMapWindow = {}
addon.MyCombatEntityMapWindow = MyCombatEntityMapWindow

-- =============================================================================
-- CONSTANTS AND CONFIGURATION
-- =============================================================================

local WINDOW_WIDTH = 400
local WINDOW_HEIGHT = 300

-- =============================================================================
-- UI ELEMENTS AND STATE
-- =============================================================================

local entityWindow = nil
local entityScrollFrame = nil
local entityEditBox = nil
local isVisible = false

-- Entity tracking state
local entityMap = {} -- GUID -> { name, count, flags, type }
local combatStartTime = 0
local lastUpdateTime = 0
local UPDATE_INTERVAL = 0.1 -- Update display every 0.1 seconds for real-time feel

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

function MyCombatEntityMapWindow:Initialize()
    addon:Debug("MyCombatEntityMapWindow: Initialize called")
end

function MyCombatEntityMapWindow:SetupSubscriptions()
    addon:Debug("MyCombatEntityMapWindow: Setting up message queue subscriptions")
    
    if not addon.CombatEventQueue then
        addon:Warn("MyCombatEntityMapWindow: CombatEventQueue not available")
        return
    end
    
    -- Subscribe to combat state changes
    self.combatStateSubscriberId = addon.CombatEventQueue:Subscribe(
        "COMBAT_STATE_CHANGED", 
        function(message)
            self:OnCombatStateChanged(message.data)
        end,
        "EntityMapWindow_StateTracker"
    )
    
    -- Subscribe to damage events
    self.damageSubscriberId = addon.CombatEventQueue:Subscribe(
        "DAMAGE_EVENT", 
        function(message)
            self:OnCombatEvent(message.data, "DAMAGE")
        end,
        "EntityMapWindow_DamageTracker"
    )
    
    -- Subscribe to healing events
    self.healSubscriberId = addon.CombatEventQueue:Subscribe(
        "HEAL_EVENT", 
        function(message)
            self:OnCombatEvent(message.data, "HEAL")
        end,
        "EntityMapWindow_HealTracker"
    )
    
    -- Subscribe to ALL raw combat events (unfiltered debugging)
    self.rawEventsSubscriberId = addon.CombatEventQueue:Subscribe(
        "RAW_COMBAT_EVENT", 
        function(message)
            self:OnRawCombatEvent(message.data)
        end,
        "EntityMapWindow_RawTracker"
    )
    
    addon:Info("MyCombatEntityMapWindow: Combat event queue subscriptions established")
end

-- =============================================================================
-- EVENT HANDLERS
-- =============================================================================

-- Handle combat state changes
function MyCombatEntityMapWindow:OnCombatStateChanged(stateData)
    if stateData.inCombat then
        self:StartCombat(stateData.startTime)
    else
        self:EndCombat()
    end
end

-- Handle combat events (damage/heal)
function MyCombatEntityMapWindow:OnCombatEvent(eventData, eventType)
    if not eventData or not eventData.source then
        return
    end
    
    local sourceGUID = eventData.source
    local sourceName = eventData.sourceName or "Unknown"
    local sourceFlags = eventData.sourceFlags
    
    -- Track the entity
    self:TrackEntity(sourceGUID, sourceName, sourceFlags, eventType)
end

-- Handle raw combat log events (ALL events, unfiltered)
function MyCombatEntityMapWindow:OnRawCombatEvent(eventData)
    if not eventData then
        return
    end
    
    -- Track both source and destination entities from raw events
    if eventData.sourceGUID and eventData.sourceName then
        self:TrackEntity(eventData.sourceGUID, eventData.sourceName, eventData.sourceFlags, 
            "RAW_" .. (eventData.eventType or "UNKNOWN"))
    end
    
    if eventData.destGUID and eventData.destName and 
       eventData.destGUID ~= eventData.sourceGUID then -- Don't double-count self-targeted events
        self:TrackEntity(eventData.destGUID, eventData.destName, eventData.destFlags, 
            "RAW_TARGET")
    end
end


-- Common entity tracking function
function MyCombatEntityMapWindow:TrackEntity(guid, name, flags, eventType)
    if not guid then
        return
    end
    
    -- Handle empty GUID case
    if guid == "" then
        guid = "EMPTY_GUID"
        name = name or "Unknown (Empty GUID)"
    end
    
    -- Track the entity
    if not entityMap[guid] then
        entityMap[guid] = {
            name = name or "Unknown",
            count = 0,
            flags = flags,
            type = self:DetermineEntityType(guid, flags),
            lastSeen = GetTime(),
            eventTypes = {}
        }
    end
    
    entityMap[guid].count = entityMap[guid].count + 1
    entityMap[guid].lastSeen = GetTime()
    
    -- Track what types of events this entity generates
    if not entityMap[guid].eventTypes[eventType] then
        entityMap[guid].eventTypes[eventType] = 0
    end
    entityMap[guid].eventTypes[eventType] = entityMap[guid].eventTypes[eventType] + 1
    
    -- Schedule display update
    self:ScheduleUpdate()
end

-- Determine entity type from GUID and flags
function MyCombatEntityMapWindow:DetermineEntityType(guid, flags)
    if not guid then
        return "Unknown"
    end
    
    -- Parse GUID type
    local guidType = string.match(guid, "^([^-]+)")
    
    if not flags then
        return guidType or "Unknown"
    end
    
    -- Check combat log flags
    local typeFlags = {}
    
    if bit.band(flags, 0x00000400) ~= 0 then -- COMBATLOG_OBJECT_TYPE_PLAYER
        table.insert(typeFlags, "Player")
    end
    if bit.band(flags, 0x00000800) ~= 0 then -- COMBATLOG_OBJECT_TYPE_NPC
        table.insert(typeFlags, "NPC")
    end
    if bit.band(flags, 0x00001000) ~= 0 then -- COMBATLOG_OBJECT_TYPE_PET
        table.insert(typeFlags, "Pet")
    end
    if bit.band(flags, 0x00002000) ~= 0 then -- COMBATLOG_OBJECT_TYPE_GUARDIAN
        table.insert(typeFlags, "Guardian")
    end
    if bit.band(flags, 0x00004000) ~= 0 then -- COMBATLOG_OBJECT_TYPE_OBJECT
        table.insert(typeFlags, "Object")
    end
    
    -- Check affiliation
    local affiliation = bit.band(flags, 0x0000000F)
    if affiliation == 0x00000001 then -- COMBATLOG_OBJECT_AFFILIATION_MINE
        table.insert(typeFlags, "Mine")
    elseif affiliation == 0x00000002 then -- COMBATLOG_OBJECT_AFFILIATION_PARTY
        table.insert(typeFlags, "Party")
    elseif affiliation == 0x00000004 then -- COMBATLOG_OBJECT_AFFILIATION_RAID
        table.insert(typeFlags, "Raid")
    elseif affiliation == 0x00000008 then -- COMBATLOG_OBJECT_AFFILIATION_OUTSIDER
        table.insert(typeFlags, "Outsider")
    end
    
    local typeString = guidType or "Unknown"
    if #typeFlags > 0 then
        typeString = typeString .. " (" .. table.concat(typeFlags, ", ") .. ")"
    end
    
    return typeString
end

-- =============================================================================
-- COMBAT STATE MANAGEMENT
-- =============================================================================

-- Start combat tracking
function MyCombatEntityMapWindow:StartCombat(startTime)
    combatStartTime = startTime or GetTime()
    entityMap = {} -- Clear entity map
    lastUpdateTime = 0 -- Reset update timer to allow immediate update
    
    -- Update display immediately
    self:UpdateDisplay()
    
    addon:Debug("MyCombatEntityMapWindow: Combat started, entity map cleared")
end

-- End combat tracking
function MyCombatEntityMapWindow:EndCombat()
    addon:Debug("MyCombatEntityMapWindow: Combat ended")
    -- Don't clear the map - keep it for analysis
end

-- =============================================================================
-- UI CREATION AND MANAGEMENT
-- =============================================================================

-- Create the main entity window
function MyCombatEntityMapWindow:CreateWindow()
    if entityWindow then return end
    
    addon:Debug("Creating MyCombatEntityMapWindow...")
    
    -- Create main frame (use simpler template)
    entityWindow = CreateFrame("Frame", addonName .. "CombatEntityMapWindow", UIParent, "BasicFrameTemplate")
    entityWindow:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    entityWindow:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    entityWindow:SetMovable(true)
    entityWindow:EnableMouse(true)
    entityWindow:RegisterForDrag("LeftButton")
    entityWindow:SetScript("OnDragStart", entityWindow.StartMoving)
    entityWindow:SetScript("OnDragStop", entityWindow.StopMovingOrSizing)
    entityWindow:Hide()
    
    -- Set title
    entityWindow.TitleText:SetText("Combat Entity Map")
    
    -- Close button behavior
    entityWindow.CloseButton:SetScript("OnClick", function()
        self:Hide()
    end)
    
    -- Create scroll frame for entity list (anchor to main frame, not Inset)
    entityScrollFrame = CreateFrame("ScrollFrame", nil, entityWindow, "UIPanelScrollFrameTemplate")
    entityScrollFrame:SetPoint("TOPLEFT", entityWindow, "TOPLEFT", 10, -25)
    entityScrollFrame:SetPoint("BOTTOMRIGHT", entityWindow, "BOTTOMRIGHT", -30, 10)
    
    -- Create edit box for selectable text
    entityEditBox = CreateFrame("EditBox", nil, entityScrollFrame)
    entityEditBox:SetMultiLine(true)
    entityEditBox:SetFontObject(ChatFontNormal)
    entityEditBox:SetWidth(WINDOW_WIDTH - 50)
    entityEditBox:SetHeight(WINDOW_HEIGHT - 50) -- Set to fill available space
    entityEditBox:SetAutoFocus(false)
    entityEditBox:EnableMouse(true)
    entityEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    entityEditBox:SetPoint("TOPLEFT", 0, 0)
    entityEditBox:SetJustifyH("LEFT")
    entityEditBox:SetJustifyV("TOP")
    
    entityScrollFrame:SetScrollChild(entityEditBox)
    
    -- Set up subscriptions after window creation
    self:SetupSubscriptions()
    
    -- Register with FocusManager
    if addon.FocusManager then
        addon.FocusManager:RegisterWindow(entityWindow, nil, "MEDIUM")
    end
    
    addon:Debug("MyCombatEntityMapWindow creation complete")
end

-- =============================================================================
-- DISPLAY UPDATE FUNCTIONS
-- =============================================================================

-- Schedule a display update
function MyCombatEntityMapWindow:ScheduleUpdate()
    local currentTime = GetTime()
    if currentTime - lastUpdateTime < UPDATE_INTERVAL then
        -- Still schedule an update for later if window is visible
        if entityWindow and entityWindow:IsVisible() and not self.pendingUpdate then
            self.pendingUpdate = true
            C_Timer.After(UPDATE_INTERVAL, function()
                self.pendingUpdate = false
                self:UpdateDisplay()
            end)
        end
        return
    end
    
    lastUpdateTime = currentTime
    self:UpdateDisplay()
end

-- Update the entity display
function MyCombatEntityMapWindow:UpdateDisplay()
    if not entityWindow or not entityWindow:IsVisible() then
        return
    end
    
    -- Build display text
    local lines = {}
    table.insert(lines, "=== Combat Entity Map ===")
    table.insert(lines, string.format("Combat Time: %.1fs", GetTime() - combatStartTime))
    table.insert(lines, string.format("Entities: %d", self:CountEntities()))
    table.insert(lines, "")
    
    -- Sort entities by count (descending)
    local sortedEntities = {}
    for guid, data in pairs(entityMap) do
        table.insert(sortedEntities, {guid = guid, data = data})
    end
    
    table.sort(sortedEntities, function(a, b)
        return a.data.count > b.data.count
    end)
    
    -- Add entity entries
    for _, entry in ipairs(sortedEntities) do
        local guid = entry.guid
        local data = entry.data
        local line = string.format("%s: %d events (%s)", 
            data.name, data.count, data.type)
        table.insert(lines, line)
        table.insert(lines, string.format("  GUID: %s", guid))
        if data.flags then
            table.insert(lines, string.format("  Flags: 0x%08X", data.flags))
        end
        
        -- Show event type breakdown
        if data.eventTypes and next(data.eventTypes) then
            local eventTypesStr = {}
            for eventType, count in pairs(data.eventTypes) do
                table.insert(eventTypesStr, string.format("%s:%d", eventType, count))
            end
            table.insert(lines, string.format("  Events: %s", table.concat(eventTypesStr, ", ")))
        end
        
        table.insert(lines, "")
    end
    
    -- Update the edit box
    local displayText = table.concat(lines, "\n")
    entityEditBox:SetText(displayText)
    
    -- Adjust edit box height to content (use fixed line height to avoid nil errors)
    local lineHeight = 14 -- Fixed line height, don't rely on GetLineHeight()
    local numLines = #lines
    local newHeight = math.max(WINDOW_HEIGHT - 50, numLines * lineHeight + 20)
    entityEditBox:SetHeight(newHeight)
    
    -- Force scroll frame to update
    if entityScrollFrame and entityScrollFrame.UpdateScrollChildRect then
        entityScrollFrame:UpdateScrollChildRect()
    end
end

-- Count total entities
function MyCombatEntityMapWindow:CountEntities()
    local count = 0
    for _ in pairs(entityMap) do
        count = count + 1
    end
    return count
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

-- Show/Hide functions
function MyCombatEntityMapWindow:Show()
    if not entityWindow then
        self:CreateWindow()
    end
    
    entityWindow:Show()
    isVisible = true
    self:UpdateDisplay()
    addon:Debug("Combat entity map window shown")
end

function MyCombatEntityMapWindow:Hide()
    if entityWindow then
        entityWindow:Hide()
        isVisible = false
        addon:Debug("Combat entity map window hidden")
    end
end

function MyCombatEntityMapWindow:Toggle()
    if isVisible then
        self:Hide()
    else
        self:Show()
    end
end

function MyCombatEntityMapWindow:IsVisible()
    return isVisible and entityWindow and entityWindow:IsVisible()
end

-- Clear entity map
function MyCombatEntityMapWindow:Clear()
    entityMap = {}
    self:UpdateDisplay()
end

return MyCombatEntityMapWindow