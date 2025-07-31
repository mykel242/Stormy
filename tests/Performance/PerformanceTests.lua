-- PerformanceTests.lua
-- Comprehensive performance testing suite for STORMY addon
-- Tests event processing throughput, memory usage, and UI responsiveness

local addonName, addon = ...

-- =============================================================================
-- PERFORMANCE TEST SUITE
-- =============================================================================

addon.PerformanceTests = {}
local PerformanceTests = addon.PerformanceTests

-- Test configuration
local TEST_CONFIG = {
    -- Event processing tests
    EVENT_BURST_SIZE = 100,         -- Events per burst
    EVENT_SUSTAINED_DURATION = 30,  -- Seconds of sustained load
    EVENT_SUSTAINED_RATE = 50,      -- Events per second
    
    -- Memory tests
    MEMORY_SAMPLE_INTERVAL = 1,     -- Seconds between memory samples
    MEMORY_TEST_DURATION = 60,      -- Total test duration
    
    -- UI performance tests
    UI_TEST_ITERATIONS = 100,       -- Number of render cycles to test
    UI_HOVER_TESTS = 50,           -- Number of hover state changes
    
    -- Stress test parameters
    MYTHIC_PLUS_SIMULATION = {
        DURATION = 300,             -- 5 minute fight simulation
        AVERAGE_EVENTS_PER_SECOND = 40,
        PEAK_EVENTS_PER_SECOND = 80,
        BURST_FREQUENCY = 10        -- Bursts every 10 seconds
    }
}

-- Test results storage
local testResults = {
    eventProcessing = {},
    memoryUsage = {},
    uiPerformance = {},
    stressTest = {}
}

-- Performance monitoring state
local perfMonitor = {
    startTime = 0,
    samples = {},
    isRunning = false
}

-- =============================================================================
-- PERFORMANCE MONITORING UTILITIES
-- =============================================================================

-- Get current memory usage in KB
local function GetMemoryUsage()
    collectgarbage("collect")
    return collectgarbage("count")
end

-- Get current CPU time (approximation using GetTime)
local function GetCPUTime()
    return GetTime()
end

-- Calculate statistical summary
local function CalculateStats(values)
    if #values == 0 then
        return {count = 0, min = 0, max = 0, avg = 0, median = 0}
    end
    
    table.sort(values)
    local sum = 0
    for _, v in ipairs(values) do
        sum = sum + v
    end
    
    local median = #values % 2 == 0 and 
                  (values[#values/2] + values[#values/2 + 1]) / 2 or 
                  values[math.ceil(#values/2)]
    
    return {
        count = #values,
        min = values[1],
        max = values[#values],
        avg = sum / #values,
        median = median
    }
end

-- =============================================================================
-- EVENT PROCESSING PERFORMANCE TESTS
-- =============================================================================

-- Test event processing burst capacity
function PerformanceTests:TestEventProcessingBurst()
    print("[PERF] Testing event processing burst capacity...")
    
    local startTime = GetCPUTime()
    local startMemory = GetMemoryUsage()
    
    -- Generate burst of fake combat events
    for i = 1, TEST_CONFIG.EVENT_BURST_SIZE do
        local timestamp = GetTime()
        local sourceGUID = "Player-1234-56789"
        local amount = math.random(1000, 5000)
        local spellId = math.random(1, 100000)
        local isCrit = math.random() < 0.3
        
        -- Simulate event processing
        if addon.EventProcessor then
            addon.EventProcessor:ProcessDamageEvent(
                timestamp, sourceGUID, "Target-1234-56789", spellId, amount,
                isCrit, true, false, "TestPlayer"
            )
        end
    end
    
    local endTime = GetCPUTime()
    local endMemory = GetMemoryUsage()
    
    local result = {
        eventsProcessed = TEST_CONFIG.EVENT_BURST_SIZE,
        totalTime = endTime - startTime,
        eventsPerSecond = TEST_CONFIG.EVENT_BURST_SIZE / (endTime - startTime),
        memoryDelta = endMemory - startMemory,
        memoryPerEvent = (endMemory - startMemory) / TEST_CONFIG.EVENT_BURST_SIZE
    }
    
    testResults.eventProcessing.burst = result
    
    print(string.format("[PERF] Burst test completed: %.0f events/sec, %.2f KB memory delta",
          result.eventsPerSecond, result.memoryDelta))
    
    return result
end

-- Test sustained event processing
function PerformanceTests:TestSustainedEventProcessing()
    print("[PERF] Testing sustained event processing...")
    
    local startTime = GetCPUTime()
    local startMemory = GetMemoryUsage()
    local eventCount = 0
    local samples = {}
    
    -- Create sustained load timer
    local testTimer = C_Timer.NewTicker(1.0 / TEST_CONFIG.EVENT_SUSTAINED_RATE, function()
        local sampleStart = GetCPUTime()
        
        -- Process single event
        local timestamp = GetTime()
        local amount = math.random(1000, 5000)
        local spellId = math.random(1, 100000)
        local isCrit = math.random() < 0.3
        
        if addon.EventProcessor then
            addon.EventProcessor:ProcessDamageEvent(
                timestamp, "Player-1234-56789", "Target-1234-56789", spellId, amount,
                isCrit, true, false, "TestPlayer"
            )
        end
        
        eventCount = eventCount + 1
        local sampleTime = GetCPUTime() - sampleStart
        table.insert(samples, sampleTime * 1000) -- Convert to milliseconds
    end)
    
    -- Stop test after duration
    C_Timer.After(TEST_CONFIG.EVENT_SUSTAINED_DURATION, function()
        testTimer:Cancel()
        
        local endTime = GetCPUTime()
        local endMemory = GetMemoryUsage()
        
        local result = {
            eventsProcessed = eventCount,
            totalTime = endTime - startTime,
            averageEventsPerSecond = eventCount / (endTime - startTime),
            memoryDelta = endMemory - startMemory,
            processingTimeStats = CalculateStats(samples)
        }
        
        testResults.eventProcessing.sustained = result
        
        print(string.format("[PERF] Sustained test completed: %.0f events, %.1f avg events/sec",
              result.eventsProcessed, result.averageEventsPerSecond))
        print(string.format("[PERF] Processing time: %.3f ms avg, %.3f ms max",
              result.processingTimeStats.avg, result.processingTimeStats.max))
    end)
end

-- =============================================================================
-- MEMORY USAGE TESTS
-- =============================================================================

-- Monitor memory usage over time during normal operation
function PerformanceTests:TestMemoryUsage()
    print("[PERF] Starting memory usage monitoring...")
    
    local startMemory = GetMemoryUsage()
    local samples = {}
    local sampleCount = 0
    
    -- Sample memory every interval
    local memoryTimer = C_Timer.NewTicker(TEST_CONFIG.MEMORY_SAMPLE_INTERVAL, function()
        local currentMemory = GetMemoryUsage()
        table.insert(samples, {
            time = GetTime(),
            memory = currentMemory,
            delta = currentMemory - startMemory
        })
        sampleCount = sampleCount + 1
    end)
    
    -- Stop monitoring after duration
    C_Timer.After(TEST_CONFIG.MEMORY_TEST_DURATION, function()
        memoryTimer:Cancel()
        
        local memoryDeltas = {}
        for _, sample in ipairs(samples) do
            table.insert(memoryDeltas, sample.delta)
        end
        
        local result = {
            startMemory = startMemory,
            endMemory = samples[#samples] and samples[#samples].memory or startMemory,
            samples = samples,
            memoryStats = CalculateStats(memoryDeltas),
            leakRate = (#samples > 1) and 
                      ((samples[#samples].memory - startMemory) / TEST_CONFIG.MEMORY_TEST_DURATION) or 0
        }
        
        testResults.memoryUsage = result
        
        print(string.format("[PERF] Memory test completed: %.2f KB total growth, %.3f KB/sec leak rate",
              result.endMemory - result.startMemory, result.leakRate))
    end)
end

-- =============================================================================
-- UI PERFORMANCE TESTS
-- =============================================================================

-- Test UI render performance
function PerformanceTests:TestUIRenderPerformance()
    print("[PERF] Testing UI render performance...")
    
    if not addon.DPSPlot then
        print("[PERF] DPS Plot not available, skipping UI tests")
        return
    end
    
    local renderTimes = {}
    local startTime = GetCPUTime()
    
    -- Test multiple render cycles
    for i = 1, TEST_CONFIG.UI_TEST_ITERATIONS do
        local renderStart = GetCPUTime()
        
        -- Force a render cycle
        addon.DPSPlot:Render()
        
        local renderTime = GetCPUTime() - renderStart
        table.insert(renderTimes, renderTime * 1000) -- Convert to milliseconds
    end
    
    local totalTime = GetCPUTime() - startTime
    
    local result = {
        iterations = TEST_CONFIG.UI_TEST_ITERATIONS,
        totalTime = totalTime,
        renderTimeStats = CalculateStats(renderTimes),
        framesPerSecond = TEST_CONFIG.UI_TEST_ITERATIONS / totalTime
    }
    
    testResults.uiPerformance.render = result
    
    print(string.format("[PERF] UI render test completed: %.3f ms avg, %.1f FPS equivalent",
          result.renderTimeStats.avg, result.framesPerSecond))
end

-- Test hover state performance
function PerformanceTests:TestHoverPerformance()
    print("[PERF] Testing hover state performance...")
    
    if not addon.DPSPlot then
        print("[PERF] DPS Plot not available, skipping hover tests")
        return
    end
    
    local hoverTimes = {}
    
    for i = 1, TEST_CONFIG.UI_HOVER_TESTS do
        local hoverStart = GetCPUTime()
        
        -- Simulate hover state change
        local randomTimestamp = math.floor(GetTime()) - math.random(0, 60)
        addon.DPSPlot.plotState.hoveredTimestamp = randomTimestamp
        addon.DPSPlot:Render()
        
        local hoverTime = GetCPUTime() - hoverStart
        table.insert(hoverTimes, hoverTime * 1000)
    end
    
    local result = {
        hoverTests = TEST_CONFIG.UI_HOVER_TESTS,
        hoverTimeStats = CalculateStats(hoverTimes)
    }
    
    testResults.uiPerformance.hover = result
    
    print(string.format("[PERF] Hover test completed: %.3f ms avg hover response",
          result.hoverTimeStats.avg))
end

-- =============================================================================
-- STRESS TEST SIMULATION
-- =============================================================================

-- Simulate mythic+ dungeon stress test
function PerformanceTests:TestMythicPlusSimulation()
    print("[PERF] Starting Mythic+ stress test simulation...")
    
    local startTime = GetCPUTime()
    local startMemory = GetMemoryUsage()
    local eventCount = 0
    local burstCount = 0
    local performanceSamples = {}
    
    -- Create base event generation timer
    local baseEventTimer = C_Timer.NewTicker(1.0 / TEST_CONFIG.MYTHIC_PLUS_SIMULATION.AVERAGE_EVENTS_PER_SECOND, function()
        local sampleStart = GetCPUTime()
        
        -- Generate event
        local timestamp = GetTime()
        local amount = math.random(2000, 8000) -- Higher damage in mythic+
        local spellId = math.random(1, 100000)
        local isCrit = math.random() < 0.35 -- Higher crit rate
        
        if addon.EventProcessor then
            addon.EventProcessor:ProcessDamageEvent(
                timestamp, "Player-1234-56789", "Target-1234-56789", spellId, amount,
                isCrit, true, false, "TestPlayer"
            )
        end
        
        eventCount = eventCount + 1
        local sampleTime = GetCPUTime() - sampleStart
        table.insert(performanceSamples, sampleTime * 1000)
    end)
    
    -- Create burst event timer
    local burstTimer = C_Timer.NewTicker(TEST_CONFIG.MYTHIC_PLUS_SIMULATION.BURST_FREQUENCY, function()
        burstCount = burstCount + 1
        print(string.format("[PERF] Burst event #%d triggered", burstCount))
        
        -- Generate burst of events
        for i = 1, TEST_CONFIG.MYTHIC_PLUS_SIMULATION.PEAK_EVENTS_PER_SECOND do
            local timestamp = GetTime()
            local amount = math.random(3000, 12000) -- Burst damage
            local spellId = math.random(1, 100000)
            local isCrit = math.random() < 0.4 -- Even higher crit in bursts
            
            if addon.EventProcessor then
                addon.EventProcessor:ProcessDamageEvent(
                    timestamp, "Player-1234-56789", "Target-1234-56789", spellId, amount,
                    isCrit, true, false, "TestPlayer"
                )
            end
            
            eventCount = eventCount + 1
        end
    end)
    
    -- Stop stress test after duration
    C_Timer.After(TEST_CONFIG.MYTHIC_PLUS_SIMULATION.DURATION, function()
        baseEventTimer:Cancel()
        burstTimer:Cancel()
        
        local endTime = GetCPUTime()
        local endMemory = GetMemoryUsage()
        
        local result = {
            duration = TEST_CONFIG.MYTHIC_PLUS_SIMULATION.DURATION,
            totalEvents = eventCount,
            burstEvents = burstCount,
            averageEventsPerSecond = eventCount / (endTime - startTime),
            memoryGrowth = endMemory - startMemory,
            processingTimeStats = CalculateStats(performanceSamples),
            
            -- Performance thresholds
            passedMemoryTest = (endMemory - startMemory) < 10000, -- Less than 10MB growth
            passedSpeedTest = #performanceSamples > 0 and CalculateStats(performanceSamples).avg < 1.0, -- Less than 1ms avg
            passedThroughputTest = (eventCount / (endTime - startTime)) > TEST_CONFIG.MYTHIC_PLUS_SIMULATION.AVERAGE_EVENTS_PER_SECOND * 0.95
        }
        
        testResults.stressTest = result
        
        print(string.format("[PERF] Stress test completed: %d events in %ds (%.1f events/sec)",
              result.totalEvents, result.duration, result.averageEventsPerSecond))
        print(string.format("[PERF] Memory growth: %.2f KB, Processing: %.3f ms avg",
              result.memoryGrowth, result.processingTimeStats.avg))
        print(string.format("[PERF] Tests passed: Memory=%s, Speed=%s, Throughput=%s",
              result.passedMemoryTest and "PASS" or "FAIL",
              result.passedSpeedTest and "PASS" or "FAIL", 
              result.passedThroughputTest and "PASS" or "FAIL"))
    end)
end

-- =============================================================================
-- TEST SUITE EXECUTION
-- =============================================================================

-- Run all performance tests
function PerformanceTests:RunAllTests()
    print("=== STORMY Performance Test Suite ===")
    print("Starting comprehensive performance testing...")
    
    -- Clear previous results
    testResults = {
        eventProcessing = {},
        memoryUsage = {},
        uiPerformance = {},
        stressTest = {}
    }
    
    -- Run tests in sequence with delays
    self:TestEventProcessingBurst()
    
    C_Timer.After(2, function()
        self:TestSustainedEventProcessing()
    end)
    
    C_Timer.After(5, function()
        self:TestMemoryUsage()
    end)
    
    C_Timer.After(8, function()
        self:TestUIRenderPerformance()
    end)
    
    C_Timer.After(10, function()
        self:TestHoverPerformance()
    end)
    
    C_Timer.After(12, function()
        self:TestMythicPlusSimulation()
    end)
    
    -- Generate final report after all tests complete
    C_Timer.After(TEST_CONFIG.MYTHIC_PLUS_SIMULATION.DURATION + 15, function()
        self:GeneratePerformanceReport()
    end)
end

-- Generate comprehensive performance report
function PerformanceTests:GeneratePerformanceReport()
    print("\n=== STORMY Performance Test Report ===")
    
    -- Event Processing Results
    if testResults.eventProcessing.burst then
        local burst = testResults.eventProcessing.burst
        print(string.format("Event Processing (Burst): %.0f events/sec, %.2f KB memory/event",
              burst.eventsPerSecond, burst.memoryPerEvent))
    end
    
    if testResults.eventProcessing.sustained then
        local sustained = testResults.eventProcessing.sustained
        print(string.format("Event Processing (Sustained): %.1f events/sec avg, %.3f ms processing time",
              sustained.averageEventsPerSecond, sustained.processingTimeStats.avg))
    end
    
    -- Memory Usage Results
    if testResults.memoryUsage.leakRate then
        print(string.format("Memory Usage: %.3f KB/sec leak rate, %.2f KB total growth",
              testResults.memoryUsage.leakRate, 
              testResults.memoryUsage.endMemory - testResults.memoryUsage.startMemory))
    end
    
    -- UI Performance Results
    if testResults.uiPerformance.render then
        local render = testResults.uiPerformance.render
        print(string.format("UI Render Performance: %.3f ms avg, %.1f FPS equivalent",
              render.renderTimeStats.avg, render.framesPerSecond))
    end
    
    if testResults.uiPerformance.hover then
        print(string.format("UI Hover Performance: %.3f ms avg response time",
              testResults.uiPerformance.hover.hoverTimeStats.avg))
    end
    
    -- Stress Test Results
    if testResults.stressTest.duration then
        local stress = testResults.stressTest
        print(string.format("Stress Test: %d events processed, %.1f events/sec",
              stress.totalEvents, stress.averageEventsPerSecond))
        print(string.format("Stress Test Results: Memory=%s, Speed=%s, Throughput=%s",
              stress.passedMemoryTest and "PASS" or "FAIL",
              stress.passedSpeedTest and "PASS" or "FAIL",
              stress.passedThroughputTest and "PASS" or "FAIL"))
    end
    
    print("=== Performance Test Suite Complete ===\n")
end

-- Get test results for external analysis
function PerformanceTests:GetResults()
    return testResults
end

-- =============================================================================
-- SLASH COMMAND INTEGRATION
-- =============================================================================

-- Register slash command for performance testing
SLASH_STORMYPERF1 = "/stormyperf"
SlashCmdList["STORMYPERF"] = function(msg)
    local cmd = string.lower(string.trim(msg or ""))
    
    if cmd == "all" or cmd == "" then
        addon.PerformanceTests:RunAllTests()
    elseif cmd == "burst" then
        addon.PerformanceTests:TestEventProcessingBurst()
    elseif cmd == "sustained" then
        addon.PerformanceTests:TestSustainedEventProcessing()
    elseif cmd == "memory" then
        addon.PerformanceTests:TestMemoryUsage()
    elseif cmd == "ui" then
        addon.PerformanceTests:TestUIRenderPerformance()
        addon.PerformanceTests:TestHoverPerformance()
    elseif cmd == "stress" then
        addon.PerformanceTests:TestMythicPlusSimulation()
    elseif cmd == "report" then
        addon.PerformanceTests:GeneratePerformanceReport()
    elseif cmd == "help" then
        print("STORMY Performance Test Commands:")
        print("  /stormyperf all     - Run all performance tests")
        print("  /stormyperf burst   - Test event processing burst")
        print("  /stormyperf sustained - Test sustained event processing")
        print("  /stormyperf memory  - Test memory usage")
        print("  /stormyperf ui      - Test UI performance")
        print("  /stormyperf stress  - Run mythic+ stress test")
        print("  /stormyperf report  - Show last test results")
    else
        print("Unknown command. Use '/stormyperf help' for available commands.")
    end
end

return PerformanceTests