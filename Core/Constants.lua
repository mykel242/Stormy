-- Constants.lua
-- Shared constants, bit flags, and lookup tables for high-performance event processing

local addonName, addon = ...

-- =============================================================================
-- ADDON CONSTANTS
-- =============================================================================

addon.Constants = {}
local Constants = addon.Constants

-- Version and metadata
Constants.VERSION = "1.0.0"
Constants.BUILD_DATE = "2025-06-28"

-- Performance configuration
Constants.PERFORMANCE = {
    -- Update rates (milliseconds)
    UI_UPDATE_RATE = 250,           -- 4 FPS during combat
    UI_UPDATE_RATE_INTENSIVE = 500, -- 2 FPS during event storms
    
    -- Ring buffer sizes
    EVENT_BUFFER_SIZE = 1000,       -- Combat events
    CALCULATION_WINDOW = 30,        -- Seconds for rolling calculations
    
    -- Event processing limits
    EVENTS_PER_SECOND_NORMAL = 20,  -- Normal combat activity
    EVENTS_PER_SECOND_INTENSIVE = 50, -- High-activity threshold
    MAX_EVENTS_PER_FRAME = 25,      -- Circuit breaker (increased from 10)
    
    -- Memory limits
    MAX_POOL_SIZE_EVENT = 50,
    MAX_POOL_SIZE_CALC = 20,
    MAX_POOL_SIZE_UI = 10
}

-- =============================================================================
-- COMBAT LOG EVENT FILTERING
-- =============================================================================

-- Combat log object control flags (from COMBATLOG_OBJECT_CONTROL_*)
Constants.OBJECT_CONTROL = {
    PLAYER = 0x00000100,
    NPC = 0x00000200,
    PET = 0x00001000,
    GUARDIAN = 0x00002000
}

-- Combined masks for fast filtering
Constants.CONTROL_MASKS = {
    -- Player or player pet/guardian
    PLAYER_OWNED = bit.bor(
        Constants.OBJECT_CONTROL.PLAYER,
        Constants.OBJECT_CONTROL.PET,
        Constants.OBJECT_CONTROL.GUARDIAN
    ),
    -- Any controllable entity
    CONTROLLABLE = bit.bor(
        Constants.OBJECT_CONTROL.PLAYER,
        Constants.OBJECT_CONTROL.PET,
        Constants.OBJECT_CONTROL.GUARDIAN,
        Constants.OBJECT_CONTROL.NPC
    )
}

-- Combat log object type flags
Constants.OBJECT_TYPE = {
    PLAYER = 0x00000400,
    NPC = 0x00000800,
    PET = 0x00001000,
    GUARDIAN = 0x00002000,
    OBJECT = 0x00004000
}

-- =============================================================================
-- DAMAGE/HEALING EVENT TABLES
-- =============================================================================

-- Damage events we care about (fast lookup)
Constants.DAMAGE_EVENTS = {
    ["SWING_DAMAGE"] = true,
    ["SPELL_DAMAGE"] = true,
    ["SPELL_PERIODIC_DAMAGE"] = true,
    ["RANGE_DAMAGE"] = true,
    ["ENVIRONMENTAL_DAMAGE"] = false, -- Exclude environmental
}

-- Healing events we care about
Constants.HEALING_EVENTS = {
    ["SPELL_HEAL"] = true,
    ["SPELL_PERIODIC_HEAL"] = true,
}


-- Events we NEVER want to process (immediate return)
Constants.IGNORED_EVENTS = {
    -- Environmental and positioning
    ["ENVIRONMENTAL_DAMAGE"] = true,
    ["SPELL_BUILDING_DAMAGE"] = true,
    ["SPELL_BUILDING_HEAL"] = true,
    
    -- Enchants and enhancements
    ["ENCHANT_APPLIED"] = true,
    ["ENCHANT_REMOVED"] = true,
    ["SPELL_ENCHANT_APPLIED"] = true,
    ["SPELL_ENCHANT_REMOVED"] = true,
    
    -- Summons and creates
    ["SPELL_SUMMON"] = true,
    ["SPELL_CREATE"] = true,
    
    -- Durability
    ["SPELL_DURABILITY_DAMAGE"] = true,
    ["SPELL_DURABILITY_DAMAGE_ALL"] = true,
    
    -- Aura events (not needed for damage tracking)
    ["SPELL_AURA_APPLIED"] = true,
    ["SPELL_AURA_REMOVED"] = true,
    ["SPELL_AURA_APPLIED_DOSE"] = true,
    ["SPELL_AURA_REMOVED_DOSE"] = true,
    ["SPELL_AURA_REFRESH"] = true,
    ["SPELL_AURA_BROKEN"] = true,
    ["SPELL_AURA_BROKEN_SPELL"] = true,
    
    -- Cast events (not needed for damage tracking)
    ["SPELL_CAST_START"] = true,
    ["SPELL_CAST_SUCCESS"] = true,
    ["SPELL_CAST_FAILED"] = true,
    
    -- Threat and other combat mechanics
    ["THREAT"] = true,
    ["UNIT_DIED"] = true,
    ["UNIT_DESTROYED"] = true,
    
    -- Resource changes
    ["SPELL_ENERGIZE"] = true,
    ["SPELL_PERIODIC_ENERGIZE"] = true,
    ["SPELL_DRAIN"] = true,
    ["SPELL_LEECH"] = true,
    
    -- Dispels and interrupts
    ["SPELL_DISPEL"] = true,
    ["SPELL_STOLEN"] = true,
    ["SPELL_INTERRUPT"] = true,
    
    -- Miscellaneous
    ["SPELL_EXTRA_ATTACKS"] = true,
    ["SPELL_INSTAKILL"] = true,
    ["SPELL_RESURRECT"] = true
}

-- All trackable events (damage + healing)
Constants.TRACKABLE_EVENTS = {}
for event in pairs(Constants.DAMAGE_EVENTS) do
    if Constants.DAMAGE_EVENTS[event] then
        Constants.TRACKABLE_EVENTS[event] = "damage"
    end
end
for event in pairs(Constants.HEALING_EVENTS) do
    Constants.TRACKABLE_EVENTS[event] = "healing"
end

-- =============================================================================
-- SPELL SCHOOL CONSTANTS
-- =============================================================================

-- Spell school bit flags
Constants.SPELL_SCHOOLS = {
    PHYSICAL = 0x01,
    HOLY = 0x02,
    FIRE = 0x04,
    NATURE = 0x08,
    FROST = 0x10,
    SHADOW = 0x20,
    ARCANE = 0x40
}

-- School names for display
Constants.SCHOOL_NAMES = {
    [0x01] = "Physical",
    [0x02] = "Holy",
    [0x04] = "Fire",
    [0x08] = "Nature",
    [0x10] = "Frost",
    [0x20] = "Shadow",
    [0x40] = "Arcane"
}

-- =============================================================================
-- COMBAT STATE CONSTANTS
-- =============================================================================

Constants.COMBAT_STATE = {
    OUT_OF_COMBAT = 0,
    IN_COMBAT = 1,
    COMBAT_ENDING = 2
}

Constants.COMBAT_EVENTS = {
    START = "COMBAT_START",
    END = "COMBAT_END",
    DAMAGE = "DAMAGE_DEALT",
    HEALING = "HEALING_DONE"
}

-- =============================================================================
-- UI CONSTANTS
-- =============================================================================

Constants.UI = {
    -- Window dimensions
    METER_WIDTH = 300,
    METER_HEIGHT = 400,
    BAR_HEIGHT = 20,
    BAR_SPACING = 2,
    
    -- Colors
    COLORS = {
        DAMAGE = {1.0, 0.3, 0.3, 1.0},     -- Red
        HEALING = {0.3, 1.0, 0.3, 1.0},    -- Green
        BACKGROUND = {0.0, 0.0, 0.0, 0.8}, -- Dark background
        BORDER = {0.5, 0.5, 0.5, 1.0},     -- Gray border
        TEXT = {1.0, 1.0, 1.0, 1.0}        -- White text
    },
    
    -- Strata and levels
    STRATA = "MEDIUM",
    FRAME_LEVEL = 10,
    
    -- Update thresholds
    MIN_DAMAGE_TO_SHOW = 100,
    MIN_PERCENT_TO_SHOW = 0.01 -- 1%
}

-- =============================================================================
-- SCALING CONSTANTS
-- =============================================================================

Constants.SCALING = {
    -- Default scales for different scenarios
    DEFAULT_SCALE = 100000,     -- 100k damage
    MIN_SCALE = 10000,          -- 10k minimum
    MAX_SCALE = 10000000,       -- 10M maximum
    
    -- Decay rates for adaptive scaling
    PEAK_DECAY_RATE = 0.98,     -- 2% decay per second
    SCALE_SMOOTHING = 0.9,      -- Smoothing factor for scale changes
    
    -- Combat intensity thresholds
    BURST_THRESHOLD = 0.8,      -- 80% of peak = burst phase
    SUSTAIN_THRESHOLD = 0.5,    -- 50% of peak = sustained phase
    NORMAL_THRESHOLD = 0.2,     -- 20% of peak = normal phase
    
    -- Scale multipliers by phase
    BURST_MULTIPLIER = 2.0,
    SUSTAIN_MULTIPLIER = 1.5,
    NORMAL_MULTIPLIER = 1.2
}

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================

-- Fast bit operations
function Constants.HasFlag(value, flag)
    return bit.band(value, flag) ~= 0
end

function Constants.IsPlayerControlled(flags)
    return Constants.HasFlag(flags, Constants.CONTROL_MASKS.PLAYER_OWNED)
end

function Constants.IsTrackableEvent(eventType)
    return Constants.TRACKABLE_EVENTS[eventType] ~= nil
end

function Constants.ShouldIgnoreEvent(eventType)
    return Constants.IGNORED_EVENTS[eventType] == true
end

-- Get event category (damage/healing/ignored)
function Constants.GetEventCategory(eventType)
    if Constants.IGNORED_EVENTS[eventType] then
        return "ignored"
    elseif Constants.DAMAGE_EVENTS[eventType] then
        return "damage"
    elseif Constants.HEALING_EVENTS[eventType] then
        return "healing"
    else
        return "unknown"
    end
end

-- Module ready
Constants.isReady = true