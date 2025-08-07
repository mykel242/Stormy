-- EventPool.lua
-- Zero-allocation event pooling system for combat events

local addonName, addon = ...

-- =============================================================================
-- EVENT POOL MODULE
-- =============================================================================

addon.EventPool = {}
local EventPool = addon.EventPool

-- Pool configuration
local POOL_SIZES = {
    DAMAGE_EVENTS = 1000,     -- Pre-allocate 1000 damage event tables
    HEALING_EVENTS = 500,     -- Pre-allocate 500 healing event tables
    COMBAT_EVENTS = 100       -- Pre-allocate 100 combat state events
}

-- Event pools
local pools = {
    damage = {
        available = {},
        active = {},
        template = {
            sourceGUID = "",
            amount = 0,
            spellId = 0,
            critical = false,
            isPlayer = false,
            isPet = false,
            timestamp = 0
        }
    },
    healing = {
        available = {},
        active = {},
        template = {
            sourceGUID = "",
            amount = 0,
            spellId = 0,
            critical = false,
            isPlayer = false,
            isPet = false,
            timestamp = 0,
            overhealing = 0,
            absorbed = 0,
            isHOT = false
        }
    },
    combat = {
        available = {},
        active = {},
        template = {
            state = "",
            timestamp = 0,
            duration = 0
        }
    }
}

-- Statistics
local stats = {
    damage = { gets = 0, releases = 0, misses = 0 },
    healing = { gets = 0, releases = 0, misses = 0 },
    combat = { gets = 0, releases = 0, misses = 0 }
}

-- =============================================================================
-- CORE POOL OPERATIONS
-- =============================================================================

-- Initialize all pools
function EventPool:Initialize()
    -- Pre-allocate damage events
    for i = 1, POOL_SIZES.DAMAGE_EVENTS do
        local event = {}
        for k, v in pairs(pools.damage.template) do
            event[k] = v
        end
        table.insert(pools.damage.available, event)
    end
    
    -- Pre-allocate healing events
    for i = 1, POOL_SIZES.HEALING_EVENTS do
        local event = {}
        for k, v in pairs(pools.healing.template) do
            event[k] = v
        end
        table.insert(pools.healing.available, event)
    end
    
    -- Pre-allocate combat events
    for i = 1, POOL_SIZES.COMBAT_EVENTS do
        local event = {}
        for k, v in pairs(pools.combat.template) do
            event[k] = v
        end
        table.insert(pools.combat.available, event)
    end
    
    print(string.format("[STORMY] EventPool initialized: %d damage, %d healing, %d combat events pre-allocated",
        POOL_SIZES.DAMAGE_EVENTS, POOL_SIZES.HEALING_EVENTS, POOL_SIZES.COMBAT_EVENTS))
end

-- Get a damage event from pool
function EventPool:GetDamageEvent()
    local pool = pools.damage
    stats.damage.gets = stats.damage.gets + 1
    
    if #pool.available > 0 then
        local event = pool.available[#pool.available]
        pool.available[#pool.available] = nil
        pool.active[event] = true
        return event
    else
        -- Pool exhausted - track miss but don't allocate
        stats.damage.misses = stats.damage.misses + 1
        return nil
    end
end

-- Get a healing event from pool
function EventPool:GetHealingEvent()
    local pool = pools.healing
    stats.healing.gets = stats.healing.gets + 1
    
    if #pool.available > 0 then
        local event = pool.available[#pool.available]
        pool.available[#pool.available] = nil
        pool.active[event] = true
        return event
    else
        -- Pool exhausted - track miss but don't allocate
        stats.healing.misses = stats.healing.misses + 1
        return nil
    end
end

-- Get a combat event from pool
function EventPool:GetCombatEvent()
    local pool = pools.combat
    stats.combat.gets = stats.combat.gets + 1
    
    if #pool.available > 0 then
        local event = pool.available[#pool.available]
        pool.available[#pool.available] = nil
        pool.active[event] = true
        return event
    else
        -- Pool exhausted - track miss but don't allocate
        stats.combat.misses = stats.combat.misses + 1
        return nil
    end
end

-- Release a damage event back to pool
function EventPool:ReleaseDamageEvent(event)
    if not event then return end
    
    local pool = pools.damage
    if not pool.active[event] then
        return -- Not from our pool
    end
    
    -- Reset to template values
    for k, v in pairs(pool.template) do
        event[k] = v
    end
    
    pool.active[event] = nil
    table.insert(pool.available, event)
    stats.damage.releases = stats.damage.releases + 1
end

-- Release a healing event back to pool
function EventPool:ReleaseHealingEvent(event)
    if not event then return end
    
    local pool = pools.healing
    if not pool.active[event] then
        return -- Not from our pool
    end
    
    -- Reset to template values
    for k, v in pairs(pool.template) do
        event[k] = v
    end
    
    pool.active[event] = nil
    table.insert(pool.available, event)
    stats.healing.releases = stats.healing.releases + 1
end

-- Release a combat event back to pool
function EventPool:ReleaseCombatEvent(event)
    if not event then return end
    
    local pool = pools.combat
    if not pool.active[event] then
        return -- Not from our pool
    end
    
    -- Reset to template values
    for k, v in pairs(pool.template) do
        event[k] = v
    end
    
    pool.active[event] = nil
    table.insert(pool.available, event)
    stats.combat.releases = stats.combat.releases + 1
end

-- Release all active events (emergency cleanup)
function EventPool:ReleaseAll()
    -- Release all active damage events
    for event in pairs(pools.damage.active) do
        self:ReleaseDamageEvent(event)
    end
    
    -- Release all active healing events
    for event in pairs(pools.healing.active) do
        self:ReleaseHealingEvent(event)
    end
    
    -- Release all active combat events
    for event in pairs(pools.combat.active) do
        self:ReleaseCombatEvent(event)
    end
end

-- =============================================================================
-- STATISTICS AND DEBUGGING
-- =============================================================================

-- Get pool statistics
function EventPool:GetStats()
    local damageAvailable = #pools.damage.available
    local damageActive = 0
    for _ in pairs(pools.damage.active) do
        damageActive = damageActive + 1
    end
    
    local healingAvailable = #pools.healing.available
    local healingActive = 0
    for _ in pairs(pools.healing.active) do
        healingActive = healingActive + 1
    end
    
    local combatAvailable = #pools.combat.available
    local combatActive = 0
    for _ in pairs(pools.combat.active) do
        combatActive = combatActive + 1
    end
    
    return {
        damage = {
            available = damageAvailable,
            active = damageActive,
            total = POOL_SIZES.DAMAGE_EVENTS,
            gets = stats.damage.gets,
            releases = stats.damage.releases,
            misses = stats.damage.misses,
            hitRate = stats.damage.gets > 0 and 
                ((stats.damage.gets - stats.damage.misses) / stats.damage.gets) or 0
        },
        healing = {
            available = healingAvailable,
            active = healingActive,
            total = POOL_SIZES.HEALING_EVENTS,
            gets = stats.healing.gets,
            releases = stats.healing.releases,
            misses = stats.healing.misses,
            hitRate = stats.healing.gets > 0 and 
                ((stats.healing.gets - stats.healing.misses) / stats.healing.gets) or 0
        },
        combat = {
            available = combatAvailable,
            active = combatActive,
            total = POOL_SIZES.COMBAT_EVENTS,
            gets = stats.combat.gets,
            releases = stats.combat.releases,
            misses = stats.combat.misses,
            hitRate = stats.combat.gets > 0 and 
                ((stats.combat.gets - stats.combat.misses) / stats.combat.gets) or 0
        }
    }
end

-- Debug function
function EventPool:Debug()
    local stats = self:GetStats()
    
    print("=== EventPool Debug ===")
    print(string.format("Damage Pool: %d/%d available (%.1f%% hit rate)",
        stats.damage.available, stats.damage.total, stats.damage.hitRate * 100))
    print(string.format("  Gets: %d, Releases: %d, Misses: %d",
        stats.damage.gets, stats.damage.releases, stats.damage.misses))
    
    print(string.format("Healing Pool: %d/%d available (%.1f%% hit rate)",
        stats.healing.available, stats.healing.total, stats.healing.hitRate * 100))
    print(string.format("  Gets: %d, Releases: %d, Misses: %d",
        stats.healing.gets, stats.healing.releases, stats.healing.misses))
    
    print(string.format("Combat Pool: %d/%d available (%.1f%% hit rate)",
        stats.combat.available, stats.combat.total, stats.combat.hitRate * 100))
    print(string.format("  Gets: %d, Releases: %d, Misses: %d",
        stats.combat.gets, stats.combat.releases, stats.combat.misses))
end

-- Module ready
EventPool.isReady = true

return EventPool