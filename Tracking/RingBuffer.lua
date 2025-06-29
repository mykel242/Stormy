-- RingBuffer.lua
-- High-performance fixed-size circular buffer for event storage
-- Optimized for frequent writes and time-windowed queries

local addonName, addon = ...

-- =============================================================================
-- RING BUFFER MODULE
-- =============================================================================

addon.RingBuffer = {}
local RingBuffer = addon.RingBuffer

-- Ring buffer configuration
local CONFIG = {
    DEFAULT_SIZE = 1000,        -- Default buffer size
    MAX_SIZE = 2000,            -- Maximum allowed size
    MIN_SIZE = 100,             -- Minimum useful size
    CLEANUP_THRESHOLD = 0.8     -- Clean when 80% full of old data
}

-- Ring buffer class
local RingBufferClass = {}
RingBufferClass.__index = RingBufferClass

-- =============================================================================
-- RING BUFFER CREATION
-- =============================================================================

-- Create a new ring buffer
function RingBuffer:New(size, name)
    size = size or CONFIG.DEFAULT_SIZE
    
    -- Validate size
    if size < CONFIG.MIN_SIZE then
        size = CONFIG.MIN_SIZE
    elseif size > CONFIG.MAX_SIZE then
        size = CONFIG.MAX_SIZE
    end
    
    local buffer = setmetatable({}, RingBufferClass)
    
    -- Core buffer properties
    buffer.size = size
    buffer.name = name or "RingBuffer"
    
    -- Pre-allocate all slots (never grows/shrinks)
    buffer.data = {}
    for i = 1, size do
        buffer.data[i] = {
            timestamp = 0,
            value = 0,
            data = nil,
            valid = false
        }
    end
    
    -- Buffer state
    buffer.writeIndex = 1
    buffer.count = 0
    buffer.totalWrites = 0
    buffer.totalOverwrites = 0
    
    -- Performance tracking
    buffer.lastWrite = 0
    buffer.lastQuery = 0
    buffer.queryCount = 0
    
    return buffer
end

-- =============================================================================
-- CORE BUFFER OPERATIONS
-- =============================================================================

-- Write data to the buffer (overwrites oldest if full)
function RingBufferClass:Write(timestamp, value, data)
    local slot = self.data[self.writeIndex]
    
    -- Track overwrites
    if slot.valid then
        self.totalOverwrites = self.totalOverwrites + 1
    end
    
    -- Store data
    slot.timestamp = timestamp
    slot.value = value
    slot.data = data
    slot.valid = true
    
    -- Update indices
    self.writeIndex = (self.writeIndex % self.size) + 1
    if self.count < self.size then
        self.count = self.count + 1
    end
    
    self.totalWrites = self.totalWrites + 1
    self.lastWrite = GetTime()
end

-- Read data within a time window (most recent first)
function RingBufferClass:QueryWindow(windowStart, windowEnd, maxResults)
    local results = {}
    local found = 0
    maxResults = maxResults or math.huge
    
    self.queryCount = self.queryCount + 1
    self.lastQuery = GetTime()
    
    -- Search backwards from most recent
    local searchIndex = self.writeIndex - 1
    if searchIndex < 1 then
        searchIndex = self.size
    end
    
    local searched = 0
    while searched < self.count and found < maxResults do
        local slot = self.data[searchIndex]
        
        if slot.valid then
            if slot.timestamp >= windowStart and slot.timestamp <= windowEnd then
                found = found + 1
                results[found] = {
                    timestamp = slot.timestamp,
                    value = slot.value,
                    data = slot.data
                }
            elseif slot.timestamp < windowStart then
                -- Since we're going backwards in time, we can stop here
                break
            end
        end
        
        searched = searched + 1
        searchIndex = searchIndex - 1
        if searchIndex < 1 then
            searchIndex = self.size
        end
    end
    
    return results, found
end

-- Get data from the last N seconds
function RingBufferClass:QueryLastSeconds(seconds, maxResults)
    local now = addon.TimingManager and addon.TimingManager:GetCurrentRelativeTime() or GetTime()
    local windowStart = now - seconds
    return self:QueryWindow(windowStart, now, maxResults)
end

-- Get all valid data (most recent first)
function RingBufferClass:QueryAll(maxResults)
    local results = {}
    local found = 0
    maxResults = maxResults or self.count
    
    -- Search backwards from most recent
    local searchIndex = self.writeIndex - 1
    if searchIndex < 1 then
        searchIndex = self.size
    end
    
    local searched = 0
    while searched < self.count and found < maxResults do
        local slot = self.data[searchIndex]
        
        if slot.valid then
            found = found + 1
            results[found] = {
                timestamp = slot.timestamp,
                value = slot.value,
                data = slot.data
            }
        end
        
        searched = searched + 1
        searchIndex = searchIndex - 1
        if searchIndex < 1 then
            searchIndex = self.size
        end
    end
    
    return results, found
end

-- =============================================================================
-- AGGREGATION FUNCTIONS
-- =============================================================================

-- Sum values in a time window
function RingBufferClass:SumWindow(windowStart, windowEnd)
    local total = 0
    local count = 0
    
    local searchIndex = self.writeIndex - 1
    if searchIndex < 1 then
        searchIndex = self.size
    end
    
    local searched = 0
    while searched < self.count do
        local slot = self.data[searchIndex]
        
        if slot.valid then
            if slot.timestamp >= windowStart and slot.timestamp <= windowEnd then
                total = total + slot.value
                count = count + 1
            elseif slot.timestamp < windowStart then
                break
            end
        end
        
        searched = searched + 1
        searchIndex = searchIndex - 1
        if searchIndex < 1 then
            searchIndex = self.size
        end
    end
    
    return total, count
end

-- Sum values from the last N seconds
function RingBufferClass:SumLastSeconds(seconds)
    local now = addon.TimingManager and addon.TimingManager:GetCurrentRelativeTime() or GetTime()
    local windowStart = now - seconds
    return self:SumWindow(windowStart, now)
end

-- Get average value in time window
function RingBufferClass:AverageWindow(windowStart, windowEnd)
    local total, count = self:SumWindow(windowStart, windowEnd)
    return count > 0 and (total / count) or 0, count
end

-- Get average value from last N seconds
function RingBufferClass:AverageLastSeconds(seconds)
    local total, count = self:SumLastSeconds(seconds)
    return count > 0 and (total / count) or 0, count
end

-- Find maximum value in time window
function RingBufferClass:MaxWindow(windowStart, windowEnd)
    local maxValue = nil
    local maxTimestamp = nil
    local count = 0
    
    local searchIndex = self.writeIndex - 1
    if searchIndex < 1 then
        searchIndex = self.size
    end
    
    local searched = 0
    while searched < self.count do
        local slot = self.data[searchIndex]
        
        if slot.valid then
            if slot.timestamp >= windowStart and slot.timestamp <= windowEnd then
                if not maxValue or slot.value > maxValue then
                    maxValue = slot.value
                    maxTimestamp = slot.timestamp
                end
                count = count + 1
            elseif slot.timestamp < windowStart then
                break
            end
        end
        
        searched = searched + 1
        searchIndex = searchIndex - 1
        if searchIndex < 1 then
            searchIndex = self.size
        end
    end
    
    return maxValue or 0, maxTimestamp, count
end

-- Find maximum value from last N seconds
function RingBufferClass:MaxLastSeconds(seconds)
    local now = addon.TimingManager and addon.TimingManager:GetCurrentRelativeTime() or GetTime()
    local windowStart = now - seconds
    return self:MaxWindow(windowStart, now)
end

-- =============================================================================
-- BUFFER MANAGEMENT
-- =============================================================================

-- Clear all data
function RingBufferClass:Clear()
    for i = 1, self.size do
        local slot = self.data[i]
        slot.timestamp = 0
        slot.value = 0
        slot.data = nil
        slot.valid = false
    end
    
    self.writeIndex = 1
    self.count = 0
    self.totalWrites = 0
    self.totalOverwrites = 0
end

-- Get the most recent entry
function RingBufferClass:GetLatest()
    if self.count == 0 then
        return nil
    end
    
    local latestIndex = self.writeIndex - 1
    if latestIndex < 1 then
        latestIndex = self.size
    end
    
    local slot = self.data[latestIndex]
    if slot.valid then
        return {
            timestamp = slot.timestamp,
            value = slot.value,
            data = slot.data
        }
    end
    
    return nil
end

-- Get the oldest entry
function RingBufferClass:GetOldest()
    if self.count == 0 then
        return nil
    end
    
    -- If buffer is full, oldest is at writeIndex
    -- If buffer is not full, oldest is at index 1
    local oldestIndex = self.count < self.size and 1 or self.writeIndex
    
    local slot = self.data[oldestIndex]
    if slot.valid then
        return {
            timestamp = slot.timestamp,
            value = slot.value,
            data = slot.data
        }
    end
    
    return nil
end

-- Check if buffer contains data in time range
function RingBufferClass:HasDataInRange(windowStart, windowEnd)
    if self.count == 0 then
        return false
    end
    
    local latest = self:GetLatest()
    local oldest = self:GetOldest()
    
    if not latest or not oldest then
        return false
    end
    
    -- Check if our data range overlaps with the query range
    return not (oldest.timestamp > windowEnd or latest.timestamp < windowStart)
end

-- =============================================================================
-- STATISTICS AND DEBUGGING
-- =============================================================================

-- Get buffer statistics
function RingBufferClass:GetStats()
    local latest = self:GetLatest()
    local oldest = self:GetOldest()
    
    local timeSpan = 0
    if latest and oldest and self.count > 1 then
        timeSpan = latest.timestamp - oldest.timestamp
    end
    
    return {
        name = self.name,
        size = self.size,
        count = self.count,
        utilization = self.count / self.size,
        
        -- Write statistics
        totalWrites = self.totalWrites,
        totalOverwrites = self.totalOverwrites,
        overwriteRatio = self.totalWrites > 0 and (self.totalOverwrites / self.totalWrites) or 0,
        
        -- Query statistics
        queryCount = self.queryCount,
        lastWrite = self.lastWrite,
        lastQuery = self.lastQuery,
        
        -- Data span
        timeSpan = timeSpan,
        oldestTimestamp = oldest and oldest.timestamp or 0,
        latestTimestamp = latest and latest.timestamp or 0,
        
        -- Performance
        writesPerSecond = timeSpan > 0 and (self.totalWrites / timeSpan) or 0
    }
end

-- Debug information
function RingBufferClass:Debug()
    local stats = self:GetStats()
    print(string.format("=== %s Debug ===", stats.name))
    print(string.format("Size: %d, Count: %d (%.1f%% full)", stats.size, stats.count, stats.utilization * 100))
    print(string.format("Writes: %d, Overwrites: %d (%.1f%%)", stats.totalWrites, stats.totalOverwrites, stats.overwriteRatio * 100))
    print(string.format("Queries: %d", stats.queryCount))
    print(string.format("Time Span: %.1fs", stats.timeSpan))
    
    if stats.timeSpan > 0 then
        print(string.format("Write Rate: %.1f/sec", stats.writesPerSecond))
    end
end

-- =============================================================================
-- RING BUFFER FACTORY
-- =============================================================================

-- Pre-created ring buffers for common use cases
local buffers = {}

-- Create or get a named ring buffer
function RingBuffer:GetBuffer(name, size)
    if buffers[name] then
        return buffers[name]
    end
    
    local buffer = self:New(size, name)
    buffers[name] = buffer
    return buffer
end

-- Create damage event ring buffer
function RingBuffer:GetDamageBuffer()
    return self:GetBuffer("damage", 1000)
end

-- Create healing event ring buffer
function RingBuffer:GetHealingBuffer()
    return self:GetBuffer("healing", 500)
end

-- Create general event ring buffer
function RingBuffer:GetEventBuffer()
    return self:GetBuffer("events", 1500)
end

-- Get all created buffers
function RingBuffer:GetAllBuffers()
    local result = {}
    for name, buffer in pairs(buffers) do
        result[name] = buffer
    end
    return result
end

-- Clear all buffers
function RingBuffer:ClearAllBuffers()
    local cleared = 0
    for name, buffer in pairs(buffers) do
        buffer:Clear()
        cleared = cleared + 1
    end
    return cleared
end

-- =============================================================================
-- DEBUGGING AND MONITORING
-- =============================================================================

-- Get statistics for all buffers
function RingBuffer:GetAllStats()
    local stats = {
        bufferCount = 0,
        totalWrites = 0,
        totalQueries = 0,
        totalMemorySlots = 0,
        buffers = {}
    }
    
    for name, buffer in pairs(buffers) do
        local bufferStats = buffer:GetStats()
        stats.buffers[name] = bufferStats
        stats.bufferCount = stats.bufferCount + 1
        stats.totalWrites = stats.totalWrites + bufferStats.totalWrites
        stats.totalQueries = stats.totalQueries + bufferStats.queryCount
        stats.totalMemorySlots = stats.totalMemorySlots + bufferStats.size
    end
    
    return stats
end

-- Debug all buffers
function RingBuffer:DebugAll()
    local stats = self:GetAllStats()
    print("=== RingBuffer System Debug ===")
    print(string.format("Buffers: %d", stats.bufferCount))
    print(string.format("Total Memory Slots: %d", stats.totalMemorySlots))
    print(string.format("Total Writes: %d", stats.totalWrites))
    print(string.format("Total Queries: %d", stats.totalQueries))
    
    print("Individual Buffers:")
    for name, buffer in pairs(buffers) do
        buffer:Debug()
    end
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the ring buffer system
function RingBuffer:Initialize()
    -- Pre-create common buffers
    self:GetDamageBuffer()
    self:GetHealingBuffer()
    self:GetEventBuffer()
    
    -- print("[STORMY] RingBuffer system initialized with 3 buffers")
end

-- Module ready
RingBuffer.isReady = true