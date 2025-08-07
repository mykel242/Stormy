-- DamageMeter.lua
-- Damage meter UI with red theme
-- Extends MeterWindow for damage-specific display

local addonName, addon = ...

-- =============================================================================
-- DAMAGE METER UI MODULE
-- =============================================================================

addon.DamageMeter = {}
local DamageMeter = addon.DamageMeter

-- Initialize base class when it's available
local MeterWindow = nil

-- Initialize function (called after MeterWindow loads)
local function InitializeBaseClass()
    if addon.MeterWindow then
        MeterWindow = addon.MeterWindow
    end
end

-- Damage-specific UI configuration
local DAMAGE_UI_CONFIG = {
    -- Red theme colors
    COLOR_DPS = {1, 0.2, 0.2, 1},           -- Bright red for DPS
    COLOR_SPELL = {1, 0.4, 0.4, 1},         -- Light red for spells
    COLOR_MELEE = {1, 0.6, 0.2, 1},         -- Orange for melee
    COLOR_PET_DAMAGE = {1, 0.8, 0.4, 1},    -- Yellow-orange for pet
    
    -- Activity colors (damage-themed)
    COLOR_ACTIVITY_LOW = {0.8, 0.2, 0.2, 1},    -- Dark red
    COLOR_ACTIVITY_MED = {1, 0.4, 0.4, 1},      -- Medium red  
    COLOR_ACTIVITY_HIGH = {1, 0.6, 0.6, 1},     -- Light red
    COLOR_ACTIVITY_MAX = {1, 0.8, 0.8, 1},      -- Bright pink
}

-- =============================================================================
-- DAMAGE METER CLASS
-- =============================================================================

function DamageMeter:New()
    -- Initialize base class if not done yet
    InitializeBaseClass()
    
    if not MeterWindow then
        error("DamageMeter: MeterWindow base class not available")
    end
    
    -- Create damage-specific config
    local damageConfig = {}
    
    -- Copy base config
    for k, v in pairs(MeterWindow.config or {}) do
        damageConfig[k] = v
    end
    
    -- Override with damage-specific colors
    for k, v in pairs(DAMAGE_UI_CONFIG) do
        damageConfig[k] = v
    end
    
    -- Create base instance
    local instance = MeterWindow:New("Damage", damageConfig)
    
    -- Add damage-specific state
    instance.damageUIState = {
        showSpellBreakdown = true,
        spellText = nil,
        meleeText = nil
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
function DamageMeter:CustomizeDisplayElements(parent, largeFont, mediumFont, smallFont)
    -- Set damage-specific colors
    if self.state.mainNumberText then
        self.state.mainNumberText:SetTextColor(unpack(self.config.COLOR_DPS))
    end
    
    if self.state.labelText then
        self.state.labelText:SetText("DPS")
        self.state.labelText:SetTextColor(unpack(self.config.COLOR_DPS))
    end
    
    -- Create spell damage display
    self.damageUIState.spellText = parent:CreateFontString(nil, "OVERLAY")
    self.damageUIState.spellText:SetFontObject(smallFont)
    self.damageUIState.spellText:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 20, 30)
    self.damageUIState.spellText:SetText("")
    self.damageUIState.spellText:SetTextColor(unpack(self.config.COLOR_SPELL))
    
    -- Create melee damage display
    self.damageUIState.meleeText = parent:CreateFontString(nil, "OVERLAY")
    self.damageUIState.meleeText:SetFontObject(smallFont)
    self.damageUIState.meleeText:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -15, 30)
    self.damageUIState.meleeText:SetText("")
    self.damageUIState.meleeText:SetTextColor(unpack(self.config.COLOR_MELEE))
end

-- =============================================================================
-- DATA RETRIEVAL
-- =============================================================================

-- Override base GetDisplayData method
function DamageMeter:GetDisplayData()
    if addon.DamageAccumulator then
        return addon.DamageAccumulator:GetDisplayData(self.state.windowSeconds)
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
        meterType = "Damage",
        currentSpellDPS = 0,
        currentMeleeDPS = 0,
        peakSpellDPS = 0,
        peakMeleeDPS = 0,
        totalSpellDamage = 0,
        totalMeleeDamage = 0
    }
end

-- Get current window setting for plot integration
function DamageMeter:GetCurrentWindow()
    return self.state.windowSeconds
end

-- Override base GetActivityLevel method
function DamageMeter:GetActivityLevel()
    if addon.DamageAccumulator then
        return addon.DamageAccumulator:GetActivityLevel()
    end
    return 0
end

-- =============================================================================
-- CUSTOM UPDATE LOGIC
-- =============================================================================

-- Override base CustomUpdateDisplay method
function DamageMeter:CustomUpdateDisplay(currentValue, displayData)
    local now = GetTime()
    
    -- Get damage-specific data
    local currentDPS = displayData.currentMetric or 0
    local currentSpellDPS = displayData.currentSpellDPS or 0
    local currentMeleeDPS = displayData.currentMeleeDPS or 0
    
    -- Get peak values
    local recentPeakValue = displayData.peakMetric or 0
    
    -- Update peaks and current values
    self.state.recentPeak = recentPeakValue
    self.state.currentValue = currentDPS
    if currentDPS > self.state.sessionPeak then
        self.state.sessionPeak = currentDPS
    end
    
    -- Format main number with auto-scaling
    local formatted, scale, unit = self:FormatNumberWithScale(currentDPS)
    self.state.currentScale = scale
    self.state.scaleUnit = unit
    
    -- Update main number display
    if self.state.mainNumberText then
        -- Use StringPool if available for zero-allocation formatting
        if addon.StringPool then
            local formattedText = addon.StringPool:GetFormattedNumber(formatted, unit)
            self.state.mainNumberText:SetText(formattedText)
        else
            -- Fallback to string concatenation
            local whole, decimal = formatted:match("^(%d+)%.?(%d*)$")
            if decimal and decimal ~= "" then
                self.state.mainNumberText:SetText(whole .. "." .. decimal .. unit)
            else
                self.state.mainNumberText:SetText(whole .. unit)
            end
        end
    end
    
    -- Update scale indicator with timing logic (same as HealingMeter)
    if self.state.scaleText then
        local activityLevel = displayData.activityLevel or 0
        local timeSinceLastUpdate = now - self.state.lastScaleUpdate
        local shouldUpdateScale = false
        
        -- Calculate what the new scale would be
        local newScaleText, newScaleValue = self:GetIntelligentScale()
        
        -- Determine if we should update the scale
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
            -- Use StringPool for scale text
            if addon.StringPool then
                self.state.scaleText:SetText(addon.StringPool:GetScale(newScaleText))
            else
                self.state.scaleText:SetText(newScaleText .. " scale")
            end
        else
            -- Use StringPool for scale text
            if addon.StringPool then
                self.state.scaleText:SetText(addon.StringPool:GetScale(self.state.lastScaleValue))
            else
                self.state.scaleText:SetText(self.state.lastScaleValue .. " scale")
            end
        end
    end
    
    -- Update peak text
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
    
    -- Update spell damage text
    if self.damageUIState.spellText then
        local spellFormatted, _, spellUnit = self:FormatNumberWithScale(currentSpellDPS)
        if currentSpellDPS > 0 then
            self.damageUIState.spellText:SetText(string.format("Spell: %s%s", spellFormatted, spellUnit))
        else
            self.damageUIState.spellText:SetText("")
        end
    end
    
    -- Update melee damage text
    if self.damageUIState.meleeText then
        local meleeFormatted, _, meleeUnit = self:FormatNumberWithScale(currentMeleeDPS)
        if currentMeleeDPS > 0 then
            self.damageUIState.meleeText:SetText(string.format("Melee: %s%s", meleeFormatted, meleeUnit))
        else
            self.damageUIState.meleeText:SetText("")
        end
    end
    
    -- Update activity bar based on DPS vs scale
    self:UpdateActivityBar(currentDPS)
end

-- =============================================================================
-- CUSTOM INITIALIZATION
-- =============================================================================

-- Override base CustomInitialize method
function DamageMeter:CustomInitialize()
    -- Set up event subscriptions for damage events
    if addon.EventBus then
        -- Subscribe to damage events for immediate feedback
        addon.EventBus:SubscribeToDamage(function(event)
            -- Could add damage flash or immediate update here
        end, "DamageMeterUI")
    end
    
    -- DamageMeter UI initialized
end

-- =============================================================================
-- WINDOW POSITIONING
-- =============================================================================

-- Override default position 
function DamageMeter:CreateMainWindow()
    -- Call base method first
    local frame = MeterWindow.CreateMainWindow(self)
    
    -- Adjust default position
    if frame and not (addon.db and addon.db.DamageWindowPosition) then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 100, 0) -- Default position
    end
    
    return frame
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the damage meter UI
function DamageMeter:Initialize()
    -- Initialize base class first
    InitializeBaseClass()
    
    if not MeterWindow then
        error("DamageMeter: Cannot initialize without MeterWindow base class")
    end
    
    MeterWindow.Initialize(self)
    
    -- DamageMeter initialized
end

-- Module ready
DamageMeter.isReady = true

return DamageMeter