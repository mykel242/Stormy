-- TimingManager.lua
-- High-precision timing management for combat events
-- Simplified from MyTimestampManager for performance focus

local addonName, addon = ...

-- =============================================================================
-- TIMING MANAGER MODULE
-- =============================================================================

addon.TimingManager = {}
local TimingManager = addon.TimingManager

-- Timing state (single source of truth)
local timingState = {
    startTime = 0,              -- GetTime() when addon started (baseline)
    logTimeOffset = 0,          -- Offset between combat log and GetTime()
    hasLogOffset = false,       -- Whether offset has been established
    lastEventTime = 0           -- Last event processed (for gaps)
}

-- Performance tracking
local performanceState = {
    eventsThisSecond = 0,
    lastEventCount = 0,
    currentSecond = 0,
    peakEventsPerSecond = 0
}

-- =============================================================================
-- CORE TIMING API
-- =============================================================================

-- Start combat timing
function TimingManager:StartCombat()
    local now = GetTime()
    
    timingState.combatStartTime = now
    timingState.combatEndTime = 0
    timingState.isInCombat = true
    timingState.logTimeOffset = 0
    timingState.hasLogOffset = false
    timingState.lastEventTime = now
    
    -- Reset performance tracking
    performanceState.eventsThisSecond = 0
    performanceState.lastEventCount = 0
    performanceState.currentSecond = math.floor(now)
    
    return now
end

-- End combat timing
function TimingManager:EndCombat()
    local now = GetTime()
    
    timingState.combatEndTime = now
    timingState.isInCombat = false
    
    return now
end

-- Get combat duration
function TimingManager:GetCombatDuration()
    if not timingState.isInCombat then
        if timingState.combatEndTime > 0 and timingState.combatStartTime > 0 then
            return timingState.combatEndTime - timingState.combatStartTime
        else
            return 0
        end
    else
        if timingState.combatStartTime > 0 then
            return GetTime() - timingState.combatStartTime
        else
            return 0
        end
    end
end

-- Convert combat log timestamp to relative time (SSOT for all events)
function TimingManager:GetRelativeTime(logTimestamp)
    -- Use current time as relative timestamp (simplified for consistency)
    return GetTime() - timingState.startTime
end

-- Get current relative time (SSOT)
function TimingManager:GetCurrentRelativeTime()
    return GetTime() - timingState.startTime
end

-- =============================================================================
-- PERFORMANCE MONITORING
-- =============================================================================

-- Track event for performance monitoring
function TimingManager:TrackEvent()
    local now = GetTime()
    local currentSecond = math.floor(now)
    
    -- Reset counter if we've moved to a new second
    if currentSecond ~= performanceState.currentSecond then
        performanceState.lastEventCount = performanceState.eventsThisSecond
        performanceState.peakEventsPerSecond = math.max(
            performanceState.peakEventsPerSecond, 
            performanceState.eventsThisSecond
        )
        performanceState.eventsThisSecond = 0
        performanceState.currentSecond = currentSecond
    end
    
    performanceState.eventsThisSecond = performanceState.eventsThisSecond + 1
    timingState.lastEventTime = now
end

-- Get current events per second
function TimingManager:GetEventsPerSecond()
    local now = GetTime()
    local currentSecond = math.floor(now)
    
    if currentSecond == performanceState.currentSecond then
        return performanceState.eventsThisSecond
    else
        return performanceState.lastEventCount
    end
end

-- Get peak events per second
function TimingManager:GetPeakEventsPerSecond()
    return performanceState.peakEventsPerSecond
end

-- Check if we're in a high-activity period
function TimingManager:IsHighActivity()
    return self:GetEventsPerSecond() > addon.Constants.PERFORMANCE.EVENTS_PER_SECOND_NORMAL
end

-- Check if we're in intensive combat
function TimingManager:IsIntensiveCombat()
    return self:GetEventsPerSecond() > addon.Constants.PERFORMANCE.EVENTS_PER_SECOND_INTENSIVE
end

-- =============================================================================
-- STATE ACCESS
-- =============================================================================

-- Check if currently in combat
function TimingManager:IsInCombat()
    return timingState.isInCombat
end

-- Get combat start time
function TimingManager:GetCombatStartTime()
    return timingState.combatStartTime
end

-- Get time since last event (for gap detection)
function TimingManager:GetTimeSinceLastEvent()
    if timingState.lastEventTime == 0 then
        return 0
    end
    return GetTime() - timingState.lastEventTime
end

-- =============================================================================
-- TIME WINDOWING UTILITIES
-- =============================================================================

-- Check if a timestamp is within the calculation window
function TimingManager:IsWithinWindow(timestamp, windowSeconds)
    local currentTime = self:GetCurrentRelativeTime()
    local relativeTime = self:GetRelativeTime(timestamp)
    
    return (currentTime - relativeTime) <= windowSeconds
end

-- Get timestamps for a time window (for ring buffer queries)
function TimingManager:GetWindowBounds(windowSeconds)
    local currentTime = self:GetCurrentRelativeTime()
    local startTime = math.max(0, currentTime - windowSeconds)
    
    return startTime, currentTime
end

-- =============================================================================
-- DEBUGGING AND MONITORING
-- =============================================================================

-- Get timing state for debugging
function TimingManager:GetState()
    return {
        combatStartTime = timingState.combatStartTime,
        combatEndTime = timingState.combatEndTime,
        isInCombat = timingState.isInCombat,
        logTimeOffset = timingState.logTimeOffset,
        hasLogOffset = timingState.hasLogOffset,
        combatDuration = self:GetCombatDuration(),
        currentRelativeTime = self:GetCurrentRelativeTime(),
        eventsPerSecond = self:GetEventsPerSecond(),
        peakEventsPerSecond = self:GetPeakEventsPerSecond(),
        timeSinceLastEvent = self:GetTimeSinceLastEvent(),
        isHighActivity = self:IsHighActivity(),
        isIntensiveCombat = self:IsIntensiveCombat()
    }
end

-- Debug dump
function TimingManager:Debug()
    local state = self:GetState()
    print("=== TimingManager Debug ===")
    print(string.format("Combat: %s (Duration: %.1fs)", 
        state.isInCombat and "ACTIVE" or "INACTIVE", state.combatDuration))
    print(string.format("Activity: %d/sec (Peak: %d/sec)", 
        state.eventsPerSecond, state.peakEventsPerSecond))
    print(string.format("Relative Time: %.3fs", state.currentRelativeTime))
    if state.hasLogOffset then
        print(string.format("Log Offset: %.3fs", state.logTimeOffset))
    else
        print("Log Offset: Not established")
    end
end

-- Initialize the timing manager
function TimingManager:Initialize()
    -- Set start time as baseline for all relative timestamps
    timingState.startTime = GetTime()
    timingState.logTimeOffset = 0
    timingState.hasLogOffset = false
    timingState.lastEventTime = 0
    
    performanceState = {
        eventsThisSecond = 0,
        lastEventCount = 0,
        currentSecond = math.floor(GetTime()),
        peakEventsPerSecond = 0
    }
end

-- Module ready
TimingManager.isReady = true