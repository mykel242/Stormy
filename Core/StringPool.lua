-- StringPool.lua
-- Pre-allocated string pool to avoid concatenation during combat

local addonName, addon = ...

-- =============================================================================
-- STRING POOL MODULE
-- =============================================================================

addon.StringPool = {}
local StringPool = addon.StringPool

-- Pre-generated strings
local stringCache = {
    -- Number formatting (0-999 with decimals)
    numbers = {},
    
    -- Common scales
    scales = {
        ["1K"] = "1K scale",
        ["5K"] = "5K scale",
        ["10K"] = "10K scale",
        ["25K"] = "25K scale",
        ["50K"] = "50K scale",
        ["100K"] = "100K scale",
        ["250K"] = "250K scale",
        ["500K"] = "500K scale",
        ["1M"] = "1M scale",
        ["2M"] = "2M scale",
        ["5M"] = "5M scale",
        ["10M"] = "10M scale"
    },
    
    -- Unit suffixes
    units = {
        K = "K",
        M = "M",
        B = "B"
    },
    
    -- Combined number+unit strings
    formatted = {}
}

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

function StringPool:Initialize()
    -- Pre-generate number strings with decimals
    for i = 0, 999 do
        stringCache.numbers[i] = tostring(i)
        
        -- Also generate with one decimal place
        for j = 0, 9 do
            local key = i + (j / 10)
            stringCache.numbers[key] = string.format("%d.%d", i, j)
        end
    end
    
    -- Pre-generate common formatted values
    self:GenerateFormattedValues()
    
    print("[STORMY] StringPool initialized with " .. self:GetCacheSize() .. " pre-generated strings")
end

-- Generate common formatted value strings
function StringPool:GenerateFormattedValues()
    -- Generate K values (1K - 999K)
    for i = 1, 999 do
        stringCache.formatted[i .. "K"] = i .. "K"
        
        -- With decimals (1.1K - 99.9K)
        if i < 100 then
            for j = 1, 9 do
                local key = i .. "." .. j .. "K"
                stringCache.formatted[key] = key
            end
        end
    end
    
    -- Generate M values (1M - 999M)
    for i = 1, 999 do
        stringCache.formatted[i .. "M"] = i .. "M"
        
        -- With decimals (1.1M - 99.9M)
        if i < 100 then
            for j = 1, 9 do
                local key = i .. "." .. j .. "M"
                stringCache.formatted[key] = key
            end
        end
    end
end

-- =============================================================================
-- STRING RETRIEVAL
-- =============================================================================

-- Get a number string (avoids tostring allocation)
function StringPool:GetNumber(num)
    if num >= 0 and num < 1000 then
        return stringCache.numbers[num] or tostring(num)
    end
    return tostring(num)  -- Fallback for out of range
end

-- Get a formatted number with unit (e.g., "123K", "45.6M")
function StringPool:GetFormattedNumber(value, unit)
    -- Try to find in cache first
    local cacheKey = value .. unit
    if stringCache.formatted[cacheKey] then
        return stringCache.formatted[cacheKey]
    end
    
    -- For simple numbers without unit
    if not unit or unit == "" then
        return self:GetNumber(value)
    end
    
    -- Fallback to string concatenation (should be rare)
    return value .. unit
end

-- Get a scale string
function StringPool:GetScale(scaleText)
    return stringCache.scales[scaleText] or (scaleText .. " scale")
end

-- Format a large number efficiently
function StringPool:FormatLargeNumber(num)
    if num < 1000 then
        -- Small numbers - use cached strings
        if num == math.floor(num) then
            return self:GetNumber(num)
        else
            -- Handle decimal
            local whole = math.floor(num)
            local decimal = math.floor((num - whole) * 10)
            return self:GetNumber(whole + decimal / 10)
        end
    elseif num < 1000000 then
        -- Thousands
        local thousands = num / 1000
        if thousands >= 100 then
            -- No decimal needed
            return self:GetFormattedNumber(math.floor(thousands), "K")
        else
            -- Include one decimal
            local whole = math.floor(thousands)
            local decimal = math.floor((thousands - whole) * 10)
            return self:GetFormattedNumber(whole .. "." .. decimal, "K")
        end
    elseif num < 1000000000 then
        -- Millions
        local millions = num / 1000000
        if millions >= 100 then
            -- No decimal needed
            return self:GetFormattedNumber(math.floor(millions), "M")
        else
            -- Include one decimal
            local whole = math.floor(millions)
            local decimal = math.floor((millions - whole) * 10)
            return self:GetFormattedNumber(whole .. "." .. decimal, "M")
        end
    else
        -- Billions (fallback to normal formatting)
        return string.format("%.1fB", num / 1000000000)
    end
end

-- =============================================================================
-- UTILITIES
-- =============================================================================

-- Get cache size for debugging
function StringPool:GetCacheSize()
    local count = 0
    
    for _ in pairs(stringCache.numbers) do
        count = count + 1
    end
    
    for _ in pairs(stringCache.formatted) do
        count = count + 1
    end
    
    for _ in pairs(stringCache.scales) do
        count = count + 1
    end
    
    return count
end

-- Debug function
function StringPool:Debug()
    print("=== StringPool Debug ===")
    print("Cache size: " .. self:GetCacheSize() .. " strings")
    print("Sample lookups:")
    print("  123 -> " .. self:GetNumber(123))
    print("  45.6 -> " .. self:GetNumber(45.6))
    print("  FormatLargeNumber(12345) -> " .. self:FormatLargeNumber(12345))
    print("  FormatLargeNumber(1234567) -> " .. self:FormatLargeNumber(1234567))
    print("  GetScale('10K') -> " .. self:GetScale("10K"))
end

-- Module ready
StringPool.isReady = true

return StringPool