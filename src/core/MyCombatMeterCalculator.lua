-- MyCombatMeterCalculator.lua
-- Calculation engine for real-time DPS/HPS meter with multiple methods
--
-- CALCULATION METHODS:
-- 1. Rolling Average: Sliding window of last T seconds (default 5s)
-- 2. Final Total: Total damage/healing divided by elapsed combat time
-- 3. Hybrid: Weighted combination of rolling (70%) and final (30%)

local addonName, addon = ...

-- =============================================================================
-- COMBAT METER CALCULATOR MODULE
-- =============================================================================

local MyCombatMeterCalculator = {}
addon.MyCombatMeterCalculator = MyCombatMeterCalculator

-- =============================================================================
-- CONSTANTS AND CONFIGURATION
-- =============================================================================

-- Calculation methods
local CALCULATION_METHODS = {
    ROLLING = "rolling",
    FINAL = "final",
    HYBRID = "hybrid"
}

-- Default configuration
local DEFAULT_CONFIG = {
    ROLLING_WINDOW_SECONDS = 5,     -- Rolling average window
    HYBRID_ROLLING_WEIGHT = 0.7,    -- 70% rolling, 30% final for hybrid
    HYBRID_FINAL_WEIGHT = 0.3,
    MIN_COMBAT_TIME = 1.0,          -- Minimum combat time for calculations
    DAMAGE_SMOOTHING = 0.1,         -- Smoothing factor for damage spikes
    HEALING_SMOOTHING = 0.1,        -- Smoothing factor for healing spikes
}

-- Calculator state
local calculatorState = {
    currentMethod = CALCULATION_METHODS.ROLLING,
    config = {},
    lastCalculation = {
        dps = 0,
        hps = 0,
        timestamp = 0
    },
    smoothedValues = {
        dps = 0,
        hps = 0
    }
}

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

function MyCombatMeterCalculator:Initialize()
    -- Copy default configuration
    for k, v in pairs(DEFAULT_CONFIG) do
        calculatorState.config[k] = v
    end
    
    addon:Debug("MyCombatMeterCalculator initialized with method: %s", calculatorState.currentMethod)
end

-- =============================================================================
-- CORE CALCULATION FUNCTIONS
-- =============================================================================

-- Main calculation function - determines which method to use
function MyCombatMeterCalculator:Calculate(combatData, eventHistory, currentTime)
    if not combatData or not combatData.inCombat then
        return 0, 0 -- No combat, no DPS/HPS
    end
    
    local combatElapsed = currentTime - combatData.startTime
    if combatElapsed < calculatorState.config.MIN_COMBAT_TIME then
        return 0, 0 -- Too early in combat for reliable calculations
    end
    
    local dps, hps = 0, 0
    
    if calculatorState.currentMethod == CALCULATION_METHODS.ROLLING then
        dps, hps = self:CalculateRollingAverage(combatData, eventHistory, currentTime)
    elseif calculatorState.currentMethod == CALCULATION_METHODS.FINAL then
        dps, hps = self:CalculateFinalTotal(combatData, combatElapsed)
    elseif calculatorState.currentMethod == CALCULATION_METHODS.HYBRID then
        dps, hps = self:CalculateHybrid(combatData, eventHistory, currentTime, combatElapsed)
    else
        addon:Error("Unknown calculation method: %s", calculatorState.currentMethod)
        return 0, 0
    end
    
    -- Apply smoothing to prevent jarring jumps
    dps, hps = self:ApplySmoothing(dps, hps)
    
    -- Store last calculation
    calculatorState.lastCalculation.dps = dps
    calculatorState.lastCalculation.hps = hps
    calculatorState.lastCalculation.timestamp = currentTime
    
    return dps, hps
end

-- Method 1: Rolling Average (sliding window)
function MyCombatMeterCalculator:CalculateRollingAverage(combatData, eventHistory, currentTime)
    local windowSeconds = calculatorState.config.ROLLING_WINDOW_SECONDS
    local cutoffTime = currentTime - windowSeconds
    
    local totalDamage = 0
    local totalHealing = 0
    local eventsInWindow = 0
    
    -- Sum damage and healing from events within the rolling window
    for i = #eventHistory, 1, -1 do
        local event = eventHistory[i]
        if event.timestamp < cutoffTime then
            break -- Events are chronologically ordered, so we can stop here
        end
        
        eventsInWindow = eventsInWindow + 1
        
        if event.type == "DAMAGE" and event.amount then
            totalDamage = totalDamage + event.amount
        elseif event.type == "HEAL" and event.amount then
            totalHealing = totalHealing + event.amount
        end
    end
    
    -- Calculate actual window size (might be less than desired if combat just started)
    local actualWindow = math.min(windowSeconds, currentTime - combatData.startTime)
    
    if actualWindow <= 0 then
        return 0, 0
    end
    
    local dps = totalDamage / actualWindow
    local hps = totalHealing / actualWindow
    
    return dps, hps
end

-- Method 2: Final Total (total damage/healing over entire combat)
function MyCombatMeterCalculator:CalculateFinalTotal(combatData, combatElapsed)
    if combatElapsed <= 0 then
        return 0, 0
    end
    
    local dps = combatData.totalDamage / combatElapsed
    local hps = combatData.totalHealing / combatElapsed
    
    return dps, hps
end

-- Method 3: Hybrid (weighted combination of rolling and final)
function MyCombatMeterCalculator:CalculateHybrid(combatData, eventHistory, currentTime, combatElapsed)
    local rollingDPS, rollingHPS = self:CalculateRollingAverage(combatData, eventHistory, currentTime)
    local finalDPS, finalHPS = self:CalculateFinalTotal(combatData, combatElapsed)
    
    local rollingWeight = calculatorState.config.HYBRID_ROLLING_WEIGHT
    local finalWeight = calculatorState.config.HYBRID_FINAL_WEIGHT
    
    local hybridDPS = (rollingDPS * rollingWeight) + (finalDPS * finalWeight)
    local hybridHPS = (rollingHPS * rollingWeight) + (finalHPS * finalWeight)
    
    return hybridDPS, hybridHPS
end

-- =============================================================================
-- SMOOTHING AND FILTERING
-- =============================================================================

-- Apply smoothing to prevent jarring visual jumps
function MyCombatMeterCalculator:ApplySmoothing(newDPS, newHPS)
    local smoothingDPS = calculatorState.config.DAMAGE_SMOOTHING
    local smoothingHPS = calculatorState.config.HEALING_SMOOTHING
    
    -- Use exponential moving average for smoothing
    calculatorState.smoothedValues.dps = (calculatorState.smoothedValues.dps * (1 - smoothingDPS)) + (newDPS * smoothingDPS)
    calculatorState.smoothedValues.hps = (calculatorState.smoothedValues.hps * (1 - smoothingHPS)) + (newHPS * smoothingHPS)
    
    return calculatorState.smoothedValues.dps, calculatorState.smoothedValues.hps
end

-- Reset smoothed values (e.g., when combat starts)
function MyCombatMeterCalculator:ResetSmoothing()
    calculatorState.smoothedValues.dps = 0
    calculatorState.smoothedValues.hps = 0
end

-- =============================================================================
-- ADVANCED CALCULATION FEATURES
-- =============================================================================

-- Calculate DPS/HPS for specific time ranges (for analysis)
function MyCombatMeterCalculator:CalculateForTimeRange(eventHistory, startTime, endTime)
    local totalDamage = 0
    local totalHealing = 0
    local duration = endTime - startTime
    
    if duration <= 0 then
        return 0, 0
    end
    
    for _, event in ipairs(eventHistory) do
        if event.timestamp >= startTime and event.timestamp <= endTime then
            if event.type == "DAMAGE" and event.amount then
                totalDamage = totalDamage + event.amount
            elseif event.type == "HEAL" and event.amount then
                totalHealing = totalHealing + event.amount
            end
        end
    end
    
    return totalDamage / duration, totalHealing / duration
end

-- Calculate peak DPS/HPS over rolling windows
function MyCombatMeterCalculator:CalculatePeakValues(eventHistory, windowSeconds, currentTime)
    if not eventHistory or #eventHistory == 0 then
        return 0, 0
    end
    
    local peakDPS = 0
    local peakHPS = 0
    local oldestTime = currentTime - (currentTime - eventHistory[1].timestamp) -- Full combat duration
    
    -- Slide the window through the entire combat
    local stepSize = windowSeconds / 4 -- Check every quarter window for smooth peak detection
    
    for windowStart = oldestTime, currentTime - windowSeconds, stepSize do
        local windowEnd = windowStart + windowSeconds
        local windowDPS, windowHPS = self:CalculateForTimeRange(eventHistory, windowStart, windowEnd)
        
        peakDPS = math.max(peakDPS, windowDPS)
        peakHPS = math.max(peakHPS, windowHPS)
    end
    
    return peakDPS, peakHPS
end

-- Calculate burst potential (short window peak vs sustained average)
function MyCombatMeterCalculator:CalculateBurstMetrics(eventHistory, currentTime)
    if not eventHistory or #eventHistory < 10 then
        return {
            burstDPS = 0,
            burstHPS = 0,
            sustainedDPS = 0,
            sustainedHPS = 0,
            burstRatio = 1
        }
    end
    
    -- Calculate 3-second burst peak
    local burstDPS, burstHPS = self:CalculatePeakValues(eventHistory, 3, currentTime)
    
    -- Calculate 15-second sustained average
    local sustainedDPS, sustainedHPS = self:CalculateForTimeRange(
        eventHistory, 
        currentTime - 15, 
        currentTime
    )
    
    local burstRatioDPS = sustainedDPS > 0 and (burstDPS / sustainedDPS) or 1
    local burstRatioHPS = sustainedHPS > 0 and (burstHPS / sustainedHPS) or 1
    
    return {
        burstDPS = burstDPS,
        burstHPS = burstHPS,
        sustainedDPS = sustainedDPS,
        sustainedHPS = sustainedHPS,
        burstRatioDPS = burstRatioDPS,
        burstRatioHPS = burstRatioHPS
    }
end

-- =============================================================================
-- CONFIGURATION MANAGEMENT
-- =============================================================================

function MyCombatMeterCalculator:SetCalculationMethod(method)
    if CALCULATION_METHODS[method:upper()] then
        calculatorState.currentMethod = CALCULATION_METHODS[method:upper()]
        
        -- Reset smoothing when changing methods
        self:ResetSmoothing()
        
        addon:Debug("Calculator method changed to: %s", method)
        return true
    end
    
    addon:Error("Invalid calculation method: %s", method)
    return false
end

function MyCombatMeterCalculator:GetCalculationMethod()
    return calculatorState.currentMethod
end

function MyCombatMeterCalculator:SetRollingWindow(seconds)
    calculatorState.config.ROLLING_WINDOW_SECONDS = math.max(1, math.min(30, seconds))
    addon:Debug("Rolling window set to: %.1fs", calculatorState.config.ROLLING_WINDOW_SECONDS)
end

function MyCombatMeterCalculator:GetRollingWindow()
    return calculatorState.config.ROLLING_WINDOW_SECONDS
end

function MyCombatMeterCalculator:SetHybridWeights(rollingWeight, finalWeight)
    -- Normalize weights to sum to 1.0
    local total = rollingWeight + finalWeight
    if total > 0 then
        calculatorState.config.HYBRID_ROLLING_WEIGHT = rollingWeight / total
        calculatorState.config.HYBRID_FINAL_WEIGHT = finalWeight / total
        
        addon:Debug("Hybrid weights set to: rolling=%.1f%%, final=%.1f%%", 
            calculatorState.config.HYBRID_ROLLING_WEIGHT * 100,
            calculatorState.config.HYBRID_FINAL_WEIGHT * 100)
    end
end

function MyCombatMeterCalculator:GetHybridWeights()
    return calculatorState.config.HYBRID_ROLLING_WEIGHT, calculatorState.config.HYBRID_FINAL_WEIGHT
end

function MyCombatMeterCalculator:SetSmoothingFactors(dpsSmoothing, hpsSmoothing)
    calculatorState.config.DAMAGE_SMOOTHING = math.max(0, math.min(1, dpsSmoothing))
    calculatorState.config.HEALING_SMOOTHING = math.max(0, math.min(1, hpsSmoothing))
    
    addon:Debug("Smoothing factors set to: DPS=%.2f, HPS=%.2f", 
        calculatorState.config.DAMAGE_SMOOTHING,
        calculatorState.config.HEALING_SMOOTHING)
end

function MyCombatMeterCalculator:GetSmoothingFactors()
    return calculatorState.config.DAMAGE_SMOOTHING, calculatorState.config.HEALING_SMOOTHING
end

-- =============================================================================
-- VALIDATION AND TESTING
-- =============================================================================

-- Validate calculations by comparing methods
function MyCombatMeterCalculator:ValidateCalculations(combatData, eventHistory, currentTime)
    if not combatData or not combatData.inCombat then
        return nil
    end
    
    local combatElapsed = currentTime - combatData.startTime
    if combatElapsed < calculatorState.config.MIN_COMBAT_TIME then
        return nil
    end
    
    -- Calculate using all three methods
    local rollingDPS, rollingHPS = self:CalculateRollingAverage(combatData, eventHistory, currentTime)
    local finalDPS, finalHPS = self:CalculateFinalTotal(combatData, combatElapsed)
    local hybridDPS, hybridHPS = self:CalculateHybrid(combatData, eventHistory, currentTime, combatElapsed)
    
    return {
        methods = {
            rolling = { dps = rollingDPS, hps = rollingHPS },
            final = { dps = finalDPS, hps = finalHPS },
            hybrid = { dps = hybridDPS, hps = hybridHPS }
        },
        variance = {
            dpsRange = math.abs(rollingDPS - finalDPS),
            hpsRange = math.abs(rollingHPS - finalHPS),
            dpsPercentage = finalDPS > 0 and (math.abs(rollingDPS - finalDPS) / finalDPS * 100) or 0,
            hpsPercentage = finalHPS > 0 and (math.abs(rollingHPS - finalHPS) / finalHPS * 100) or 0
        },
        combatData = {
            elapsed = combatElapsed,
            totalDamage = combatData.totalDamage,
            totalHealing = combatData.totalHealing,
            eventCount = #eventHistory
        }
    }
end

-- Generate calculation report for debugging
function MyCombatMeterCalculator:GenerateCalculationReport(combatData, eventHistory, currentTime)
    local validation = self:ValidateCalculations(combatData, eventHistory, currentTime)
    if not validation then
        return "No active combat for calculation report"
    end
    
    local lines = {}
    table.insert(lines, "=== Combat Meter Calculation Report ===")
    table.insert(lines, string.format("Combat Duration: %.1fs", validation.combatData.elapsed))
    table.insert(lines, string.format("Total Damage: %d", validation.combatData.totalDamage))
    table.insert(lines, string.format("Total Healing: %d", validation.combatData.totalHealing))
    table.insert(lines, string.format("Event Count: %d", validation.combatData.eventCount))
    table.insert(lines, "")
    
    table.insert(lines, "Method Comparison:")
    table.insert(lines, string.format("  Rolling (%.1fs):  DPS=%6.0f  HPS=%6.0f", 
        calculatorState.config.ROLLING_WINDOW_SECONDS,
        validation.methods.rolling.dps, 
        validation.methods.rolling.hps))
    table.insert(lines, string.format("  Final Total:      DPS=%6.0f  HPS=%6.0f", 
        validation.methods.final.dps, 
        validation.methods.final.hps))
    table.insert(lines, string.format("  Hybrid (%.0f%%/%.0f%%): DPS=%6.0f  HPS=%6.0f", 
        calculatorState.config.HYBRID_ROLLING_WEIGHT * 100,
        calculatorState.config.HYBRID_FINAL_WEIGHT * 100,
        validation.methods.hybrid.dps, 
        validation.methods.hybrid.hps))
    table.insert(lines, "")
    
    table.insert(lines, "Variance Analysis:")
    table.insert(lines, string.format("  DPS Difference: %.0f (%.1f%%)", 
        validation.variance.dpsRange, 
        validation.variance.dpsPercentage))
    table.insert(lines, string.format("  HPS Difference: %.0f (%.1f%%)", 
        validation.variance.hpsRange, 
        validation.variance.hpsPercentage))
    table.insert(lines, "")
    
    -- Add burst analysis
    local burstMetrics = self:CalculateBurstMetrics(eventHistory, currentTime)
    table.insert(lines, "Burst Analysis:")
    table.insert(lines, string.format("  3s Peak DPS: %.0f (%.1fx sustained)", 
        burstMetrics.burstDPS, burstMetrics.burstRatioDPS))
    table.insert(lines, string.format("  3s Peak HPS: %.0f (%.1fx sustained)", 
        burstMetrics.burstHPS, burstMetrics.burstRatioHPS))
    
    return table.concat(lines, "\n")
end

-- =============================================================================
-- STATUS AND DEBUGGING
-- =============================================================================

function MyCombatMeterCalculator:GetStatus()
    return {
        currentMethod = calculatorState.currentMethod,
        rollingWindow = calculatorState.config.ROLLING_WINDOW_SECONDS,
        hybridWeights = {
            rolling = calculatorState.config.HYBRID_ROLLING_WEIGHT,
            final = calculatorState.config.HYBRID_FINAL_WEIGHT
        },
        smoothing = {
            dps = calculatorState.config.DAMAGE_SMOOTHING,
            hps = calculatorState.config.HEALING_SMOOTHING
        },
        lastCalculation = calculatorState.lastCalculation,
        smoothedValues = calculatorState.smoothedValues
    }
end

function MyCombatMeterCalculator:GetAvailableMethods()
    return {
        CALCULATION_METHODS.ROLLING,
        CALCULATION_METHODS.FINAL,
        CALCULATION_METHODS.HYBRID
    }
end

-- =============================================================================
-- EXPORTED CONSTANTS
-- =============================================================================

MyCombatMeterCalculator.METHODS = CALCULATION_METHODS

return MyCombatMeterCalculator