-- TablePool.lua
-- High-performance table pooling with strict ownership rules
-- Simplified from MyUI StorageManager to prevent leaks and corruption

local addonName, addon = ...

-- =============================================================================
-- TABLE POOL MODULE
-- =============================================================================

addon.TablePool = {}
local TablePool = addon.TablePool

-- Pool configuration - smaller pools for better performance
local POOL_CONFIG = {
    EVENT_POOL_SIZE = 50,       -- Combat events
    CALC_POOL_SIZE = 20,        -- Calculation temporaries
    UI_POOL_SIZE = 10,          -- UI update data
    DETAIL_POOL_SIZE = 200,     -- Event detail objects
    SUMMARY_POOL_SIZE = 60      -- Second summary objects
}

-- Separate pools by purpose to prevent cross-contamination
local pools = {
    event = {},
    calc = {},
    ui = {},
    detail = {},
    summary = {}
}

-- Pool statistics
local stats = {
    event = { created = 0, reused = 0, corrupted = 0 },
    calc = { created = 0, reused = 0, corrupted = 0 },
    ui = { created = 0, reused = 0, corrupted = 0 },
    detail = { created = 0, reused = 0, corrupted = 0 },
    summary = { created = 0, reused = 0, corrupted = 0 }
}

-- Template structures for each pool type
local TEMPLATES = {
    event = {
        timestamp = 0,
        sourceGUID = "",
        destGUID = "",
        amount = 0,
        spellId = 0,
        eventType = ""
    },
    calc = {
        dps = 0,
        damage = 0,
        elapsed = 0
    },
    ui = {
        value = 0,
        percent = 0,
        text = ""
    },
    detail = {
        timestamp = 0,
        amount = 0,
        spellId = 0,
        sourceGUID = "",
        sourceName = "",
        sourceType = 0,     -- 0=player, 1=pet, 2=guardian
        isCrit = false
    },
    summary = {
        timestamp = 0,
        totalDamage = 0,
        eventCount = 0,
        critCount = 0,
        critDamage = 0,
        spells = {}         -- Will be cleared on release
    }
}

-- =============================================================================
-- CORE POOL OPERATIONS
-- =============================================================================

-- Get a table from the specified pool
function TablePool:Get(poolType)
    local pool = pools[poolType]
    local template = TEMPLATES[poolType]
    local poolStats = stats[poolType]
    
    if not pool or not template then
        error("Invalid pool type: " .. tostring(poolType))
    end
    
    local t
    
    if #pool > 0 then
        -- Reuse from pool
        t = pool[#pool]
        pool[#pool] = nil
        poolStats.reused = poolStats.reused + 1
        
        -- Validate table state
        if type(t) ~= "table" then
            -- Corruption detected - create new table
            poolStats.corrupted = poolStats.corrupted + 1
            t = {}
            poolStats.created = poolStats.created + 1
        end
        
        -- Reset to template state
        for k, v in pairs(template) do
            t[k] = v
        end
        
        -- Clear any extra fields that shouldn't be there
        for k in pairs(t) do
            if template[k] == nil then
                t[k] = nil
            end
        end
    else
        -- Create new table
        t = {}
        for k, v in pairs(template) do
            t[k] = v
        end
        poolStats.created = poolStats.created + 1
    end
    
    return t
end

-- Return a table to the specified pool
function TablePool:Release(poolType, t)
    if type(t) ~= "table" then
        return -- Ignore invalid input
    end
    
    local pool = pools[poolType]
    local maxSize = POOL_CONFIG[string.upper(poolType) .. "_POOL_SIZE"]
    
    if not pool or not maxSize then
        return -- Invalid pool type
    end
    
    -- Only accept if pool isn't full
    if #pool < maxSize then
        -- Clear metatable
        setmetatable(t, nil)
        
        -- Add to pool (clearing happens on Get)
        pool[#pool + 1] = t
    end
    -- If pool is full, just let the table be garbage collected
end

-- =============================================================================
-- SPECIALIZED ACCESSORS FOR COMMON OPERATIONS
-- =============================================================================

-- Get/Release event tables (most common)
function TablePool:GetEvent()
    return self:Get("event")
end

function TablePool:ReleaseEvent(t)
    self:Release("event", t)
end

-- Get/Release calculation tables
function TablePool:GetCalc()
    return self:Get("calc")
end

function TablePool:ReleaseCalc(t)
    self:Release("calc", t)
end

-- Get/Release UI tables
function TablePool:GetUI()
    return self:Get("ui")
end

function TablePool:ReleaseUI(t)
    self:Release("ui", t)
end

-- Get/Release event detail tables
function TablePool:GetDetail()
    return self:Get("detail")
end

function TablePool:ReleaseDetail(t)
    self:Release("detail", t)
end

-- Get/Release summary tables
function TablePool:GetSummary()
    return self:Get("summary")
end

function TablePool:ReleaseSummary(t)
    -- Clear the spells table before releasing
    if t and t.spells then
        for k in pairs(t.spells) do
            t.spells[k] = nil
        end
    end
    self:Release("summary", t)
end

-- =============================================================================
-- DEBUGGING AND MONITORING
-- =============================================================================

-- Get pool statistics
function TablePool:GetStats()
    local totalCreated = 0
    local totalReused = 0
    local totalCorrupted = 0
    
    for poolType, poolStats in pairs(stats) do
        totalCreated = totalCreated + poolStats.created
        totalReused = totalReused + poolStats.reused
        totalCorrupted = totalCorrupted + poolStats.corrupted
    end
    
    return {
        event = stats.event,
        calc = stats.calc,
        ui = stats.ui,
        total = {
            created = totalCreated,
            reused = totalReused,
            corrupted = totalCorrupted,
            reuseRatio = totalCreated > 0 and (totalReused / totalCreated) or 0
        },
        poolSizes = {
            event = #pools.event,
            calc = #pools.calc,
            ui = #pools.ui
        }
    }
end

-- Debug function to dump pool state
function TablePool:Debug()
    local stats = self:GetStats()
    print("=== TablePool Debug ===")
    print(string.format("Event Pool: %d/%d (Created: %d, Reused: %d)", 
        stats.poolSizes.event, POOL_CONFIG.EVENT_POOL_SIZE, stats.event.created, stats.event.reused))
    print(string.format("Calc Pool: %d/%d (Created: %d, Reused: %d)", 
        stats.poolSizes.calc, POOL_CONFIG.CALC_POOL_SIZE, stats.calc.created, stats.calc.reused))
    print(string.format("UI Pool: %d/%d (Created: %d, Reused: %d)", 
        stats.poolSizes.ui, POOL_CONFIG.UI_POOL_SIZE, stats.ui.created, stats.ui.reused))
    print(string.format("Total Reuse Ratio: %.1f%%", stats.total.reuseRatio * 100))
    if stats.total.corrupted > 0 then
        print(string.format("⚠️ Corrupted Tables: %d", stats.total.corrupted))
    end
end

-- Clear all pools (emergency use only)
function TablePool:Clear()
    for poolType in pairs(pools) do
        pools[poolType] = {}
    end
    
    for poolType in pairs(stats) do
        stats[poolType] = { created = 0, reused = 0, corrupted = 0 }
    end
end

-- Initialize the table pool
function TablePool:Initialize()
    -- Pre-allocate some tables for immediate use
    for i = 1, 10 do
        self:Release("event", self:Get("event"))
    end
    for i = 1, 5 do
        self:Release("calc", self:Get("calc"))
    end
    for i = 1, 3 do
        self:Release("ui", self:Get("ui"))
    end
    for i = 1, 20 do
        self:Release("detail", self:Get("detail"))
    end
    for i = 1, 10 do
        self:Release("summary", self:Get("summary"))
    end
    
    -- Clear stats after pre-allocation
    for poolType in pairs(stats) do
        stats[poolType] = { created = 0, reused = 0, corrupted = 0 }
    end
end

-- Module is ready
addon.TablePool.isReady = true