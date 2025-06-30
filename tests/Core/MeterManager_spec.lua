-- MeterManager_spec.lua
-- Unit tests for the MeterManager module

local helpers = require("tests.spec_helper")

describe("MeterManager", function()
    local MeterManager
    local addon
    
    before_each(function()
        addon = helpers.create_mock_addon()
        
        -- Mock C_Timer for maintenance timer
        _G.C_Timer = {
            NewTicker = function(delay, callback)
                return {
                    Cancel = function() end,
                    IsCancelled = function() return false end
                }
            end
        }
        
        -- Load module
        helpers.load_module_at_path("Core/MeterManager.lua", addon)
        MeterManager = addon.MeterManager
    end)
    
    describe("Initialize", function()
        it("should initialize successfully", function()
            assert.has_no_errors(function()
                MeterManager:Initialize()
            end)
            assert.is_truthy(MeterManager.maintenanceTimer)
        end)
    end)
    
    describe("RegisterMeter", function()
        before_each(function()
            MeterManager:Initialize()
        end)
        
        it("should register a new meter type", function()
            local mockAccumulator = { name = "TestAccumulator" }
            local mockWindow = { name = "TestWindow" }
            
            local result = MeterManager:RegisterMeter("Test", mockAccumulator, mockWindow)
            assert.is_true(result)
            
            local meterInfo = MeterManager:GetMeterInfo("Test")
            assert.is_table(meterInfo)
            assert.equals("Test", meterInfo.type)
            assert.equals(mockAccumulator, meterInfo.accumulator)
            assert.equals(mockWindow, meterInfo.window)
        end)
        
        it("should not register duplicate meter types", function()
            local mockAccumulator = { name = "TestAccumulator" }
            local mockWindow = { name = "TestWindow" }
            
            MeterManager:RegisterMeter("Test", mockAccumulator, mockWindow)
            local result = MeterManager:RegisterMeter("Test", mockAccumulator, mockWindow)
            
            assert.is_false(result)
        end)
    end)
    
    describe("RouteDamageEvent", function()
        before_each(function()
            MeterManager:Initialize()
        end)
        
        it("should route damage events to registered accumulator", function()
            local eventReceived = false
            local mockAccumulator = {
                AddEvent = function(self, timestamp, sourceGUID, amount, isPlayer, isPet, isCritical)
                    eventReceived = true
                    assert.equals(100, timestamp)
                    assert.equals("player-guid", sourceGUID)
                    assert.equals(1000, amount)
                    assert.is_true(isPlayer)
                    assert.is_false(isPet)
                    assert.is_true(isCritical)
                end
            }
            
            MeterManager:RegisterMeter("Damage", mockAccumulator, {})
            MeterManager:RouteDamageEvent(100, "player-guid", 1000, true, false, true)
            
            assert.is_true(eventReceived)
        end)
        
        it("should call OnDamageEvent on other accumulators", function()
            local damageReceived = false
            local otherReceived = false
            
            local damageAccumulator = {
                AddEvent = function() damageReceived = true end
            }
            
            local otherAccumulator = {
                OnDamageEvent = function() otherReceived = true end
            }
            
            MeterManager:RegisterMeter("Damage", damageAccumulator, {})
            MeterManager:RegisterMeter("Other", otherAccumulator, {})
            
            MeterManager:RouteDamageEvent(100, "player-guid", 1000, true, false, false)
            
            assert.is_true(damageReceived)
            assert.is_true(otherReceived)
        end)
    end)
    
    describe("RouteHealingEvent", function()
        before_each(function()
            MeterManager:Initialize()
        end)
        
        it("should route healing events with extra data", function()
            local eventReceived = false
            local extraDataReceived = nil
            
            local mockAccumulator = {
                AddEvent = function(self, timestamp, sourceGUID, amount, isPlayer, isPet, isCritical, extraData)
                    eventReceived = true
                    extraDataReceived = extraData
                    assert.equals(500, extraData.absorbAmount)
                    assert.equals(100, extraData.overhealing)
                end
            }
            
            MeterManager:RegisterMeter("Healing", mockAccumulator, {})
            MeterManager:RouteHealingEvent(100, "player-guid", 1000, 500, true, false, false, 100)
            
            assert.is_true(eventReceived)
            assert.is_table(extraDataReceived)
        end)
    end)
    
    -- Note: RouteAbsorbEvent was removed as absorb functionality was simplified out
    
    describe("Meter Control", function()
        local mockWindow
        
        before_each(function()
            MeterManager:Initialize()
            
            mockWindow = {
                Show = function(self) self.isShown = true end,
                Hide = function(self) self.isShown = false end,
                isShown = false,
                state = {
                    mainFrame = {
                        ClearAllPoints = function() end,
                        SetPoint = function() end
                    }
                }
            }
        end)
        
        it("should show meter", function()
            MeterManager:RegisterMeter("Test", {}, mockWindow)
            local result = MeterManager:ShowMeter("Test")
            
            assert.is_true(result)
            assert.is_true(mockWindow.isShown)
        end)
        
        it("should hide meter", function()
            MeterManager:RegisterMeter("Test", {}, mockWindow)
            -- First show the meter so it's marked as visible
            MeterManager:ShowMeter("Test")
            assert.is_true(mockWindow.isShown)
            
            local result = MeterManager:HideMeter("Test")
            
            assert.is_true(result)
            assert.is_false(mockWindow.isShown)
        end)
        
        it("should toggle meter", function()
            MeterManager:RegisterMeter("Test", {}, mockWindow)
            
            -- Initially hidden, should show
            MeterManager:ToggleMeter("Test")
            assert.is_true(mockWindow.isShown)
            
            -- Now shown, should hide
            MeterManager:ToggleMeter("Test")
            assert.is_false(mockWindow.isShown)
        end)
        
        it("should handle unknown meter types", function()
            local result = MeterManager:ShowMeter("Unknown")
            assert.is_false(result)
            
            result = MeterManager:HideMeter("Unknown")
            assert.is_false(result)
            
            result = MeterManager:ToggleMeter("Unknown")
            assert.is_false(result)
        end)
    end)
    
    describe("GetAllMeters", function()
        before_each(function()
            MeterManager:Initialize()
        end)
        
        it("should return all registered meters", function()
            MeterManager:RegisterMeter("Damage", {}, {})
            MeterManager:RegisterMeter("Healing", {}, {})
            
            local meters = MeterManager:GetAllMeters()
            
            assert.is_table(meters)
            assert.is_table(meters.Damage)
            assert.is_table(meters.Healing)
            assert.equals("Damage", meters.Damage.type)
            assert.equals("Healing", meters.Healing.type)
        end)
    end)
    
    describe("SetMeterEnabled", function()
        before_each(function()
            MeterManager:Initialize()
        end)
        
        it("should enable/disable meters", function()
            local mockWindow = {
                Show = function() end,
                Hide = function() end,
                isShown = true
            }
            
            MeterManager:RegisterMeter("Test", {}, mockWindow)
            
            -- Disable
            local result = MeterManager:SetMeterEnabled("Test", false)
            assert.is_true(result)
            assert.is_false(MeterManager:IsMeterEnabled("Test"))
            
            -- Enable
            result = MeterManager:SetMeterEnabled("Test", true)
            assert.is_true(result)
            assert.is_true(MeterManager:IsMeterEnabled("Test"))
        end)
        
        it("should hide meter when disabled", function()
            local hideCalled = false
            local mockWindow = {
                Show = function() end,
                Hide = function() hideCalled = true end,
                isShown = true
            }
            
            MeterManager:RegisterMeter("Test", {}, mockWindow)
            MeterManager:ShowMeter("Test")
            
            MeterManager:SetMeterEnabled("Test", false)
            
            assert.is_true(hideCalled)
        end)
    end)
    
    describe("ResetAllMeters", function()
        before_each(function()
            MeterManager:Initialize()
        end)
        
        it("should reset all accumulators", function()
            local resetCount = 0
            
            local mockAccumulator1 = {
                Reset = function() resetCount = resetCount + 1 end
            }
            local mockAccumulator2 = {
                Reset = function() resetCount = resetCount + 1 end
            }
            
            MeterManager:RegisterMeter("Test1", mockAccumulator1, {})
            MeterManager:RegisterMeter("Test2", mockAccumulator2, {})
            
            local count = MeterManager:ResetAllMeters()
            
            assert.equals(2, resetCount)
            assert.equals(2, count)
        end)
    end)
    
    describe("GetStatus", function()
        before_each(function()
            MeterManager:Initialize()
        end)
        
        it("should return meter status", function()
            local mockWindow = {
                Show = function() end,
                Hide = function() end,
                isShown = false
            }
            
            MeterManager:RegisterMeter("Test", {}, mockWindow)
            MeterManager:ShowMeter("Test")
            
            local status = MeterManager:GetStatus()
            
            assert.is_table(status)
            assert.equals(1, status.registeredCount)
            assert.equals(1, status.enabledCount)
            assert.equals(1, status.visibleCount)
            assert.is_table(status.meters.Test)
            assert.is_true(status.meters.Test.visible)
        end)
    end)
end)