-- EventBus.lua
-- Lightweight event system for real-time communication between modules
-- Simplified from EventQueue to remove persistence and focus on speed

local addonName, addon = ...

-- =============================================================================
-- EVENT BUS MODULE
-- =============================================================================

addon.EventBus = {}
local EventBus = addon.EventBus

-- Event types
local EVENT_TYPES = {
    COMBAT_START = "COMBAT_START",
    COMBAT_END = "COMBAT_END",
    DAMAGE_DEALT = "DAMAGE_DEALT",
    HEALING_DONE = "HEALING_DONE",
    PET_DETECTED = "PET_DETECTED",
    SCALE_UPDATE = "SCALE_UPDATE",
    UI_UPDATE = "UI_UPDATE"
}

-- Event bus state
local eventBusState = {
    subscribers = {},           -- [eventType] = { {callback, name}, ... }
    subscriberCount = 0,
    totalEventsDispatched = 0,
    lastEventTime = 0
}

-- =============================================================================
-- CORE EVENT BUS API
-- =============================================================================

-- Subscribe to an event type
function EventBus:Subscribe(eventType, callback, subscriberName)
    if not eventType or not callback then
        error("EventBus:Subscribe requires eventType and callback")
    end
    
    if not eventBusState.subscribers[eventType] then
        eventBusState.subscribers[eventType] = {}
    end
    
    local subscriber = {
        callback = callback,
        name = subscriberName or "Anonymous",
        subscribed = GetTime(),
        eventCount = 0
    }
    
    table.insert(eventBusState.subscribers[eventType], subscriber)
    eventBusState.subscriberCount = eventBusState.subscriberCount + 1
    
    return subscriber -- Return for potential unsubscription
end

-- Unsubscribe from an event type
function EventBus:Unsubscribe(eventType, subscriberToRemove)
    if not eventType or not eventBusState.subscribers[eventType] then
        return false
    end
    
    local subscribers = eventBusState.subscribers[eventType]
    for i = #subscribers, 1, -1 do
        if subscribers[i] == subscriberToRemove then
            table.remove(subscribers, i)
            eventBusState.subscriberCount = eventBusState.subscriberCount - 1
            return true
        end
    end
    
    return false
end

-- Dispatch an event to all subscribers
function EventBus:Dispatch(eventType, eventData)
    if not eventType then
        return
    end
    
    local subscribers = eventBusState.subscribers[eventType]
    if not subscribers or #subscribers == 0 then
        -- If no subscribers and we have a pooled event, release it
        if eventData and addon.EventPool then
            self:ReleasePooledEvent(eventType, eventData)
        end
        return
    end
    
    -- Check if eventData is a pooled event (has all expected fields)
    local isPooledEvent = false
    if eventData and type(eventData) == "table" then
        -- Check for common event fields that indicate a pooled event
        if eventData.sourceGUID and eventData.amount and eventData.timestamp then
            isPooledEvent = true
        end
    end
    
    -- Create event wrapper only if not using pooled event
    local event
    if isPooledEvent then
        -- Use pooled event directly - just add type field temporarily
        event = eventData
        event._eventType = eventType  -- Store type temporarily
    else
        -- Create wrapper for non-pooled events (fallback/compatibility)
        event = {
            type = eventType,
            data = eventData,
            timestamp = GetTime()
        }
    end
    
    -- Dispatch to all subscribers
    for i = 1, #subscribers do
        local subscriber = subscribers[i]
        
        -- For pooled events, create a minimal wrapper for the callback
        local callbackEvent = event
        if isPooledEvent then
            -- Pass pooled event with type info
            callbackEvent = {
                type = eventType,
                data = event,
                timestamp = event.timestamp
            }
        end
        
        -- Protected call to prevent one subscriber from breaking others
        local success, err = pcall(subscriber.callback, callbackEvent)
        if not success then
            -- print(string.format("[STORMY EventBus Error] %s subscriber '%s': %s", 
            --     eventType, subscriber.name, tostring(err)))
        else
            subscriber.eventCount = subscriber.eventCount + 1
        end
    end
    
    -- Clean up temporary type field if we added it
    if isPooledEvent and event._eventType then
        event._eventType = nil
    end
    
    -- Release pooled event after all subscribers have processed it
    if isPooledEvent and addon.EventPool then
        self:ReleasePooledEvent(eventType, eventData)
    end
    
    eventBusState.totalEventsDispatched = eventBusState.totalEventsDispatched + 1
    eventBusState.lastEventTime = GetTime()
end

-- Release a pooled event back to the appropriate pool
function EventBus:ReleasePooledEvent(eventType, event)
    if not addon.EventPool or not event then return end
    
    if eventType == EVENT_TYPES.DAMAGE_DEALT then
        addon.EventPool:ReleaseDamageEvent(event)
    elseif eventType == EVENT_TYPES.HEALING_DONE then
        addon.EventPool:ReleaseHealingEvent(event)
    elseif eventType == EVENT_TYPES.COMBAT_START or eventType == EVENT_TYPES.COMBAT_END then
        addon.EventPool:ReleaseCombatEvent(event)
    end
end

-- =============================================================================
-- CONVENIENCE METHODS FOR COMMON EVENTS
-- =============================================================================

-- Combat state events
function EventBus:DispatchCombatStart(combatData)
    self:Dispatch(EVENT_TYPES.COMBAT_START, combatData)
end

function EventBus:DispatchCombatEnd(combatData)
    self:Dispatch(EVENT_TYPES.COMBAT_END, combatData)
end

-- Damage/healing events
function EventBus:DispatchDamage(damageData)
    self:Dispatch(EVENT_TYPES.DAMAGE_DEALT, damageData)
end

function EventBus:DispatchHealing(healingData)
    self:Dispatch(EVENT_TYPES.HEALING_DONE, healingData)
end

-- Pet detection
function EventBus:DispatchPetDetected(petData)
    self:Dispatch(EVENT_TYPES.PET_DETECTED, petData)
end

-- Scale updates
function EventBus:DispatchScaleUpdate(scaleData)
    self:Dispatch(EVENT_TYPES.SCALE_UPDATE, scaleData)
end

-- UI updates
function EventBus:DispatchUIUpdate(uiData)
    self:Dispatch(EVENT_TYPES.UI_UPDATE, uiData)
end

-- =============================================================================
-- CONVENIENCE SUBSCRIPTION METHODS
-- =============================================================================

-- Subscribe to combat events
function EventBus:SubscribeToCombat(callback, name)
    local startSub = self:Subscribe(EVENT_TYPES.COMBAT_START, callback, name .. "_start")
    local endSub = self:Subscribe(EVENT_TYPES.COMBAT_END, callback, name .. "_end")
    return { startSub, endSub }
end

-- Subscribe to damage events
function EventBus:SubscribeToDamage(callback, name)
    return self:Subscribe(EVENT_TYPES.DAMAGE_DEALT, callback, name)
end

-- Subscribe to healing events
function EventBus:SubscribeToHealing(callback, name)
    return self:Subscribe(EVENT_TYPES.HEALING_DONE, callback, name)
end

-- Subscribe to scale updates
function EventBus:SubscribeToScaleUpdates(callback, name)
    return self:Subscribe(EVENT_TYPES.SCALE_UPDATE, callback, name)
end

-- Subscribe to UI updates
function EventBus:SubscribeToUIUpdates(callback, name)
    return self:Subscribe(EVENT_TYPES.UI_UPDATE, callback, name)
end

-- =============================================================================
-- DEBUGGING AND MONITORING
-- =============================================================================

-- Get event bus statistics
function EventBus:GetStats()
    local eventTypeStats = {}
    local totalSubscribers = 0
    
    for eventType, subscribers in pairs(eventBusState.subscribers) do
        local subscriberCount = #subscribers
        totalSubscribers = totalSubscribers + subscriberCount
        
        local totalEvents = 0
        for i = 1, subscriberCount do
            totalEvents = totalEvents + subscribers[i].eventCount
        end
        
        eventTypeStats[eventType] = {
            subscriberCount = subscriberCount,
            totalEvents = totalEvents
        }
    end
    
    return {
        totalSubscribers = totalSubscribers,
        totalEventsDispatched = eventBusState.totalEventsDispatched,
        lastEventTime = eventBusState.lastEventTime,
        eventTypes = eventTypeStats,
        uptime = GetTime() - (addon.startTime or GetTime())
    }
end

-- Get all subscribers for debugging
function EventBus:GetSubscribers()
    local allSubscribers = {}
    
    for eventType, subscribers in pairs(eventBusState.subscribers) do
        for i = 1, #subscribers do
            local sub = subscribers[i]
            table.insert(allSubscribers, {
                eventType = eventType,
                name = sub.name,
                subscribed = sub.subscribed,
                eventCount = sub.eventCount,
                uptime = GetTime() - sub.subscribed
            })
        end
    end
    
    return allSubscribers
end

-- Debug dump
function EventBus:Debug()
    local stats = self:GetStats()
    print("=== STORMY EventBus Debug ===")
    print(string.format("Total Subscribers: %d", stats.totalSubscribers))
    print(string.format("Events Dispatched: %d", stats.totalEventsDispatched))
    print(string.format("Uptime: %.1fs", stats.uptime))
    
    print("Event Types:")
    for eventType, typeStats in pairs(stats.eventTypes) do
        print(string.format("  %s: %d subscribers, %d events", 
            eventType, typeStats.subscriberCount, typeStats.totalEvents))
    end
end

-- Clear all subscriptions (emergency use)
function EventBus:Clear()
    eventBusState.subscribers = {}
    eventBusState.subscriberCount = 0
    eventBusState.totalEventsDispatched = 0
    eventBusState.lastEventTime = 0
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the event bus
function EventBus:Initialize()
    -- Clear any existing state
    self:Clear()
    
    -- Set up initial state
    eventBusState.lastEventTime = GetTime()
end

-- Export event types for external use
EventBus.EVENT_TYPES = EVENT_TYPES

-- Module ready
EventBus.isReady = true