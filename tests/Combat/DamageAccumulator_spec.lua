-- DamageAccumulator_spec.lua
-- Unit tests for the DamageAccumulator class

local helpers = require("tests.spec_helper")

describe("DamageAccumulator", function()
    local DamageAccumulator
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
        
        -- Then load DamageAccumulator
        helpers.load_module_at_path("Combat/DamageAccumulator.lua", addon)
        DamageAccumulator = addon.DamageAccumulator
    end)
    
    describe("New", function()
        it("should create instance extending MeterAccumulator", function()
            local accumulator = DamageAccumulator:New()
            assert.equals("Damage", accumulator.meterType)
            assert.is_table(accumulator.damageState)
            assert.is_table(accumulator.damageRollingData)
        end)
        
        it("should initialize damage-specific state", function()
            local accumulator = DamageAccumulator:New()
            assert.equals(0, accumulator.damageState.totalSpellDamage)
            assert.equals(0, accumulator.damageState.totalMeleeDamage)
            assert.equals(0, accumulator.damageState.totalDOTDamage)
            assert.equals(0, accumulator.damageState.currentSpellDPS)
            assert.equals(0, accumulator.damageState.currentMeleeDPS)
        end)
    end)
    
    describe("AddEvent with damage data", function()
        local accumulator
        
        before_each(function()
            accumulator = DamageAccumulator:New()
            accumulator:Initialize()
        end)
        
        it("should track basic damage", function()
            local timestamp = GetTime()
            accumulator:AddEvent(timestamp, "player-guid", 1000, true, false, false)
            
            local stats = accumulator:GetStats()
            assert.equals(1000, stats.totalValue)
            assert.equals(1, stats.totalEvents)
        end)
        
        it("should classify spell damage", function()
            local timestamp = GetTime()
            accumulator:AddEvent(timestamp, "player-guid", 1000, true, false, false, {
                spellId = 12345,
                damageType = "spell"
            })
            
            assert.equals(1000, accumulator.damageState.totalSpellDamage)
            assert.equals(1, accumulator.damageState.spellEvents)
            assert.equals(0, accumulator.damageState.totalMeleeDamage)
        end)
        
        it("should classify melee damage", function()
            local timestamp = GetTime()
            accumulator:AddEvent(timestamp, "player-guid", 1500, true, false, false, {
                spellId = nil,
                damageType = "melee"
            })
            
            assert.equals(1500, accumulator.damageState.totalMeleeDamage)
            assert.equals(1, accumulator.damageState.meleeEvents)
            assert.equals(0, accumulator.damageState.totalSpellDamage)
        end)
        
        it("should track DOT damage", function()
            local timestamp = GetTime()
            accumulator:AddEvent(timestamp, "player-guid", 500, true, false, false, {
                spellId = 12345,
                isDOT = true
            })
            
            assert.equals(500, accumulator.damageState.totalDOTDamage)
            assert.equals(1, accumulator.damageState.dotEvents)
        end)
        
        it("should separate player and pet damage by type", function()
            local timestamp = GetTime()
            -- Player spell
            accumulator:AddEvent(timestamp, "player-guid", 1000, true, false, false, {
                spellId = 12345
            })
            -- Pet melee
            accumulator:AddEvent(timestamp, "pet-guid", 500, false, true, false, {
                spellId = nil
            })
            
            assert.equals(1000, accumulator.damageState.playerSpellDamage)
            assert.equals(500, accumulator.damageState.petMeleeDamage)
            assert.equals(0, accumulator.damageState.playerMeleeDamage)
            assert.equals(0, accumulator.damageState.petSpellDamage)
        end)
    end)
    
    describe("GetCurrentSpellDPS", function()
        local accumulator
        
        before_each(function()
            accumulator = DamageAccumulator:New()
            accumulator:Initialize()
        end)
        
        it("should return spell damage per second", function()
            local now = GetTime()
            accumulator:AddEvent(now - 2, "player-guid", 5000, true, false, false, {
                spellId = 12345
            })
            accumulator:AddEvent(now - 1, "player-guid", 5000, true, false, false, {
                spellId = 67890
            })
            
            accumulator:UpdateCurrentValues()
            local spellDPS = accumulator:GetCurrentSpellDPS()
            -- 10000 over 5 seconds = 2000 DPS
            assert.is_near(2000, spellDPS, 50)
        end)
    end)
    
    describe("GetCurrentMeleeDPS", function()
        local accumulator
        
        before_each(function()
            accumulator = DamageAccumulator:New()
            accumulator:Initialize()
        end)
        
        it("should return melee damage per second", function()
            local now = GetTime()
            accumulator:AddEvent(now - 3, "player-guid", 3000, true, false, false, {
                spellId = nil
            })
            accumulator:AddEvent(now - 1, "player-guid", 2000, true, false, false, {
                spellId = nil
            })
            
            accumulator:UpdateCurrentValues()
            local meleeDPS = accumulator:GetCurrentMeleeDPS()
            -- 5000 over 5 seconds = 1000 DPS
            assert.is_near(1000, meleeDPS, 50)
        end)
    end)
    
    describe("Mixed damage tracking", function()
        local accumulator
        
        before_each(function()
            accumulator = DamageAccumulator:New()
            accumulator:Initialize()
        end)
        
        it("should track spell and melee damage separately", function()
            local now = addon.TimingManager:GetCurrentRelativeTime()
            -- Spell damage
            accumulator:AddEvent(now - 2, "player-guid", 6000, true, false, false, {
                spellId = 12345
            })
            -- Melee damage
            accumulator:AddEvent(now - 1, "player-guid", 4000, true, false, false, {
                spellId = nil
            })
            
            accumulator:UpdateCurrentValues()
            
            -- Total DPS should be 10000/5 = 2000
            local totalDPS = accumulator:GetCurrentDPS()
            assert.is_near(2000, totalDPS, 50)
            
            -- Spell DPS should be 6000/5 = 1200
            local spellDPS = accumulator:GetCurrentSpellDPS()
            assert.is_near(1200, spellDPS, 50)
            
            -- Melee DPS should be 4000/5 = 800
            local meleeDPS = accumulator:GetCurrentMeleeDPS()
            assert.is_near(800, meleeDPS, 50)
        end)
    end)
    
    describe("GetWindowTotals with extras", function()
        local accumulator
        
        before_each(function()
            accumulator = DamageAccumulator:New()
            accumulator:Initialize()
        end)
        
        it("should include damage type breakdown in window totals", function()
            local now = addon.TimingManager:GetCurrentRelativeTime()
            accumulator:AddEvent(now - 3, "player-guid", 2000, true, false, false, {
                spellId = 12345
            })
            accumulator:AddEvent(now - 2, "player-guid", 1500, true, false, false, {
                spellId = nil
            })
            accumulator:AddEvent(now - 1, "player-guid", 500, true, false, false, {
                isDOT = true,
                spellId = 67890
            })
            
            local window = accumulator:GetWindowTotals(5)
            assert.equals(4000, window.value) -- Total damage
            assert.equals(2000, window.spellDamage)
            assert.equals(1500, window.meleeDamage)
            assert.equals(500, window.dotDamage)
            assert.is_near(400, window.spellDPS, 10) -- 2000/5
            assert.is_near(300, window.meleeDPS, 10) -- 1500/5
            assert.is_near(100, window.dotDPS, 10) -- 500/5
        end)
    end)
    
    describe("Peak tracking", function()
        local accumulator
        
        before_each(function()
            accumulator = DamageAccumulator:New()
            accumulator:Initialize()
        end)
        
        it("should track peak spell and melee DPS separately", function()
            local now = GetTime()
            -- High spell burst
            accumulator:AddEvent(now - 1, "player-guid", 10000, true, false, false, {
                spellId = 12345
            })
            
            accumulator:UpdateCurrentValues()
            
            -- Check peaks were recorded
            assert.is_true(accumulator.damageState.peakSpellDPS > 0)
            assert.equals(0, accumulator.damageState.peakMeleeDPS) -- No melee damage
        end)
    end)
    
    describe("Reset", function()
        local accumulator
        
        before_each(function()
            accumulator = DamageAccumulator:New()
            accumulator:Initialize()
        end)
        
        it("should clear all damage-specific data", function()
            -- Add some data
            accumulator:AddEvent(GetTime(), "player-guid", 5000, true, false, false, {
                spellId = 12345
            })
            accumulator.damageState.peakSpellDPS = 1000
            accumulator.damageState.peakMeleeDPS = 500
            
            accumulator:Reset()
            
            -- Check damage state is cleared
            assert.equals(0, accumulator.damageState.totalSpellDamage)
            assert.equals(0, accumulator.damageState.totalMeleeDamage)
            assert.equals(0, accumulator.damageState.totalDOTDamage)
            assert.equals(0, accumulator.damageState.peakSpellDPS)
            assert.equals(0, accumulator.damageState.peakMeleeDPS)
            
            -- Check rolling data is cleared
            assert.equals(0, helpers.table_length(accumulator.damageRollingData.spellDamage))
            assert.equals(0, helpers.table_length(accumulator.damageRollingData.meleeDamage))
        end)
    end)
end)