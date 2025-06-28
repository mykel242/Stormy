-- SlashCommands.lua
-- Slash command handlers for MyUI2

local addonName, addon = ...

-- Slash command module
addon.SlashCommands = {}
local SlashCommands = addon.SlashCommands

-- Main slash command handler
function SlashCommands:Initialize()
    SLASH_MYUI1 = "/myui"
    
    function SlashCmdList.MYUI(msg, editBox)
        local command = string.lower(msg)

        if command == "toggle" or command == "" then
            addon:ToggleMainWindow()
        elseif command:match("^session%s+(.+)$") then
            local sessionId = msg:match("^session%s+(.+)$")  -- Use original msg, not lowercased command
            if addon.StorageManager then
                local session = addon.StorageManager:GetSession(sessionId)

                if session then
                    addon:Info("=== Session Details: [%s] %s ===", session.hash or "----", sessionId)
                    addon:Info("Duration: %.1fs", session.duration or 0)
                    addon:Info("Events: %d", session.eventCount or 0)
                    
                    -- Show segmentation info
                    if session.isSegmented and session.segments then
                        addon:Info("Segmented: %d segments", #session.segments)
                        for i, segment in ipairs(session.segments) do
                            addon:Info("  Segment %d: %.1fs, %d events (%s)", 
                                i, segment.duration or 0, segment.eventCount or 0, segment.id)
                        end
                    else
                        addon:Info("Segmented: No")
                    end
                    
                    if session.metadata and session.metadata.zone then
                        if type(session.metadata.zone) == "string" then
                            addon:Info("Zone: %s", session.metadata.zone)
                        elseif session.metadata.zone.name then
                            addon:Info("Zone: %s", session.metadata.zone.name)
                        end
                    end
                    if session.events then
                        addon:Info("Latest 5 events:")
                        local startIndex = math.max(1, #session.events - 4)
                        for i = startIndex, #session.events do
                            local event = session.events[i]
                            addon:Info("  [%.3f] %s: %s -> %s", 
                                event.realTime or event.time or 0,
                                event.subevent or "UNKNOWN",
                                event.sourceName or "?",
                                event.destName or "?")
                        end
                    end
                    addon:Info("Use '/myui logs' to view full output")
                else
                    addon:Error("Session not found: %s", sessionId)
                end
            else
                addon:Error("StorageManager not loaded")
            end
        elseif command == "version" then
            local tocVersion, title
            if C_AddOns and C_AddOns.GetAddOnMetadata then
                tocVersion = C_AddOns.GetAddOnMetadata("myui2", "Version") or "Unknown"
                title = C_AddOns.GetAddOnMetadata("myui2", "Title") or "MyUI2"
            elseif GetAddOnMetadata then
                tocVersion = GetAddOnMetadata("myui2", "Version") or "Unknown"
                title = GetAddOnMetadata("myui2", "Title") or "MyUI2"
            else
                tocVersion = "Unknown"
                title = "MyUI2"
            end
            
            -- Get build info from addon table
            local buildVersion = addon.VERSION or "Unknown"
            local buildDate = addon.BUILD_DATE or "Unknown"
            
            addon:Info("=== %s Version Info ===", title)
            addon:Info("TOC Version: %s", tocVersion)
            addon:Info("Build Version: %s", buildVersion)
            addon:Info("Build Date: %s", buildDate)
        elseif command == "sessions" then
            if addon.StorageManager then
                local sessions = addon.StorageManager:GetRecentSessions(25)
                addon:Info("=== Recent Combat Sessions (%d shown) ===", #sessions)
                for i, session in ipairs(sessions) do
                    local segments = session.isSegmented and session.segments and #session.segments or 1
                    local zoneInfo = "Unknown Zone"
                    if session.metadata then
                        if type(session.metadata.zone) == "string" then
                            zoneInfo = session.metadata.zone
                        elseif session.metadata.zone and session.metadata.zone.name then
                            zoneInfo = session.metadata.zone.name
                        end
                    end
                    addon:Info("  [%s] %s: %.1fs, %d events, %d segments (%s)", 
                        session.hash or "----",
                        session.id, 
                        session.duration or 0, 
                        session.eventCount or 0,
                        segments,
                        zoneInfo)
                end
                addon:Info("Use '/myui logs' to view full output")
            else
                addon:Error("StorageManager not loaded")
            end
        elseif command == "logs" or command == "logwindow" then
            -- Use the simple log window only
            if addon.MySimpleLogWindow then
                addon.MySimpleLogWindow:Toggle()
            else
                print("Simple log window not loaded")
            end
        elseif command:match("^loglevel%s+(.+)$") then
            local level = command:match("^loglevel%s+(.+)$"):upper()
            if addon.MyLogger then
                local success = addon.MyLogger:SetLevel(level)
                if success then
                    print(string.format("Log level set to: %s", level))
                    addon.db.logLevel = level
                else
                    print(string.format("Invalid log level: %s", level))
                    print("Valid levels: OFF, PANIC, ERROR, WARN, INFO, DEBUG, TRACE")
                    print("Note: DEBUG shows combat detection, TRACE shows detailed scaler analysis")
                end
            else
                print("MyLogger not loaded")
            end
        elseif command == "loglevel" then
            if addon.MyLogger then
                local currentLevel = addon.MyLogger:GetLevel()
                local levelNames = {"OFF", "PANIC", "ERROR", "WARN", "INFO", "DEBUG", "TRACE"}
                addon:Info("Current log level: %s (%d)", levelNames[currentLevel + 1] or "UNKNOWN", currentLevel)
                addon:Info("Usage: /myui loglevel <level>")
                addon:Info("Valid levels: OFF, PANIC, ERROR, WARN, INFO, DEBUG, TRACE")
                addon:Info("Note: DEBUG shows combat detection, TRACE shows detailed scaler analysis")
            else
                addon:Error("MyLogger not loaded")
            end
        elseif command == "browser" then
            if addon.SessionBrowser then
                addon.SessionBrowser:Toggle()
            else
                print("SessionBrowser not loaded")
            end
        elseif command == "meter" then
            if addon.MyDPSMeterWindow then
                addon.MyDPSMeterWindow:Toggle()
            else
                print("DPS meter not loaded")
            end
        elseif command == "dps" then
            if addon.MyDPSMeterWindow then
                addon.MyDPSMeterWindow:Toggle()
            else
                print("DPS meter not loaded")
            end
        elseif command == "hps" then
            if addon.MyHPSMeterWindow then
                addon.MyHPSMeterWindow:Toggle()
            else
                print("HPS meter not loaded")
            end
        elseif command:match("^metermethod%s+(.+)$") then
            local method = msg:match("^metermethod%s+(.+)$"):lower()
            if addon.MyDPSMeterWindow then
                if addon.MyDPSMeterWindow:SetCalculationMethod(method) then
                    addon:Info("DPS meter calculation method set to: %s", method)
                else
                    addon:Error("Invalid method: %s. Valid: rolling, final, hybrid", method)
                end
            else
                print("DPS meter not loaded")
            end
        elseif command:match("^hpsmethod%s+(.+)$") then
            local method = msg:match("^hpsmethod%s+(.+)$"):lower()
            if addon.MyHPSMeterWindow then
                if addon.MyHPSMeterWindow:SetCalculationMethod(method) then
                    addon:Info("HPS meter calculation method set to: %s", method)
                else
                    addon:Error("Invalid method: %s. Valid: rolling, final, hybrid", method)
                end
            else
                print("HPS meter not loaded")
            end
        elseif command:match("^dpsscale%s+(.+)$") then
            local scaleArg = msg:match("^dpsscale%s+(.+)$")
            if addon.MyDPSMeterWindow then
                if scaleArg:lower() == "auto" then
                    addon.MyDPSMeterWindow:SetAutoScale(true)
                    addon:Info("DPS meter switched to auto-scaling")
                else
                    local dpsScale = tonumber(scaleArg)
                    if dpsScale and dpsScale > 0 then
                        addon.MyDPSMeterWindow:SetManualScale(dpsScale)
                        addon:Info("DPS meter manual scale set to: %.0f", dpsScale)
                    else
                        addon:Error("Invalid scale value. Use: /myui dpsscale <number> or /myui dpsscale auto")
                    end
                end
            else
                print("DPS meter not loaded")
            end
        elseif command:match("^hpsscale%s+(.+)$") then
            local scaleArg = msg:match("^hpsscale%s+(.+)$")
            if addon.MyHPSMeterWindow then
                if scaleArg:lower() == "auto" then
                    addon.MyHPSMeterWindow:SetAutoScale(true)
                    addon:Info("HPS meter switched to auto-scaling")
                else
                    local hpsScale = tonumber(scaleArg)
                    if hpsScale and hpsScale > 0 then
                        addon.MyHPSMeterWindow:SetManualScale(hpsScale)
                        addon:Info("HPS meter manual scale set to: %.0f", hpsScale)
                    else
                        addon:Error("Invalid scale value. Use: /myui hpsscale <number> or /myui hpsscale auto")
                    end
                end
            else
                print("HPS meter not loaded")
            end
        elseif command == "meteranalyze" then
            if addon.MyCombatMeterScaler then
                local analysis = addon.MyCombatMeterScaler:ForceScaleUpdate()
                if analysis then
                    addon:Info("=== Scale Analysis Complete ===")
                    addon:Info("Analyzed %d sessions", analysis.sessionsAnalyzed)
                    addon:Info("Recommended DPS Scale: %.0f", analysis.recommendedDPSScale)
                    addon:Info("Recommended HPS Scale: %.0f", analysis.recommendedHPSScale)
                    
                    -- Force publish scale update for immediate UI refresh
                    addon.MyCombatMeterScaler:PublishScaleUpdate(analysis.recommendedDPSScale, analysis.recommendedHPSScale)
                    
                    addon:Info("Use '/myui logs' to view detailed output")
                else
                    addon:Error("No sessions available for analysis")
                end
            else
                print("Combat meter scaler not loaded")
            end
        elseif command == "queuesubscribers" or command == "subscribers" then
            addon:Info("=== Event Queue Subscribers ===")
            
            if addon.CombatEventQueue then
                local subscribers = addon.CombatEventQueue:GetSubscribers()
                addon:Info("Combat Event Queue (%d subscribers):", #subscribers)
                for _, sub in ipairs(subscribers) do
                    addon:Info("  [%d] %s -> %s (%d msgs, %.1fs)", 
                        sub.id, sub.name, sub.messageType, sub.messageCount, sub.duration)
                end
            else
                addon:Warn("  Combat Event Queue: Not available")
            end
            
            if addon.LogEventQueue then
                local subscribers = addon.LogEventQueue:GetSubscribers()
                addon:Info("Log Event Queue (%d subscribers):", #subscribers)
                for _, sub in ipairs(subscribers) do
                    addon:Info("  [%d] %s -> %s (%d msgs, %.1fs)", 
                        sub.id, sub.name, sub.messageType, sub.messageCount, sub.duration)
                end
            else
                addon:Warn("  Log Event Queue: Not available")
            end
        elseif command == "queuestats" then
            addon:Info("=== Event Queue Statistics ===")
            
            if addon.CombatEventQueue then
                local stats = addon.CombatEventQueue:GetStats()
                addon:Info("Combat Event Queue:")
                addon:Info("  Name: %s", stats.name)
                local utilization = stats.maxSize > 0 and (stats.currentSize / stats.maxSize * 100) or 0
                addon:Info("  Size: %d/%d (%.1f%% full)", 
                    stats.currentSize, stats.maxSize, utilization)
                addon:Info("  Messages: %d pushed, %d dropped (%.2f%% drop rate)", 
                    stats.totalPushed, stats.totalDropped, stats.dropRate * 100)
                addon:Info("  Subscribers: %d active", stats.subscriberCount)
                addon:Info("  Performance: %.2f msg/sec over %.1fs", 
                    stats.messagesPerSecond, stats.uptime)
                
                if next(stats.messageTypes) then
                    addon:Info("  Message Types:")
                    for msgType, count in pairs(stats.messageTypes) do
                        addon:Info("    %s: %d", msgType, count)
                    end
                end
            else
                addon:Warn("  Combat Event Queue: Not available")
            end
            
            if addon.LogEventQueue then
                local stats = addon.LogEventQueue:GetStats()
                addon:Info("")
                addon:Info("Log Event Queue:")
                addon:Info("  Name: %s", stats.name)
                local utilization = stats.maxSize > 0 and (stats.currentSize / stats.maxSize * 100) or 0
                addon:Info("  Size: %d/%d (%.1f%% full)", 
                    stats.currentSize, stats.maxSize, utilization)
                addon:Info("  Messages: %d pushed, %d dropped (%.2f%% drop rate)", 
                    stats.totalPushed, stats.totalDropped, stats.dropRate * 100)
                addon:Info("  Subscribers: %d active", stats.subscriberCount)
                addon:Info("  Performance: %.2f msg/sec over %.1fs", 
                    stats.messagesPerSecond, stats.uptime)
            else
                addon:Warn("  Log Event Queue: Not available")
            end
            
            addon:Info("Use '/myui logs' to view detailed output")
        elseif command == "queuedebug" then
            addon:Info("=== Event Queue Debug Information ===")
            
            if addon.CombatEventQueue then
                addon.CombatEventQueue:DebugState()
            else
                addon:Warn("Combat Event Queue: Not available")
            end
            
            if addon.LogEventQueue then
                addon.LogEventQueue:DebugState()
            else
                addon:Warn("Log Event Queue: Not available")
            end
            
            addon:Info("Use '/myui logs' to view detailed output")
        elseif command:match("^queuesubscribers?%s*(.*)$") then
            local queueName = command:match("^queuesubscribers?%s*(.*)$")
            
            local queue = nil
            if queueName == "combat" or queueName == "" then
                queue = addon.CombatEventQueue
                queueName = "Combat Event Queue"
            elseif queueName == "log" then
                queue = addon.LogEventQueue
                queueName = "Log Event Queue"
            end
            
            if queue then
                local subscribers = queue:GetSubscribers()
                addon:Info("=== %s Subscribers ===", queueName)
                
                if #subscribers == 0 then
                    addon:Info("No active subscribers")
                else
                    for _, sub in ipairs(subscribers) do
                        local runtime = GetTime() - sub.subscribeTime
                        addon:Info("  %s -> %s", sub.id, sub.messageType)
                        addon:Info("    Messages received: %d", sub.messagesReceived)
                        addon:Info("    Runtime: %.1fs", runtime)
                        addon:Info("    Has filter: %s", sub.hasFilter and "Yes" or "No")
                        if next(sub.metadata) then
                            addon:Info("    Metadata: %s", table.concat(addon:GetTableKeys(sub.metadata), ", "))
                        end
                    end
                end
            else
                addon:Error("Unknown queue: %s. Use 'combat' or 'log'", queueName)
            end
            
            addon:Info("Use '/myui logs' to view detailed output")
        elseif command == "queueclear" then
            local clearedCombat, clearedLog = 0, 0
            
            if addon.CombatEventQueue then
                clearedCombat = addon.CombatEventQueue.size
                addon.CombatEventQueue:Clear()
                addon:Info("Combat Event Queue cleared (%d messages)", clearedCombat)
            end
            
            if addon.LogEventQueue then
                clearedLog = addon.LogEventQueue.size
                addon.LogEventQueue:Clear()
                addon:Info("Log Event Queue cleared (%d messages)", clearedLog)
            end
            
            addon:Info("Total cleared: %d messages", clearedCombat + clearedLog)
        elseif command == "clearall" then
            if addon.StorageManager then
                addon.StorageManager:ClearAllSessions()
                addon:Info("All combat sessions cleared!")
            else
                addon:Info("StorageManager not available")
            end
        elseif command == "memory" then
            local memoryKB = collectgarbage("count")
            local memoryMB = memoryKB / 1024
            
            addon:Info("=== MyUI2 Memory Usage ===")
            addon:Info("Total Lua Memory: %.2f MB (%.0f KB)", memoryMB, memoryKB)
            
            if addon.StorageManager then
                local stats = addon.StorageManager:GetDebugSummary()
                addon:Info("Storage Manager:")
                addon:Info("  Sessions: %s", stats:match("Sessions: ([^,]+)") or "Unknown")
                addon:Info("  Memory Usage: %s", stats:match("Memory: ([^,]+)") or "Unknown")
                
                local poolStats = addon.StorageManager:GetPoolStats()
                addon:Info("  Table Pool: %d/%d tables (%.1f%% reuse)", 
                    poolStats.currentPoolSize, poolStats.maxPoolSize, poolStats.reuseRatio * 100)
                addon:Info("    Created: %d, Reused: %d, Returned: %d", 
                    poolStats.created, poolStats.reused, poolStats.returned)
            end
            
            if addon.GUIDResolver then
                local guidStats = addon.GUIDResolver:GetCacheStats()
                if guidStats then
                    addon:Info("  GUID Cache: %d entries, %d recent encounters", 
                        guidStats.cacheSize or 0, guidStats.encounterCount or 0)
                else
                    local guidSummary = addon.GUIDResolver:GetDebugSummary()
                    local cacheCount = guidSummary:match("Cache: (%d+)") or "Unknown"
                    addon:Info("  GUID Cache: %s entries", cacheCount)
                end
            end
            
            if addon.MyLoggerWindow then
                local bufferStats = addon.MyLoggerWindow:GetBufferStats()
                addon:Info("  Logger Buffer: %d/%d entries (%.1f%% full)", 
                    bufferStats.size, bufferStats.capacity, 
                    (bufferStats.size / bufferStats.capacity) * 100)
                addon:Info("    Display Buffer: %d entries", bufferStats.displayBufferSize)
                addon:Info("    Overflow Count: %d messages lost", bufferStats.overflowCount)
                addon:Info("    Current Lag: %d unread messages", bufferStats.currentLag)
                if bufferStats.isLagged then
                    addon:Warn("    ⚠️ Buffer lagged: %d messages behind", bufferStats.laggedCount)
                end
                addon:Info("    Refresh Rate: %dms (%.1fHz)", 
                    bufferStats.refreshRate, 1000 / bufferStats.refreshRate)
            elseif addon.MyLogger then
                addon:Info("  Logger: ~100 recent messages in memory")
            end
            
            addon:Info("")
            addon:Info("Component Memory Estimates:")
            
            if addon.EnhancedCombatLogger then
                addon:Info("  Enhanced Combat Logger: Active")
            end
            
            if addon.TimelineTracker then
                addon:Info("  Timeline Tracker: Active")
            end

            if addon.StorageManager then
                local stats = addon.StorageManager:GetDebugSummary()
                local sessionInfo = stats:match("Sessions: ([^,]+)") or "Unknown"
                addon:Info("  Combat Sessions: %s stored", sessionInfo)
            end
            
            addon:Info("")
            addon:Info("Memory Usage Gap: %.1f MB unaccounted", 
                math.max(0, memoryMB - 10))
            addon:Info("Use '/myui logs' to view detailed output")
        elseif command == "storagestats" then
            if addon.StorageManager then
                addon:Info("=== Storage Analysis ===")
                addon:Info("Storage Limits: 25 sessions max, 7 days retention, 8 MB memory limit")
                addon:Info("Priority Sessions: 10 (kept regardless of age)")
                
                local sessions = addon.StorageManager:GetAllSessions()
                addon:Info("Current Sessions: %d", #sessions)
                
                if #sessions > 0 then
                    local totalEvents = 0
                    for _, session in ipairs(sessions) do
                        totalEvents = totalEvents + (session.eventCount or 0)
                    end
                    addon:Info("Total Events: %d (avg %.0f per session)", totalEvents, totalEvents / #sessions)
                end
                
                local poolStats = addon.StorageManager:GetPoolStats()
                addon:Info("Table Pool: %d/%d (%.1f%% reuse)", 
                    poolStats.currentPoolSize, poolStats.maxPoolSize, poolStats.reuseRatio * 100)
                    
                local memoryMB = collectgarbage("count") / 1024
                addon:Info("Total Memory: %.2f MB", memoryMB)
            else
                addon:Error("StorageManager not loaded")
            end
        elseif command == "petdebug" then
            if addon.MySimpleCombatDetector and addon.MySimpleCombatDetector.GetActivePets then
                local pets = addon.MySimpleCombatDetector:GetActivePets()
                local petCount = 0
                
                addon:Info("=== Active Pet Debug ===")
                for guid, petInfo in pairs(pets) do
                    petCount = petCount + 1
                    local timeSince = GetTime() - petInfo.detectedAt
                    addon:Info("Pet %d: %s (Owner: %s, Age: %.1fs)", 
                        petCount, petInfo.name, petInfo.owner, timeSince)
                    addon:Info("  GUID: %s", guid)
                end
                
                if petCount == 0 then
                    addon:Info("No active pets detected")
                    
                    -- Also check current pet status for debugging
                    local currentPetGUID = UnitGUID("pet")
                    if currentPetGUID then
                        local petName = UnitName("pet") or "Unknown"
                        addon:Info("Current pet exists but not tracked: %s (%s)", petName, currentPetGUID)
                    else
                        addon:Info("No current pet active")
                    end
                end
            else
                addon:Error("Pet detection not available")
            end
        elseif command == "petscan" then
            -- Manual pet scan for testing
            if addon.MySimpleCombatDetector and addon.MySimpleCombatDetector.ForcePetScan then
                addon:Info("=== Manual Pet Scan ===")
                
                -- Check current pet status
                local currentPetGUID = UnitGUID("pet")
                local currentPetName = UnitName("pet")
                addon:Info("Current UnitGUID('pet'): %s", tostring(currentPetGUID))
                addon:Info("Current UnitName('pet'): %s", tostring(currentPetName))
                
                -- Force a pet scan
                local foundNew = addon.MySimpleCombatDetector:ForcePetScan()
                addon:Info("Scan completed, found new pets: %s", tostring(foundNew))
                
                -- Show current tracked pets
                local pets = addon.MySimpleCombatDetector:GetActivePets()
                local petCount = 0
                for guid, petInfo in pairs(pets) do
                    petCount = petCount + 1
                    addon:Info("Tracked Pet %d: %s (%s)", petCount, petInfo.name, guid)
                end
                
                if petCount == 0 then
                    addon:Info("No pets are currently tracked")
                end
            else
                addon:Error("Pet detection not available")
            end
        elseif command == "entitymap" then
            if addon.MyCombatEntityMapWindow then
                addon.MyCombatEntityMapWindow:Toggle()
            else
                print("Combat entity map not loaded")
            end
        elseif command == "poolstats" then
            -- Show table pool statistics
            if addon.StorageManager then
                local stats = addon.StorageManager:GetPoolStats()
                addon:Info("=== Table Pool Statistics ===")
                addon:Info("Main Pool:")
                addon:Info("  Size: %d / %d (%.1f%% full)", 
                    stats.currentPoolSize, stats.maxPoolSize, 
                    (stats.currentPoolSize / stats.maxPoolSize) * 100)
                addon:Info("  Created: %d tables", stats.created)
                addon:Info("  Reused: %d tables (%.1f%% reuse rate)", 
                    stats.reused, stats.reuseRatio * 100)
                addon:Info("  Returned: %d tables", stats.returned)
                addon:Info("  Warnings: %d", stats.warnings)
                addon:Info("  Corrupted: %d", stats.corrupted)
                addon:Info("  Health Checks: %d", stats.healthChecks)
                addon:Info("Overflow Pool:")
                addon:Info("  Created: %d tables", stats.overflow.created)
                addon:Info("  Collected: %d tables", stats.overflow.collected)
            else
                addon:Error("StorageManager not available")
            end
        elseif command == "poolhealth" then
            -- Validate pool health
            if addon.StorageManager then
                addon:Info("Running table pool health check...")
                local result = addon.StorageManager:ValidatePool()
                addon:Info("Pool Health Check Results:")
                addon:Info("  Corrupted tables removed: %d", result.corrupted)
                addon:Info("  Healthy tables remaining: %d", result.healthy)
                addon:Info("  Overflow collected: %d", result.overflowCollected)
            else
                addon:Error("StorageManager not available")
            end
        elseif command == "poolflush" then
            -- Emergency pool flush
            if addon.StorageManager then
                addon:Warn("WARNING: This will flush all pooled tables!")
                addon:Info("Performing emergency pool flush...")
                local result = addon.StorageManager:EmergencyPoolFlush()
                addon:Info("Emergency Flush Complete:")
                addon:Info("  Main pool flushed: %d tables", result.mainPoolFlushed)
                addon:Info("  Overflow pool flushed: %d tables", result.overflowPoolFlushed)
                addon:Info("Garbage collection forced")
            else
                addon:Error("StorageManager not available")
            end
        elseif command == "pooldebug" then
            -- Toggle table lineage debugging
            if addon.StorageManager then
                local currentState = addon.StorageManager:GetDebugTableLineage()
                addon.StorageManager:SetDebugTableLineage(not currentState)
                local newState = addon.StorageManager:GetDebugTableLineage()
                addon:Info("Table lineage debugging: %s", newState and "ENABLED" or "DISABLED")
                if newState then
                    addon:Info("New tables will track creation stack traces and purpose")
                else
                    addon:Info("Table lineage tracking disabled")
                end
            else
                addon:Error("StorageManager not available")
            end
        elseif command == "poolleaks" then
            -- Show current table leaks
            if addon.StorageManager then
                local leaks, totalTracked = addon.StorageManager:GetLeakedTables()
                addon:Info("=== Table Pool Leak Analysis ===")
                addon:Info("Total tracked tables: %d", totalTracked)
                addon:Info("Potential leaks (>10s old): %d", #leaks)
                
                if #leaks > 0 then
                    addon:Info("Top 10 oldest leaks:")
                    for i = 1, math.min(10, #leaks) do
                        local leak = leaks[i]
                        addon:Info("  %d. Age: %.1fs, Purpose: %s", i, leak.age, leak.purpose)
                        -- Show first line of stack trace
                        local firstLine = leak.stack:match("([^\n]*)")
                        if firstLine then
                            addon:Info("     Stack: %s", firstLine)
                        end
                    end
                else
                    addon:Info("No leaks detected! All tables properly released.")
                end
            else
                addon:Error("StorageManager not available")
            end
        else
            print("MyUI Essential Commands:")
            print("  /myui - Toggle main window")
            print("  /myui logs - Toggle log viewer (copy/paste friendly)")
            print("  /myui loglevel [level] - Show/set log level")
            print("  /myui browser - Toggle session browser")
            print("  /myui sessions - Show recent sessions")
            print("  /myui session <hash> - Show session details")
            print("  /myui memory - Show memory usage")
            print("  /myui storagestats - Show storage analysis")
            print("  /myui petdebug - Show currently detected pets")
            print("  /myui petscan - Manual pet scan for testing")
            print("  /myui entitymap - Toggle combat entity map window")
            print("  /myui version - Show addon version")
            print("")
            print("Combat Meters:")
            print("  /myui dps - Toggle DPS meter")
            print("  /myui hps - Toggle HPS meter")
            print("  /myui meter - Toggle DPS meter (alias)")
            print("  /myui metermethod <method> - Set DPS calculation method")
            print("  /myui hpsmethod <method> - Set HPS calculation method")
            print("  /myui dpsscale <number|auto> - Set DPS scale or auto-scaling")
            print("  /myui hpsscale <number|auto> - Set HPS scale or auto-scaling")
            print("  /myui meteranalyze - Force scale analysis")
            print("")
            print("Event Queue Debugging:")
            print("  /myui queuestats - Show queue statistics")
            print("  /myui queuedebug - Show detailed queue debug info")
            print("  /myui queuesubscribers [combat|log] - List queue subscribers")
            print("  /myui queueclear - Clear all queues")
            print("")
            print("Table Pool Management:")
            print("  /myui poolstats - Show table pool statistics")
            print("  /myui poolhealth - Run pool health check")
            print("  /myui poolflush - Emergency flush all pooled tables")
            print("  /myui pooldebug - Toggle table lineage debugging")
            print("  /myui poolleaks - Show current table leaks")
        end
    end
end