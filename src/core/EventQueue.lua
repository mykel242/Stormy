-- EventQueue.lua
-- Improved message queue system with state monitoring and transparent data flow
-- Provides specialized queues for different event types (Combat, Log, etc.)

local addonName, addon = ...

-- =============================================================================
-- BASE EVENT QUEUE CLASS
-- =============================================================================

local EventQueue = {}
EventQueue.__index = EventQueue

-- State change event types that queues can emit
local STATE_EVENTS = {
    SUBSCRIBER_ADDED = "SUBSCRIBER_ADDED",
    SUBSCRIBER_REMOVED = "SUBSCRIBER_REMOVED", 
    QUEUE_SIZE_CHANGED = "QUEUE_SIZE_CHANGED",
    MESSAGES_DROPPED = "MESSAGES_DROPPED",
    QUEUE_CLEARED = "QUEUE_CLEARED",
    QUEUE_STATS_CHANGED = "QUEUE_STATS_CHANGED"
}

-- Create a new event queue instance
function EventQueue:New(queueType, config)
    local instance = setmetatable({}, self)
    
    -- Queue identification
    instance.queueType = queueType or "GENERIC"
    instance.name = queueType .. "EventQueue"
    
    -- Configuration with defaults
    config = config or {}
    instance.maxSize = config.maxSize or 1000
    instance.ttl = config.ttl or 300  -- Time to live in seconds
    
    -- Core queue storage (ring buffer)
    instance.messages = {}
    instance.writeIndex = 1
    instance.size = 0
    instance.totalPushed = 0
    instance.totalDropped = 0
    
    -- Subscription system with enhanced tracking
    instance.subscribers = {}
    instance.subscriberCount = 0
    instance.nextSubscriberId = 1
    
    -- State monitoring
    instance.stateSubscribers = {}  -- Subscribers to queue state changes
    instance.lastSizeThreshold = 0  -- For size change events
    instance.sizeChangeThreshold = 100  -- Emit event every N messages
    
    -- Statistics tracking
    instance.stats = {
        totalMessages = 0,
        droppedMessages = 0,
        activeSubscribers = 0,
        messageTypes = {},  -- Count by message type
        lastActivity = GetTime(),
        created = GetTime()
    }
    
    -- Debug removed to prevent circular dependency during queue creation
    -- addon:Debug("%s created with maxSize=%d, ttl=%d", instance.name, instance.maxSize, instance.ttl)
    
    return instance
end

-- =============================================================================
-- CORE QUEUE OPERATIONS
-- =============================================================================

-- Push a message to the queue
function EventQueue:Push(messageType, data)
    local message = {
        type = messageType,
        data = data,
        timestamp = GetTime(),
        sequenceId = self.totalPushed + 1,
        queueSource = self.queueType
    }
    
    -- Handle queue overflow
    local wasDropped = false
    if self.size >= self.maxSize then
        self.totalDropped = self.totalDropped + 1
        wasDropped = true
        -- Overwrite oldest message
        self.messages[self.writeIndex] = message
        self:EmitStateEvent(STATE_EVENTS.MESSAGES_DROPPED, {
            droppedSequenceId = self.messages[self.writeIndex].sequenceId,
            newMessage = message
        })
    else
        -- Add new message
        self.messages[self.writeIndex] = message
        self.size = self.size + 1
    end
    
    -- Advance write index
    self.writeIndex = (self.writeIndex % self.maxSize) + 1
    self.totalPushed = self.totalPushed + 1
    
    -- Update statistics
    self.stats.totalMessages = self.totalPushed
    self.stats.droppedMessages = self.totalDropped
    self.stats.lastActivity = GetTime()
    self.stats.messageTypes[messageType] = (self.stats.messageTypes[messageType] or 0) + 1
    
    -- Check for size change events
    if self.totalPushed - self.lastSizeThreshold >= self.sizeChangeThreshold then
        self:EmitStateEvent(STATE_EVENTS.QUEUE_SIZE_CHANGED, {
            currentSize = self.size,
            totalPushed = self.totalPushed,
            wasDropped = wasDropped
        })
        self.lastSizeThreshold = self.totalPushed
    end
    
    -- Notify subscribers immediately for real-time processing
    self:NotifySubscribers(message)
    
    return message.sequenceId
end

-- =============================================================================
-- SUBSCRIPTION SYSTEM WITH STATE MONITORING
-- =============================================================================

-- Subscribe to queue messages with unique subscriber ID
function EventQueue:Subscribe(messageType, callback, subscriberName, filter)
    -- Generate unique subscriber ID
    local subscriberId = self.nextSubscriberId
    self.nextSubscriberId = self.nextSubscriberId + 1
    
    -- Create subscriber record
    local subscriber = {
        id = subscriberId,
        name = subscriberName or ("Subscriber" .. subscriberId),
        messageType = messageType,
        callback = callback,
        filter = filter,
        active = true,
        subscribed = GetTime(),
        messageCount = 0
    }
    
    -- Store subscriber (using ID as key for uniqueness)
    self.subscribers[subscriberId] = subscriber
    self.subscriberCount = self.subscriberCount + 1
    self.stats.activeSubscribers = self.subscriberCount
    
    -- Emit state change event
    self:EmitStateEvent(STATE_EVENTS.SUBSCRIBER_ADDED, {
        subscriberId = subscriberId,
        subscriberName = subscriber.name,
        messageType = messageType,
        totalSubscribers = self.subscriberCount
    })
    
    -- addon:Debug("%s: New subscriber '%s' (ID: %d) for %s. Total: %d", 
    --     self.name, subscriber.name, subscriberId, messageType, self.subscriberCount)
    
    return subscriberId  -- Return ID for unsubscribing
end

-- Unsubscribe using subscriber ID
function EventQueue:Unsubscribe(subscriberId)
    local subscriber = self.subscribers[subscriberId]
    if subscriber then
        -- Emit state change event before removal
        self:EmitStateEvent(STATE_EVENTS.SUBSCRIBER_REMOVED, {
            subscriberId = subscriberId,
            subscriberName = subscriber.name,
            messageType = subscriber.messageType,
            messageCount = subscriber.messageCount,
            duration = GetTime() - subscriber.subscribed
        })
        
        self.subscribers[subscriberId] = nil
        self.subscriberCount = self.subscriberCount - 1
        self.stats.activeSubscribers = self.subscriberCount
        
        -- addon:Debug("%s: Removed subscriber '%s' (ID: %d). Total: %d", 
        --     self.name, subscriber.name, subscriberId, self.subscriberCount)
        return true
    end
    return false
end

-- Notify subscribers with enhanced tracking
function EventQueue:NotifySubscribers(message)
    for subscriberId, subscriber in pairs(self.subscribers) do
        if subscriber.active and subscriber.messageType == message.type then
            -- Apply additional filter if present
            if not subscriber.filter or subscriber.filter(message) then
                -- Track subscriber activity
                subscriber.messageCount = subscriber.messageCount + 1
                
                -- Protected call to prevent one subscriber from breaking others
                local success, err = pcall(subscriber.callback, message)
                if not success then
                    -- Use print instead of addon:Debug to avoid circular dependency
                    print("[EventQueue Error]", self.name, "subscriber error in", subscriber.name, ":", err)
                end
            end
        end
    end
end

-- Subscribe to queue state changes
function EventQueue:SubscribeToStateChanges(callback, subscriberName)
    local subscriberId = "state_" .. (subscriberName or tostring(GetTime()))
    self.stateSubscribers[subscriberId] = {
        callback = callback,
        name = subscriberName or subscriberId,
        subscribed = GetTime()
    }
    
    -- addon:Debug("%s: State subscriber added: %s", self.name, subscriberName or subscriberId)
    return subscriberId
end

-- Emit state change events
function EventQueue:EmitStateEvent(eventType, data)
    local stateMessage = {
        eventType = eventType,
        queueName = self.name,
        queueType = self.queueType,
        timestamp = GetTime(),
        data = data
    }
    
    for subscriberId, subscriber in pairs(self.stateSubscribers) do
        local success, err = pcall(subscriber.callback, stateMessage)
        if not success then
            print("[EventQueue State Error]", self.name, "state subscriber error in", subscriber.name, ":", err)
        end
    end
end

-- =============================================================================
-- INTROSPECTION AND DEBUGGING
-- =============================================================================

-- Get all current subscribers with detailed information
function EventQueue:GetSubscribers()
    local subscriberList = {}
    for subscriberId, subscriber in pairs(self.subscribers) do
        table.insert(subscriberList, {
            id = subscriberId,
            name = subscriber.name,
            messageType = subscriber.messageType,
            active = subscriber.active,
            messageCount = subscriber.messageCount,
            subscribed = subscriber.subscribed,
            duration = GetTime() - subscriber.subscribed
        })
    end
    return subscriberList
end

-- Get comprehensive queue statistics
function EventQueue:GetStats()
    return {
        -- Basic info
        queueType = self.queueType,
        name = self.name,
        maxSize = self.maxSize,
        currentSize = self.size,
        
        -- Activity stats
        totalPushed = self.totalPushed,
        totalDropped = self.totalDropped,
        subscriberCount = self.subscriberCount,
        
        -- Timing
        created = self.stats.created,
        lastActivity = self.stats.lastActivity,
        uptime = GetTime() - self.stats.created,
        
        -- Message type breakdown
        messageTypes = self.stats.messageTypes,
        
        -- Performance
        dropRate = self.totalPushed > 0 and (self.totalDropped / self.totalPushed) or 0,
        messagesPerSecond = (GetTime() - self.stats.created) > 0 and 
                          (self.totalPushed / (GetTime() - self.stats.created)) or 0
    }
end

-- Debug current state (comprehensive) - uses print to avoid circular dependency
function EventQueue:DebugState()
    local stats = self:GetStats()
    print("=== " .. self.name .. " Debug State ===")
    print("Queue: " .. stats.name .. " (Type: " .. stats.queueType .. ")")
    print(string.format("Size: %d/%d (%.1f%% full)", stats.currentSize, stats.maxSize, 
        (stats.currentSize / stats.maxSize) * 100))
    print(string.format("Activity: %d pushed, %d dropped (%.2f%% drop rate)", 
        stats.totalPushed, stats.totalDropped, stats.dropRate * 100))
    print("Subscribers: " .. stats.subscriberCount .. " active")
    print(string.format("Performance: %.2f msg/sec over %.1f seconds", 
        stats.messagesPerSecond, stats.uptime))
    
    -- Message type breakdown
    if next(stats.messageTypes) then
        print("Message Types:")
        for msgType, count in pairs(stats.messageTypes) do
            print("  " .. msgType .. ": " .. count .. " messages")
        end
    end
    
    -- Subscriber details
    local subscribers = self:GetSubscribers()
    if #subscribers > 0 then
        print("Active Subscribers:")
        for _, sub in ipairs(subscribers) do
            print(string.format("  [%d] %s -> %s (%d msgs, %.1fs)", 
                sub.id, sub.name, sub.messageType, sub.messageCount, sub.duration))
        end
    end
    print("=== End Debug State ===")
end

-- Clear queue and reset statistics
function EventQueue:Clear()
    local oldSize = self.size
    local oldTotal = self.totalPushed
    
    self.messages = {}
    self.writeIndex = 1
    self.size = 0
    self.stats.messageTypes = {}
    
    self:EmitStateEvent(STATE_EVENTS.QUEUE_CLEARED, {
        clearedSize = oldSize,
        clearedTotal = oldTotal
    })
    
    print("[EventQueue]", self.name, "Queue cleared (", oldSize, "messages removed)")
end

-- =============================================================================
-- FACTORY FUNCTIONS FOR SPECIALIZED QUEUES
-- =============================================================================

-- Create specialized queue instances
function addon:CreateCombatEventQueue(config)
    return EventQueue:New("COMBAT", config)
end

function addon:CreateLogEventQueue(config)
    return EventQueue:New("LOG", config)
end

function addon:CreateUIEventQueue(config)
    return EventQueue:New("UI", config)
end

-- Expose the base class for custom queue types
addon.EventQueue = EventQueue
addon.STATE_EVENTS = STATE_EVENTS