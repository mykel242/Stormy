require("tests.spec_helper").apply()

describe("TablePool", function()
    local TablePool
    local addon
    
    before_each(function()
        -- Reset global state
        _G.STORMY_NAMESPACE = {}
        addon = _G.STORMY_NAMESPACE
        
        -- Load TablePool
        dofile("Core/TablePool.lua")
        TablePool = addon.TablePool
        
        -- Clear any existing state
        if TablePool.Clear then
            TablePool:Clear()
        end
    end)
    
    describe("initialization", function()
        it("should have required methods", function()
            assert.is_not_nil(TablePool)
            assert.is_function(TablePool.Get)
            assert.is_function(TablePool.Release)
            assert.is_function(TablePool.GetEvent)
            assert.is_function(TablePool.ReleaseEvent)
            assert.is_function(TablePool.Initialize)
        end)
        
        it("should initialize pools", function()
            TablePool:Initialize()
            local stats = TablePool:GetStats()
            assert.is_not_nil(stats)
            assert.is_table(stats.poolSizes)
        end)
    end)
    
    describe("Get/Release operations", function()
        it("should get and release event tables", function()
            local t1 = TablePool:GetEvent()
            assert.is_table(t1)
            assert.equals(0, t1.timestamp)
            assert.equals("", t1.sourceGUID)
            assert.equals(0, t1.amount)
            
            -- Modify table
            t1.amount = 100
            t1.sourceGUID = "test-guid"
            
            -- Release it
            TablePool:ReleaseEvent(t1)
            
            -- Get another table - should be clean
            local t2 = TablePool:GetEvent()
            assert.equals(0, t2.timestamp)
            assert.equals("", t2.sourceGUID)
            assert.equals(0, t2.amount)
        end)
        
        it("should get and release calc tables", function()
            local t = TablePool:GetCalc()
            assert.is_table(t)
            assert.equals(0, t.dps)
            assert.equals(0, t.damage)
            assert.equals(0, t.elapsed)
            
            t.dps = 1500.5
            TablePool:ReleaseCalc(t)
            
            local t2 = TablePool:GetCalc()
            assert.equals(0, t2.dps)
        end)
        
        it("should get and release UI tables", function()
            local t = TablePool:GetUI()
            assert.is_table(t)
            assert.equals(0, t.value)
            assert.equals(0, t.percent)
            assert.equals("", t.text)
            
            t.text = "test text"
            TablePool:ReleaseUI(t)
            
            local t2 = TablePool:GetUI()
            assert.equals("", t2.text)
        end)
    end)
    
    describe("pool types", function()
        it("should support different pool types", function()
            local event = TablePool:Get("event")
            local calc = TablePool:Get("calc")
            local ui = TablePool:Get("ui")
            
            assert.is_not_nil(event.sourceGUID)
            assert.is_not_nil(calc.dps)
            assert.is_not_nil(ui.text)
            
            TablePool:Release("event", event)
            TablePool:Release("calc", calc)
            TablePool:Release("ui", ui)
        end)
        
        it("should error on invalid pool type", function()
            assert.has_error(function()
                TablePool:Get("invalid")
            end, "Invalid pool type: invalid")
        end)
    end)
    
    describe("table reuse", function()
        it("should reuse released tables", function()
            TablePool:Clear()
            
            local t1 = TablePool:GetEvent()
            TablePool:ReleaseEvent(t1)
            
            local stats1 = TablePool:GetStats()
            local created1 = stats1.event.created
            
            local t2 = TablePool:GetEvent()
            local stats2 = TablePool:GetStats()
            
            assert.equals(created1, stats2.event.created)
            assert.equals(1, stats2.event.reused)
        end)
        
        it("should enforce pool size limits", function()
            TablePool:Clear()
            
            -- Release many tables
            for i = 1, 100 do
                local t = TablePool:GetEvent()
                TablePool:ReleaseEvent(t)
            end
            
            local stats = TablePool:GetStats()
            -- Pool size should be capped at EVENT_POOL_SIZE (50)
            assert.is_true(stats.poolSizes.event <= 50)
        end)
    end)
    
    describe("table cleanup", function()
        it("should clear extra fields on reuse", function()
            local t1 = TablePool:GetEvent()
            t1.extraField = "should be removed"
            t1.anotherExtra = 123
            
            TablePool:ReleaseEvent(t1)
            
            local t2 = TablePool:GetEvent()
            assert.is_nil(t2.extraField)
            assert.is_nil(t2.anotherExtra)
            assert.equals("", t2.sourceGUID) -- Template field preserved
        end)
        
        it("should clear metatables on release", function()
            local t = TablePool:GetEvent()
            local mt = { __index = { custom = true } }
            setmetatable(t, mt)
            
            TablePool:ReleaseEvent(t)
            
            local t2 = TablePool:GetEvent()
            assert.is_nil(getmetatable(t2))
        end)
    end)
    
    describe("statistics", function()
        it("should track creation and reuse counts", function()
            TablePool:Clear()
            
            -- Create some tables
            local tables = {}
            for i = 1, 5 do
                tables[i] = TablePool:GetEvent()
            end
            
            local stats1 = TablePool:GetStats()
            assert.equals(5, stats1.event.created)
            assert.equals(0, stats1.event.reused)
            
            -- Release and reuse
            for i = 1, 3 do
                TablePool:ReleaseEvent(tables[i])
            end
            
            for i = 1, 2 do
                TablePool:GetEvent()
            end
            
            local stats2 = TablePool:GetStats()
            assert.equals(5, stats2.event.created)
            assert.equals(2, stats2.event.reused)
        end)
        
        it("should calculate reuse ratio", function()
            TablePool:Clear()
            
            -- Create and release tables
            for i = 1, 10 do
                local t = TablePool:GetCalc()
                TablePool:ReleaseCalc(t)
            end
            
            -- Reuse some
            for i = 1, 5 do
                TablePool:GetCalc()
            end
            
            local stats = TablePool:GetStats()
            assert.is_true(stats.total.reuseRatio > 0)
        end)
    end)
    
    describe("error handling", function()
        it("should handle corruption gracefully", function()
            -- This test simulates corruption by manipulating the pool directly
            -- In real usage, this shouldn't happen
            local t = TablePool:GetEvent()
            TablePool:ReleaseEvent(t)
            
            -- Since we can't directly access the pools table, we'll just verify
            -- that releasing non-table values is handled gracefully
            assert.has_no.errors(function()
                TablePool:ReleaseEvent(nil)
                TablePool:ReleaseEvent("not a table")
                TablePool:ReleaseEvent(123)
            end)
        end)
    end)
end)