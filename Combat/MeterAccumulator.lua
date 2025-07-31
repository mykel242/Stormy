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
            firstEventTime = 0
        },
        
        -- Rolling window data (separate arrays for performance)
        rollingData = {
            values = {},    -- [timestamp] = amount
            events = {},    -- [timestamp] = { value = amount, criticals = num, hits = num }
            
            -- Cached window totals (invalidated on new data)
            cachedTotals = {},
            lastCacheTime = 0,
            cacheValid = false,
            
            -- NEW: Ring buffer for detailed events
            detailBuffer = {
                buffer = nil,      -- Will be initialized based on size
                size = 9000,       -- Default, will be configured
                head = 1,          -- Next write position
                tail = 1,          -- Oldest data position
                count = 0,         -- Current number of items
                timeIndex = {},    -- [flooredTimestamp] = {startIdx, endIdx}
                initialized = false
            },
            
            -- Per-second summaries
            secondSummaries = {}   -- [timestamp] = summary table from pool
        },
        
        -- Configuration
        detailBufferMode = "AUTO"  -- AUTO, SOLO, DUNGEON, RAID, MYTHIC, CUSTOM
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
-- RING BUFFER MANAGEMENT
-- =============================================================================

-- Initialize the detail buffer with appropriate size
function MeterAccumulator:InitializeDetailBuffer()
    local buffer = self.rollingData.detailBuffer
    
    -- Don't reinitialize if already done
    if buffer.initialized then
        return
    end
    
    -- Determine optimal buffer size
    buffer.size = self:GetOptimalBufferSize()
    
    -- Pre-allocate all tables
    buffer.buffer = {}
    for i = 1, buffer.size do
        buffer.buffer[i] = addon.TablePool:GetDetail()
    end
    
    buffer.head = 1
    buffer.tail = 1
    buffer.count = 0
    buffer.timeIndex = {}
    buffer.initialized = true
end

-- Get optimal buffer size based on mode or activity
function MeterAccumulator:GetOptimalBufferSize()
    local mode = self.detailBufferMode or "AUTO"
    local Constants = addon.Constants
    
    if mode == "AUTO" then
        -- Use recent event rate to determine size
        local recentRate = self:GetRecentEventRate()
        if recentRate < Constants.DETAIL_BUFFER.AUTO_THRESHOLDS.SOLO then
            return Constants.DETAIL_BUFFER.SIZES.SOLO
        elseif recentRate < Constants.DETAIL_BUFFER.AUTO_THRESHOLDS.DUNGEON then
            return Constants.DETAIL_BUFFER.SIZES.DUNGEON
        elseif recentRate < Constants.DETAIL_BUFFER.AUTO_THRESHOLDS.RAID then
            return Constants.DETAIL_BUFFER.SIZES.RAID
        else
            return Constants.DETAIL_BUFFER.SIZES.MYTHIC
        end
    else
        return Constants.DETAIL_BUFFER.SIZES[mode] or Constants.DETAIL_BUFFER.SIZES.CUSTOM
    end
end

-- Get recent event rate (events per second over last 30 seconds)
function MeterAccumulator:GetRecentEventRate()
    local now = GetTime()
    local cutoff = now - 30
    local count = 0
    
    for timestamp in pairs(self.rollingData.values) do
        if timestamp > cutoff then
            count = count + 1
        end
    end
    
    return count / 30
end

-- Add detailed event to ring buffer
function MeterAccumulator:AddDetailedEvent(timestamp, amount, spellId, sourceGUID, sourceName, sourceType, isCrit)
    -- Debug: Log detailed events occasionally
    if math.random() < 0.05 then  -- 5% chance
        print(string.format("[STORMY DEBUG] AddDetailedEvent: spell=%s, amount=%s, time=%s", tostring(spellId), tostring(amount), tostring(timestamp)))
    end
    
    local buffer = self.rollingData.detailBuffer
    
    -- Initialize if needed
    if not buffer.initialized then
        self:InitializeDetailBuffer()
    end
    
    -- Get table at head position (already allocated)
    local detail = buffer.buffer[buffer.head]
    
    -- Populate with new data
    detail.timestamp = timestamp
    detail.amount = amount
    detail.spellId = spellId or 0
    detail.sourceGUID = sourceGUID or ""
    detail.sourceName = sourceName or ""
    detail.sourceType = sourceType or 0
    detail.isCrit = isCrit or false
    
    -- Update time index
    local flooredTime = math.floor(timestamp)
    local timeEntry = buffer.timeIndex[flooredTime]
    if not timeEntry then
        buffer.timeIndex[flooredTime] = {startIdx = buffer.head, endIdx = buffer.head, count = 1}
    else
        timeEntry.endIdx = buffer.head
        timeEntry.count = timeEntry.count + 1
    end
    
    -- Update second summary
    self:UpdateSecondSummary(flooredTime, amount, spellId, isCrit)
    
    -- Advance head
    buffer.head = buffer.head % buffer.size + 1
    
    -- Handle wrap-around
    if buffer.count < buffer.size then
        buffer.count = buffer.count + 1
    else
        -- Overwriting old data
        buffer.tail = buffer.tail % buffer.size + 1
        -- Clean up old time index entry
        self:CleanupOldTimeIndex(buffer.buffer[buffer.tail].timestamp)
    end
end

-- Update per-second summary
function MeterAccumulator:UpdateSecondSummary(timestamp, amount, spellId, isCrit)
    local summary = self.rollingData.secondSummaries[timestamp]
    
    if not summary then
        summary = addon.TablePool:GetSummary()
        summary.timestamp = timestamp
        summary.totalDamage = 0
        summary.eventCount = 0
        summary.critCount = 0
        summary.critDamage = 0
        -- spells table already exists from pool
        self.rollingData.secondSummaries[timestamp] = summary
    end
    
    -- Update totals
    summary.totalDamage = summary.totalDamage + amount
    summary.eventCount = summary.eventCount + 1
    
    if isCrit then
        summary.critCount = summary.critCount + 1
        summary.critDamage = summary.critDamage + amount
    end
    
    -- Update spell breakdown
    if spellId and spellId > 0 then
        local baseSpellId = addon.SpellCache:GetBaseSpellId(spellId)
        if not summary.spells[baseSpellId] then
            summary.spells[baseSpellId] = {
                total = 0,
                count = 0,
                crits = 0
            }
        end
        
        local spell = summary.spells[baseSpellId]
        spell.total = spell.total + amount
        spell.count = spell.count + 1
        if isCrit then
            spell.crits = spell.crits + 1
        end
    else
        -- Debug: Log when spellId is invalid
        print(string.format("[STORMY DEBUG] Invalid spellId: %s, amount: %s, timestamp: %s", tostring(spellId), tostring(amount), tostring(timestamp)))
    end
end

-- Clean up old time index entry
function MeterAccumulator:CleanupOldTimeIndex(timestamp)
    if not timestamp then return end
    
    local flooredTime = math.floor(timestamp)
    self.rollingData.detailBuffer.timeIndex[flooredTime] = nil
    
    -- Also clean up second summary
    local summary = self.rollingData.secondSummaries[flooredTime]
    if summary then
        addon.TablePool:ReleaseSummary(summary)
        self.rollingData.secondSummaries[flooredTime] = nil
    end
end

-- Get events for a specific second
function MeterAccumulator:GetSecondDetails(timestamp)
    local buffer = self.rollingData.detailBuffer
    local flooredTime = math.floor(timestamp)
    
    -- First check if we have a summary
    local summary = self.rollingData.secondSummaries[flooredTime]
    if not summary then
        return nil
    end
    
    -- Get the events if requested
    local timeEntry = buffer.timeIndex[flooredTime]
    if not timeEntry then
        return summary
    end
    
    -- Collect events from ring buffer
    local events = {}
    local idx = timeEntry.startIdx
    for i = 1, timeEntry.count do
        local event = buffer.buffer[idx]
        if math.floor(event.timestamp) == flooredTime then
            table.insert(events, {
                timestamp = event.timestamp,
                amount = event.amount,
                spellId = event.spellId,
                sourceGUID = event.sourceGUID,
                sourceName = event.sourceName,
                sourceType = event.sourceType,
                isCrit = event.isCrit
            })
        end
        
        idx = idx % buffer.size + 1
    end
    
    return summary, events
end

-- =============================================================================
-- ROLLING WINDOW CALCULATIONS
-- =============================================================================

-- Store event in rolling data structure
function MeterAccumulator:StoreEvent(timestamp, amount, isCritical, extraData)
    -- Convert timestamp to relative time using TimingManager
    local relativeTime = addon.TimingManager:GetRelativeTime(timestamp)
    
    -- Only store if we get a valid number
    if type(relativeTime) ~= "number" then
        return
    end
    
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
    
    -- Activity-based data expiration: if no events for longer than the window, return zeros
    local timeSinceLastEvent = self.state.lastEventTime > 0 and (GetTime() - self.state.lastEventTime) or 0
    if timeSinceLastEvent > windowSeconds then
        return {
            value = 0,
            events = 0,
            criticals = 0,
            duration = windowSeconds,
            metric = 0,
            metricPS = 0,
            critPercent = 0
        }
    end
    
    local totalValue = 0
    local eventCount = 0
    local critCount = 0
    
    -- Sum values in window
    for timestamp, amount in pairs(self.rollingData.values) do
        if type(timestamp) == "number" and timestamp >= cutoffTime then
            totalValue = totalValue + amount
        end
    end
    
    -- Count events and crits in window
    for timestamp, event in pairs(self.rollingData.events) do
        if type(timestamp) == "number" and timestamp >= cutoffTime then
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
        metricPS = windowSeconds > 0 and (totalValue / windowSeconds) or 0,
        critPercent = eventCount > 0 and (critCount / eventCount * 100) or 0
    }
    
    -- Allow subclasses to add extra calculations
    if self.CalculateWindowExtras then
        self:CalculateWindowExtras(result, windowSeconds, cutoffTime)
    end
    
    return result
end

-- Get time series data for plotting (aligned to fixed bucket boundaries)
function MeterAccumulator:GetTimeSeriesData(startTime, endTime, bucketSize)
    bucketSize = bucketSize or 1  -- Default to 1-second buckets
    
    local buckets = {}
    
    -- Align start time to bucket boundary (floor to nearest bucket)
    local alignedStartTime = math.floor(startTime / bucketSize) * bucketSize
    local currentTime = alignedStartTime
    
    -- Create time buckets aligned to fixed boundaries
    while currentTime <= endTime do
        local bucketEnd = currentTime + bucketSize
        local totalValue = 0
        
        -- Sum all events in this time bucket
        for timestamp, amount in pairs(self.rollingData.values) do
            if type(timestamp) == "number" and timestamp >= currentTime and timestamp < bucketEnd then
                totalValue = totalValue + amount
            end
        end
        
        table.insert(buckets, {
            time = currentTime,
            value = totalValue  -- Raw total damage/healing in this bucket
        })
        
        currentTime = currentTime + bucketSize
    end
    
    return buckets
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
    
    -- Clean second summaries older than detail retention time
    -- But preserve data that might be viewed by paused plots
    local detailCutoff = now - addon.Constants.DETAIL_BUFFER.RETENTION_TIME
    
    -- Check if any plots are paused and extend retention accordingly
    local minPausedTime = detailCutoff
    
    -- Check both DPS and HPS plots if they exist
    for _, plotKey in ipairs({"DPSPlot", "HPSPlot"}) do
        local plot = addon[plotKey]
        if plot and plot.plotState and plot.plotState.mode == "PAUSED" then
            local pausedAt = plot.plotState.pausedAt
            if pausedAt then
                local pausedRelativeTime = addon.TimingManager and addon.TimingManager:GetRelativeTime(pausedAt) or pausedAt
                local plotWindowStart = pausedRelativeTime - (plot.config and plot.config.timeWindow or 60)
                minPausedTime = math.min(minPausedTime, plotWindowStart - 30) -- Extra 30s buffer
                print(string.format("[STORMY DEBUG] %s is paused, extending retention to preserve data from %d", plotKey, plotWindowStart - 30))
            end
        end
    end
    
    for timestamp, summary in pairs(self.rollingData.secondSummaries) do
        if timestamp < minPausedTime then
            addon.TablePool:ReleaseSummary(summary)
            self.rollingData.secondSummaries[timestamp] = nil
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
    
    -- Event gap detection: if gap is larger than current window, reset current metric
    local timeSinceLastEvent = self.state.lastEventTime > 0 and (now - self.state.lastEventTime) or 0
    if timeSinceLastEvent > WINDOWS.CURRENT then
        self.state.currentMetric = 0
        self.state.lastCalculation = now
        -- Still update peaks to allow decay
        self:UpdatePeaks(now)
        return
    end
    
    -- Update peak values with decay
    self:UpdatePeaks(now)
    
    -- Calculate current values
    local currentWindow = self:GetWindowTotals(WINDOWS.CURRENT)
    self.state.currentMetric = currentWindow.metricPS or currentWindow.metric
    
    self.state.lastCalculation = now
end

-- Update peak values with decay
function MeterAccumulator:UpdatePeaks(currentTime)
    -- Update peak if current is higher
    if self.state.currentMetric > self.state.peakMetric then
        self.state.peakMetric = self.state.currentMetric
    end
    
    -- Apply decay over time
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
    -- No activity if no events yet
    if self.state.lastEventTime == 0 then
        return 0.0
    end
    
    local timeSinceLastEvent = GetTime() - self.state.lastEventTime
    
    -- Full activity if recent event
    if timeSinceLastEvent < 1.0 then
        return 1.0
    elseif timeSinceLastEvent <= 5.0 then
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
        totalHits = self.state.totalHits,
        criticalHits = self.state.criticalHits,
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

-- Get simple display data (for UI) for specific window
function MeterAccumulator:GetDisplayData(windowSeconds)
    windowSeconds = windowSeconds or 5  -- Default to 5 seconds for backward compatibility
    
    local stats = self:GetStats()
    local windowData = self:GetWindowTotals(windowSeconds)
    
    local displayData = {
        currentMetric = math.floor(windowData.metricPS),
        peakMetric = math.floor(stats.peakMetric),  -- Keep global peak
        totalValue = stats.totalValue,
        playerValue = stats.playerValue,
        petValue = stats.petValue,
        critPercent = math.floor(stats.criticalPercent * 10) / 10, -- One decimal
        activityLevel = stats.activityLevel,
        encounterTime = math.floor(stats.encounterDuration),
        meterType = self.meterType,
        windowSeconds = windowSeconds,
        windowData = windowData  -- Include full window data for multi-window display
    }
    
    -- Allow subclasses to modify display data
    if self.ModifyDisplayData then
        self:ModifyDisplayData(displayData, stats, windowData)
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
    
    -- Clear detail buffer
    if self.rollingData.detailBuffer.initialized then
        local buffer = self.rollingData.detailBuffer
        -- Reset indices but keep pre-allocated tables
        buffer.head = 1
        buffer.tail = 1
        buffer.count = 0
        buffer.timeIndex = {}
    end
    
    -- Release and clear second summaries
    for timestamp, summary in pairs(self.rollingData.secondSummaries) do
        addon.TablePool:ReleaseSummary(summary)
    end
    self.rollingData.secondSummaries = {}
    
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