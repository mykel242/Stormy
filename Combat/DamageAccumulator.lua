-- DamageAccumulator.lua
-- Real-time damage accumulation with rolling window calculations
-- Extends MeterAccumulator for damage-specific functionality

local addonName, addon = ...

-- =============================================================================
-- DAMAGE ACCUMULATOR MODULE
-- =============================================================================

addon.DamageAccumulator = {}
local DamageAccumulator = addon.DamageAccumulator

-- Initialize base class when it's available
local MeterAccumulator = nil

-- Initialize function (called after MeterAccumulator loads)
local function InitializeBaseClass()
    if addon.MeterAccumulator then
        MeterAccumulator = addon.MeterAccumulator
    end
end

-- Damage-specific configuration
local DAMAGE_CONFIG = {
    -- Track different damage types
    trackDamageTypes = true,
    
    -- Critical damage tracking
    trackCriticals = true,
    
    -- Spell vs melee separation
    trackAttackTypes = true
}

-- =============================================================================
-- DAMAGE ACCUMULATOR CLASS
-- =============================================================================

function DamageAccumulator:New()
    -- Initialize base class if not done yet
    InitializeBaseClass()
    
    if not MeterAccumulator then
        error("DamageAccumulator: MeterAccumulator base class not available")
    end
    
    -- Create base instance
    local instance = MeterAccumulator:New("Damage")
    
    -- Add damage-specific state
    instance.damageState = {
        -- Total values
        totalSpellDamage = 0,
        totalMeleeDamage = 0,
        totalDOTDamage = 0,
        
        -- Player vs Pet breakdown
        playerSpellDamage = 0,
        petSpellDamage = 0,
        playerMeleeDamage = 0,
        petMeleeDamage = 0,
        
        -- Damage type breakdown
        spellEvents = 0,
        meleeEvents = 0,
        dotEvents = 0,
        
        -- Current calculations
        currentSpellDPS = 0,
        currentMeleeDPS = 0,
        peakSpellDPS = 0,
        peakMeleeDPS = 0
    }
    
    -- Add damage-specific rolling data
    instance.damageRollingData = {
        spellDamage = {},   -- [timestamp] = amount
        meleeDamage = {},   -- [timestamp] = amount  
        dotDamage = {},     -- [timestamp] = amount
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
-- DAMAGE-SPECIFIC EVENT PROCESSING
-- =============================================================================

-- Override the base OnEvent method to process damage-specific data
function DamageAccumulator:OnEvent(timestamp, sourceGUID, amount, isPlayer, isPet, isCritical, extraData)
    -- For damage events, extraData could contain spell info, damage type, etc.
    local spellId = extraData and extraData.spellId
    local damageType = extraData and extraData.damageType or "unknown"
    local isSpell = spellId and spellId > 0
    local isDOT = extraData and extraData.isDOT or false
    
    -- Store damage-specific data
    self:StoreDamageData(timestamp, amount, isSpell, isDOT, isPlayer, isPet)
    
    -- Update totals based on damage type
    if isDOT then
        self.damageState.totalDOTDamage = self.damageState.totalDOTDamage + amount
        self.damageState.dotEvents = self.damageState.dotEvents + 1
    elseif isSpell then
        self.damageState.totalSpellDamage = self.damageState.totalSpellDamage + amount
        self.damageState.spellEvents = self.damageState.spellEvents + 1
    else
        self.damageState.totalMeleeDamage = self.damageState.totalMeleeDamage + amount
        self.damageState.meleeEvents = self.damageState.meleeEvents + 1
    end
    
    -- Player vs Pet breakdown
    if isPlayer then
        if isSpell then
            self.damageState.playerSpellDamage = self.damageState.playerSpellDamage + amount
        else
            self.damageState.playerMeleeDamage = self.damageState.playerMeleeDamage + amount
        end
    elseif isPet then
        if isSpell then
            self.damageState.petSpellDamage = self.damageState.petSpellDamage + amount
        else
            self.damageState.petMeleeDamage = self.damageState.petMeleeDamage + amount
        end
    end
end

-- Store damage-specific data in rolling windows
function DamageAccumulator:StoreDamageData(timestamp, damageAmount, isSpell, isDOT, isPlayer, isPet)
    local relativeTime = addon.TimingManager:GetCurrentRelativeTime()
    
    -- Store damage by type
    if isDOT then
        self.damageRollingData.dotDamage[relativeTime] = (self.damageRollingData.dotDamage[relativeTime] or 0) + damageAmount
    elseif isSpell then
        self.damageRollingData.spellDamage[relativeTime] = (self.damageRollingData.spellDamage[relativeTime] or 0) + damageAmount
    else
        self.damageRollingData.meleeDamage[relativeTime] = (self.damageRollingData.meleeDamage[relativeTime] or 0) + damageAmount
    end
end

-- Override base StoreExtraData method
function DamageAccumulator:StoreExtraData(event, extraData)
    if not event.damageData then
        event.damageData = {
            spellDamage = 0,
            meleeDamage = 0,
            dotDamage = 0
        }
    end
    
    local data = event.damageData
    local isSpell = extraData and extraData.spellId and extraData.spellId > 0
    local isDOT = extraData and extraData.isDOT or false
    
    if isDOT then
        data.dotDamage = data.dotDamage + event.value
    elseif isSpell then
        data.spellDamage = data.spellDamage + event.value
    else
        data.meleeDamage = data.meleeDamage + event.value
    end
end

-- =============================================================================
-- DAMAGE-SPECIFIC CALCULATIONS
-- =============================================================================

-- Override base CalculateWindowExtras method
function DamageAccumulator:CalculateWindowExtras(result, windowSeconds, cutoffTime)
    local totalSpellDamage = 0
    local totalMeleeDamage = 0
    local totalDOTDamage = 0
    
    -- Sum spell damage in window
    for timestamp, amount in pairs(self.damageRollingData.spellDamage) do
        if timestamp >= cutoffTime then
            totalSpellDamage = totalSpellDamage + amount
        end
    end
    
    -- Sum melee damage in window
    for timestamp, amount in pairs(self.damageRollingData.meleeDamage) do
        if timestamp >= cutoffTime then
            totalMeleeDamage = totalMeleeDamage + amount
        end
    end
    
    -- Sum DOT damage in window
    for timestamp, amount in pairs(self.damageRollingData.dotDamage) do
        if timestamp >= cutoffTime then
            totalDOTDamage = totalDOTDamage + amount
        end
    end
    
    -- Add damage-specific metrics to result
    result.spellDamage = totalSpellDamage
    result.meleeDamage = totalMeleeDamage
    result.dotDamage = totalDOTDamage
    result.spellDPS = windowSeconds > 0 and (totalSpellDamage / windowSeconds) or 0
    result.meleeDPS = windowSeconds > 0 and (totalMeleeDamage / windowSeconds) or 0
    result.dotDPS = windowSeconds > 0 and (totalDOTDamage / windowSeconds) or 0
end

-- Update current damage calculations
function DamageAccumulator:UpdateCurrentValues()
    -- Call base method first
    MeterAccumulator.UpdateCurrentValues(self)
    
    -- Calculate damage-specific current values
    local currentWindow = self:GetWindowTotals(5) -- 5 second window
    
    self.damageState.currentSpellDPS = currentWindow.spellDPS or 0
    self.damageState.currentMeleeDPS = currentWindow.meleeDPS or 0
    
    -- Update peaks
    if self.damageState.currentSpellDPS > self.damageState.peakSpellDPS then
        self.damageState.peakSpellDPS = self.damageState.currentSpellDPS
    end
    
    if self.damageState.currentMeleeDPS > self.damageState.peakMeleeDPS then
        self.damageState.peakMeleeDPS = self.damageState.currentMeleeDPS
    end
end

-- =============================================================================
-- CLEAN UP DAMAGE DATA
-- =============================================================================

-- Override base CleanOldData method
function DamageAccumulator:CleanOldData()
    local cleaned = MeterAccumulator.CleanOldData(self)
    
    local maxWindow = 60 -- 60 second window
    local now = addon.TimingManager and addon.TimingManager:GetCurrentRelativeTime() or GetTime()
    local cutoffTime = now - maxWindow
    
    -- Clean damage-specific data
    for timestamp in pairs(self.damageRollingData.spellDamage) do
        if timestamp < cutoffTime then
            self.damageRollingData.spellDamage[timestamp] = nil
        end
    end
    
    for timestamp in pairs(self.damageRollingData.meleeDamage) do
        if timestamp < cutoffTime then
            self.damageRollingData.meleeDamage[timestamp] = nil
        end
    end
    
    for timestamp in pairs(self.damageRollingData.dotDamage) do
        if timestamp < cutoffTime then
            self.damageRollingData.dotDamage[timestamp] = nil
        end
    end
    
    return cleaned
end

-- =============================================================================
-- PUBLIC API EXTENSIONS
-- =============================================================================

-- Get current DPS (base damage only)
function DamageAccumulator:GetCurrentDPS()
    return self:GetCurrentMetric()
end

-- Get current spell DPS
function DamageAccumulator:GetCurrentSpellDPS()
    if GetTime() - self.state.lastCalculation > 0.5 then
        self:UpdateCurrentValues()
    end
    return self.damageState.currentSpellDPS
end

-- Get current melee DPS
function DamageAccumulator:GetCurrentMeleeDPS()
    if GetTime() - self.state.lastCalculation > 0.5 then
        self:UpdateCurrentValues()
    end
    return self.damageState.currentMeleeDPS
end

-- Override base GetExtraStats method
function DamageAccumulator:GetExtraStats(stats)
    -- Add damage-specific stats
    stats.totalSpellDamage = self.damageState.totalSpellDamage
    stats.totalMeleeDamage = self.damageState.totalMeleeDamage
    stats.totalDOTDamage = self.damageState.totalDOTDamage
    
    stats.playerSpellDamage = self.damageState.playerSpellDamage
    stats.petSpellDamage = self.damageState.petSpellDamage
    stats.playerMeleeDamage = self.damageState.playerMeleeDamage
    stats.petMeleeDamage = self.damageState.petMeleeDamage
    
    stats.currentSpellDPS = self.damageState.currentSpellDPS
    stats.currentMeleeDPS = self.damageState.currentMeleeDPS
    stats.peakSpellDPS = self.damageState.peakSpellDPS
    stats.peakMeleeDPS = self.damageState.peakMeleeDPS
    
    stats.spellEvents = self.damageState.spellEvents
    stats.meleeEvents = self.damageState.meleeEvents
    stats.dotEvents = self.damageState.dotEvents
end

-- =============================================================================
-- RESET AND DEBUGGING
-- =============================================================================

-- Override base OnReset method
function DamageAccumulator:OnReset()
    -- Clear damage-specific state
    for key in pairs(self.damageState) do
        if type(self.damageState[key]) == "number" then
            self.damageState[key] = 0
        end
    end
    
    -- Clear damage rolling data
    self.damageRollingData.spellDamage = {}
    self.damageRollingData.meleeDamage = {}
    self.damageRollingData.dotDamage = {}
end

-- Override base DebugExtra method
function DamageAccumulator:DebugExtra(stats)
    print("Damage-Specific Metrics:")
    print(string.format("  Spell DPS: %.0f, Melee DPS: %.0f", 
          stats.currentSpellDPS, stats.currentMeleeDPS))
    print(string.format("  Peak Spell: %.0f, Peak Melee: %.0f", 
          stats.peakSpellDPS, stats.peakMeleeDPS))
    print(string.format("  Total Spell: %s, Total Melee: %s, Total DOT: %s", 
          self:FormatNumber(stats.totalSpellDamage), 
          self:FormatNumber(stats.totalMeleeDamage),
          self:FormatNumber(stats.totalDOTDamage)))
    print(string.format("  Events: %d spell, %d melee, %d DOT", 
          stats.spellEvents, stats.meleeEvents, stats.dotEvents))
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the damage accumulator
function DamageAccumulator:Initialize()
    -- Initialize base class first
    InitializeBaseClass()
    
    if not MeterAccumulator then
        error("DamageAccumulator: Cannot initialize without MeterAccumulator base class")
    end
    
    MeterAccumulator.Initialize(self)
    
    -- DamageAccumulator initialized
end

-- Module ready
DamageAccumulator.isReady = true

return DamageAccumulator