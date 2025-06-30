-- HealingAccumulator.lua
-- Real-time healing and absorb accumulation with rolling window calculations
-- Extends MeterAccumulator for healing-specific functionality

local addonName, addon = ...

-- =============================================================================
-- HEALING ACCUMULATOR MODULE
-- =============================================================================

addon.HealingAccumulator = {}
local HealingAccumulator = addon.HealingAccumulator

-- Initialize base class when it's available
local MeterAccumulator = nil

-- Initialize function (called after MeterAccumulator loads)
local function InitializeBaseClass()
    if addon.MeterAccumulator then
        MeterAccumulator = addon.MeterAccumulator
    end
end

-- Healing-specific configuration
local HEALING_CONFIG = {
    -- Track overhealing but don't display it yet
    trackOverhealing = true,
    displayOverhealing = false,
    
    -- Absorb tracking (priority for display)
    trackAbsorbs = true,
    displayAbsorbs = true,
    
    -- HOT vs direct heal separation
    trackHealTypes = true,
    
    -- Critical healing tracking
    trackCriticals = true
}

-- =============================================================================
-- HEALING ACCUMULATOR CLASS
-- =============================================================================

function HealingAccumulator:New()
    -- Initialize base class if not done yet
    InitializeBaseClass()
    
    if not MeterAccumulator then
        error("HealingAccumulator: MeterAccumulator base class not available")
    end
    
    -- Create base instance
    local instance = MeterAccumulator:New("Healing")
    
    -- Add healing-specific state
    instance.healingState = {
        -- Total values
        totalAbsorbs = 0,
        totalOverhealing = 0,
        totalDirectHealing = 0,
        totalHOTHealing = 0,
        
        -- Player vs Pet breakdown
        playerAbsorbs = 0,
        petAbsorbs = 0,
        playerOverhealing = 0,
        petOverhealing = 0,
        
        -- Heal type breakdown
        directHealEvents = 0,
        hotHealEvents = 0,
        absorbEvents = 0,
        
        -- Current calculations
        currentAbsorbPS = 0,
        currentEffectiveHPS = 0, -- Healing + Absorbs
        peakAbsorbPS = 0,
        peakEffectiveHPS = 0,
        
        -- Efficiency tracking
        overhealingPercent = 0,
        effectivenessPercent = 100 -- (Healing + Absorbs) / (Total including overheals)
    }
    
    -- Add healing-specific rolling data
    instance.healingRollingData = {
        absorbs = {},      -- [timestamp] = amount
        overhealing = {},  -- [timestamp] = amount  
        directHeals = {},  -- [timestamp] = amount
        hots = {},         -- [timestamp] = amount
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
-- HEALING-SPECIFIC EVENT PROCESSING
-- =============================================================================

-- Override the base OnEvent method to process healing-specific data
function HealingAccumulator:OnEvent(timestamp, sourceGUID, amount, isPlayer, isPet, isCritical, extraData)
    if not extraData then
        return
    end
    
    local absorbAmount = extraData.absorbAmount or 0
    local overhealing = extraData.overhealing or 0
    local isHOT = extraData.isHOT or false
    
    -- Store healing-specific data
    self:StoreHealingData(timestamp, amount, absorbAmount, overhealing, isHOT, isPlayer, isPet)
    
    -- Update totals
    self.healingState.totalAbsorbs = self.healingState.totalAbsorbs + absorbAmount
    self.healingState.totalOverhealing = self.healingState.totalOverhealing + overhealing
    
    -- Player vs Pet breakdown for absorbs and overhealing
    if isPlayer then
        self.healingState.playerAbsorbs = self.healingState.playerAbsorbs + absorbAmount
        self.healingState.playerOverhealing = self.healingState.playerOverhealing + overhealing
    elseif isPet then
        self.healingState.petAbsorbs = self.healingState.petAbsorbs + absorbAmount
        self.healingState.petOverhealing = self.healingState.petOverhealing + overhealing
    end
    
    -- Heal type tracking
    if absorbAmount > 0 then
        self.healingState.absorbEvents = self.healingState.absorbEvents + 1
    elseif isHOT then
        self.healingState.totalHOTHealing = self.healingState.totalHOTHealing + amount
        self.healingState.hotHealEvents = self.healingState.hotHealEvents + 1
    else
        self.healingState.totalDirectHealing = self.healingState.totalDirectHealing + amount
        self.healingState.directHealEvents = self.healingState.directHealEvents + 1
    end
    
    -- Update efficiency calculations
    self:UpdateEfficiencyMetrics()
end

-- Store healing-specific data in rolling windows
function HealingAccumulator:StoreHealingData(timestamp, healAmount, absorbAmount, overhealing, isHOT, isPlayer, isPet)
    local relativeTime = addon.TimingManager:GetCurrentRelativeTime()
    
    -- Store absorb data
    if absorbAmount > 0 then
        self.healingRollingData.absorbs[relativeTime] = (self.healingRollingData.absorbs[relativeTime] or 0) + absorbAmount
    end
    
    -- Store overhealing data
    if overhealing > 0 then
        self.healingRollingData.overhealing[relativeTime] = (self.healingRollingData.overhealing[relativeTime] or 0) + overhealing
    end
    
    -- Store heal type data
    if isHOT then
        self.healingRollingData.hots[relativeTime] = (self.healingRollingData.hots[relativeTime] or 0) + healAmount
    else
        self.healingRollingData.directHeals[relativeTime] = (self.healingRollingData.directHeals[relativeTime] or 0) + healAmount
    end
end

-- Override base StoreExtraData method
function HealingAccumulator:StoreExtraData(event, extraData)
    if not event.healingData then
        event.healingData = {
            absorbs = 0,
            overhealing = 0,
            directHeals = 0,
            hots = 0
        }
    end
    
    local data = event.healingData
    data.absorbs = data.absorbs + (extraData.absorbAmount or 0)
    data.overhealing = data.overhealing + (extraData.overhealing or 0)
    
    if extraData.isHOT then
        data.hots = data.hots + event.value
    else
        data.directHeals = data.directHeals + event.value
    end
end

-- =============================================================================
-- HEALING-SPECIFIC CALCULATIONS
-- =============================================================================

-- Override base CalculateWindowExtras method
function HealingAccumulator:CalculateWindowExtras(result, windowSeconds, cutoffTime)
    local totalAbsorbs = 0
    local totalOverhealing = 0
    local totalDirectHeals = 0
    local totalHOTs = 0
    
    -- Sum absorbs in window
    for timestamp, amount in pairs(self.healingRollingData.absorbs) do
        if timestamp >= cutoffTime then
            totalAbsorbs = totalAbsorbs + amount
        end
    end
    
    -- Sum overhealing in window
    for timestamp, amount in pairs(self.healingRollingData.overhealing) do
        if timestamp >= cutoffTime then
            totalOverhealing = totalOverhealing + amount
        end
    end
    
    -- Sum direct heals in window
    for timestamp, amount in pairs(self.healingRollingData.directHeals) do
        if timestamp >= cutoffTime then
            totalDirectHeals = totalDirectHeals + amount
        end
    end
    
    -- Sum HOTs in window
    for timestamp, amount in pairs(self.healingRollingData.hots) do
        if timestamp >= cutoffTime then
            totalHOTs = totalHOTs + amount
        end
    end
    
    -- Add healing-specific metrics to result
    result.absorbs = totalAbsorbs
    result.overhealing = totalOverhealing
    result.directHeals = totalDirectHeals
    result.hots = totalHOTs
    result.absorbPS = windowSeconds > 0 and (totalAbsorbs / windowSeconds) or 0
    result.effectiveHPS = windowSeconds > 0 and ((result.value + totalAbsorbs) / windowSeconds) or 0
    
    -- Calculate efficiency metrics
    local totalPotential = result.value + totalAbsorbs + totalOverhealing
    result.overhealPercent = totalPotential > 0 and (totalOverhealing / totalPotential * 100) or 0
    result.effectivenessPercent = totalPotential > 0 and ((result.value + totalAbsorbs) / totalPotential * 100) or 100
end

-- Update current healing calculations
function HealingAccumulator:UpdateCurrentValues()
    -- Call base method first
    MeterAccumulator.UpdateCurrentValues(self)
    
    -- Calculate healing-specific current values
    local currentWindow = self:GetWindowTotals(5) -- 5 second window
    
    self.healingState.currentAbsorbPS = currentWindow.absorbPS or 0
    self.healingState.currentEffectiveHPS = currentWindow.effectiveHPS or 0
    
    -- Update peaks
    if self.healingState.currentAbsorbPS > self.healingState.peakAbsorbPS then
        self.healingState.peakAbsorbPS = self.healingState.currentAbsorbPS
    end
    
    if self.healingState.currentEffectiveHPS > self.healingState.peakEffectiveHPS then
        self.healingState.peakEffectiveHPS = self.healingState.currentEffectiveHPS
    end
end

-- Update efficiency metrics
function HealingAccumulator:UpdateEfficiencyMetrics()
    local totalPotential = self.state.totalValue + self.healingState.totalAbsorbs + self.healingState.totalOverhealing
    
    if totalPotential > 0 then
        self.healingState.overhealingPercent = (self.healingState.totalOverhealing / totalPotential) * 100
        self.healingState.effectivenessPercent = ((self.state.totalValue + self.healingState.totalAbsorbs) / totalPotential) * 100
    else
        self.healingState.overhealingPercent = 0
        self.healingState.effectivenessPercent = 100
    end
end

-- =============================================================================
-- CLEAN UP HEALING DATA
-- =============================================================================

-- Override base CleanOldData method
function HealingAccumulator:CleanOldData()
    local cleaned = MeterAccumulator.CleanOldData(self)
    
    local maxWindow = 60 -- 60 second window
    local now = addon.TimingManager and addon.TimingManager:GetCurrentRelativeTime() or GetTime()
    local cutoffTime = now - maxWindow
    
    -- Clean healing-specific data
    for timestamp in pairs(self.healingRollingData.absorbs) do
        if timestamp < cutoffTime then
            self.healingRollingData.absorbs[timestamp] = nil
        end
    end
    
    for timestamp in pairs(self.healingRollingData.overhealing) do
        if timestamp < cutoffTime then
            self.healingRollingData.overhealing[timestamp] = nil
        end
    end
    
    for timestamp in pairs(self.healingRollingData.directHeals) do
        if timestamp < cutoffTime then
            self.healingRollingData.directHeals[timestamp] = nil
        end
    end
    
    for timestamp in pairs(self.healingRollingData.hots) do
        if timestamp < cutoffTime then
            self.healingRollingData.hots[timestamp] = nil
        end
    end
    
    return cleaned
end

-- =============================================================================
-- PUBLIC API EXTENSIONS
-- =============================================================================

-- Get current HPS (base healing only)
function HealingAccumulator:GetCurrentHPS()
    return self:GetCurrentMetric()
end

-- Get current effective HPS (healing + absorbs)
function HealingAccumulator:GetCurrentEffectiveHPS()
    if GetTime() - self.state.lastCalculation > 0.5 then
        self:UpdateCurrentValues()
    end
    return self.healingState.currentEffectiveHPS
end

-- Get current absorb PS
function HealingAccumulator:GetCurrentAbsorbPS()
    if GetTime() - self.state.lastCalculation > 0.5 then
        self:UpdateCurrentValues()
    end
    return self.healingState.currentAbsorbPS
end

-- Get peak effective HPS
function HealingAccumulator:GetPeakEffectiveHPS()
    self:UpdatePeaks(GetTime())
    return self.healingState.peakEffectiveHPS
end

-- Override base GetExtraStats method
function HealingAccumulator:GetExtraStats(stats)
    -- Add healing-specific stats
    stats.totalAbsorbs = self.healingState.totalAbsorbs
    stats.totalOverhealing = self.healingState.totalOverhealing
    stats.totalDirectHealing = self.healingState.totalDirectHealing
    stats.totalHOTHealing = self.healingState.totalHOTHealing
    
    stats.playerAbsorbs = self.healingState.playerAbsorbs
    stats.petAbsorbs = self.healingState.petAbsorbs
    stats.playerOverhealing = self.healingState.playerOverhealing
    stats.petOverhealing = self.healingState.petOverhealing
    
    stats.currentEffectiveHPS = self.healingState.currentEffectiveHPS
    stats.currentAbsorbPS = self.healingState.currentAbsorbPS
    stats.peakEffectiveHPS = self:GetPeakEffectiveHPS()
    stats.peakAbsorbPS = self.healingState.peakAbsorbPS
    
    stats.directHealEvents = self.healingState.directHealEvents
    stats.hotHealEvents = self.healingState.hotHealEvents
    stats.absorbEvents = self.healingState.absorbEvents
    
    stats.overhealingPercent = self.healingState.overhealingPercent
    stats.effectivenessPercent = self.healingState.effectivenessPercent
end

-- Override base ModifyDisplayData method
function HealingAccumulator:ModifyDisplayData(displayData, stats)
    -- Modify display to show effective HPS (healing + absorbs) as primary metric
    displayData.currentEffectiveHPS = math.floor(stats.currentEffectiveHPS)
    displayData.peakEffectiveHPS = math.floor(stats.peakEffectiveHPS)
    displayData.currentAbsorbPS = math.floor(stats.currentAbsorbPS)
    displayData.totalAbsorbs = stats.totalAbsorbs
    displayData.effectivenessPercent = math.floor(stats.effectivenessPercent * 10) / 10
    
    -- Use effective HPS as the main metric for display
    displayData.currentMetric = displayData.currentEffectiveHPS
    displayData.peakMetric = displayData.peakEffectiveHPS
end

-- =============================================================================
-- RESET AND DEBUGGING
-- =============================================================================

-- Override base OnReset method
function HealingAccumulator:OnReset()
    -- Clear healing-specific state
    for key in pairs(self.healingState) do
        if type(self.healingState[key]) == "number" then
            self.healingState[key] = 0
        end
    end
    
    -- Reset effectiveness to 100%
    self.healingState.effectivenessPercent = 100
    
    -- Clear healing rolling data
    self.healingRollingData.absorbs = {}
    self.healingRollingData.overhealing = {}
    self.healingRollingData.directHeals = {}
    self.healingRollingData.hots = {}
end

-- Override base DebugExtra method
function HealingAccumulator:DebugExtra(stats)
    print("Healing-Specific Metrics:")
    print(string.format("  Effective HPS: %.0f (Healing: %.0f + Absorbs: %.0f)", 
          stats.currentEffectiveHPS, stats.currentMetric, stats.currentAbsorbPS))
    print(string.format("  Peak Effective: %.0f, Peak Absorbs: %.0f", 
          stats.peakEffectiveHPS, stats.peakAbsorbPS))
    print(string.format("  Total Absorbs: %s, Total Overhealing: %s", 
          self:FormatNumber(stats.totalAbsorbs), self:FormatNumber(stats.totalOverhealing)))
    print(string.format("  Effectiveness: %.1f%% (%.1f%% overheal)", 
          stats.effectivenessPercent, stats.overhealingPercent))
    print(string.format("  Heal Types: %d direct, %d HOTs, %d absorbs", 
          stats.directHealEvents, stats.hotHealEvents, stats.absorbEvents))
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the healing accumulator
function HealingAccumulator:Initialize()
    -- Initialize base class first
    InitializeBaseClass()
    
    if not MeterAccumulator then
        error("HealingAccumulator: Cannot initialize without MeterAccumulator base class")
    end
    
    MeterAccumulator.Initialize(self)
    
    print("[STORMY] HealingAccumulator: Initialized with absorb tracking")
end

-- Module ready
HealingAccumulator.isReady = true

return HealingAccumulator