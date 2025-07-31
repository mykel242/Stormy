-- SpellCache.lua
-- Lazy-loaded spell name cache with LRU eviction and spell rank grouping
-- Optimized for minimal memory usage and fast lookups

local addonName, addon = ...

-- =============================================================================
-- SPELL CACHE MODULE
-- =============================================================================

addon.SpellCache = {}
local SpellCache = addon.SpellCache

-- Cache configuration
local CACHE_CONFIG = {
    MAX_SPELLS = 500,           -- Maximum cached spells
    MAX_ENTITIES = 200,         -- Maximum cached entity names
    CLEANUP_THRESHOLD = 0.9,    -- Cleanup when 90% full
    CLEANUP_COUNT = 50          -- Remove 50 oldest entries
}

-- Cache storage
local cache = {
    -- Spell information cache
    spells = {},                -- [spellId] = {name, icon, school}
    spellAccessTime = {},       -- [spellId] = timestamp
    spellCount = 0,
    
    -- Entity name cache
    entities = {},              -- [guid] = name
    entityAccessTime = {},      -- [guid] = timestamp
    entityCount = 0,
    
    -- Spell rank grouping
    rankMap = {},               -- [rankedSpellId] = baseSpellId
    baseSpellIds = {},          -- [baseName] = firstSeenSpellId
}

-- =============================================================================
-- SPELL INFORMATION
-- =============================================================================

-- Get spell information with caching
function SpellCache:GetSpellInfo(spellId)
    if not spellId or spellId == 0 then
        return "Melee"
    end
    
    -- Check cache first
    local info = cache.spells[spellId]
    if info then
        cache.spellAccessTime[spellId] = GetTime()
        return info.name, info.icon, info.school
    end
    
    -- Lazy load from API - handle both old and new API
    local name, icon, school
    if C_Spell and C_Spell.GetSpellInfo then
        -- Modern WoW API (10.x+)
        local spellInfo = C_Spell.GetSpellInfo(spellId)
        if spellInfo then
            name = spellInfo.name
            icon = spellInfo.iconID
            school = spellInfo.school
        end
    else
        -- Legacy API
        name, _, icon, _, _, _, _, _, school = GetSpellInfo(spellId)
    end
    
    if name then
        -- Store in cache
        cache.spells[spellId] = {
            name = name,
            icon = icon,
            school = school
        }
        cache.spellAccessTime[spellId] = GetTime()
        cache.spellCount = cache.spellCount + 1
        
        -- Debug: Log successful spell lookups occasionally
        if math.random() < 0.02 then  -- 2% chance
            print(string.format("[STORMY DEBUG] Spell cached: ID=%s, Name=%s", tostring(spellId), tostring(name)))
        end
        
        -- Cleanup if needed
        if cache.spellCount > CACHE_CONFIG.MAX_SPELLS * CACHE_CONFIG.CLEANUP_THRESHOLD then
            self:CleanupSpellCache()
        end
        
        return name, icon, school
    end
    
    -- Debug: Log failed spell lookups
    print(string.format("[STORMY DEBUG] Failed to get spell info for ID: %s", tostring(spellId)))
    
    return "Unknown Spell #" .. spellId
end

-- Get just the spell name (most common use case)
function SpellCache:GetSpellName(spellId)
    local name = self:GetSpellInfo(spellId)
    -- Debug: Log spell name lookups occasionally
    if math.random() < 0.1 then  -- 10% chance to log
        print(string.format("[STORMY DEBUG] SpellCache lookup: ID=%s, Name=%s", tostring(spellId), tostring(name)))
    end
    return name
end

-- =============================================================================
-- SPELL RANK GROUPING
-- =============================================================================

-- Get base spell ID (removes rank variations)
function SpellCache:GetBaseSpellId(spellId)
    if not spellId or spellId == 0 then
        return 0
    end
    
    -- Check if we've already mapped this
    local baseId = cache.rankMap[spellId]
    if baseId then
        return baseId
    end
    
    -- Get spell name to check for ranks
    local name = self:GetSpellName(spellId)
    if not name or name == "Unknown Spell #" .. spellId then
        return spellId
    end
    
    -- Remove rank indicators
    local baseName = name:gsub(" %(Rank %d+%)$", "")
    
    -- Check if we've seen this base spell before
    local existingBaseId = cache.baseSpellIds[baseName]
    if existingBaseId then
        -- Map this ranked version to the base
        cache.rankMap[spellId] = existingBaseId
        return existingBaseId
    else
        -- This is the first time seeing this spell
        cache.baseSpellIds[baseName] = spellId
        cache.rankMap[spellId] = spellId
        return spellId
    end
end

-- =============================================================================
-- ENTITY NAME CACHE
-- =============================================================================

-- Get entity name from GUID
function SpellCache:GetEntityName(guid)
    if not guid then
        return "Unknown"
    end
    
    -- Check cache first
    local name = cache.entities[guid]
    if name then
        cache.entityAccessTime[guid] = GetTime()
        return name
    end
    
    -- Try to get name from game
    -- This is limited - may not work for all GUIDs
    -- In combat log processing, names are usually provided
    return "Unknown Entity"
end

-- Store entity name (called during combat log processing)
function SpellCache:StoreEntityName(guid, name)
    if not guid or not name then
        return
    end
    
    -- Don't store if already cached and same
    if cache.entities[guid] == name then
        cache.entityAccessTime[guid] = GetTime()
        return
    end
    
    -- Store in cache
    cache.entities[guid] = name
    cache.entityAccessTime[guid] = GetTime()
    
    -- Track count for new entries
    if not cache.entities[guid] then
        cache.entityCount = cache.entityCount + 1
    end
    
    -- Cleanup if needed
    if cache.entityCount > CACHE_CONFIG.MAX_ENTITIES * CACHE_CONFIG.CLEANUP_THRESHOLD then
        self:CleanupEntityCache()
    end
end

-- =============================================================================
-- CACHE MANAGEMENT
-- =============================================================================

-- Cleanup old spell entries (LRU eviction)
function SpellCache:CleanupSpellCache()
    local now = GetTime()
    local entries = {}
    
    -- Build list of entries with access times
    for spellId, accessTime in pairs(cache.spellAccessTime) do
        table.insert(entries, {id = spellId, time = accessTime})
    end
    
    -- Sort by access time (oldest first)
    table.sort(entries, function(a, b) return a.time < b.time end)
    
    -- Remove oldest entries
    local removeCount = math.min(CACHE_CONFIG.CLEANUP_COUNT, #entries)
    for i = 1, removeCount do
        local spellId = entries[i].id
        cache.spells[spellId] = nil
        cache.spellAccessTime[spellId] = nil
        cache.spellCount = cache.spellCount - 1
    end
end

-- Cleanup old entity entries (LRU eviction)
function SpellCache:CleanupEntityCache()
    local now = GetTime()
    local entries = {}
    
    -- Build list of entries with access times
    for guid, accessTime in pairs(cache.entityAccessTime) do
        table.insert(entries, {id = guid, time = accessTime})
    end
    
    -- Sort by access time (oldest first)
    table.sort(entries, function(a, b) return a.time < b.time end)
    
    -- Remove oldest entries
    local removeCount = math.min(CACHE_CONFIG.CLEANUP_COUNT, #entries)
    for i = 1, removeCount do
        local guid = entries[i].id
        cache.entities[guid] = nil
        cache.entityAccessTime[guid] = nil
        cache.entityCount = cache.entityCount - 1
    end
end

-- Clear all caches
function SpellCache:Clear()
    cache.spells = {}
    cache.spellAccessTime = {}
    cache.spellCount = 0
    
    cache.entities = {}
    cache.entityAccessTime = {}
    cache.entityCount = 0
    
    cache.rankMap = {}
    cache.baseSpellIds = {}
end

-- =============================================================================
-- DEBUGGING
-- =============================================================================

-- Get cache statistics
function SpellCache:GetStats()
    return {
        spells = {
            count = cache.spellCount,
            maxSize = CACHE_CONFIG.MAX_SPELLS,
            usage = cache.spellCount / CACHE_CONFIG.MAX_SPELLS
        },
        entities = {
            count = cache.entityCount,
            maxSize = CACHE_CONFIG.MAX_ENTITIES,
            usage = cache.entityCount / CACHE_CONFIG.MAX_ENTITIES
        },
        rankMappings = #cache.rankMap,
        baseSpells = #cache.baseSpellIds
    }
end

-- Debug output
function SpellCache:Debug()
    local stats = self:GetStats()
    print("=== SpellCache Debug ===")
    print(string.format("Spells: %d/%d (%.1f%% full)", 
        stats.spells.count, stats.spells.maxSize, stats.spells.usage * 100))
    print(string.format("Entities: %d/%d (%.1f%% full)", 
        stats.entities.count, stats.entities.maxSize, stats.entities.usage * 100))
    print(string.format("Rank Mappings: %d", stats.rankMappings))
    print(string.format("Base Spells: %d", stats.baseSpells))
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the spell cache
function SpellCache:Initialize()
    -- Cache is ready to use immediately
    self.isReady = true
end

-- Module ready
SpellCache.isReady = true