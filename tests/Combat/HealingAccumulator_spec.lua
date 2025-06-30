-- HealingAccumulator_spec.lua
-- Unit tests for the HealingAccumulator class

local helpers = require("tests.spec_helper")

describe("HealingAccumulator", function()
    local HealingAccumulator
    local MeterAccumulator
    local addon
    
    before_each(function()
        addon = helpers.create_mock_addon()
        
        -- Mock TimingManager that maintains relative time consistency
        local testStartTime = GetTime()
        addon.TimingManager = {
            GetCurrentRelativeTime = function() return testStartTime end,
            GetRelativeTime = function(timestamp) 
                -- Ensure we always return a number
                if type(timestamp) == "number" then
                    return timestamp
                else
                    return testStartTime
                end
            end
        }
        
        -- Load base class first
        helpers.load_module_at_path("Combat/MeterAccumulator.lua", addon)
        MeterAccumulator = addon.MeterAccumulator
        
        -- Then load HealingAccumulator
        helpers.load_module_at_path("Combat/HealingAccumulator.lua", addon)
        HealingAccumulator = addon.HealingAccumulator
    end)
    
    describe("New", function()
        it("should create instance extending MeterAccumulator", function()
            local accumulator = HealingAccumulator:New()
            assert.equals("Healing", accumulator.meterType)
            assert.is_table(accumulator.healingState)
            assert.is_table(accumulator.healingRollingData)
        end)
        
        it("should initialize healing-specific state", function()
            local accumulator = HealingAccumulator:New()
            assert.equals(0, accumulator.healingState.totalAbsorbs)
            assert.equals(0, accumulator.healingState.totalOverhealing)
            assert.equals(0, accumulator.healingState.currentAbsorbPS)
            assert.equals(0, accumulator.healingState.currentEffectiveHPS)
        end)
    end)
    
    describe("AddEvent with healing data", function()
        local accumulator
        
        before_each(function()
            accumulator = HealingAccumulator:New()
            accumulator:Initialize()
        end)
        
        it("should track basic healing", function()
            local timestamp = GetTime()
            accumulator:AddEvent(timestamp, "player-guid", 1000, true, false, false, {
                absorbAmount = 0,
                overhealing = 0
            })
            
            local stats = accumulator:GetStats()
            assert.equals(1000, stats.totalValue)
            assert.equals(1, stats.totalEvents)
        end)
        
        it("should track absorbs separately", function()
            local timestamp = GetTime()
            accumulator:AddEvent(timestamp, "player-guid", 1000, true, false, false, {
                absorbAmount = 500,
                overhealing = 0
            })
            
            local stats = accumulator:GetStats()
            assert.equals(1000, stats.totalValue) -- Base healing
            assert.equals(500, accumulator.healingState.totalAbsorbs)
            assert.equals(500, accumulator.healingState.playerAbsorbs)
        end)
        
        it("should track overhealing", function()
            local timestamp = GetTime()
            accumulator:AddEvent(timestamp, "player-guid", 1000, true, false, false, {
                absorbAmount = 0,
                overhealing = 200
            })
            
            assert.equals(200, accumulator.healingState.totalOverhealing)
            assert.equals(200, accumulator.healingState.playerOverhealing)
        end)
        
        it("should separate HOTs from direct heals", function()
            local timestamp = GetTime()
            -- Direct heal
            accumulator:AddEvent(timestamp, "player-guid", 1000, true, false, false, {
                absorbAmount = 0,
                overhealing = 0,
                isHOT = false
            })
            -- HOT
            accumulator:AddEvent(timestamp, "player-guid", 500, true, false, false, {
                absorbAmount = 0,
                overhealing = 0,
                isHOT = true
            })
            
            assert.equals(1000, accumulator.healingState.totalDirectHealing)
            assert.equals(500, accumulator.healingState.totalHOTHealing)
            assert.equals(1, accumulator.healingState.directHealEvents)
            assert.equals(1, accumulator.healingState.hotHealEvents)
        end)
        
        it("should track pet healing separately", function()
            local timestamp = GetTime()
            accumulator:AddEvent(timestamp, "pet-guid", 500, false, true, false, {
                absorbAmount = 200,
                overhealing = 50
            })
            
            local stats = accumulator:GetStats()
            assert.equals(500, stats.petValue)
            assert.equals(200, accumulator.healingState.petAbsorbs)
            assert.equals(50, accumulator.healingState.petOverhealing)
        end)
    end)
    
    describe("GetCurrentEffectiveHPS", function()
        local accumulator
        
        before_each(function()
            accumulator = HealingAccumulator:New()
            accumulator:Initialize()
        end)
        
        it("should return healing + absorbs per second", function()
            local now = addon.TimingManager:GetCurrentRelativeTime()
            -- Add healing
            accumulator:AddEvent(now - 2, "player-guid", 5000, true, false, false, {
                absorbAmount = 0,
                overhealing = 0
            })
            -- Add absorb
            accumulator:AddEvent(now - 1, "player-guid", 0, true, false, false, {
                absorbAmount = 2500,
                overhealing = 0
            })
            
            accumulator:UpdateCurrentValues()
            local effectiveHPS = accumulator:GetCurrentEffectiveHPS()
            -- 5000 healing + 2500 absorbs over 5 seconds = 1500 HPS
            assert.is_near(1500, effectiveHPS, 50)
        end)
    end)
    
    describe("GetCurrentAbsorbPS", function()
        local accumulator
        
        before_each(function()
            accumulator = HealingAccumulator:New()
            accumulator:Initialize()
        end)
        
        it("should return absorbs per second", function()
            local now = GetTime()
            accumulator:AddEvent(now - 2, "player-guid", 0, true, false, false, {
                absorbAmount = 5000,
                overhealing = 0
            })
            
            accumulator:UpdateCurrentValues()
            local absorbPS = accumulator:GetCurrentAbsorbPS()
            -- 5000 over 5 seconds = 1000 APS
            assert.is_near(1000, absorbPS, 50)
        end)
    end)
    
    describe("Efficiency calculations", function()
        local accumulator
        
        before_each(function()
            accumulator = HealingAccumulator:New()
            accumulator:Initialize()
        end)
        
        it("should calculate effectiveness percentage", function()
            local timestamp = GetTime()
            -- 800 effective healing, 200 overhealing = 80% effective
            accumulator:AddEvent(timestamp, "player-guid", 800, true, false, false, {
                absorbAmount = 0,
                overhealing = 200
            })
            
            accumulator:UpdateEfficiencyMetrics()
            assert.is_near(80, accumulator.healingState.effectivenessPercent, 0.1)
        end)
        
        it("should include absorbs in effectiveness", function()
            local timestamp = GetTime()
            -- 600 healing + 300 absorbs = 900 effective, 100 overheal = 90% effective
            accumulator:AddEvent(timestamp, "player-guid", 600, true, false, false, {
                absorbAmount = 300,
                overhealing = 100
            })
            
            accumulator:UpdateEfficiencyMetrics()
            assert.is_near(90, accumulator.healingState.effectivenessPercent, 0.1)
        end)
    end)
    
    describe("ModifyDisplayData", function()
        local accumulator
        
        before_each(function()
            accumulator = HealingAccumulator:New()
            accumulator:Initialize()
        end)
        
        it("should add healing-specific display fields", function()
            -- Add some test data
            accumulator.healingState.currentEffectiveHPS = 1234.56
            accumulator.healingState.currentAbsorbPS = 456.78
            accumulator.healingState.totalAbsorbs = 50000
            accumulator.healingState.effectivenessPercent = 85.5
            
            local displayData = {}
            local stats = {
                currentEffectiveHPS = 1234.56,
                peakEffectiveHPS = 2000,
                currentAbsorbPS = 456.78,
                totalAbsorbs = 50000,
                effectivenessPercent = 85.5
            }
            
            accumulator:ModifyDisplayData(displayData, stats)
            
            assert.equals(1234, displayData.currentEffectiveHPS)
            assert.equals(456, displayData.currentAbsorbPS)
            assert.equals(50000, displayData.totalAbsorbs)
            assert.equals(85.5, displayData.effectivenessPercent)
            assert.equals(1234, displayData.currentMetric) -- Should use effective HPS as main metric
        end)
    end)
    
    describe("GetWindowTotals with extras", function()
        local accumulator
        
        before_each(function()
            accumulator = HealingAccumulator:New()
            accumulator:Initialize()
        end)
        
        it("should include absorbs and overhealing in window totals", function()
            local now = addon.TimingManager:GetCurrentRelativeTime()
            accumulator:AddEvent(now - 3, "player-guid", 1000, true, false, false, {
                absorbAmount = 500,
                overhealing = 100
            })
            accumulator:AddEvent(now - 1, "player-guid", 2000, true, false, false, {
                absorbAmount = 1000,
                overhealing = 200
            })
            
            local window = accumulator:GetWindowTotals(5)
            assert.equals(3000, window.value) -- Total healing
            assert.equals(1500, window.absorbs) -- Total absorbs
            assert.equals(300, window.overhealing) -- Total overhealing
            assert.is_near(900, window.effectiveHPS, 10) -- (3000 + 1500) / 5
            assert.is_near(300, window.absorbPS, 10) -- 1500 / 5
        end)
    end)
    
    describe("Reset", function()
        local accumulator
        
        before_each(function()
            accumulator = HealingAccumulator:New()
            accumulator:Initialize()
        end)
        
        it("should clear all healing-specific data", function()
            -- Add some data
            accumulator:AddEvent(GetTime(), "player-guid", 1000, true, false, false, {
                absorbAmount = 500,
                overhealing = 200
            })
            
            accumulator:Reset()
            
            -- Check healing state is cleared
            assert.equals(0, accumulator.healingState.totalAbsorbs)
            assert.equals(0, accumulator.healingState.totalOverhealing)
            assert.equals(0, accumulator.healingState.currentEffectiveHPS)
            assert.equals(100, accumulator.healingState.effectivenessPercent) -- Reset to 100%
            
            -- Check rolling data is cleared
            assert.equals(0, helpers.table_length(accumulator.healingRollingData.absorbs))
            assert.equals(0, helpers.table_length(accumulator.healingRollingData.overhealing))
        end)
    end)
end)