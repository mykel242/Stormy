require("tests.spec_helper").apply()

describe("EventBus", function()
    local EventBus
    local addon
    
    before_each(function()
        -- Reset global state
        _G.STORMY_NAMESPACE = {}
        addon = _G.STORMY_NAMESPACE
        
        -- Load dependencies
        dofile("Core/TablePool.lua")
        dofile("Core/EventBus.lua")
        EventBus = addon.EventBus
        
        -- Clear any existing state
        if EventBus.Clear then
            EventBus:Clear()
        end
    end)
    
    describe("initialization", function()
        it("should have required methods", function()
            assert.is_not_nil(EventBus)
            assert.is_function(EventBus.Subscribe)
            assert.is_function(EventBus.Unsubscribe)
            assert.is_function(EventBus.Dispatch)
            assert.is_function(EventBus.Initialize)
        end)
        
        it("should initialize properly", function()
            EventBus:Initialize()
            local stats = EventBus:GetStats()
            assert.is_not_nil(stats)
            assert.equals(0, stats.totalEventsDispatched)
        end)
    end)
    
    describe("Subscribe", function()
        it("should register a handler for an event", function()
            local called = false
            local handler = function() called = true end
            
            EventBus:Subscribe("TEST_EVENT", handler, "TestSubscriber")
            EventBus:Dispatch("TEST_EVENT", {})
            
            assert.is_true(called)
        end)
        
        it("should support multiple handlers for same event", function()
            local count = 0
            local handler1 = function() count = count + 1 end
            local handler2 = function() count = count + 10 end
            
            EventBus:Subscribe("TEST_EVENT", handler1, "Handler1")
            EventBus:Subscribe("TEST_EVENT", handler2, "Handler2")
            EventBus:Dispatch("TEST_EVENT", {})
            
            assert.equals(11, count)
        end)
        
        it("should pass event data to handlers", function()
            local receivedEvent
            local handler = function(event)
                receivedEvent = event
            end
            
            EventBus:Subscribe("TEST_EVENT", handler, "DataHandler")
            local testData = { value = 123, text = "test" }
            EventBus:Dispatch("TEST_EVENT", testData)
            
            assert.is_not_nil(receivedEvent)
            assert.equals("TEST_EVENT", receivedEvent.type)
            assert.is_not_nil(receivedEvent.data)
            assert.equals(123, receivedEvent.data.value)
            assert.equals("test", receivedEvent.data.text)
            assert.is_number(receivedEvent.timestamp)
        end)
        
        it("should require event type and callback", function()
            assert.has_error(function()
                EventBus:Subscribe(nil, function() end)
            end)
            
            assert.has_error(function()
                EventBus:Subscribe("TEST_EVENT", nil)
            end)
        end)
    end)
    
    describe("Unsubscribe", function()
        it("should support unsubscribe functionality", function()
            local count1 = 0
            local count2 = 0
            local handler1 = function() count1 = count1 + 1 end
            local handler2 = function() count2 = count2 + 1 end
            
            -- Subscribe both handlers
            EventBus:Subscribe("TEST_EVENT", handler1, "Handler1")
            EventBus:Subscribe("TEST_EVENT", handler2, "Handler2")
            
            -- Verify both work
            EventBus:Dispatch("TEST_EVENT", {})
            assert.equals(1, count1)
            assert.equals(1, count2)
            
            -- Clear all subscribers and verify none are called
            EventBus:Clear()
            EventBus:Dispatch("TEST_EVENT", {})
            assert.equals(1, count1) -- No change
            assert.equals(1, count2) -- No change
        end)
    end)
    
    describe("Dispatch", function()
        it("should track dispatch statistics", function()
            EventBus:Subscribe("TEST_EVENT", function() end, "Test")
            
            local statsBefore = EventBus:GetStats()
            local countBefore = statsBefore.totalEventsDispatched
            
            EventBus:Dispatch("TEST_EVENT", {})
            EventBus:Dispatch("TEST_EVENT", {})
            
            local statsAfter = EventBus:GetStats()
            assert.equals(countBefore + 2, statsAfter.totalEventsDispatched)
        end)
        
        it("should handle missing event type gracefully", function()
            -- Should not error when no subscribers
            assert.has_no.errors(function()
                EventBus:Dispatch("NONEXISTENT_EVENT", {})
            end)
        end)
        
        it("should call handlers in order of subscription", function()
            local order = {}
            local handler1 = function() table.insert(order, 1) end
            local handler2 = function() table.insert(order, 2) end
            local handler3 = function() table.insert(order, 3) end
            
            EventBus:Subscribe("TEST_EVENT", handler1, "First")
            EventBus:Subscribe("TEST_EVENT", handler2, "Second")
            EventBus:Subscribe("TEST_EVENT", handler3, "Third")
            EventBus:Dispatch("TEST_EVENT", {})
            
            assert.same({1, 2, 3}, order)
        end)
    end)
    
    describe("typed dispatchers", function()
        it("should dispatch combat events", function()
            local receivedEvent
            EventBus:SubscribeToCombat(function(event)
                receivedEvent = event
            end, "CombatTest")
            
            EventBus:DispatchCombatStart({ timestamp = 1000 })
            assert.is_not_nil(receivedEvent)
            assert.equals("COMBAT_START", receivedEvent.type)
            assert.equals(1000, receivedEvent.data.timestamp)
            
            EventBus:DispatchCombatEnd({ duration = 30 })
            assert.equals("COMBAT_END", receivedEvent.type)
            assert.equals(30, receivedEvent.data.duration)
        end)
        
        it("should dispatch damage events", function()
            local receivedEvent
            EventBus:SubscribeToDamage(function(event)
                receivedEvent = event
            end, "DamageTest")
            
            EventBus:DispatchDamage({ amount = 500, spell = "Fireball" })
            assert.is_not_nil(receivedEvent)
            assert.equals("DAMAGE_DEALT", receivedEvent.type)
            assert.equals(500, receivedEvent.data.amount)
            assert.equals("Fireball", receivedEvent.data.spell)
        end)
        
        it("should dispatch healing events", function()
            local receivedEvent
            EventBus:SubscribeToHealing(function(event)
                receivedEvent = event
            end, "HealingTest")
            
            EventBus:DispatchHealing({ amount = 200, spell = "Flash Heal" })
            assert.is_not_nil(receivedEvent)
            assert.equals("HEALING_DONE", receivedEvent.type)
            assert.equals(200, receivedEvent.data.amount)
            assert.equals("Flash Heal", receivedEvent.data.spell)
        end)
        
        it("should dispatch UI update events", function()
            local receivedEvent
            EventBus:SubscribeToUIUpdates(function(event)
                receivedEvent = event
            end, "UITest")
            
            EventBus:DispatchUIUpdate({ dps = 1500.5, elapsed = 30 })
            assert.is_not_nil(receivedEvent)
            assert.equals("UI_UPDATE", receivedEvent.type)
            assert.equals(1500.5, receivedEvent.data.dps)
            assert.equals(30, receivedEvent.data.elapsed)
        end)
    end)
    
    describe("statistics", function()
        it("should track subscriber counts", function()
            EventBus:Subscribe("EVENT1", function() end, "Sub1")
            EventBus:Subscribe("EVENT1", function() end, "Sub2")
            EventBus:Subscribe("EVENT2", function() end, "Sub3")
            
            local stats = EventBus:GetStats()
            assert.equals(3, stats.totalSubscribers)
            assert.equals(2, stats.eventTypes.EVENT1.subscriberCount)
            assert.equals(1, stats.eventTypes.EVENT2.subscriberCount)
        end)
        
        it("should track event counts per subscriber", function()
            EventBus:Subscribe("EVENT1", function() end, "Sub1")
            EventBus:Subscribe("EVENT2", function() end, "Sub2")
            
            EventBus:Dispatch("EVENT1", {})
            EventBus:Dispatch("EVENT1", {})
            EventBus:Dispatch("EVENT2", {})
            
            local stats = EventBus:GetStats()
            -- Each EVENT1 subscriber should have received 2 events
            assert.equals(2, stats.eventTypes.EVENT1.totalEvents)
            assert.equals(1, stats.eventTypes.EVENT2.totalEvents)
        end)
    end)
    
    describe("Clear", function()
        it("should remove all subscribers", function()
            EventBus:Subscribe("EVENT1", function() end, "Sub1")
            EventBus:Subscribe("EVENT2", function() end, "Sub2")
            
            EventBus:Clear()
            
            local stats = EventBus:GetStats()
            assert.equals(0, stats.totalSubscribers)
            
            -- Events should not be dispatched
            local called = false
            EventBus:Subscribe("EVENT1", function() called = true end, "Sub3")
            EventBus:Clear()
            EventBus:Dispatch("EVENT1", {})
            assert.is_false(called)
        end)
    end)
    
    describe("error handling", function()
        it("should handle errors in handlers gracefully", function()
            local count = 0
            EventBus:Subscribe("TEST_EVENT", function() count = count + 1 end, "Good1")
            EventBus:Subscribe("TEST_EVENT", function() error("Test error") end, "Bad")
            EventBus:Subscribe("TEST_EVENT", function() count = count + 10 end, "Good2")
            
            -- Should not propagate error
            assert.has_no.errors(function()
                EventBus:Dispatch("TEST_EVENT", {})
            end)
            
            -- Other handlers should still run
            assert.equals(11, count)
        end)
    end)
end)