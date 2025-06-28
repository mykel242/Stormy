-- MyMessageQueue.lua
-- Generic message queue implementation for decoupled communication
-- Used by both logging and combat data systems

local addonName, addon = ...

-- =============================================================================
-- BASE MESSAGE QUEUE CLASS
-- =============================================================================

local MyMessageQueue = {}
MyMessageQueue.__index = MyMessageQueue

-- Create a new message queue instance
function MyMessageQueue:New(config)
    local instance = setmetatable({}, self)
    
    -- Configuration with defaults
    instance.maxSize = config.maxSize or 1000
    instance.ttl = config.ttl or 300  -- Time to live in seconds (5 min default)
    instance.name = config.name or "UnnamedQueue"
    
    -- Internal state
    instance.messages = {}
    instance.writeIndex = 1
    instance.size = 0
    instance.totalPushed = 0
    instance.totalDropped = 0
    
    -- Subscribers
    instance.subscribers = {}
    
    return instance
end

-- =============================================================================
-- CORE QUEUE OPERATIONS
-- =============================================================================

-- Push a message to the queue
function MyMessageQueue:Push(messageType, data)
    -- Debug logging removed - system is working
    
    local message = {
        type = messageType,
        data = data,
        timestamp = GetTime(),
        sequenceId = self.totalPushed + 1
    }
    
    -- Handle queue overflow
    if self.size >= self.maxSize then
        self.totalDropped = self.totalDropped + 1
        -- Overwrite oldest message
        self.messages[self.writeIndex] = message
    else
        -- Add new message
        self.messages[self.writeIndex] = message
        self.size = self.size + 1
    end
    
    -- Advance write index
    self.writeIndex = (self.writeIndex % self.maxSize) + 1
    self.totalPushed = self.totalPushed + 1
    
    -- Notify subscribers immediately for real-time processing
    self:NotifySubscribers(message)
    
    return message.sequenceId
end

-- Pull messages from the queue (non-destructive)
function MyMessageQueue:Pull(config)
    config = config or {}
    local results = {}
    
    local count = config.count or self.size
    local since = config.since or 0
    local messageType = config.type
    local includeExpired = config.includeExpired or false
    
    local now = GetTime()
    local cutoffTime = now - self.ttl
    
    -- Calculate start position
    local startPos = self.writeIndex - self.size
    if startPos <= 0 then startPos = startPos + self.maxSize end
    
    -- Collect messages
    local collected = 0
    for i = 0, self.size - 1 do
        if collected >= count then break end
        
        local index = ((startPos + i - 1) % self.maxSize) + 1
        local message = self.messages[index]
        
        if message then
            -- Apply filters
            local include = true
            
            -- Time filters
            if message.timestamp < since then include = false end
            if not includeExpired and message.timestamp < cutoffTime then include = false end
            
            -- Type filter
            if messageType and message.type ~= messageType then include = false end
            
            if include then
                table.insert(results, message)
                collected = collected + 1
            end
        end
    end
    
    return results
end

-- =============================================================================
-- SUBSCRIPTION SYSTEM
-- =============================================================================

-- Subscribe to queue messages by message type
function MyMessageQueue:Subscribe(messageType, callback, filter)
    -- Use messageType as subscriber key for automatic filtering
    self.subscribers[messageType] = {
        callback = callback,
        messageType = messageType,  -- Store the message type for filtering
        filter = filter,  -- Optional additional filter function
        active = true
    }
end

-- Unsubscribe from queue
function MyMessageQueue:Unsubscribe(name)
    self.subscribers[name] = nil
end

-- Notify subscribers that match the message type
function MyMessageQueue:NotifySubscribers(message)
    -- Debug logging removed - system is working
    
    for subscriberKey, subscriber in pairs(self.subscribers) do
        if subscriber.active then
            -- Check if this subscriber wants this message type
            if subscriber.messageType == message.type then
                
                -- Apply additional filter if present
                if not subscriber.filter or subscriber.filter(message) then
                    -- Protected call to prevent one subscriber from breaking others
                    local success, err = pcall(subscriber.callback, message)
                    if not success then
                        addon:Debug("MyMessageQueue subscriber error in %s: %s", subscriberKey, err)
                    end
                end
            end
        end
    end
end

-- =============================================================================
-- QUEUE MANAGEMENT
-- =============================================================================

-- Clean up expired messages
function MyMessageQueue:Cleanup()
    local now = GetTime()
    local cutoffTime = now - self.ttl
    local cleaned = 0
    
    -- Since we use a circular buffer, we need to compact the array
    local validMessages = {}
    
    for i = 1, self.size do
        local index = ((self.writeIndex - self.size + i - 1) % self.maxSize) + 1
        local message = self.messages[index]
        
        if message and message.timestamp >= cutoffTime then
            table.insert(validMessages, message)
        else
            cleaned = cleaned + 1
        end
    end
    
    -- Rebuild the queue with valid messages
    self.messages = {}
    self.size = #validMessages
    self.writeIndex = 1
    
    for i, message in ipairs(validMessages) do
        self.messages[i] = message
        self.writeIndex = i + 1
    end
    
    if self.writeIndex > self.maxSize then
        self.writeIndex = 1
    end
    
    return cleaned
end

-- Get queue statistics
function MyMessageQueue:GetStats()
    return {
        name = self.name,
        size = self.size,
        maxSize = self.maxSize,
        totalPushed = self.totalPushed,
        totalDropped = self.totalDropped,
        oldestTimestamp = self.size > 0 and self.messages[((self.writeIndex - self.size) % self.maxSize) + 1].timestamp or nil,
        newestTimestamp = self.size > 0 and self.messages[((self.writeIndex - 2) % self.maxSize) + 1].timestamp or nil,
        utilization = (self.size / self.maxSize) * 100
    }
end

-- Clear all messages
function MyMessageQueue:Clear()
    self.messages = {}
    self.writeIndex = 1
    self.size = 0
    -- Don't reset totalPushed/totalDropped for historical tracking
end

-- =============================================================================
-- SPECIALIZED QUEUE TYPES
-- =============================================================================

-- Factory for creating specialized queues
local MyQueueFactory = {}

-- Create a log message queue
function MyQueueFactory:CreateLogQueue()
    return MyMessageQueue:New({
        name = "LogMessages",
        maxSize = 200,      -- Last 200 log messages
        ttl = 300           -- 5 minute retention
    })
end

-- Create a combat event queue
function MyQueueFactory:CreateCombatEventQueue()
    return MyMessageQueue:New({
        name = "CombatEvents", 
        maxSize = 10000,    -- Large buffer for combat analysis
        ttl = 600           -- 10 minute retention
    })
end

-- Create a metrics queue for DPS/HPS calculations
function MyQueueFactory:CreateMetricsQueue()
    return MyMessageQueue:New({
        name = "CombatMetrics",
        maxSize = 300,      -- 5 minutes of per-second metrics
        ttl = 300           -- 5 minute retention
    })
end

-- =============================================================================
-- EXPORT
-- =============================================================================

addon.MyMessageQueue = MyMessageQueue
addon.MyQueueFactory = MyQueueFactory