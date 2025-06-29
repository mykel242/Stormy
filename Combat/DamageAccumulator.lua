-- DamageAccumulator.lua
-- Real-time damage and healing accumulation with rolling window calculations
-- Heart of the STORMY system - all damage flows through here

local addonName, addon = ...

-- =============================================================================
-- DAMAGE ACCUMULATOR MODULE
-- =============================================================================

addon.DamageAccumulator = {}
local DamageAccumulator = addon.DamageAccumulator

-- Rolling window configurations
local WINDOWS = {
    CURRENT = 5,    -- 5 second "current" DPS
    SHORT = 15,     -- 15 second short-term average
    MEDIUM = 30,    -- 30 second medium-term average
    LONG = 60       -- 60 second encounter length
}

-- Accumulator state (all mutable in place for performance)
local accumulatorState = {
    -- Lifetime totals
    totalDamage = 0,
    totalHealing = 0,
    totalEvents = 0,
    
    -- Player vs Pet breakdown
    playerDamage = 0,
    petDamage = 0,
    playerHealing = 0,
    petHealing = 0,
    
    -- Peak tracking with decay
    peakDPS = 0,
    peakHPS = 0,
    peakDecayRate = 0.98, -- 2% decay per second
    lastPeakUpdate = 0,
    
    -- Current calculations (updated on request)
    currentDPS = 0,
    currentHPS = 0,
    lastCalculation = 0,
    
    -- Activity tracking
    lastDamageTime = 0,
    lastHealingTime = 0,
    eventsThisSecond = 0,
    currentSecond = 0,
    
    -- Efficiency metrics
    totalCritDamage = 0,
    totalCritHealing = 0,
    criticalHits = 0,
    totalHits = 0,
    
    -- Time tracking
    firstEventTime = 0,
    lastEventTime = 0
}

-- Rolling window data (separate arrays for performance)
local rollingData = {
    damage = {},    -- [timestamp] = amount
    healing = {},   -- [timestamp] = amount
    events = {},    -- [timestamp] = { damage = amount, healing = amount }
    
    -- Cached window totals (invalidated on new data)
    cachedTotals = {},
    lastCacheTime = 0,
    cacheValid = false
}

-- =============================================================================
-- CORE ACCUMULATION FUNCTIONS
-- =============================================================================

-- Add damage event (zero allocation)
function DamageAccumulator:AddDamage(timestamp, sourceGUID, amount, isPlayer, isPet, isCritical)
    local now = GetTime()
    
    -- Update activity tracking
    self:UpdateActivity(now)
    
    -- Store in rolling data
    self:StoreEvent(timestamp, amount, 0, isCritical)
    
    -- Update totals
    accumulatorState.totalDamage = accumulatorState.totalDamage + amount
    accumulatorState.totalEvents = accumulatorState.totalEvents + 1
    accumulatorState.lastDamageTime = now
    accumulatorState.lastEventTime = now
    
    -- Track first event
    if accumulatorState.firstEventTime == 0 then
        accumulatorState.firstEventTime = now
    end
    
    -- Player vs Pet breakdown
    if isPlayer then
        accumulatorState.playerDamage = accumulatorState.playerDamage + amount
    elseif isPet then
        accumulatorState.petDamage = accumulatorState.petDamage + amount
    end
    
    -- Critical hit tracking
    if isCritical then
        accumulatorState.totalCritDamage = accumulatorState.totalCritDamage + amount
        accumulatorState.criticalHits = accumulatorState.criticalHits + 1
    end
    accumulatorState.totalHits = accumulatorState.totalHits + 1
    
    -- Invalidate cache
    rollingData.cacheValid = false
end

-- Add healing event (zero allocation)
function DamageAccumulator:AddHealing(timestamp, sourceGUID, amount, isPlayer, isPet, isCritical)
    local now = GetTime()
    
    -- Update activity tracking
    self:UpdateActivity(now)
    
    -- Store in rolling data
    self:StoreEvent(timestamp, 0, amount, isCritical)
    
    -- Update totals
    accumulatorState.totalHealing = accumulatorState.totalHealing + amount
    accumulatorState.totalEvents = accumulatorState.totalEvents + 1
    accumulatorState.lastHealingTime = now
    accumulatorState.lastEventTime = now
    
    -- Track first event
    if accumulatorState.firstEventTime == 0 then
        accumulatorState.firstEventTime = now
    end
    
    -- Player vs Pet breakdown
    if isPlayer then
        accumulatorState.playerHealing = accumulatorState.playerHealing + amount
    elseif isPet then
        accumulatorState.petHealing = accumulatorState.petHealing + amount
    end
    
    -- Critical healing tracking
    if isCritical then
        accumulatorState.totalCritHealing = accumulatorState.totalCritHealing + amount
        accumulatorState.criticalHits = accumulatorState.criticalHits + 1
    end
    accumulatorState.totalHits = accumulatorState.totalHits + 1
    
    -- Invalidate cache
    rollingData.cacheValid = false
end

-- =============================================================================
-- ROLLING WINDOW CALCULATIONS
-- =============================================================================

-- Store event in rolling data structure
function DamageAccumulator:StoreEvent(timestamp, damageAmount, healingAmount, isCritical)
    -- Use TimingManager as single source of truth for all timestamps
    local relativeTime = addon.TimingManager:GetCurrentRelativeTime()
    
    -- Store in separate arrays for fast access
    if damageAmount > 0 then
        rollingData.damage[relativeTime] = (rollingData.damage[relativeTime] or 0) + damageAmount
    end
    
    if healingAmount > 0 then
        rollingData.healing[relativeTime] = (rollingData.healing[relativeTime] or 0) + healingAmount
    end
    
    -- Store combined event data
    if not rollingData.events[relativeTime] then
        rollingData.events[relativeTime] = { damage = 0, healing = 0, criticals = 0, hits = 0 }
    end
    
    local event = rollingData.events[relativeTime]
    event.damage = event.damage + damageAmount
    event.healing = event.healing + healingAmount
    event.hits = event.hits + 1
    if isCritical then
        event.criticals = event.criticals + 1
    end
end

-- Calculate totals for a specific time window
function DamageAccumulator:GetWindowTotals(windowSeconds)
    local now = addon.TimingManager:GetCurrentRelativeTime()
    local cutoffTime = now - windowSeconds
    
    -- Debug: first few calls to see what's happening
    local debugCount = 0
    local recentEvents = 0
    
    local totalDamage = 0
    local totalHealing = 0
    local eventCount = 0
    local critCount = 0
    
    -- Sum damage in window
    for timestamp, amount in pairs(rollingData.damage) do
        debugCount = debugCount + 1
        if timestamp >= cutoffTime then
            totalDamage = totalDamage + amount
            recentEvents = recentEvents + 1
        end
    end
    
    -- Debug: Print if we have issues with decay
    if debugCount > 0 and totalDamage > 0 and windowSeconds == 5 then
        local timeSinceLastEvent = now - accumulatorState.lastEventTime
        if timeSinceLastEvent > 10 and accumulatorState.totalEvents < 50 then  -- Only debug early in session
            -- print(string.format("[STORMY DEBUG] Window calc: %d total events, %d recent, %.1fs since last event", 
                -- debugCount, recentEvents, timeSinceLastEvent))
        end
    end
    
    -- Sum healing in window
    for timestamp, amount in pairs(rollingData.healing) do
        if timestamp >= cutoffTime then
            totalHealing = totalHealing + amount
        end
    end
    
    -- Count events and crits in window
    for timestamp, event in pairs(rollingData.events) do
        if timestamp >= cutoffTime then
            eventCount = eventCount + event.hits
            critCount = critCount + event.criticals
        end
    end
    
    return {
        damage = totalDamage,
        healing = totalHealing,
        events = eventCount,
        criticals = critCount,
        duration = windowSeconds,
        dps = windowSeconds > 0 and (totalDamage / windowSeconds) or 0,
        hps = windowSeconds > 0 and (totalHealing / windowSeconds) or 0,
        critPercent = eventCount > 0 and (critCount / eventCount * 100) or 0
    }
end

-- Clean old data beyond maximum window
function DamageAccumulator:CleanOldData()
    local maxWindow = WINDOWS.LONG
    local now = addon.TimingManager and addon.TimingManager:GetCurrentRelativeTime() or GetTime()
    local cutoffTime = now - maxWindow
    
    local cleaned = 0
    
    -- Clean damage data
    for timestamp in pairs(rollingData.damage) do
        if timestamp < cutoffTime then
            rollingData.damage[timestamp] = nil
            cleaned = cleaned + 1
        end
    end
    
    -- Clean healing data
    for timestamp in pairs(rollingData.healing) do
        if timestamp < cutoffTime then
            rollingData.healing[timestamp] = nil
        end
    end
    
    -- Clean event data
    for timestamp in pairs(rollingData.events) do
        if timestamp < cutoffTime then
            rollingData.events[timestamp] = nil
        end
    end
    
    -- Invalidate cache after cleanup
    rollingData.cacheValid = false
    
    return cleaned
end

-- =============================================================================
-- CURRENT DPS/HPS CALCULATIONS
-- =============================================================================

-- Calculate and cache current DPS/HPS
function DamageAccumulator:UpdateCurrentValues()
    local now = GetTime()
    
    -- Update peak values with decay
    self:UpdatePeaks(now)
    
    -- Calculate current values
    local currentWindow = self:GetWindowTotals(WINDOWS.CURRENT)
    accumulatorState.currentDPS = currentWindow.dps
    accumulatorState.currentHPS = currentWindow.hps
    
    -- Update peaks if current values are higher
    if accumulatorState.currentDPS > accumulatorState.peakDPS then
        accumulatorState.peakDPS = accumulatorState.currentDPS
    end
    
    if accumulatorState.currentHPS > accumulatorState.peakHPS then
        accumulatorState.peakHPS = accumulatorState.currentHPS
    end
    
    accumulatorState.lastCalculation = now
end

-- Update peak values with decay
function DamageAccumulator:UpdatePeaks(currentTime)
    local elapsed = currentTime - accumulatorState.lastPeakUpdate
    if elapsed > 0 then
        local decayFactor = accumulatorState.peakDecayRate ^ elapsed
        accumulatorState.peakDPS = accumulatorState.peakDPS * decayFactor
        accumulatorState.peakHPS = accumulatorState.peakHPS * decayFactor
        accumulatorState.lastPeakUpdate = currentTime
    end
end

-- =============================================================================
-- ACTIVITY TRACKING
-- =============================================================================

-- Update activity metrics
function DamageAccumulator:UpdateActivity(currentTime)
    local currentSecond = math.floor(currentTime)
    
    -- Reset counter if we've moved to a new second
    if currentSecond ~= accumulatorState.currentSecond then
        accumulatorState.eventsThisSecond = 0
        accumulatorState.currentSecond = currentSecond
    end
    
    accumulatorState.eventsThisSecond = accumulatorState.eventsThisSecond + 1
end

-- Get current activity level (0.0 to 1.0)
function DamageAccumulator:GetActivityLevel()
    local timeSinceLastEvent = GetTime() - accumulatorState.lastEventTime
    
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

-- Get current DPS (cached)
function DamageAccumulator:GetCurrentDPS()
    -- Update if stale
    if GetTime() - accumulatorState.lastCalculation > 0.5 then
        self:UpdateCurrentValues()
    end
    return accumulatorState.currentDPS
end

-- Get current HPS (cached)
function DamageAccumulator:GetCurrentHPS()
    -- Update if stale
    if GetTime() - accumulatorState.lastCalculation > 0.5 then
        self:UpdateCurrentValues()
    end
    return accumulatorState.currentHPS
end

-- Get peak DPS
function DamageAccumulator:GetPeakDPS()
    self:UpdatePeaks(GetTime())
    return accumulatorState.peakDPS
end

-- Get peak HPS
function DamageAccumulator:GetPeakHPS()
    self:UpdatePeaks(GetTime())
    return accumulatorState.peakHPS
end

-- Get comprehensive statistics
function DamageAccumulator:GetStats()
    -- Ensure current values are up to date
    self:UpdateCurrentValues()
    
    -- Calculate total encounter time
    local encounterDuration = 0
    if accumulatorState.firstEventTime > 0 then
        encounterDuration = GetTime() - accumulatorState.firstEventTime
    end
    
    -- Get window calculations
    local current = self:GetWindowTotals(WINDOWS.CURRENT)
    local short = self:GetWindowTotals(WINDOWS.SHORT)
    local medium = self:GetWindowTotals(WINDOWS.MEDIUM)
    
    return {
        -- Totals
        totalDamage = accumulatorState.totalDamage,
        totalHealing = accumulatorState.totalHealing,
        totalEvents = accumulatorState.totalEvents,
        
        -- Player vs Pet
        playerDamage = accumulatorState.playerDamage,
        petDamage = accumulatorState.petDamage,
        playerHealing = accumulatorState.playerHealing,
        petHealing = accumulatorState.petHealing,
        
        -- Current values
        currentDPS = accumulatorState.currentDPS,
        currentHPS = accumulatorState.currentHPS,
        peakDPS = self:GetPeakDPS(),
        peakHPS = self:GetPeakHPS(),
        
        -- Rolling windows
        current = current,
        short = short,
        medium = medium,
        
        -- Efficiency
        criticalPercent = accumulatorState.totalHits > 0 and 
                         (accumulatorState.criticalHits / accumulatorState.totalHits * 100) or 0,
        totalCritDamage = accumulatorState.totalCritDamage,
        totalCritHealing = accumulatorState.totalCritHealing,
        
        -- Activity
        encounterDuration = encounterDuration,
        activityLevel = self:GetActivityLevel(),
        eventsPerSecond = accumulatorState.eventsThisSecond,
        timeSinceLastEvent = GetTime() - accumulatorState.lastEventTime,
        
        -- Performance
        lastCalculation = accumulatorState.lastCalculation
    }
end

-- Get simple display data (for UI)
function DamageAccumulator:GetDisplayData()
    local stats = self:GetStats()
    
    return {
        currentDPS = math.floor(stats.currentDPS),
        peakDPS = math.floor(stats.peakDPS),
        totalDamage = stats.totalDamage,
        
        currentHPS = math.floor(stats.currentHPS),
        peakHPS = math.floor(stats.peakHPS),
        totalHealing = stats.totalHealing,
        
        critPercent = math.floor(stats.criticalPercent * 10) / 10, -- One decimal
        activityLevel = stats.activityLevel,
        encounterTime = math.floor(stats.encounterDuration)
    }
end

-- =============================================================================
-- MAINTENANCE AND DEBUGGING
-- =============================================================================

-- Reset all accumulated data
function DamageAccumulator:Reset()
    -- Clear state
    for key in pairs(accumulatorState) do
        if type(accumulatorState[key]) == "number" then
            accumulatorState[key] = 0
        end
    end
    
    -- Reset decay rate
    accumulatorState.peakDecayRate = 0.98
    
    -- Clear rolling data
    rollingData.damage = {}
    rollingData.healing = {}
    rollingData.events = {}
    rollingData.cachedTotals = {}
    rollingData.cacheValid = false
    
    -- print("[STORMY] DamageAccumulator reset")
end

-- Maintenance cleanup (called periodically)
function DamageAccumulator:Maintenance()
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
function DamageAccumulator:Debug()
    local stats = self:GetStats()
    print("=== DamageAccumulator Debug ===")
    print(string.format("Total Damage: %s (%.0f DPS)", self:FormatNumber(stats.totalDamage), stats.currentDPS))
    print(string.format("Peak DPS: %.0f", stats.peakDPS))
    print(string.format("Events: %d (%.1f%% crit)", stats.totalEvents, stats.criticalPercent))
    print(string.format("Player: %s (%.1f%%), Pet: %s (%.1f%%)", 
        self:FormatNumber(stats.playerDamage), 
        stats.totalDamage > 0 and (stats.playerDamage / stats.totalDamage * 100) or 0,
        self:FormatNumber(stats.petDamage),
        stats.totalDamage > 0 and (stats.petDamage / stats.totalDamage * 100) or 0))
    print(string.format("Activity: %.1f%%, Duration: %.1fs", stats.activityLevel * 100, stats.encounterDuration))
    
    -- Window breakdown
    print("Rolling Windows:")
    print(string.format("  5s: %.0f DPS", stats.current.dps))
    print(string.format("  15s: %.0f DPS", stats.short.dps))
    print(string.format("  30s: %.0f DPS", stats.medium.dps))
end

-- Format large numbers for display
function DamageAccumulator:FormatNumber(num)
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

-- Initialize the damage accumulator
function DamageAccumulator:Initialize()
    self:Reset()
    
    -- Set up periodic maintenance
    local maintenanceTimer = C_Timer.NewTicker(30, function()
        self:Maintenance()
    end)
    
    self.maintenanceTimer = maintenanceTimer
end

-- Module ready
DamageAccumulator.isReady = true