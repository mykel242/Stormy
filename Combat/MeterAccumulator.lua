-- MeterAccumulator.lua
-- Base class for accumulating meter data with rolling window calculations
-- Provides common functionality for damage, healing, damage taken, and other meters

local addonName, addon = ...

-- =============================================================================
-- METER ACCUMULATOR BASE CLASS
-- =============================================================================

addon.MeterAccumulator = {}
local MeterAccumulator = addon.MeterAccumulator

-- Rolling window configurations
local WINDOWS = {
    CURRENT = 5,    -- 5 second "current" metric
    SHORT = 15,     -- 15 second short-term average
    MEDIUM = 30,    -- 30 second medium-term average
    LONG = 60       -- 60 second encounter length
}

-- =============================================================================
-- BASE ACCUMULATOR CLASS
-- =============================================================================

function MeterAccumulator:New(meterType)
    local instance = {
        meterType = meterType,
        
        -- Accumulator state (all mutable in place for performance)
        state = {
            -- Lifetime totals
            totalValue = 0,
            totalEvents = 0,
            
            -- Player vs Pet breakdown
            playerValue = 0,
            petValue = 0,
            
            -- Peak tracking with decay
            peakMetric = 0,
            peakDecayRate = 0.98, -- 2% decay per second
            lastPeakUpdate = 0,
            
            -- Current calculations (updated on request)
            currentMetric = 0,
            lastCalculation = 0,
            
            -- Activity tracking
            lastEventTime = 0,
            eventsThisSecond = 0,
            currentSecond = 0,
            
            -- Efficiency metrics
            totalCritValue = 0,
            criticalHits = 0,
            totalHits = 0,
            
            -- Time tracking
            firstEventTime = 0,
            lastEventTime = 0
        },
        
        -- Rolling window data (separate arrays for performance)
        rollingData = {
            values = {},    -- [timestamp] = amount
            events = {},    -- [timestamp] = { value = amount, criticals = num, hits = num }
            
            -- Cached window totals (invalidated on new data)
            cachedTotals = {},
            lastCacheTime = 0,
            cacheValid = false
        }
    }
    
    -- Copy methods to instance
    for k, v in pairs(self) do
        if type(v) == "function" and k ~= "New" then
            instance[k] = v
        end
    end
    
    return instance
end

-- =============================================================================
-- CORE ACCUMULATION FUNCTIONS
-- =============================================================================

-- Add event (zero allocation)
function MeterAccumulator:AddEvent(timestamp, sourceGUID, amount, isPlayer, isPet, isCritical, extraData)
    local now = GetTime()
    
    -- Update activity tracking
    self:UpdateActivity(now)
    
    -- Store in rolling data
    self:StoreEvent(timestamp, amount, isCritical, extraData)
    
    -- Update totals
    self.state.totalValue = self.state.totalValue + amount
    self.state.totalEvents = self.state.totalEvents + 1
    self.state.lastEventTime = now
    
    -- Track first event
    if self.state.firstEventTime == 0 then
        self.state.firstEventTime = now
    end
    
    -- Player vs Pet breakdown
    if isPlayer then
        self.state.playerValue = self.state.playerValue + amount
    elseif isPet then
        self.state.petValue = self.state.petValue + amount
    end
    
    -- Critical hit tracking
    if isCritical then
        self.state.totalCritValue = self.state.totalCritValue + amount
        self.state.criticalHits = self.state.criticalHits + 1
    end
    self.state.totalHits = self.state.totalHits + 1
    
    -- Invalidate cache
    self.rollingData.cacheValid = false
    
    -- Allow subclasses to process additional logic
    if self.OnEvent then
        self:OnEvent(timestamp, sourceGUID, amount, isPlayer, isPet, isCritical, extraData)
    end
end

-- =============================================================================
-- ROLLING WINDOW CALCULATIONS
-- =============================================================================

-- Store event in rolling data structure
function MeterAccumulator:StoreEvent(timestamp, amount, isCritical, extraData)
    -- Use TimingManager as single source of truth for all timestamps
    local relativeTime = addon.TimingManager:GetCurrentRelativeTime()
    
    -- Store in values array for fast access
    self.rollingData.values[relativeTime] = (self.rollingData.values[relativeTime] or 0) + amount
    
    -- Store combined event data
    if not self.rollingData.events[relativeTime] then
        self.rollingData.events[relativeTime] = { 
            value = 0, 
            criticals = 0, 
            hits = 0,
            extraData = {}
        }
    end
    
    local event = self.rollingData.events[relativeTime]
    event.value = event.value + amount
    event.hits = event.hits + 1
    if isCritical then
        event.criticals = event.criticals + 1
    end
    
    -- Store extra data if provided
    if extraData and self.StoreExtraData then
        self:StoreExtraData(event, extraData)
    end
end

-- Calculate totals for a specific time window
function MeterAccumulator:GetWindowTotals(windowSeconds)
    local now = addon.TimingManager:GetCurrentRelativeTime()
    local cutoffTime = now - windowSeconds
    
    local totalValue = 0
    local eventCount = 0
    local critCount = 0
    
    -- Sum values in window
    for timestamp, amount in pairs(self.rollingData.values) do
        if timestamp >= cutoffTime then
            totalValue = totalValue + amount
        end
    end
    
    -- Count events and crits in window
    for timestamp, event in pairs(self.rollingData.events) do
        if timestamp >= cutoffTime then
            eventCount = eventCount + event.hits
            critCount = critCount + event.criticals
        end
    end
    
    local result = {
        value = totalValue,
        events = eventCount,
        criticals = critCount,
        duration = windowSeconds,
        metric = windowSeconds > 0 and (totalValue / windowSeconds) or 0,
        critPercent = eventCount > 0 and (critCount / eventCount * 100) or 0
    }
    
    -- Allow subclasses to add extra calculations
    if self.CalculateWindowExtras then
        self:CalculateWindowExtras(result, windowSeconds, cutoffTime)
    end
    
    return result
end

-- Clean old data beyond maximum window
function MeterAccumulator:CleanOldData()
    local maxWindow = WINDOWS.LONG
    local now = addon.TimingManager and addon.TimingManager:GetCurrentRelativeTime() or GetTime()
    local cutoffTime = now - maxWindow
    
    local cleaned = 0
    
    -- Clean values data
    for timestamp in pairs(self.rollingData.values) do
        if timestamp < cutoffTime then
            self.rollingData.values[timestamp] = nil
            cleaned = cleaned + 1
        end
    end
    
    -- Clean event data
    for timestamp in pairs(self.rollingData.events) do
        if timestamp < cutoffTime then
            self.rollingData.events[timestamp] = nil
        end
    end
    
    -- Invalidate cache after cleanup
    self.rollingData.cacheValid = false
    
    return cleaned
end

-- =============================================================================
-- CURRENT METRIC CALCULATIONS
-- =============================================================================

-- Calculate and cache current metric
function MeterAccumulator:UpdateCurrentValues()
    local now = GetTime()
    
    -- Update peak values with decay
    self:UpdatePeaks(now)
    
    -- Calculate current values
    local currentWindow = self:GetWindowTotals(WINDOWS.CURRENT)
    self.state.currentMetric = currentWindow.metric
    
    -- Update peaks if current values are higher
    if self.state.currentMetric > self.state.peakMetric then
        self.state.peakMetric = self.state.currentMetric
    end
    
    self.state.lastCalculation = now
end

-- Update peak values with decay
function MeterAccumulator:UpdatePeaks(currentTime)
    local elapsed = currentTime - self.state.lastPeakUpdate
    if elapsed > 0 then
        local decayFactor = self.state.peakDecayRate ^ elapsed
        self.state.peakMetric = self.state.peakMetric * decayFactor
        self.state.lastPeakUpdate = currentTime
    end
end

-- =============================================================================
-- ACTIVITY TRACKING
-- =============================================================================

-- Update activity metrics
function MeterAccumulator:UpdateActivity(currentTime)
    local currentSecond = math.floor(currentTime)
    
    -- Reset counter if we've moved to a new second
    if currentSecond ~= self.state.currentSecond then
        self.state.eventsThisSecond = 0
        self.state.currentSecond = currentSecond
    end
    
    self.state.eventsThisSecond = self.state.eventsThisSecond + 1
end

-- Get current activity level (0.0 to 1.0)
function MeterAccumulator:GetActivityLevel()
    local timeSinceLastEvent = GetTime() - self.state.lastEventTime
    
    -- Full activity if recent event
    if timeSinceLastEvent < 1.0 then
        return 1.0
    elseif timeSinceLastEvent < 5.0 then
        -- Decay over 5 seconds
        return 1.0 - ((timeSinceLastEvent - 1.0) / 4.0)
    else
        return 0.0
    end
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

-- Get current metric (cached)
function MeterAccumulator:GetCurrentMetric()
    -- Update if stale
    if GetTime() - self.state.lastCalculation > 0.5 then
        self:UpdateCurrentValues()
    end
    return self.state.currentMetric
end

-- Get peak metric
function MeterAccumulator:GetPeakMetric()
    self:UpdatePeaks(GetTime())
    return self.state.peakMetric
end

-- Get comprehensive statistics
function MeterAccumulator:GetStats()
    -- Ensure current values are up to date
    self:UpdateCurrentValues()
    
    -- Calculate total encounter time
    local encounterDuration = 0
    if self.state.firstEventTime > 0 then
        encounterDuration = GetTime() - self.state.firstEventTime
    end
    
    -- Get window calculations
    local current = self:GetWindowTotals(WINDOWS.CURRENT)
    local short = self:GetWindowTotals(WINDOWS.SHORT)
    local medium = self:GetWindowTotals(WINDOWS.MEDIUM)
    
    local stats = {
        -- Totals
        totalValue = self.state.totalValue,
        totalEvents = self.state.totalEvents,
        
        -- Player vs Pet
        playerValue = self.state.playerValue,
        petValue = self.state.petValue,
        
        -- Current values
        currentMetric = self.state.currentMetric,
        peakMetric = self:GetPeakMetric(),
        
        -- Rolling windows
        current = current,
        short = short,
        medium = medium,
        
        -- Efficiency
        criticalPercent = self.state.totalHits > 0 and 
                         (self.state.criticalHits / self.state.totalHits * 100) or 0,
        totalCritValue = self.state.totalCritValue,
        
        -- Activity
        encounterDuration = encounterDuration,
        activityLevel = self:GetActivityLevel(),
        eventsPerSecond = self.state.eventsThisSecond,
        timeSinceLastEvent = GetTime() - self.state.lastEventTime,
        
        -- Performance
        lastCalculation = self.state.lastCalculation,
        
        -- Type
        meterType = self.meterType
    }
    
    -- Allow subclasses to add extra stats
    if self.GetExtraStats then
        self:GetExtraStats(stats)
    end
    
    return stats
end

-- Get simple display data (for UI)
function MeterAccumulator:GetDisplayData()
    local stats = self:GetStats()
    
    local displayData = {
        currentMetric = math.floor(stats.currentMetric),
        peakMetric = math.floor(stats.peakMetric),
        totalValue = stats.totalValue,
        playerValue = stats.playerValue,
        petValue = stats.petValue,
        critPercent = math.floor(stats.criticalPercent * 10) / 10, -- One decimal
        activityLevel = stats.activityLevel,
        encounterTime = math.floor(stats.encounterDuration),
        meterType = self.meterType
    }
    
    -- Allow subclasses to modify display data
    if self.ModifyDisplayData then
        self:ModifyDisplayData(displayData, stats)
    end
    
    return displayData
end

-- =============================================================================
-- MAINTENANCE AND DEBUGGING
-- =============================================================================

-- Reset all accumulated data
function MeterAccumulator:Reset()
    -- Clear state
    for key in pairs(self.state) do
        if type(self.state[key]) == "number" then
            self.state[key] = 0
        end
    end
    
    -- Reset decay rate
    self.state.peakDecayRate = 0.98
    
    -- Clear rolling data
    self.rollingData.values = {}
    self.rollingData.events = {}
    self.rollingData.cachedTotals = {}
    self.rollingData.cacheValid = false
    
    -- Allow subclasses to reset additional data
    if self.OnReset then
        self:OnReset()
    end
end

-- Maintenance cleanup (called periodically)
function MeterAccumulator:Maintenance()
    local cleaned = self:CleanOldData()
    
    if cleaned > 0 then
        -- Force garbage collection if we cleaned a lot
        if cleaned > 100 then
            collectgarbage("step", 100)
        end
    end
    
    return cleaned
end

-- Debug information
function MeterAccumulator:Debug()
    local stats = self:GetStats()
    print(string.format("=== %s MeterAccumulator Debug ===", self.meterType or "Unknown"))
    print(string.format("Total Value: %s (%.0f per second)", self:FormatNumber(stats.totalValue), stats.currentMetric))
    print(string.format("Peak: %.0f", stats.peakMetric))
    print(string.format("Events: %d (%.1f%% crit)", stats.totalEvents, stats.criticalPercent))
    print(string.format("Player: %s (%.1f%%), Pet: %s (%.1f%%)", 
        self:FormatNumber(stats.playerValue), 
        stats.totalValue > 0 and (stats.playerValue / stats.totalValue * 100) or 0,
        self:FormatNumber(stats.petValue),
        stats.totalValue > 0 and (stats.petValue / stats.totalValue * 100) or 0))
    print(string.format("Activity: %.1f%%, Duration: %.1fs", stats.activityLevel * 100, stats.encounterDuration))
    
    -- Window breakdown
    print("Rolling Windows:")
    print(string.format("  5s: %.0f per second", stats.current.metric))
    print(string.format("  15s: %.0f per second", stats.short.metric))
    print(string.format("  30s: %.0f per second", stats.medium.metric))
    
    -- Allow subclasses to add debug info
    if self.DebugExtra then
        self:DebugExtra(stats)
    end
end

-- Format large numbers for display
function MeterAccumulator:FormatNumber(num)
    if num >= 1000000 then
        return string.format("%.1fM", num / 1000000)
    elseif num >= 1000 then
        return string.format("%.1fK", num / 1000)
    else
        return tostring(math.floor(num))
    end
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the accumulator
function MeterAccumulator:Initialize()
    self:Reset()
    
    -- Set up periodic maintenance
    local maintenanceTimer = C_Timer.NewTicker(30, function()
        self:Maintenance()
    end)
    
    self.maintenanceTimer = maintenanceTimer
end

-- Module ready
MeterAccumulator.isReady = true

return MeterAccumulator