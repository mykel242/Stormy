-- MeterAccumulator_spec.lua
-- Unit tests for the base MeterAccumulator class

local helpers = require("tests.spec_helper")

describe("MeterAccumulator", function()
    local MeterAccumulator
    local addon
    
    before_each(function()
        addon = helpers.create_mock_addon()
        
        -- Mock TimingManager with consistent base time for tests
        local baseTime = 100  -- Use a fixed base time for all tests
        addon.TimingManager = {
            GetCurrentRelativeTime = function() return baseTime end,
            GetRelativeTime = function(timestamp) 
                -- Ensure we always return a number
                if type(timestamp) == "number" then
                    return timestamp
                else
                    return baseTime
                end
            end
        }
        
        -- Load module
        helpers.load_module_at_path("Combat/MeterAccumulator.lua", addon)
        MeterAccumulator = addon.MeterAccumulator
    end)
    
    describe("New", function()
        it("should create new instance with correct meter type", function()
            local accumulator = MeterAccumulator:New("TestMeter")
            assert.equals("TestMeter", accumulator.meterType)
            assert.is_table(accumulator.state)
            assert.is_table(accumulator.rollingData)
        end)
        
        it("should copy methods to instance", function()
            local accumulator = MeterAccumulator:New("TestMeter")
            assert.is_function(accumulator.AddEvent)
            assert.is_function(accumulator.GetStats)
            assert.is_function(accumulator.GetWindowTotals)
        end)
    end)
    
    describe("AddEvent", function()
        local accumulator
        
        before_each(function()
            accumulator = MeterAccumulator:New("TestMeter")
            accumulator:Initialize()
        end)
        
        it("should accumulate damage events", function()
            local timestamp = GetTime()
            accumulator:AddEvent(timestamp, "player-guid", 1000, true, false, false)
            
            local stats = accumulator:GetStats()
            assert.equals(1000, stats.totalValue)
            assert.equals(1000, stats.playerValue)
            assert.equals(0, stats.petValue)
            assert.equals(1, stats.totalEvents)
        end)
        
        it("should track pet damage separately", function()
            local timestamp = GetTime()
            accumulator:AddEvent(timestamp, "player-guid", 1000, true, false, false)
            accumulator:AddEvent(timestamp, "pet-guid", 500, false, true, false)
            
            local stats = accumulator:GetStats()
            assert.equals(1500, stats.totalValue)
            assert.equals(1000, stats.playerValue)
            assert.equals(500, stats.petValue)
        end)
        
        it("should track critical hits", function()
            local timestamp = GetTime()
            accumulator:AddEvent(timestamp, "player-guid", 1000, true, false, true)
            accumulator:AddEvent(timestamp, "player-guid", 500, true, false, false)
            
            local stats = accumulator:GetStats()
            assert.equals(2, stats.totalHits)
            assert.equals(1, stats.criticalHits)
            assert.is_near(50, stats.criticalPercent, 0.1)
        end)
        
        it("should pass extra data to subclass", function()
            local onEventCalled = false
            local extraDataReceived = nil
            
            accumulator.OnEvent = function(self, ts, guid, amt, isPlayer, isPet, isCrit, extra)
                onEventCalled = true
                extraDataReceived = extra
            end
            
            local extraData = { absorbAmount = 250 }
            accumulator:AddEvent(GetTime(), "player-guid", 1000, true, false, false, extraData)
            
            assert.is_true(onEventCalled)
            assert.equals(250, extraDataReceived.absorbAmount)
        end)
    end)
    
    describe("GetWindowTotals", function()
        local accumulator
        
        before_each(function()
            accumulator = MeterAccumulator:New("TestMeter")
            accumulator:Initialize()
        end)
        
        it("should calculate window totals correctly", function()
            local now = addon.TimingManager:GetCurrentRelativeTime()
            -- Add events at specific times relative to current time
            accumulator:AddEvent(now - 10, "player-guid", 1000, true, false, false)
            accumulator:AddEvent(now - 2, "player-guid", 2000, true, false, false)
            accumulator:AddEvent(now - 1, "player-guid", 3000, true, false, false)
            
            -- Check 5 second window calculation
            local window5 = accumulator:GetWindowTotals(5)
            assert.is_true(window5.value > 0) -- Should have some events
            assert.is_true(window5.events > 0) -- Should count events
            assert.equals(window5.duration, 5) -- Duration should be correct
            
            -- Check larger window includes more
            local window15 = accumulator:GetWindowTotals(15)
            assert.is_true(window15.value >= window5.value) -- Larger window >= smaller window
            assert.is_true(window15.events >= window5.events) -- More events in larger window
        end)
        
        it("should handle empty windows", function()
            local window = accumulator:GetWindowTotals(5)
            assert.equals(0, window.value)
            assert.equals(0, window.events)
            assert.equals(0, window.metricPS)
        end)
    end)
    
    describe("GetCurrentMetric", function()
        local accumulator
        
        before_each(function()
            accumulator = MeterAccumulator:New("TestMeter")
            accumulator:Initialize()
        end)
        
        it("should return current metric per second", function()
            local now = addon.TimingManager:GetCurrentRelativeTime()
            accumulator:AddEvent(now - 2, "player-guid", 5000, true, false, false)
            accumulator:AddEvent(now - 1, "player-guid", 5000, true, false, false)
            
            -- Force update of current values
            accumulator:UpdateCurrentValues()
            
            local currentMetric = accumulator:GetCurrentMetric()
            assert.is_near(2000, currentMetric, 50) -- ~10000/5 seconds
        end)
    end)
    
    describe("GetActivityLevel", function()
        local accumulator
        
        before_each(function()
            accumulator = MeterAccumulator:New("TestMeter")
            accumulator:Initialize()
        end)
        
        it("should return 0 for no activity", function()
            assert.equals(0, accumulator:GetActivityLevel())
        end)
        
        it("should return 1.0 for recent activity", function()
            accumulator:AddEvent(GetTime(), "player-guid", 1000, true, false, false)
            assert.is_near(1.0, accumulator:GetActivityLevel(), 0.1)
        end)
        
        it("should decay over time", function()
            local now = GetTime()
            accumulator:AddEvent(now - 3, "player-guid", 1000, true, false, false)
            accumulator.state.lastEventTime = now - 3  -- 3 seconds ago
            
            local activity = accumulator:GetActivityLevel()
            assert.is_true(activity < 1.0)
            assert.is_true(activity > 0.0)
            -- Should be 0.5 for 3 seconds: 1.0 - ((3-1)/4) = 0.5
            assert.is_near(0.5, activity, 0.01)
        end)
    end)
    
    describe("UpdatePeaks", function()
        local accumulator
        
        before_each(function()
            accumulator = MeterAccumulator:New("TestMeter")
            accumulator:Initialize()
        end)
        
        it("should track peak metric", function()
            local now = GetTime()
            accumulator.state.currentMetric = 5000
            accumulator.state.lastPeakUpdate = now  -- Set to current time to avoid decay
            accumulator:UpdatePeaks(now)
            
            assert.equals(5000, accumulator.state.peakMetric)
        end)
        
        it("should decay peaks over time", function()
            local now = GetTime()
            accumulator.state.peakMetric = 1000
            accumulator.state.lastPeakUpdate = now - 2
            accumulator.state.currentMetric = 0
            
            accumulator:UpdatePeaks(now)
            
            -- Peak should have decayed (0.98^2 ≈ 0.96)
            assert.is_near(960, accumulator.state.peakMetric, 5)
        end)
    end)
    
    describe("Reset", function()
        local accumulator
        
        before_each(function()
            accumulator = MeterAccumulator:New("TestMeter")
            accumulator:Initialize()
        end)
        
        it("should clear all data", function()
            -- Add some data
            accumulator:AddEvent(GetTime(), "player-guid", 5000, true, false, true)
            accumulator.state.peakMetric = 1000
            
            -- Reset
            accumulator:Reset()
            
            -- Check everything is cleared
            local stats = accumulator:GetStats()
            assert.equals(0, stats.totalValue)
            assert.equals(0, stats.totalEvents)
            assert.equals(0, stats.playerValue)
            assert.equals(0, stats.petValue)
            assert.equals(0, stats.criticalHits)
            assert.equals(0, accumulator.state.peakMetric)
        end)
    end)
    
    describe("GetDisplayData", function()
        local accumulator
        
        before_each(function()
            accumulator = MeterAccumulator:New("TestMeter")
            accumulator:Initialize()
        end)
        
        it("should return formatted display data", function()
            local now = GetTime()
            accumulator:AddEvent(now, "player-guid", 5555, true, false, true)
            -- Manually set values that won't be recalculated
            accumulator.state.peakMetric = 2345.67
            accumulator.state.lastPeakUpdate = now  -- Prevent decay
            
            local displayData = accumulator:GetDisplayData()
            
            -- currentMetric is calculated from window totals, so check it's a number
            assert.is_number(displayData.currentMetric)
            assert.equals(2345, displayData.peakMetric) -- Floored
            assert.equals(5555, displayData.totalValue)
            assert.equals("TestMeter", displayData.meterType)
        end)
        
        it("should call ModifyDisplayData if present", function()
            local modifyCalled = false
            accumulator.ModifyDisplayData = function(self, data, stats)
                modifyCalled = true
                data.customField = "test"
            end
            
            local displayData = accumulator:GetDisplayData()
            
            assert.is_true(modifyCalled)
            assert.equals("test", displayData.customField)
        end)
    end)
end)