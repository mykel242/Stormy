-- GUIDResolver.lua
-- GUID to name resolution and caching system for combat narrative reconstruction

local addonName, addon = ...

-- GUID Resolver module
addon.GUIDResolver = {}
local GUIDResolver = addon.GUIDResolver

-- State tracking
local isInitialized = false
local guidNameCache = {}
local recentEncounters = {}

-- Configuration (REDUCED for memory management)
local CONFIG = {
    CACHE_CLEANUP_INTERVAL = 300, -- 5 minutes
    MAX_CACHE_SIZE = 1000,        -- Reduced from 2000 - Maximum cached entries  
    CACHE_EXPIRY_TIME = 1800,     -- Reduced from 3600 - 30 min expiry for entries
    ENCOUNTER_RETENTION = 3600,   -- Reduced from 86400 - 1 hour for encounter data (was 24 hours!)
}

-- Saved variable key for persistent cache
local CACHE_KEY = "MyUI_GUIDCache"

-- Initialize the GUID resolver
function GUIDResolver:Initialize()
    if isInitialized then
        return
    end
    
    -- Load cached data from saved variables
    self:LoadFromSavedVariables()
    
    -- Create event frame for name resolution opportunities
    self.frame = CreateFrame("Frame", addonName .. "GUIDResolver")
    self.frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    self.frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    self.frame:RegisterEvent("UNIT_NAME_UPDATE")
    self.frame:RegisterEvent("GROUP_ROSTER_UPDATE")
    self.frame:SetScript("OnEvent", function(frame, event, ...)
        self:OnEvent(event, ...)
    end)
    
    -- Start cleanup timer
    self:StartCleanupTimer()
    
    isInitialized = true
    
    addon:Debug("GUIDResolver initialized - %d cached entries loaded", self:GetCacheSize())
end

-- Event handler for name resolution opportunities
function GUIDResolver:OnEvent(event, ...)
    if event == "UPDATE_MOUSEOVER_UNIT" then
        self:CacheUnitName("mouseover")
    elseif event == "PLAYER_TARGET_CHANGED" then
        self:CacheUnitName("target")
    elseif event == "UNIT_NAME_UPDATE" then
        local unitID = ...
        if unitID then
            self:CacheUnitName(unitID)
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        self:CacheGroupMembers()
    end
end

-- Cache name for a specific unit
function GUIDResolver:CacheUnitName(unitID)
    if not unitID or not UnitExists(unitID) then
        return
    end
    
    local guid = UnitGUID(unitID)
    local name = UnitName(unitID)
    
    if guid and name and name ~= "" then
        self:StoreGUIDName(guid, name, {
            unitType = self:ParseGUIDType(guid),
            level = UnitLevel(unitID),
            classification = UnitClassification(unitID),
            creatureType = UnitCreatureType(unitID),
            timestamp = GetTime()
        })
    end
end

-- Cache all group members
function GUIDResolver:CacheGroupMembers()
    -- Cache player
    self:CacheUnitName("player")
    
    -- Cache party members
    if IsInGroup() then
        for i = 1, GetNumGroupMembers() - 1 do
            self:CacheUnitName("party" .. i)
        end
    end
    
    -- Cache raid members
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            self:CacheUnitName("raid" .. i)
        end
    end
end

-- Store GUID to name mapping with metadata
function GUIDResolver:StoreGUIDName(guid, name, metadata)
    if not guid or not name then
        return
    end
    
    -- Use regular table for cache entries (long-term storage)
    local cacheEntry = {}
    cacheEntry.name = name
    cacheEntry.metadata = metadata or {}
    cacheEntry.lastSeen = GetTime()
    cacheEntry.seenCount = (guidNameCache[guid] and guidNameCache[guid].seenCount or 0) + 1
    
    -- No need to release regular tables - let GC handle it
    -- Old entry will be garbage collected when overwritten
    
    guidNameCache[guid] = cacheEntry
    
    -- Also store encounter data for creatures
    if metadata and metadata.unitType == "Creature" then
        -- Use regular table for encounter entries (long-term storage)
        local encounterEntry = {}
        encounterEntry.name = name
        encounterEntry.level = metadata.level
        encounterEntry.classification = metadata.classification
        encounterEntry.creatureType = metadata.creatureType
        encounterEntry.firstSeen = recentEncounters[guid] and recentEncounters[guid].firstSeen or GetTime()
        encounterEntry.lastSeen = GetTime()
        
        -- No need to release regular tables - let GC handle it
        -- Old entry will be garbage collected when overwritten
        
        recentEncounters[guid] = encounterEntry
    end
end

-- Resolve GUID to name with fallback strategies
function GUIDResolver:ResolveGUID(guid, fallbackName)
    if not guid then
        return fallbackName or "Unknown"
    end
    
    -- Check cache first
    local cached = guidNameCache[guid]
    if cached and cached.name then
        -- Update last seen time
        cached.lastSeen = GetTime()
        return cached.name
    end
    
    -- Try active unit scanning
    local activeName = self:ScanActiveUnits(guid)
    if activeName then
        return activeName
    end
    
    -- Use fallback name if provided (from combat log)
    if fallbackName and fallbackName ~= "" then
        -- Cache the fallback name for future use
        self:StoreGUIDName(guid, fallbackName, {
            unitType = self:ParseGUIDType(guid),
            source = "combat_log",
            timestamp = GetTime()
        })
        return fallbackName
    end
    
    -- Generate descriptive fallback based on GUID
    return self:GenerateGUIDFallback(guid)
end

-- Scan active units for GUID
function GUIDResolver:ScanActiveUnits(guid)
    -- Check common units using table pool
    local units = addon.StorageManager and addon.StorageManager:GetTable() or {}
    units[1] = "target"
    units[2] = "mouseover" 
    units[3] = "focus"
    units[4] = "player"
    
    -- Add group members
    if IsInGroup() then
        for i = 1, GetNumGroupMembers() - 1 do
            table.insert(units, "party" .. i)
        end
    end
    
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            table.insert(units, "raid" .. i)
        end
    end
    
    -- Check each unit
    for _, unitID in ipairs(units) do
        if UnitExists(unitID) and UnitGUID(unitID) == guid then
            local name = UnitName(unitID)
            if name and name ~= "" then
                -- Cache this discovery
                self:CacheUnitName(unitID)
                
                -- Release units table back to pool
                if addon.StorageManager then
                    addon.StorageManager:ReleaseTable(units)
                end
                
                return name
            end
        end
    end
    
    -- Release units table back to pool
    if addon.StorageManager then
        addon.StorageManager:ReleaseTable(units)
    end
    
    return nil
end

-- Parse GUID type and generate fallback name
function GUIDResolver:ParseGUIDType(guid)
    if not guid then
        return "Unknown"
    end
    
    local guidType = strsplit("-", guid)
    return guidType or "Unknown"
end

-- Generate descriptive fallback name from GUID
function GUIDResolver:GenerateGUIDFallback(guid)
    if not guid then
        return "Unknown Entity"
    end
    
    local parts = {strsplit("-", guid)}
    local guidType = parts[1]
    
    if guidType == "Player" then
        local serverID = parts[2]
        local playerID = parts[3]
        return string.format("Player-%s", playerID and playerID:sub(-6) or "Unknown")
    elseif guidType == "Creature" then
        local creatureID = parts[6]
        return string.format("Creature-%s", creatureID or "Unknown")
    elseif guidType == "Pet" then
        return "Pet"
    elseif guidType == "GameObject" then
        return "Object"
    elseif guidType == "Vehicle" then
        return "Vehicle"
    else
        return guidType or "Unknown Entity"
    end
end

-- Enhanced combat event processing with name resolution
function GUIDResolver:ResolveCombatEvent(eventData)
    -- Resolve source name
    eventData.sourceName = self:ResolveGUID(eventData.sourceGUID, eventData.sourceName)
    
    -- Resolve destination name
    eventData.destName = self:ResolveGUID(eventData.destGUID, eventData.destName)
    
    return eventData
end

-- Get comprehensive name mapping for a session
function GUIDResolver:GetSessionNameMapping(events)
    local mapping = addon.StorageManager and addon.StorageManager:GetTable() or {}
    local uniqueGUIDs = addon.StorageManager and addon.StorageManager:GetTable() or {}
    
    -- Collect all unique GUIDs from events
    for _, event in ipairs(events) do
        if event.sourceGUID then
            uniqueGUIDs[event.sourceGUID] = true
        end
        if event.destGUID then
            uniqueGUIDs[event.destGUID] = true
        end
    end
    
    -- Build name mapping using table pool
    for guid, _ in pairs(uniqueGUIDs) do
        local mappingEntry = addon.StorageManager and addon.StorageManager:GetTable() or {}
        mappingEntry.name = self:ResolveGUID(guid)
        mappingEntry.guidType = self:ParseGUIDType(guid)
        mappingEntry.cached = guidNameCache[guid] ~= nil
        mappingEntry.metadata = guidNameCache[guid] and guidNameCache[guid].metadata or nil
        
        mapping[guid] = mappingEntry
    end
    
    -- Release uniqueGUIDs table back to pool
    if addon.StorageManager then
        addon.StorageManager:ReleaseTable(uniqueGUIDs)
    end
    
    return mapping
end

-- Start cleanup timer
function GUIDResolver:StartCleanupTimer()
    if self.cleanupTimer then
        self.cleanupTimer:Cancel()
    end
    
    self.cleanupTimer = C_Timer.NewTicker(CONFIG.CACHE_CLEANUP_INTERVAL, function()
        self:PerformCleanup()
    end)
end

-- Perform cache cleanup
function GUIDResolver:PerformCleanup()
    local now = GetTime()
    local removed = 0
    
    -- Clean expired cache entries
    for guid, entry in pairs(guidNameCache) do
        if entry.lastSeen and (now - entry.lastSeen) > CONFIG.CACHE_EXPIRY_TIME then
            -- Regular tables - no need to release, just remove reference
            guidNameCache[guid] = nil
            removed = removed + 1
        end
    end
    
    -- Clean old encounter data
    for guid, encounter in pairs(recentEncounters) do
        if encounter.lastSeen and (now - encounter.lastSeen) > CONFIG.ENCOUNTER_RETENTION then
            -- Regular tables - no need to release, just remove reference
            recentEncounters[guid] = nil
        end
    end
    
    -- Size-based cleanup if still too large
    if self:GetCacheSize() > CONFIG.MAX_CACHE_SIZE then
        local sortedEntries = addon.StorageManager and addon.StorageManager:GetTable() or {}
        for guid, entry in pairs(guidNameCache) do
            local sortEntry = addon.StorageManager and addon.StorageManager:GetTable() or {}
            sortEntry.guid = guid
            sortEntry.lastSeen = entry.lastSeen
            table.insert(sortedEntries, sortEntry)
        end
        
        -- Sort by last seen time (oldest first)
        table.sort(sortedEntries, function(a, b) return a.lastSeen < b.lastSeen end)
        
        -- Remove oldest entries
        local removeCount = self:GetCacheSize() - CONFIG.MAX_CACHE_SIZE
        for i = 1, removeCount do
            if sortedEntries[i] then
                local guidToRemove = sortedEntries[i].guid
                
                -- Regular tables - no need to release, just remove reference
                
                guidNameCache[guidToRemove] = nil
                removed = removed + 1
            end
        end
        
        -- Release sorted entries and their content back to pool
        if addon.StorageManager then
            for _, sortEntry in ipairs(sortedEntries) do
                addon.StorageManager:ReleaseTable(sortEntry)
            end
            addon.StorageManager:ReleaseTable(sortedEntries)
        end
    end
    
    if removed > 0 then
        addon:Debug("GUIDResolver cleanup: removed %d expired entries", removed)
    end
    
    -- Save after cleanup
    self:SaveToSavedVariables()
end

-- Load cache from saved variables
function GUIDResolver:LoadFromSavedVariables()
    if MyUIDB and MyUIDB[CACHE_KEY] then
        guidNameCache = MyUIDB[CACHE_KEY].cache or {}
        recentEncounters = MyUIDB[CACHE_KEY].encounters or {}
        
        addon:Debug("GUIDResolver: loaded %d cached entries", self:GetCacheSize())
    else
        guidNameCache = {}
        recentEncounters = {}
    end
end

-- Save cache to saved variables
function GUIDResolver:SaveToSavedVariables()
    if not MyUIDB then
        MyUIDB = {}
    end
    
    MyUIDB[CACHE_KEY] = {
        cache = guidNameCache,
        encounters = recentEncounters,
        lastSave = GetTime()
    }
end

-- Public API methods
function GUIDResolver:GetCacheSize()
    local count = 0
    for _ in pairs(guidNameCache) do
        count = count + 1
    end
    return count
end

function GUIDResolver:GetCachedName(guid)
    local cached = guidNameCache[guid]
    return cached and cached.name or nil
end

function GUIDResolver:GetRecentEncounters()
    return recentEncounters
end

function GUIDResolver:ClearCache()
    -- Release all cache entries back to pool before clearing
    if addon.StorageManager then
        for _, entry in pairs(guidNameCache) do
            addon.StorageManager:ReleaseTable(entry)
        end
        
        for _, encounter in pairs(recentEncounters) do
            addon.StorageManager:ReleaseTable(encounter)
        end
    end
    
    guidNameCache = {}
    recentEncounters = {}
    self:SaveToSavedVariables()
    
    addon:Debug("GUIDResolver cache cleared")
end

function GUIDResolver:GetStatus()
    return {
        isInitialized = isInitialized,
        cacheSize = self:GetCacheSize(),
        encounterCount = self:GetTableSize(recentEncounters),
        lastCleanup = self.lastCleanup or 0
    }
end

-- Get cache statistics for memory reporting
function GUIDResolver:GetCacheStats()
    return {
        cacheSize = self:GetCacheSize(),
        encounterCount = self:GetTableSize(recentEncounters),
        maxCacheSize = CONFIG.MAX_CACHE_SIZE,
        cacheUtilization = (self:GetCacheSize() / CONFIG.MAX_CACHE_SIZE) * 100,
        expiryTime = CONFIG.CACHE_EXPIRY_TIME
    }
end

function GUIDResolver:GetTableSize(tbl)
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

-- Release session name mapping tables back to pool
function GUIDResolver:ReleaseSessionNameMapping(mapping)
    if not mapping or not addon.StorageManager then
        return
    end
    
    -- Release each mapping entry
    for _, entry in pairs(mapping) do
        addon.StorageManager:ReleaseTable(entry)
    end
    
    -- Release the main mapping table
    addon.StorageManager:ReleaseTable(mapping)
end

-- Debug summary
function GUIDResolver:GetDebugSummary()
    local status = self:GetStatus()
    return string.format(
        "GUIDResolver Status:\n" ..
        "  Initialized: %s\n" ..
        "  Cache Size: %d entries\n" ..
        "  Recent Encounters: %d\n" ..
        "  Cache Limit: %d entries\n" ..
        "  Expiry Time: %.0f minutes",
        tostring(status.isInitialized),
        status.cacheSize,
        status.encounterCount,
        CONFIG.MAX_CACHE_SIZE,
        CONFIG.CACHE_EXPIRY_TIME / 60
    )
end