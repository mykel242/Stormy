-- StorageManager.lua
-- Memory-efficient storage system for combat sessions

local addonName, addon = ...

-- Storage Manager module
addon.StorageManager = {}
local StorageManager = addon.StorageManager

-- State tracking
local isInitialized = false
local sessionStorage = {}
local memoryStats = {}

-- Table Pooling System (based on Recount's approach)
local tablePool = {}
local poolStats = {
    created = 0,        -- Total tables created
    reused = 0,         -- Tables reused from pool
    returned = 0,       -- Tables returned to pool
    currentPoolSize = 0, -- Current pool size
    maxPoolSize = 1000,  -- Doubled from 500 for extra safety during intensive combat
    warnings = 0,       -- Pool-related warnings
    corrupted = 0,      -- Corrupted tables rejected
    healthChecks = 0    -- Pool health check count
}

-- Debug mode for table lineage tracking
local DEBUG_TABLE_LINEAGE = false

-- Leak tracking system
local leakTracker = {}
local leakCounter = 0

-- Export debug state for slash commands
function StorageManager:GetDebugTableLineage()
    return DEBUG_TABLE_LINEAGE
end

function StorageManager:SetDebugTableLineage(enabled)
    DEBUG_TABLE_LINEAGE = enabled
end

-- Get current leaked tables for debugging
function StorageManager:GetLeakedTables()
    local leaks = {}
    local now = GetTime()
    
    for leakId, info in pairs(leakTracker) do
        -- Only report tables older than 10 seconds as potential leaks
        if (now - info.created) > 10 then
            table.insert(leaks, {
                id = leakId,
                purpose = info.purpose,
                age = now - info.created,
                stack = info.stack
            })
        end
    end
    
    -- Sort by age (oldest first)
    table.sort(leaks, function(a, b) return a.age > b.age end)
    
    return leaks, #leakTracker
end

-- Weak reference overflow pool for emergency situations
local overflowPool = setmetatable({}, {__mode = "v"})
local overflowStats = {
    created = 0,
    collected = 0
}

-- Get current storage configuration (hardcoded defaults since SettingsWindow is disabled)
-- MEMORY OPTIMIZATION: Reduced limits to prevent 34MB saved file issue
local function GetStorageConfig()
    return {

        MAX_SESSIONS = 25,        -- Increased from 15 - better history balance
        MAX_SESSION_AGE_DAYS = 7, -- Restored to 7 - full week of raid history
        MAX_MEMORY_MB = 8,        -- Increased from 5 - reasonable for combat data
        COMPRESSION_ENABLED = false,
        ENHANCED_COMPRESSION = false, -- Compression disabled to debug auto scaling
        WARNING_THRESHOLD = 0.7,  -- Warn at 70% instead of 80% - earlier warnings
        -- New tiered retention strategy
        PRIORITY_SESSIONS = 10,   -- Keep most recent 10 sessions regardless of age
        LONG_TERM_SESSIONS = 15   -- Keep additional 15 sessions up to age limit

    }
end

-- Saved variable for persistent storage
local STORAGE_KEY = "MyUI_CombatSessions"

-- ============================================================================
-- TABLE POOLING SYSTEM (based on Recount's methodology)
-- ============================================================================

-- Get a table from the pool (reuse existing or create new)
function StorageManager:GetTable(purpose)
    local table
    
    if #tablePool > 0 then
        -- Reuse existing table from pool
        table = tablePool[#tablePool]
        
        -- Validate it's actually a table
        if type(table) ~= "table" then
            poolStats.warnings = poolStats.warnings + 1
            poolStats.corrupted = poolStats.corrupted + 1
            if addon.MyLogger then
                addon.MyLogger:Warn("Table pool corruption: non-table found (%s)", type(table))
            end
            table = {}
            poolStats.created = poolStats.created + 1
        else
            tablePool[#tablePool] = nil
            poolStats.currentPoolSize = poolStats.currentPoolSize - 1
            poolStats.reused = poolStats.reused + 1
            
            -- Sanity check - warn if table isn't empty or has metatable
            local count = 0
            for _ in pairs(table) do
                count = count + 1
            end
            
            local mt = getmetatable(table)
            if count > 0 or mt then
                poolStats.warnings = poolStats.warnings + 1
                if addon.MyLogger then
                    -- Log the table contents for debugging
                    local contents = {}
                    local i = 1
                    for k, v in pairs(table) do
                        if i <= 5 then  -- Only log first 5 entries
                            contents[i] = string.format("%s=%s", tostring(k), tostring(v))
                            i = i + 1
                        else
                            contents[i] = "...(more)"
                            break
                        end
                    end
                    addon.MyLogger:Warn("Table pool warning: reused table has %d entries and %s metatable. Contents: [%s]. Purpose: %s", 
                        count, mt and "a" or "no", strjoin(", ", unpack(contents)), tostring(purpose))
                end
                -- Clear the table and metatable to prevent data corruption
                setmetatable(table, nil)
                for k in pairs(table) do
                    table[k] = nil
                end
            end
        end
    else
        -- Create new table
        table = {}
        poolStats.created = poolStats.created + 1
    end
    
    -- Track lineage in debug mode or for leak detection
    if DEBUG_TABLE_LINEAGE and purpose then
        rawset(table, "_lineage", {
            created = GetTime(),
            purpose = purpose,
            stackTrace = debugstack(2, 1, 0),
            recycleCount = 0
        })
    end
    
    -- Always track for leak detection
    leakCounter = leakCounter + 1
    local leakId = leakCounter
    leakTracker[leakId] = {
        purpose = purpose or "unknown",
        created = GetTime(),
        stack = debugstack(2, 1, 0),
        table = table
    }
    rawset(table, "_leakId", leakId)
    
    return table
end

-- Return a table to the pool for reuse
function StorageManager:ReleaseTable(table, seen, depth)
    -- Validate input
    if type(table) ~= "table" then
        if table ~= nil and addon.MyLogger then
            addon.MyLogger:Warn("Non-table passed to ReleaseTable: %s", type(table))
        end
        return
    end
    
    -- Track seen tables to prevent infinite recursion
    seen = seen or {}
    depth = depth or 0
    
    if seen[table] then
        return  -- Already processed this table
    end
    seen[table] = true
    
    -- Prevent stack overflow with max recursion depth
    if depth > 10 then
        if addon.MyLogger then
            addon.MyLogger:Warn("Max recursion depth reached in ReleaseTable")
        end
        return
    end
    
    -- Check for signs of corruption
    local success, err = pcall(function()
        for k in pairs(table) do
            -- This will error if table is corrupted
        end
    end)
    
    if not success then
        poolStats.corrupted = poolStats.corrupted + 1
        if addon.MyLogger then
            addon.MyLogger:Warn("Corrupted table rejected from pool: %s", err)
        end
        return
    end
    
    -- Update lineage if tracking
    if DEBUG_TABLE_LINEAGE and rawget(table, "_lineage") then
        local lineage = rawget(table, "_lineage")
        lineage.recycleCount = (lineage.recycleCount or 0) + 1
        lineage.recycled = GetTime()
        rawset(table, "_lineage", nil)  -- Remove before clearing
    end
    
    -- Remove from leak tracker when properly released
    local leakId = rawget(table, "_leakId")
    if leakId and leakTracker[leakId] then
        leakTracker[leakId] = nil
    end
    
    -- Clear metatable first
    setmetatable(table, nil)
    
    -- Recursively release nested tables first
    for k, v in pairs(table) do
        if type(v) == "table" and v ~= table then  -- Avoid self-reference
            self:ReleaseTable(v, seen, depth + 1)
        end
        table[k] = nil
    end
    
    -- Clean up any raw fields that pairs() might miss
    rawset(table, "_leakId", nil)
    rawset(table, "_lineage", nil)
    
    -- Only add to pool if we haven't exceeded maximum size
    if poolStats.currentPoolSize < poolStats.maxPoolSize then
        tablePool[#tablePool + 1] = table
        poolStats.currentPoolSize = poolStats.currentPoolSize + 1
        poolStats.returned = poolStats.returned + 1
    else
        -- Pool is full, try overflow pool
        overflowPool[#overflowPool + 1] = table
        overflowStats.created = overflowStats.created + 1
    end
end

-- Get table pool statistics for debugging/monitoring
function StorageManager:GetPoolStats()
    return {
        created = poolStats.created,
        reused = poolStats.reused,
        returned = poolStats.returned,
        currentPoolSize = poolStats.currentPoolSize,
        maxPoolSize = poolStats.maxPoolSize,
        warnings = poolStats.warnings,
        corrupted = poolStats.corrupted,
        healthChecks = poolStats.healthChecks,
        reuseRatio = (poolStats.created > 0) and (poolStats.reused / poolStats.created) or 0,
        overflow = {
            created = overflowStats.created,
            collected = overflowStats.collected
        }
    }
end

-- Validate pool health - remove corrupted tables
function StorageManager:ValidatePool()
    local corrupted = 0
    local startSize = #tablePool
    
    poolStats.healthChecks = poolStats.healthChecks + 1
    
    -- Check each table in pool
    for i = #tablePool, 1, -1 do
        local t = tablePool[i]
        local isCorrupted = false
        
        -- Check if still a valid table
        if type(t) ~= "table" then
            isCorrupted = true
        else
            -- Check if empty and has no metatable
            local count = 0
            local success, err = pcall(function()
                for _ in pairs(t) do
                    count = count + 1
                    break
                end
            end)
            
            if not success or count > 0 or getmetatable(t) then
                isCorrupted = true
            end
        end
        
        if isCorrupted then
            table.remove(tablePool, i)
            corrupted = corrupted + 1
            poolStats.corrupted = poolStats.corrupted + 1
        end
    end
    
    poolStats.currentPoolSize = #tablePool
    
    if corrupted > 0 and addon.MyLogger then
        addon.MyLogger:Info("Pool validation: removed %d corrupted tables (pool: %d -> %d)", 
            corrupted, startSize, #tablePool)
    end
    
    -- Check overflow pool collection
    local overflowBefore = #overflowPool
    local collected = 0
    
    -- Force a partial GC to clean up weak references
    collectgarbage("step", 100)
    
    local overflowAfter = #overflowPool
    if overflowAfter < overflowBefore then
        collected = overflowBefore - overflowAfter
        overflowStats.collected = overflowStats.collected + collected
    end
    
    return {
        corrupted = corrupted,
        healthy = #tablePool,
        overflowCollected = collected
    }
end

-- Emergency pool flush - use only in critical situations
function StorageManager:EmergencyPoolFlush()
    if addon.MyLogger then
        addon.MyLogger:Warn("EMERGENCY: Flushing table pool (size: %d)", #tablePool)
    end
    
    -- Clear main pool
    local flushedMain = #tablePool
    for i = 1, #tablePool do
        tablePool[i] = nil
    end
    poolStats.currentPoolSize = 0
    
    -- Clear overflow pool
    local flushedOverflow = #overflowPool
    for i = 1, #overflowPool do
        overflowPool[i] = nil
    end
    
    -- Force garbage collection
    collectgarbage("collect")
    
    if addon.MyLogger then
        addon.MyLogger:Info("Emergency flush complete: %d main + %d overflow tables cleared", 
            flushedMain, flushedOverflow)
    end
    
    return {
        mainPoolFlushed = flushedMain,
        overflowPoolFlushed = flushedOverflow
    }
end

-- Reset pool statistics (useful for testing)
function StorageManager:ResetPoolStats()
    poolStats.created = 0
    poolStats.reused = 0
    poolStats.returned = 0
    poolStats.warnings = 0
    -- Don't reset currentPoolSize or maxPoolSize as they reflect actual state
end

-- Clear the entire table pool (emergency cleanup)
function StorageManager:ClearTablePool()
    for i = 1, #tablePool do
        tablePool[i] = nil
    end
    poolStats.currentPoolSize = 0
    if addon.MyLogger then
        addon.MyLogger:Info("Table pool cleared")
    end
end

-- ============================================================================
-- SPECIALIZED TABLE FACTORIES
-- ============================================================================

-- Factory method for combat event tables
function StorageManager:GetEventTable()
    local t = self:GetTable("event")
    -- Pre-initialize expected fields using rawset to avoid metamethod issues
    rawset(t, "time", 0)
    rawset(t, "subevent", nil)
    rawset(t, "sourceGUID", nil)
    rawset(t, "destGUID", nil)
    rawset(t, "args", nil)
    return t
end

-- Factory method for segment tables
function StorageManager:GetSegmentTable()
    local t = self:GetTable("segment")
    -- Pre-initialize all segment fields using rawset to prevent corruption
    rawset(t, "id", nil)
    rawset(t, "segmentIndex", 0)
    rawset(t, "startTime", 0)
    rawset(t, "endTime", nil)
    rawset(t, "events", nil)  -- Will be set to a new table when needed
    rawset(t, "eventCount", 0)
    rawset(t, "isActive", false)
    rawset(t, "duration", 0)
    return t
end

-- Factory method for session tables
function StorageManager:GetSessionTable()
    local t = self:GetTable("session")
    -- Pre-initialize session fields using rawset
    rawset(t, "id", nil)
    rawset(t, "hash", nil)
    rawset(t, "startTime", 0)
    rawset(t, "endTime", nil)
    rawset(t, "duration", 0)
    rawset(t, "eventCount", 0)
    rawset(t, "events", nil)
    rawset(t, "guidMap", nil)
    rawset(t, "segments", nil)
    return t
end

-- Helper function to clean up pooled tables in a session before removal
local function CleanupSessionPooledTables(sessionData)
    if not sessionData then
        return
    end
    
    -- Clean up event tables
    if sessionData.events then
        for _, eventData in ipairs(sessionData.events) do
            if eventData and type(eventData) == "table" then
                StorageManager:ReleaseTable(eventData)
            end
        end
        StorageManager:ReleaseTable(sessionData.events)
    end
    
    -- Clean up segment tables (new segmentation support)
    if sessionData.segments then
        for _, segment in ipairs(sessionData.segments) do
            if segment and type(segment) == "table" then
                -- Clean up segment events
                if segment.events then
                    for _, eventData in ipairs(segment.events) do
                        if eventData and type(eventData) == "table" then
                            StorageManager:ReleaseTable(eventData)
                        end
                    end
                    StorageManager:ReleaseTable(segment.events)
                end
                -- Clean up the segment table itself
                StorageManager:ReleaseTable(segment)
            end
        end
        StorageManager:ReleaseTable(sessionData.segments)
    end
    
    -- Clean up GUID map
    if sessionData.guidMap then
        StorageManager:ReleaseTable(sessionData.guidMap)
    end
    
    -- Clean up the main session table
    StorageManager:ReleaseTable(sessionData)
end

-- ============================================================================
-- END TABLE POOLING SYSTEM
-- ============================================================================

-- Initialize the storage manager
function StorageManager:Initialize()
    if isInitialized then
        return
    end
    
    -- Initialize storage from saved variables
    self:LoadFromSavedVariables()
    
    -- Initialize memory stats
    memoryStats = {
        sessionsStored = #sessionStorage,
        totalMemoryKB = 0,
        lastCleanup = GetTime(),
        compressionRatio = 1.0
    }
    
    isInitialized = true
    
    -- Check storage limits on initialization (delayed to allow settings to load)
    C_Timer.After(2.0, function()
        self:CheckStorageLimits()
    end)
    
    -- REGULAR AUTO-CLEANUP: Schedule periodic cleanup every 30 minutes
    self.cleanupTimer = C_Timer.NewTicker(1800, function() -- 30 minutes
        self:PerformScheduledCleanup()
    end)
    
    -- POOL HEALTH CHECK: Validate pool health every 5 minutes
    self.poolHealthTimer = C_Timer.NewTicker(300, function() -- 5 minutes
        local result = self:ValidatePool()
        if result.corrupted > 0 then
            addon:Debug("Pool health check: %d corrupted tables removed", result.corrupted)
        end
    end)
    
    addon:Debug("StorageManager initialized - %d sessions loaded", #sessionStorage)
end

-- Store a completed combat session
function StorageManager:StoreCombatSession(sessionData)
    if not isInitialized then
        self:Initialize()
    end
    
    -- Add metadata and timestamps
    sessionData.storedAt = GetTime()
    sessionData.serverTime = GetServerTime()
    
    -- Create a safe copy of the session data to prevent holding pooled tables
    local sessionCopy = {}
    
    -- Copy basic fields
    for k, v in pairs(sessionData) do
        if type(v) ~= "table" then
            sessionCopy[k] = v
        end
    end
    
    -- Copy GUID map (prevent table pool cleanup)
    if sessionData.guidMap then
        sessionCopy.guidMap = {}
        for guid, name in pairs(sessionData.guidMap) do
            sessionCopy.guidMap[guid] = name
        end
    end
    
    -- Copy events array (prevent table pool cleanup)
    if sessionData.events then
        sessionCopy.events = {}
        for i, event in ipairs(sessionData.events) do
            if event then
                local eventCopy = {}
                for k, v in pairs(event) do
                    eventCopy[k] = v
                end
                sessionCopy.events[i] = eventCopy
            end
        end
    end
    
    -- Copy segments if they exist
    if sessionData.segments then
        sessionCopy.segments = {}
        for i, segment in ipairs(sessionData.segments) do
            if segment then
                local segmentCopy = {}
                for k, v in pairs(segment) do
                    if k ~= "events" then
                        segmentCopy[k] = v
                    end
                end
                
                -- Copy segment events
                if segment.events then
                    segmentCopy.events = {}
                    for j, event in ipairs(segment.events) do
                        if event then
                            local eventCopy = {}
                            for k, v in pairs(event) do
                                eventCopy[k] = v
                            end
                            segmentCopy.events[j] = eventCopy
                        end
                    end
                end
                
                sessionCopy.segments[i] = segmentCopy
            end
        end
    end
    
    -- Use the copy instead of original
    sessionData = sessionCopy
    
    -- Get context metadata if available
    if addon.MetadataCollector then
        sessionData.metadata = addon.MetadataCollector:GetMetadataForCombat(sessionData.id)
        local zoneName = sessionData.metadata and sessionData.metadata.zone and sessionData.metadata.zone.name or "NO_ZONE"
        addon:Debug("StorageManager: Collected metadata with zone: %s", zoneName)
    else
        addon:Debug("StorageManager: MetadataCollector not available")
    end
    
    -- Compression disabled for debugging auto scaling
    -- sessionData.events are stored as-is
    
    -- Add to storage
    table.insert(sessionStorage, sessionData)
    
    -- Update memory stats
    self:UpdateMemoryStats()
    
    -- Check for storage warnings and cleanup if needed
    self:CheckStorageLimits()
    
    -- Auto-save after storing new session
    self:SaveToSavedVariables()
    
    addon:Debug("Combat session stored: %s (%d events, %.1fKB)", 
        sessionData.id, 
        sessionData.eventCount,
        self:EstimateSessionSizeKB(sessionData))
    
    -- Notify Session Browser to refresh if it's open
    if addon.SessionBrowser and addon.SessionBrowser:IsShown() then
        addon.SessionBrowser:RefreshSessionList()
    end
end

-- Decompression disabled (compression removed)
function StorageManager:DecompressEvents(compressedData)
    return {}
end

-- Estimate memory usage of a session in KB
function StorageManager:EstimateSessionSizeKB(sessionData)
    -- Rough estimation based on data structure
    local baseSize = 1 -- Base session metadata
    local eventSize = sessionData.eventCount * 0.1 -- ~100 bytes per event
    local metadataSize = sessionData.metadata and 2 or 0 -- ~2KB for metadata
    
    -- Add segment overhead for segmented sessions
    local segmentOverhead = 0
    if sessionData.isSegmented and sessionData.segments then
        segmentOverhead = #sessionData.segments * 0.5 -- ~0.5KB per segment metadata
    end
    
    return baseSize + eventSize + metadataSize + segmentOverhead
end

-- Update memory statistics
function StorageManager:UpdateMemoryStats()
    local totalSizeKB = 0
    local compressedEvents = 0
    local originalEvents = 0
    
    for _, session in ipairs(sessionStorage) do
        totalSizeKB = totalSizeKB + self:EstimateSessionSizeKB(session)
        
        -- Compression disabled, no compressed events to track
    end
    
    memoryStats.sessionsStored = #sessionStorage
    memoryStats.totalMemoryKB = totalSizeKB
    memoryStats.compressionRatio = 1.0  -- No compression
end

-- Check storage limits and warn/cleanup as needed
function StorageManager:CheckStorageLimits(testMode)
    local config = GetStorageConfig()
    
    -- In test mode, temporarily lower limits to force warnings
    if testMode then
        config.MAX_SESSIONS = math.max(1, #sessionStorage - 5) -- Force close to limit
        config.MAX_MEMORY_MB = math.max(0.1, (memoryStats.totalMemoryKB / 1024) + 0.1) -- Force close to limit
        config.WARNING_THRESHOLD = 0.5 -- Lower threshold for easier testing
    end
    
    self:UpdateMemoryStats()
    
    local warnings = {}
    local cleanupNeeded = false
    
    -- Check session count limit
    local sessionCount = #sessionStorage
    local maxSessions = config.MAX_SESSIONS
    local sessionWarningThreshold = math.floor(maxSessions * config.WARNING_THRESHOLD)
    
    if sessionCount >= maxSessions then
        cleanupNeeded = true
    elseif sessionCount >= sessionWarningThreshold then
        table.insert(warnings, string.format("Session count: %d/%d (%.0f%%)", 
            sessionCount, maxSessions, (sessionCount / maxSessions) * 100))
    end
    
    -- Check memory limit  
    local memoryMB = memoryStats.totalMemoryKB / 1024
    local maxMemoryMB = config.MAX_MEMORY_MB
    local memoryWarningThreshold = maxMemoryMB * config.WARNING_THRESHOLD
    
    if memoryMB >= maxMemoryMB then
        cleanupNeeded = true
    elseif memoryMB >= memoryWarningThreshold then
        table.insert(warnings, string.format("Memory usage: %.1f/%.1f MB (%.0f%%)", 
            memoryMB, maxMemoryMB, (memoryMB / maxMemoryMB) * 100))
    end
    
    -- Check age-based cleanup need
    local cutoffTime = GetServerTime() - (config.MAX_SESSION_AGE_DAYS * 24 * 60 * 60)
    local expiredCount = 0
    for _, session in ipairs(sessionStorage) do
        if session.serverTime and session.serverTime < cutoffTime then
            expiredCount = expiredCount + 1
        end
    end
    
    if expiredCount > 0 then
        table.insert(warnings, string.format("%d sessions older than %d days", 
            expiredCount, config.MAX_SESSION_AGE_DAYS))
        cleanupNeeded = true
    end
    
    -- Show warnings if any
    if #warnings > 0 then
        self:ShowStorageWarning(warnings, cleanupNeeded)
    end
    
    -- Perform cleanup if over limits (not just warnings)
    if cleanupNeeded then
        self:PerformMemoryCleanup()
    end
end

-- Perform memory cleanup (when limits are exceeded)
function StorageManager:PerformMemoryCleanup()
    local config = GetStorageConfig()
    local cleaned = false
    local cleanupLog = {}
    
    -- Remove sessions exceeding max count (oldest first)
    local initialCount = #sessionStorage
    while #sessionStorage > config.MAX_SESSIONS do
        local removedSession = table.remove(sessionStorage, 1)
        CleanupSessionPooledTables(removedSession)
        cleaned = true
    end
    if initialCount > #sessionStorage then
        table.insert(cleanupLog, string.format("Removed %d sessions over limit", initialCount - #sessionStorage))
    end
    
    -- Remove sessions older than max age
    local cutoffTime = GetServerTime() - (config.MAX_SESSION_AGE_DAYS * 24 * 60 * 60)
    local expiredRemoved = 0
    local i = 1
    while i <= #sessionStorage do
        local session = sessionStorage[i]
        if session.serverTime and session.serverTime < cutoffTime then
            local removedSession = table.remove(sessionStorage, i)
            CleanupSessionPooledTables(removedSession)
            expiredRemoved = expiredRemoved + 1
            cleaned = true
        else
            i = i + 1
        end
    end
    if expiredRemoved > 0 then
        table.insert(cleanupLog, string.format("Removed %d expired sessions", expiredRemoved))
    end
    
    -- Memory-based cleanup if still over limit
    self:UpdateMemoryStats()
    if memoryStats.totalMemoryKB > (config.MAX_MEMORY_MB * 1024) then
        local beforeCount = #sessionStorage
        -- Remove oldest 25% of sessions
        local removeCount = math.floor(#sessionStorage * 0.25)
        for i = 1, removeCount do
            local removedSession = table.remove(sessionStorage, 1)
            CleanupSessionPooledTables(removedSession)
        end
        cleaned = true
        table.insert(cleanupLog, string.format("Removed %d sessions for memory limit", removeCount))
    end
    
    if cleaned then
        self:UpdateMemoryStats()
        if #cleanupLog > 0 then
            addon:Info("Storage cleanup performed:")
            for _, msg in ipairs(cleanupLog) do
                addon:Info("  " .. msg)
            end
            addon:Info("  Final: %d sessions, %.1fKB", 
                memoryStats.sessionsStored, memoryStats.totalMemoryKB)
        end
    end
end

-- Show storage warning to user (now silent - logs instead of popup)
function StorageManager:ShowStorageWarning(warnings, cleanupNeeded)
    -- Log warnings silently instead of showing popup
    addon:Info("Storage Usage Warning:")
    for _, warning in ipairs(warnings) do
        addon:Info("  • " .. warning)
    end
    
    if cleanupNeeded then
        addon:Info("  Automatic cleanup will occur to stay within limits.")
    else
        addon:Info("  Consider exporting important sessions or adjusting storage limits.")
    end
    
    -- Also log to MyLogger if available for persistent visibility
    if addon.MyLogger then
        addon.MyLogger:Info("Storage Usage Warning:")
        for _, warning in ipairs(warnings) do
            addon.MyLogger:Info("  • " .. warning)
        end
        
        if cleanupNeeded then
            addon.MyLogger:Info("  Automatic cleanup will occur to stay within limits.")
        else
            addon.MyLogger:Info("  Consider exporting important sessions or adjusting storage limits.")
        end
    end
end

-- Load sessions from saved variables - SIMPLE, NO LAZY LOADING
function StorageManager:LoadFromSavedVariables()
    if MyUIDB and MyUIDB[STORAGE_KEY] then
        local loadedSessions = MyUIDB[STORAGE_KEY]
        sessionStorage = loadedSessions or {}
        
        addon:Debug("Loaded %d combat sessions from saved variables", #sessionStorage)
    else
        sessionStorage = {}
    end
end

-- Convert a session and all its nested data to use table pool
function StorageManager:ConvertSessionToPool(session)
    local pooledSession = self:GetTable()
    
    -- Copy basic properties
    for k, v in pairs(session) do
        if type(v) ~= "table" then
            pooledSession[k] = v
        end
    end
    
    -- Convert events array if present (compression disabled)
    if session.events then
        -- Handle regular events array only
        pooledSession.events = self:GetTable()
        for _, event in ipairs(session.events) do
            local pooledEvent = self:GetTable()
            for k, v in pairs(event) do
                pooledEvent[k] = v
            end
            table.insert(pooledSession.events, pooledEvent)
        end
        pooledSession.compressed = false  -- Never compressed
    end
    
    -- Convert segments array if present
    if session.segments then
        pooledSession.segments = self:GetTable()
        for _, segment in ipairs(session.segments) do
            local pooledSegment = self:GetTable()
            
            -- Copy segment properties
            for k, v in pairs(segment) do
                if type(v) ~= "table" then
                    pooledSegment[k] = v
                end
            end
            
            -- Convert segment events if present
            if segment.events then
                pooledSegment.events = self:GetTable()
                for _, event in ipairs(segment.events) do
                    local pooledEvent = self:GetTable()
                    for k, v in pairs(event) do
                        pooledEvent[k] = v
                    end
                    table.insert(pooledSegment.events, pooledEvent)
                end
            end
            
            table.insert(pooledSession.segments, pooledSegment)
        end
    end
    
    -- Convert guidMap if present (keep as regular table since it's used for lookups)
    if session.guidMap then
        pooledSession.guidMap = {}
        for k, v in pairs(session.guidMap) do
            pooledSession.guidMap[k] = v
        end
    end
    
    -- Convert metadata if present
    if session.metadata then
        pooledSession.metadata = self:ConvertMetadataToPool(session.metadata)

    end
    
    return pooledSession
end

-- Compression conversion functions removed

-- Convert metadata structure to use table pool
function StorageManager:ConvertMetadataToPool(metadata)
    local pooledMetadata = self:GetTable()
    
    for k, v in pairs(metadata) do
        if type(v) == "table" then
            pooledMetadata[k] = self:GetTable()
            for k2, v2 in pairs(v) do
                if type(v2) == "table" then
                    pooledMetadata[k][k2] = self:GetTable()
                    for k3, v3 in pairs(v2) do
                        pooledMetadata[k][k2][k3] = v3
                    end
                else
                    pooledMetadata[k][k2] = v2
                end
            end
        else
            pooledMetadata[k] = v
        end
    end
    
    return pooledMetadata
end

-- REGULAR AUTO-CLEANUP: Scheduled cleanup to prevent memory buildup
function StorageManager:PerformScheduledCleanup()
    local config = GetStorageConfig()
    local initialCount = #sessionStorage
    local cleaned = false
    
    addon:Debug("Performing scheduled session cleanup (every 30 minutes)")
    
    -- Remove sessions older than max age
    local cutoffTime = GetServerTime() - (config.MAX_SESSION_AGE_DAYS * 24 * 60 * 60)
    local expiredRemoved = 0
    local i = 1
    while i <= #sessionStorage do
        local session = sessionStorage[i]
        if session.serverTime and session.serverTime < cutoffTime then
            local removedSession = table.remove(sessionStorage, i)
            
            -- Clean up session data
            CleanupSessionPooledTables(removedSession)
            
            expiredRemoved = expiredRemoved + 1
            cleaned = true
        else
            i = i + 1
        end
    end
    
    -- Remove excess sessions if over limit (oldest first)
    while #sessionStorage > config.MAX_SESSIONS do
        local removedSession = table.remove(sessionStorage, 1)
        
        -- Clean up session data
        CleanupSessionPooledTables(removedSession)
        
        cleaned = true
    end
    
    if cleaned then
        self:UpdateMemoryStats()
        self:SaveToSavedVariables()
        
        local finalCount = #sessionStorage
        local totalRemoved = initialCount - finalCount
        
        if totalRemoved > 0 then
            addon:Info("Scheduled cleanup: removed %d sessions (%d expired, %d over limit)", 
                totalRemoved, expiredRemoved, totalRemoved - expiredRemoved)
            addon:Info("Sessions remaining: %d / %d", finalCount, config.MAX_SESSIONS)
        end
    end
end

-- Save sessions to saved variables - SIMPLE, NO LAZY LOADING
function StorageManager:SaveToSavedVariables()
    if not MyUIDB then
        MyUIDB = {}
    end
    
    -- Save sessions directly - what you save is what you get back
    MyUIDB[STORAGE_KEY] = sessionStorage
    addon:Debug("Saved %d sessions", #sessionStorage)
end

-- Public API methods
function StorageManager:GetAllSessions()
    -- Return copy to prevent modification - use regular table since returned to caller
    local sessions = {}
    for i, session in ipairs(sessionStorage) do
        sessions[i] = session
    end
    return sessions
end

function StorageManager:GetSession(sessionId)
    for i, session in ipairs(sessionStorage) do
        if session.id == sessionId or (session.hash and string.upper(session.hash) == string.upper(sessionId)) then
            -- Return the session directly - no copying, no lazy loading, no complexity
            return session
        end
    end
    return nil
end


function StorageManager:GetRecentSessions(count)
    count = count or 10
    -- Use regular table since this is returned to caller
    local recent = {}
    local startIndex = math.max(1, #sessionStorage - count + 1)
    
    for i = startIndex, #sessionStorage do
        table.insert(recent, sessionStorage[i])
    end
    
    return recent
end

function StorageManager:DeleteSession(sessionId)
    for i, session in ipairs(sessionStorage) do
        if session.id == sessionId or (session.hash and string.upper(session.hash) == string.upper(sessionId)) then
            local removedSession = table.remove(sessionStorage, i)
            CleanupSessionPooledTables(removedSession)
            self:UpdateMemoryStats()
            self:SaveToSavedVariables() -- Auto-save after deletion
            return true
        end
    end
    return false
end

function StorageManager:ClearAllSessions()
    -- Clean up all pooled tables before clearing
    for _, session in ipairs(sessionStorage) do
        CleanupSessionPooledTables(session)
    end
    sessionStorage = {}
    memoryStats.sessionsStored = 0
    memoryStats.totalMemoryKB = 0
    self:SaveToSavedVariables() -- Auto-save after clearing
    
    addon:Debug("All combat sessions cleared")
end

-- ============================================================================
-- SESSION SEGMENTATION SUPPORT
-- ============================================================================

-- Get a specific segment from a session (supports hash or full ID)
function StorageManager:GetSessionSegment(sessionId, segmentIndex)
    local session = self:GetSession(sessionId)
    if not session or not session.segments or not session.segments[segmentIndex] then
        return nil
    end
    
    return session.segments[segmentIndex]
end

-- Get all segments for a session (with optional lazy loading)
function StorageManager:GetSessionSegments(sessionId, loadEvents)
    local session = self:GetSession(sessionId)
    if not session or not session.segments then
        return {}
    end
    
    -- If loadEvents is false, return segments without event data for performance
    if loadEvents == false then
        local lightSegments = {}
        for i, segment in ipairs(session.segments) do
            local lightSegment = {
                id = segment.id,
                segmentIndex = segment.segmentIndex,
                startTime = segment.startTime,
                endTime = segment.endTime,
                duration = segment.duration,
                eventCount = segment.eventCount,
                isActive = segment.isActive
            }
            lightSegments[i] = lightSegment
        end
        return lightSegments
    end
    
    return session.segments
end

-- Get segment summary for UI display
function StorageManager:GetSegmentSummary(sessionId)
    local session = self:GetSession(sessionId)
    if not session then
        return nil
    end
    
    local summary = {
        sessionId = sessionId,
        isSegmented = session.isSegmented or false,
        segmentCount = session.segmentCount or 0,
        totalEvents = session.eventCount or 0,
        totalDuration = session.duration or 0
    }
    
    if session.segments then
        summary.segments = {}
        for i, segment in ipairs(session.segments) do
            summary.segments[i] = {
                index = i,
                id = segment.id,
                duration = segment.duration or 0,
                eventCount = segment.eventCount or 0,
                startTime = segment.startTime,
                endTime = segment.endTime
            }
        end
    end
    
    return summary
end

-- Merge segments back into a single event stream (for export/analysis)
function StorageManager:MergeSessionSegments(sessionId)
    local session = self:GetSession(sessionId)
    if not session or not session.segments then
        -- Return existing events if not segmented
        return session and session.events or {}
    end
    
    local mergedEvents = {}
    
    for _, segment in ipairs(session.segments) do
        if segment.events then
            for _, event in ipairs(segment.events) do
                table.insert(mergedEvents, event)
            end
        end
    end
    
    -- Sort by timestamp to maintain chronological order
    table.sort(mergedEvents, function(a, b)
        return (a.time or 0) < (b.time or 0)
    end)
    
    return mergedEvents
end

function StorageManager:GetMemoryStats()
    local config = GetStorageConfig()
    return {
        sessionsStored = memoryStats.sessionsStored,
        totalMemoryKB = memoryStats.totalMemoryKB,
        totalMemoryMB = memoryStats.totalMemoryKB / 1024,
        compressionRatio = memoryStats.compressionRatio,
        maxSessions = config.MAX_SESSIONS,
        maxMemoryMB = config.MAX_MEMORY_MB,
        maxSessionAgeDays = config.MAX_SESSION_AGE_DAYS,
        compressionEnabled = false  -- Always false now
    }
end

-- Compression cleanup functions removed

-- Release session copy returned by GetSession
function StorageManager:ReleaseSessionCopy(sessionCopy)
    if not sessionCopy then
        return
    end
    
    -- Release events array if it was decompressed
    if sessionCopy.events then
        for _, event in ipairs(sessionCopy.events) do
            self:ReleaseTable(event)
        end
        self:ReleaseTable(sessionCopy.events)
    end
    
    -- Release segments if they exist
    if sessionCopy.segments then
        for _, segment in ipairs(sessionCopy.segments) do
            if segment.events then
                for _, event in ipairs(segment.events) do
                    self:ReleaseTable(event)
                end
                self:ReleaseTable(segment.events)
            end
            self:ReleaseTable(segment)
        end
        self:ReleaseTable(sessionCopy.segments)
    end
    
    -- Release the main session copy
    self:ReleaseTable(sessionCopy)
end

-- Release session list returned by GetAllSessions or GetRecentSessions
-- NOTE: No longer needed since GetAllSessions/GetRecentSessions use regular tables
function StorageManager:ReleaseSessionList(sessionList)
    -- This function is deprecated since GetAllSessions/GetRecentSessions 
    -- now return regular tables that don't need to be released
end

function StorageManager:GetStatus()
    local stats = self:GetMemoryStats()
    return {
        isInitialized = isInitialized,
        sessionsStored = stats.sessionsStored,
        memoryUsageMB = stats.totalMemoryMB,
        compressionEnabled = false,  -- Always false now
        lastCleanup = memoryStats.lastCleanup
    }
end

-- Debug summary for slash commands
function StorageManager:GetDebugSummary()
    local status = self:GetStatus()
    local stats = self:GetMemoryStats()
    local poolStats = self:GetPoolStats()
    
    -- Count segmented sessions
    local segmentedSessions = 0
    local totalSegments = 0
    for _, session in ipairs(sessionStorage) do
        if session.isSegmented and session.segments then
            segmentedSessions = segmentedSessions + 1
            totalSegments = totalSegments + #session.segments
        end
    end
    
    return string.format(
        "StorageManager Status:\n" ..
        "  Initialized: %s\n" ..
        "  Sessions Stored: %d / %d (%.0f%%)\n" ..
        "  Segmented Sessions: %d (%.0f%% of total)\n" ..
        "  Total Segments: %d\n" ..
        "  Memory Usage: %.2f / %.1f MB (%.0f%%)\n" ..
        "  Session Age Limit: %d days\n" ..
        "  Compression: DISABLED\n" ..
        "  Recent Sessions: %d available\n" ..
        "Table Pool Stats:\n" ..
        "  Pool Size: %d / %d\n" ..
        "  Created: %d, Reused: %d (%.1f%% reuse)\n" ..
        "  Returned: %d, Warnings: %d, Corrupted: %d\n" ..
        "  Health Checks: %d\n" ..
        "  Overflow: %d created, %d collected",
        tostring(status.isInitialized),
        stats.sessionsStored,
        stats.maxSessions,
        (stats.sessionsStored / stats.maxSessions) * 100,
        segmentedSessions,
        stats.sessionsStored > 0 and (segmentedSessions / stats.sessionsStored) * 100 or 0,
        totalSegments,
        stats.totalMemoryMB,
        stats.maxMemoryMB,
        (stats.totalMemoryMB / stats.maxMemoryMB) * 100,
        stats.maxSessionAgeDays,
        math.min(5, stats.sessionsStored),
        poolStats.currentPoolSize,
        poolStats.maxPoolSize,
        poolStats.created,
        poolStats.reused,
        (poolStats.reuseRatio * 100),
        poolStats.returned,
        poolStats.warnings,
        poolStats.corrupted,
        poolStats.healthChecks,
        overflowStats.created,
        overflowStats.collected
    )
end

-- Export data for external tools
function StorageManager:ExportSessionsToTable()
    local exportData = {
        metadata = {
            exportTime = GetServerTime(),
            addonVersion = addon.VERSION,
            sessionCount = #sessionStorage
        },
        sessions = {}
    }
    
    for _, session in ipairs(sessionStorage) do
        local exportSession = {}
        for k, v in pairs(session) do
            exportSession[k] = v
        end
        
        -- Compression disabled - events are already uncompressed
        
        table.insert(exportData.sessions, exportSession)
    end
    
    return exportData
end