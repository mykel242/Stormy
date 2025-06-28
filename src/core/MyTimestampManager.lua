-- MyTimestampManager.lua
-- Unified timestamp management - single source of truth for all combat timing

local addonName, addon = ...

-- Self-contained module with internal debugging
local MyTimestampManager = {}
addon.MyTimestampManager = MyTimestampManager

-- Internal debug configuration
local DEBUG_MODE = false
local logger = nil -- Injected logger instance

-- Internal debug function with logger fallback
local function debugPrint(...)
    if logger and logger.Debug then
        logger:Debug(...)
    elseif DEBUG_MODE then
        print("[MyTimestampManager]", ...)
    end
end

-- Trace function for very verbose logging
local function tracePrint(...)
    if logger and logger.Trace then
        logger:Trace(...)
    elseif DEBUG_MODE then
        print("[MyTimestampManager][TRACE]", ...)
    end
end

-- =============================================================================
-- UNIFIED TIMESTAMP SYSTEM
-- =============================================================================

-- Single source of truth for combat timing
local timestampData = {
    combatStartTime = nil,      -- GetTime() when combat started (baseline)
    combatEndTime = nil,        -- GetTime() when combat ended
    isActive = false,           -- Is combat currently active
    -- Store the offset between combat log time and GetTime() when combat starts
    logTimeOffset = nil         -- (firstCombatLogTime - combatStartTime) for conversion
}

-- =============================================================================
-- CORE TIMESTAMP API
-- =============================================================================

-- Start a new combat session
function MyTimestampManager:StartCombat(logTimestamp)
    timestampData.combatStartTime = GetTime()
    timestampData.combatEndTime = nil
    timestampData.isActive = true
    timestampData.logTimeOffset = nil  -- Will be set when we get the first combat log event
    
    logger:Debug("TimestampManager: Combat started - GetTime: %.3f", 
        timestampData.combatStartTime)
end

-- End the current combat session
function MyTimestampManager:EndCombat()
    timestampData.combatEndTime = GetTime()
    timestampData.isActive = false
    
    local duration = self:GetCombatDuration()
    logger:Debug("TimestampManager: Combat ended - Duration: %.3fs", duration)
end

-- Set the log time offset (called by the first combat log event after combat starts)
function MyTimestampManager:SetLogTimeOffset(firstLogTimestamp)
    if not timestampData.logTimeOffset and timestampData.isActive then
        local currentGetTime = GetTime()
        timestampData.logTimeOffset = firstLogTimestamp - timestampData.combatStartTime
        
        logger:Trace("TimestampManager: Set log offset - FirstLog: %.3f, Offset: %.3f", 
            firstLogTimestamp, timestampData.logTimeOffset)
    end
end

-- Convert any timestamp to relative time since combat start
function MyTimestampManager:GetRelativeTime(inputTimestamp)
    if not timestampData.combatStartTime then
        logger:Debug("GetRelativeTime called but no combat start time - returning 0")
        return 0
    end
    
    if not inputTimestamp then
        logger:Debug("GetRelativeTime called with nil timestamp - returning 0")
        return 0
    end
    
    -- Combat log timestamps are large numbers (server time), GetTime() are smaller (client uptime)
    if inputTimestamp > 1000000 then
        -- This is a combat log timestamp
        if not timestampData.logTimeOffset then
            -- This is the first combat log event - set the offset
            self:SetLogTimeOffset(inputTimestamp)
        end
        
        -- Convert using the established offset
        local relativeTime = inputTimestamp - (timestampData.combatStartTime + timestampData.logTimeOffset)
        
        -- Removed: Per-event trace logging caused massive spam
        return relativeTime
    else
        -- This is already a GetTime() timestamp
        local relativeTime = inputTimestamp - timestampData.combatStartTime
        -- Removed: Per-event trace logging caused massive spam
        return relativeTime
    end
end

-- Get current relative time since combat start
function MyTimestampManager:GetCurrentRelativeTime()
    if not timestampData.combatStartTime then
        return 0
    end
    return GetTime() - timestampData.combatStartTime
end

-- Get total combat duration
function MyTimestampManager:GetCombatDuration()
    if not timestampData.combatStartTime then
        return 0
    end
    
    local endTime = timestampData.combatEndTime or GetTime()
    return endTime - timestampData.combatStartTime
end

-- =============================================================================
-- STATUS AND DEBUG API
-- =============================================================================

-- Check if combat is active
function MyTimestampManager:IsActive()
    return timestampData.isActive
end

-- Get all timestamp data for debugging
function MyTimestampManager:GetTimestampData()
    return {
        combatStartTime = timestampData.combatStartTime,
        combatEndTime = timestampData.combatEndTime,
        isActive = timestampData.isActive,
        logTimeOffset = timestampData.logTimeOffset,
        currentRelativeTime = self:GetCurrentRelativeTime(),
        totalDuration = self:GetCombatDuration()
    }
end


-- Reset all timestamp data
function MyTimestampManager:Reset()
    timestampData.combatStartTime = nil
    timestampData.combatEndTime = nil
    timestampData.isActive = false
    timestampData.logTimeOffset = nil
    
    logger:Debug("TimestampManager: Reset complete")
end

-- =============================================================================
-- VALIDATION AND TESTING
-- =============================================================================

-- Validate timestamp conversion
function MyTimestampManager:ValidateTimestamp(inputTimestamp, expectedRange)
    local relativeTime = self:GetRelativeTime(inputTimestamp)
    local currentDuration = self:GetCombatDuration()
    
    local isValid = relativeTime >= 0 and relativeTime <= currentDuration
    
    if expectedRange then
        isValid = isValid and relativeTime >= expectedRange.min and relativeTime <= expectedRange.max
    end
    
    -- Removed: Per-event validation trace caused massive spam
    
    return isValid, relativeTime
end

-- Get debug summary
function MyTimestampManager:GetDebugSummary()
    local data = self:GetTimestampData()
    local summary = "=== TIMESTAMP MANAGER DEBUG ==="
    summary = summary .. string.format("\nCombat Active: %s", tostring(data.isActive))
    summary = summary .. string.format("\nStart Time (GetTime): %.3f", data.combatStartTime or 0)
    summary = summary .. string.format("\nLog Time Offset: %.3f", data.logTimeOffset or 0)
    summary = summary .. string.format("\nCurrent Relative: %.3f", data.currentRelativeTime)
    summary = summary .. string.format("\nTotal Duration: %.3f", data.totalDuration)
    summary = summary .. "\n============================="
    return summary
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

function MyTimestampManager:Initialize(injectedLogger)
    -- Inject logger and validate it exists with required methods
    assert(injectedLogger, "MyTimestampManager requires a logger instance")
    assert(type(injectedLogger.Debug) == "function", "Logger must have Debug method")
    assert(type(injectedLogger.Trace) == "function", "Logger must have Trace method")
    
    logger = injectedLogger
    
    self:Reset()
    
    logger:Debug("MyTimestampManager: Initialized")
end

-- Enable/disable internal debug mode
function MyTimestampManager:SetInternalDebug(enabled)
    DEBUG_MODE = enabled
    debugPrint("Internal debug mode:", enabled and "enabled" or "disabled")
end

debugPrint("MyTimestampManager module loaded")
return MyTimestampManager