require("tests.spec_helper").apply()

describe("RingBuffer", function()
    local RingBuffer
    local addon
    
    before_each(function()
        -- Reset global state
        _G.STORMY_NAMESPACE = {}
        addon = _G.STORMY_NAMESPACE
        
        -- Load RingBuffer
        dofile("Tracking/RingBuffer.lua")
        RingBuffer = addon.RingBuffer
    end)
    
    describe("initialization", function()
        it("should create a buffer with specified capacity", function()
            local buffer = RingBuffer:New(150, "TestBuffer")
            assert.is_not_nil(buffer)
            assert.equals(150, buffer.size)
            assert.equals("TestBuffer", buffer.name)
            assert.equals(0, buffer.count)
        end)
        
        it("should initialize with empty buffer", function()
            local buffer = RingBuffer:New(100, "TestBuffer")
            local latest = buffer:GetLatest()
            assert.is_nil(latest)
        end)
    end)
    
    describe("Write operations", function()
        it("should write entries to buffer", function()
            local buffer = RingBuffer:New(150, "TestBuffer")
            local now = GetTime()
            
            buffer:Write(now, 100, { spell = "Fireball" })
            buffer:Write(now + 1, 200, { spell = "Frostbolt" })
            
            assert.equals(2, buffer.count)
            
            local latest = buffer:GetLatest()
            assert.equals(200, latest.value)
            assert.equals("Frostbolt", latest.data.spell)
        end)
        
        it("should overwrite oldest entries when full", function()
            local buffer = RingBuffer:New(100, "TestBuffer")
            local now = GetTime()
            
            -- Fill buffer beyond capacity
            for i = 1, 105 do
                buffer:Write(now + i, i, { id = i })
            end
            
            assert.equals(100, buffer.count) -- Count stays at max size
            assert.is_true(buffer.totalOverwrites > 0) -- Should have overwrites
            
            local oldest = buffer:GetOldest()
            assert.is_true(oldest.value > 1) -- First entries were overwritten
        end)
        
        it("should handle invalid inputs gracefully", function()
            local buffer = RingBuffer:New(100, "TestBuffer")
            
            -- The implementation doesn't validate inputs strictly,
            -- it just stores what's given
            local countBefore = buffer.count
            buffer:Write(nil, 100)
            assert.equals(countBefore + 1, buffer.count) -- Still writes
            
            buffer:Write(GetTime(), nil)
            assert.equals(countBefore + 2, buffer.count) -- Still writes
        end)
    end)
    
    describe("Query operations", function()
        it("should query entries within time window", function()
            local buffer = RingBuffer:New(100, "TestBuffer")
            local now = GetTime()
            
            -- Write entries at different times
            for i = 1, 5 do
                buffer:Write(now + i, i * 100, { index = i })
            end
            
            -- Query middle window (results are in reverse chronological order)
            local results = buffer:QueryWindow(now + 2, now + 4)
            assert.equals(3, #results) -- Should get entries 2, 3, 4
            assert.equals(400, results[1].value) -- Most recent first
            assert.equals(200, results[3].value) -- Oldest last
        end)
        
        it("should query last N seconds", function()
            local buffer = RingBuffer:New(100, "TestBuffer")
            local now = GetTime()
            
            -- Write entries
            buffer:Write(now - 10, 100)
            buffer:Write(now - 5, 200)
            buffer:Write(now - 2, 300)
            buffer:Write(now - 1, 400)
            
            local results = buffer:QueryLastSeconds(3)
            assert.equals(2, #results) -- Last 3 seconds: entries at -2 and -1
            assert.equals(400, results[1].value) -- Most recent first
            assert.equals(300, results[2].value) -- Older second
        end)
        
        it("should limit results with maxResults", function()
            local buffer = RingBuffer:New(100, "TestBuffer")
            local now = GetTime()
            
            for i = 1, 10 do
                buffer:Write(now + i, i * 100)
            end
            
            local results = buffer:QueryAll(5)
            assert.equals(5, #results)
        end)
    end)
    
    describe("Aggregation operations", function()
        it("should sum values in window", function()
            local buffer = RingBuffer:New(100, "TestBuffer")
            local now = GetTime()
            
            buffer:Write(now, 100)
            buffer:Write(now + 1, 200)
            buffer:Write(now + 2, 300)
            
            local sum = buffer:SumWindow(now, now + 2)
            assert.equals(600, sum)
        end)
        
        it("should sum last N seconds", function()
            local buffer = RingBuffer:New(100, "TestBuffer")
            local now = GetTime()
            
            buffer:Write(now - 5, 100)
            buffer:Write(now - 2, 200)
            buffer:Write(now - 1, 300)
            
            local sum = buffer:SumLastSeconds(3)
            assert.equals(500, sum) -- 200 + 300
        end)
        
        it("should calculate average in window", function()
            local buffer = RingBuffer:New(100, "TestBuffer")
            local now = GetTime()
            
            buffer:Write(now, 100)
            buffer:Write(now + 1, 200)
            buffer:Write(now + 2, 300)
            
            local avg = buffer:AverageWindow(now, now + 2)
            assert.equals(200, avg)
        end)
        
        it("should find max value in window", function()
            local buffer = RingBuffer:New(100, "TestBuffer")
            local now = GetTime()
            
            buffer:Write(now, 100)
            buffer:Write(now + 1, 500)
            buffer:Write(now + 2, 200)
            
            local maxValue, maxTimestamp, count = buffer:MaxWindow(now, now + 2)
            assert.equals(500, maxValue)
            assert.equals(now + 1, maxTimestamp)
            assert.equals(3, count)
        end)
    end)
    
    describe("Clear operation", function()
        it("should empty the buffer", function()
            local buffer = RingBuffer:New(100, "TestBuffer")
            
            buffer:Write(GetTime(), 100)
            buffer:Write(GetTime() + 1, 200)
            
            buffer:Clear()
            
            assert.equals(0, buffer.count)
            assert.is_nil(buffer:GetLatest())
            assert.is_nil(buffer:GetOldest())
        end)
    end)
    
    describe("Statistics", function()
        it("should provide buffer statistics", function()
            local buffer = RingBuffer:New(150, "TestBuffer")
            local now = GetTime()
            
            buffer:Write(now - 10, 100)
            buffer:Write(now - 5, 200)
            buffer:Write(now, 300)
            
            local stats = buffer:GetStats()
            assert.equals("TestBuffer", stats.name)
            assert.equals(150, stats.size)
            assert.equals(3, stats.count)
            assert.equals(0.02, stats.utilization) -- 3/150
            assert.is_true(stats.writesPerSecond >= 0)
        end)
    end)
    
    describe("Buffer management", function()
        it("should get or create named buffers", function()
            local buffer1 = RingBuffer:GetBuffer("test", 100)
            local buffer2 = RingBuffer:GetBuffer("test", 100)
            
            assert.equals(buffer1, buffer2) -- Should return same instance
            
            buffer1:Write(GetTime(), 100)
            assert.equals(1, buffer2.count) -- Same buffer
        end)
        
        it("should provide specialized damage buffer", function()
            local damageBuffer = RingBuffer:GetDamageBuffer()
            assert.is_not_nil(damageBuffer)
            assert.equals("damage", damageBuffer.name)
            assert.equals(1000, damageBuffer.size)
        end)
        
        it("should provide specialized healing buffer", function()
            local healingBuffer = RingBuffer:GetHealingBuffer()
            assert.is_not_nil(healingBuffer)
            assert.equals("healing", healingBuffer.name)
            assert.equals(500, healingBuffer.size)
        end)
    end)
    
    describe("edge cases", function()
        it("should handle minimum size buffer", function()
            local buffer = RingBuffer:New(100, "MinBuffer") -- Minimum enforced by CONFIG
            
            buffer:Write(GetTime(), 100)
            assert.equals(100, buffer:GetLatest().value)
            
            buffer:Write(GetTime() + 1, 200)
            assert.equals(200, buffer:GetLatest().value)
            assert.equals(2, buffer.count)
        end)
        
        it("should handle time range queries on empty buffer", function()
            local buffer = RingBuffer:New(100, "EmptyBuffer")
            
            local results = buffer:QueryLastSeconds(10)
            assert.equals(0, #results)
            
            local sum = buffer:SumLastSeconds(10)
            assert.equals(0, sum)
            
            local avg = buffer:AverageLastSeconds(10)
            assert.equals(0, avg)
        end)
        
        it("should handle wrapped buffer correctly", function()
            local buffer = RingBuffer:New(100, "WrapBuffer")
            local now = GetTime()
            
            -- Fill and wrap buffer (need more than 100 to cause wrapping)
            for i = 1, 110 do
                buffer:Write(now + i, i * 100, { index = i })
            end
            
            -- Should have last 100 entries
            local all = buffer:QueryAll()
            assert.equals(100, #all)
            assert.equals(11000, all[1].value) -- Most recent (110 * 100)
            assert.equals(1100, all[100].value) -- Oldest remaining (11 * 100)
        end)
    end)
end)