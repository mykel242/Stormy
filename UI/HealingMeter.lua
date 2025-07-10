-- HealingMeter.lua
-- Healing meter UI with green theme and absorb tracking
-- Extends MeterWindow for healing-specific display

local addonName, addon = ...

-- =============================================================================
-- HEALING METER UI MODULE
-- =============================================================================

addon.HealingMeter = {}
local HealingMeter = addon.HealingMeter

-- Initialize base class when it's available
local MeterWindow = nil

-- Initialize function (called after MeterWindow loads)
local function InitializeBaseClass()
    if addon.MeterWindow then
        MeterWindow = addon.MeterWindow
    end
end

-- Healing-specific UI configuration
local HEALING_UI_CONFIG = {
    -- Green theme colors
    COLOR_HPS = {0.2, 1, 0.4, 1},           -- Bright green for HPS
    COLOR_ABSORB = {0.4, 0.8, 1, 1},        -- Light blue for absorbs
    COLOR_EFFECTIVE = {0.6, 1, 0.6, 1},     -- Light green for effective
    COLOR_PET_HEALING = {0.8, 1, 0.6, 1},   -- Yellow-green for pet
    
    -- Activity colors (healing-themed)
    COLOR_ACTIVITY_LOW = {0.2, 0.8, 0.2, 1},    -- Dark green
    COLOR_ACTIVITY_MED = {0.4, 1, 0.4, 1},      -- Medium green  
    COLOR_ACTIVITY_HIGH = {0.6, 1, 0.8, 1},     -- Light green-cyan
    COLOR_ACTIVITY_MAX = {0.8, 1, 1, 1},        -- Bright cyan
}

-- =============================================================================
-- HEALING METER CLASS
-- =============================================================================

function HealingMeter:New()
    -- Initialize base class if not done yet
    InitializeBaseClass()
    
    if not MeterWindow then
        error("HealingMeter: MeterWindow base class not available")
    end
    
    -- Create healing-specific config
    local healingConfig = {}
    
    -- Copy base config
    for k, v in pairs(MeterWindow.config or {}) do
        healingConfig[k] = v
    end
    
    -- Override with healing-specific colors
    for k, v in pairs(HEALING_UI_CONFIG) do
        healingConfig[k] = v
    end
    
    -- Create base instance
    local instance = MeterWindow:New("Healing", healingConfig)
    
    -- Add healing-specific state
    instance.healingUIState = {
        showAbsorbs = true,
        showEffectiveness = true,
        absorbText = nil,
        effectivenessText = nil
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
-- CUSTOM DISPLAY ELEMENTS
-- =============================================================================

-- Override base CustomizeDisplayElements method
function HealingMeter:CustomizeDisplayElements(parent, largeFont, mediumFont, smallFont)
    -- Set healing-specific colors
    if self.state.mainNumberText then
        self.state.mainNumberText:SetTextColor(unpack(self.config.COLOR_HPS))
    end
    
    if self.state.labelText then
        self.state.labelText:SetText("HPS")
        self.state.labelText:SetTextColor(unpack(self.config.COLOR_HPS))
    end
    
    -- We'll use the base pet text for the combined display, no need for separate absorb text
    
    -- Create effectiveness display
    self.healingUIState.effectivenessText = parent:CreateFontString(nil, "OVERLAY")
    self.healingUIState.effectivenessText:SetFontObject(smallFont)
    self.healingUIState.effectivenessText:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -15, 30)
    self.healingUIState.effectivenessText:SetText("")
    self.healingUIState.effectivenessText:SetTextColor(unpack(self.config.COLOR_EFFECTIVE))
end

-- =============================================================================
-- DATA RETRIEVAL
-- =============================================================================

-- Override base GetDisplayData method
function HealingMeter:GetDisplayData()
    if addon.HealingAccumulator then
        return addon.HealingAccumulator:GetDisplayData(self.state.windowSeconds)
    end
    
    -- Fallback empty data
    return {
        currentMetric = 0,
        peakMetric = 0,
        totalValue = 0,
        playerValue = 0,
        petValue = 0,
        critPercent = 0,
        activityLevel = 0,
        encounterTime = 0,
        meterType = "Healing",
        currentEffectiveHPS = 0,
        peakEffectiveHPS = 0,
        currentAbsorbPS = 0,
        totalAbsorbs = 0,
        effectivenessPercent = 100
    }
end

-- Get current window setting for plot integration
function HealingMeter:GetCurrentWindow()
    return self.state.windowSeconds
end

-- Override base GetActivityLevel method
function HealingMeter:GetActivityLevel()
    if addon.HealingAccumulator then
        return addon.HealingAccumulator:GetActivityLevel()
    end
    return 0
end

-- =============================================================================
-- HELPER METHODS
-- =============================================================================

-- Format number with fixed decimal places (000.0k format)
function HealingMeter:FormatFixedNumber(value)
    if value >= 1000000 then
        return string.format("%05.1fM", value / 1000000)
    elseif value >= 1000 then
        return string.format("%05.1fK", value / 1000)
    else
        return string.format("%05.1f", value)
    end
end

-- =============================================================================
-- CUSTOM UPDATE LOGIC
-- =============================================================================

-- Override base CustomUpdateDisplay method
function HealingMeter:CustomUpdateDisplay(currentValue, displayData)
    local now = GetTime()
    
    -- Get healing-specific data
    local currentHPS = displayData.currentMetric or 0
    local currentEffectiveHPS = displayData.currentEffectiveHPS or 0
    local currentAbsorbPS = displayData.currentAbsorbPS or 0
    
    -- Get peak values
    local recentPeakValue = displayData.peakEffectiveHPS or 0
    
    -- Update peaks and current values (use effective HPS for scaling)
    self.state.recentPeak = recentPeakValue
    self.state.currentValue = currentEffectiveHPS
    if currentEffectiveHPS > self.state.sessionPeak then
        self.state.sessionPeak = currentEffectiveHPS
    end
    
    -- Ensure recent peak is at least as high as current value
    if currentEffectiveHPS > self.state.recentPeak then
        self.state.recentPeak = currentEffectiveHPS
    end
    
    -- Format main number with auto-scaling (show effective HPS)
    local formatted, scale, unit = self:FormatNumberWithScale(currentEffectiveHPS)
    self.state.currentScale = scale
    self.state.scaleUnit = unit
    
    -- Update main number display
    if self.state.mainNumberText then
        local whole, decimal = formatted:match("^(%d+)%.?(%d*)$")
        if decimal and decimal ~= "" then
            self.state.mainNumberText:SetText(whole .. "." .. decimal .. unit)
        else
            self.state.mainNumberText:SetText(whole .. unit)
        end
    end
    
    -- Update scale indicator with timing logic
    if self.state.scaleText then
        local activityLevel = displayData.activityLevel or 0
        local timeSinceLastUpdate = now - self.state.lastScaleUpdate
        local shouldUpdateScale = false
        
        -- Calculate what the new scale would be
        local newScaleText, newScaleValue = self:GetIntelligentScale()
        
        -- Determine if we should update the scale (same logic as base class)
        if self.state.lastScaleUpdate == 0 then
            shouldUpdateScale = true
        elseif newScaleValue > self.state.currentScaleMax then
            shouldUpdateScale = true
        elseif newScaleValue < self.state.currentScaleMax then
            if activityLevel < 0.1 then
                if timeSinceLastUpdate > 3 then
                    local scaleDifference = (self.state.currentScaleMax - newScaleValue) / self.state.currentScaleMax
                    if scaleDifference > 0.2 then
                        shouldUpdateScale = true
                    elseif timeSinceLastUpdate > 10 then
                        shouldUpdateScale = true
                    end
                end
            elseif activityLevel >= 0.1 and timeSinceLastUpdate > 5 then
                shouldUpdateScale = true
            end
        else
            if timeSinceLastUpdate > 30 then
                shouldUpdateScale = true
            end
        end
        
        if shouldUpdateScale then
            self.state.lastScaleValue = newScaleText
            self.state.currentScaleMax = newScaleValue
            self.state.lastScaleUpdate = now
            self.state.scaleText:SetText(newScaleText .. " scale")
        else
            self.state.scaleText:SetText(self.state.lastScaleValue .. " scale")
        end
    end
    
    -- Update peak text - show both recent and session peaks for effective HPS
    if self.state.peakText then
        local sessionFormatted = "0"
        local recentFormatted = "0"
        local sessionUnit = ""
        local recentUnit = ""
        
        if self.state.sessionPeak > 0 then
            local fmt, _, unit = self:FormatNumberWithScale(self.state.sessionPeak)
            sessionFormatted = fmt
            sessionUnit = unit
        end
        
        if self.state.recentPeak > 0 then
            local fmt, _, unit = self:FormatNumberWithScale(self.state.recentPeak)
            recentFormatted = fmt
            recentUnit = unit
        end
        
        self.state.peakText:SetText(string.format("Recent: %s%s  Peak: %s%s", 
            recentFormatted, recentUnit, sessionFormatted, sessionUnit))
    end
    
    -- Hide pet text
    if self.state.petText then
        self.state.petText:SetText("")
    end
    
    -- Update effectiveness text
    if self.healingUIState.effectivenessText then
        local effectiveness = displayData.effectivenessPercent or 100
        if effectiveness < 99.9 then -- Only show if there's meaningful overhealing
            self.healingUIState.effectivenessText:SetText(string.format("%.1f%% eff", effectiveness))
        else
            self.healingUIState.effectivenessText:SetText("")
        end
    end
    
    -- Update activity bar based on effective HPS vs scale
    self:UpdateActivityBar(currentEffectiveHPS)
end

-- =============================================================================
-- CUSTOM INITIALIZATION
-- =============================================================================

-- Override base CustomInitialize method
function HealingMeter:CustomInitialize()
    -- Set up event subscriptions for healing events
    if addon.EventBus then
        -- Subscribe to healing events for immediate feedback
        addon.EventBus:SubscribeToHealing(function(event)
            -- Could add heal flash or immediate update here
        end, "HealingMeterUI")
    end
    
    -- HealingMeter UI initialized
end

-- =============================================================================
-- WINDOW POSITIONING
-- =============================================================================

-- Override default position to avoid overlap with DPS meter
function HealingMeter:CreateMainWindow()
    -- Call base method first
    local frame = MeterWindow.CreateMainWindow(self)
    
    -- Adjust default position to be offset from DPS meter
    if frame and not (addon.db and addon.db.HealingWindowPosition) then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 100 + 400, 0) -- 400 pixels right of DPS meter
    end
    
    return frame
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the healing meter UI
function HealingMeter:Initialize()
    -- Initialize base class first
    InitializeBaseClass()
    
    if not MeterWindow then
        error("HealingMeter: Cannot initialize without MeterWindow base class")
    end
    
    MeterWindow.Initialize(self)
    
    -- HealingMeter initialized
end

-- Module ready
HealingMeter.isReady = true

return HealingMeter