-- MyCombatMeterScaler.lua
-- Dynamic scaling system for combat meter based on session history
--
-- SCALING STRATEGY:
-- - Analyzes last N sessions for peak DPS/HPS values
-- - Calculates appropriate scale using 95th percentile + 10% buffer
-- - Maintains separate scales per character/spec combination
-- - Provides manual override capability
-- - Adapts to player progression and gear improvements

local addonName, addon = ...

-- =============================================================================
-- COMBAT METER SCALER MODULE
-- =============================================================================

local MyCombatMeterScaler = {}
addon.MyCombatMeterScaler = MyCombatMeterScaler

-- =============================================================================
-- CONSTANTS AND CONFIGURATION
-- =============================================================================

local DEFAULT_CONFIG = {
    HISTORY_SESSION_COUNT = 10,     -- Number of recent sessions to analyze
    PERCENTILE_THRESHOLD = 0.95,    -- Use 95th percentile for scale calculation
    SCALE_BUFFER_PERCENT = 10,      -- Add 10% buffer above percentile
    MIN_SCALE = 100,                -- Minimum scale value
    MAX_SCALE = 1000000,            -- Maximum scale value (1M DPS/HPS)
    DEFAULT_SCALE = 1000,           -- Default scale for new characters
    MINIMUM_COMBAT_DURATION = 10,   -- Only use sessions longer than 10 seconds
    SCALE_DECAY_DAYS = 7,           -- Reduce scale weight for sessions older than 7 days
    AUTO_SCALE_ENABLED = true,      -- Whether to automatically update scales
    MANUAL_OVERRIDE_DURATION = 300, -- Manual overrides last 5 minutes
}

-- Scale storage structure
local scaleData = {
    characterScales = {},           -- Per-character/spec scales
    lastAnalysis = 0,               -- When we last analyzed sessions
    analysisCache = {},             -- Cached analysis results
    manualOverrides = {},           -- Manual scale overrides with timestamps
    globalSettings = {              -- Global scaler settings
        autoScaleEnabled = DEFAULT_CONFIG.AUTO_SCALE_ENABLED,
        historyCount = DEFAULT_CONFIG.HISTORY_SESSION_COUNT,
        scaleBuffer = DEFAULT_CONFIG.SCALE_BUFFER_PERCENT
    }
}

-- Current character/spec info
local currentCharacterKey = nil
local currentSpecName = nil

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

function MyCombatMeterScaler:Initialize()
    -- Get current character info
    self:UpdateCharacterInfo()
    
    -- Load saved scale data
    self:LoadScaleData()
    
    addon:Debug("MyCombatMeterScaler initialized for: %s", currentCharacterKey or "Unknown")
end

-- Update current character and spec information
function MyCombatMeterScaler:UpdateCharacterInfo()
    local playerName = UnitName("player")
    local realmName = GetRealmName()
    
    -- Get current spec
    local specIndex = GetSpecialization()
    local specName = "Unknown"
    
    if specIndex then
        local specID, name = GetSpecializationInfo(specIndex)
        if name then
            specName = name
        end
    end
    
    currentCharacterKey = string.format("%s-%s-%s", playerName, realmName, specName)
    currentSpecName = specName
    
    -- Initialize character scale data if not exists
    if not scaleData.characterScales[currentCharacterKey] then
        scaleData.characterScales[currentCharacterKey] = {
            dpsScale = DEFAULT_CONFIG.DEFAULT_SCALE,
            hpsScale = DEFAULT_CONFIG.DEFAULT_SCALE,
            lastUpdated = GetServerTime(),
            sessionCount = 0,
            peakValues = {
                dps = 0,
                hps = 0,
                timestamp = 0
            }
        }
    end
end

-- =============================================================================
-- SCALE CALCULATION FUNCTIONS
-- =============================================================================

-- Analyze recent sessions and calculate optimal scales
function MyCombatMeterScaler:AnalyzeSessionHistory()
    addon:Info("=== MyCombatMeterScaler: Starting session history analysis ===")
    
    if not addon.StorageManager then
        addon:Error("StorageManager not available for scale analysis")
        return nil
    end
    
    local recentSessions = addon.StorageManager:GetRecentSessions(scaleData.globalSettings.historyCount)
    addon:Info("MyCombatMeterScaler: Retrieved %d sessions from StorageManager", recentSessions and #recentSessions or 0)
    
    if not recentSessions or #recentSessions == 0 then
        addon:Warn("MyCombatMeterScaler: No sessions available for scale analysis")
        return nil
    end
    
    -- Load full session data (including events) for each session
    local sessions = {}
    for _, lightSession in ipairs(recentSessions) do
        local fullSession = addon.StorageManager:GetSession(lightSession.id)
        if fullSession then
            table.insert(sessions, fullSession)
            addon:Trace("MyCombatMeterScaler: Loaded full session %s with %d events", 
                fullSession.id, fullSession.eventCount or 0)
            addon:Trace("MyCombatMeterScaler: Full session has events field: %s, events type: %s", 
                fullSession.events and "YES" or "NO", type(fullSession.events))
            if fullSession.events then
                addon:Trace("MyCombatMeterScaler: Events array length: %d", #fullSession.events)
            end
        else
            addon:Warn("MyCombatMeterScaler: Failed to load full session for %s", lightSession.id)
        end
    end
    
    addon:Info("MyCombatMeterScaler: Loaded %d full sessions with event data", #sessions)
    
    local validSessions = self:FilterValidSessions(sessions)
    addon:Info("MyCombatMeterScaler: %d valid sessions after filtering (from %d total)", #validSessions, #sessions)
    
    if #validSessions == 0 then
        addon:Warn("MyCombatMeterScaler: No valid sessions found for scale analysis")
        return nil
    end
    
    local dpsValues = {}
    local hpsValues = {}
    
    -- Extract peak DPS/HPS values from each session
    addon:Info("MyCombatMeterScaler: Extracting DPS/HPS values from sessions...")
    for i, session in ipairs(validSessions) do
        addon:Trace("MyCombatMeterScaler: Processing session %d/%d - ID: %s, Duration: %.1fs, Events: %d", 
            i, #validSessions, session.id or "unknown", session.duration or 0, session.eventCount or 0)
        
        -- Compression disabled - events are stored directly
        addon:Trace("MyCombatMeterScaler: Session hasEvents=%s", tostring(session.events ~= nil))
            
        local peakDPS, peakHPS = self:ExtractSessionPeaks(session)
        
        if peakDPS > 0 then
            table.insert(dpsValues, peakDPS)
            addon:Trace("MyCombatMeterScaler: Session %d contributed DPS: %.0f", i, peakDPS)
        else
            addon:Trace("MyCombatMeterScaler: Session %d had no DPS data", i)
        end
        
        if peakHPS > 0 then
            table.insert(hpsValues, peakHPS)
            addon:Trace("MyCombatMeterScaler: Session %d contributed HPS: %.0f", i, peakHPS)
        end
    end
    
    addon:Info("MyCombatMeterScaler: Collected %d DPS values and %d HPS values", #dpsValues, #hpsValues)
    
    -- Calculate scales based on percentiles
    addon:Info("MyCombatMeterScaler: Calculating recommended scales...")
    local dpsScale = self:CalculateScaleFromValues(dpsValues)
    local hpsScale = self:CalculateScaleFromValues(hpsValues)
    
    local analysis = {
        sessionsAnalyzed = #validSessions,
        dpsValues = dpsValues,
        hpsValues = hpsValues,
        recommendedDPSScale = dpsScale,
        recommendedHPSScale = hpsScale,
        timestamp = GetServerTime()
    }
    
    -- Cache the analysis
    scaleData.analysisCache = analysis
    scaleData.lastAnalysis = GetServerTime()
    
    addon:Info("=== MyCombatMeterScaler: Analysis complete ===")
    addon:Info("  Recommended DPS Scale: %.0f", dpsScale)
    addon:Info("  Recommended HPS Scale: %.0f", hpsScale)
    addon:Info("  Based on %d sessions with %d DPS values", #validSessions, #dpsValues)
    
    return analysis
end

-- Filter sessions to only include valid ones for scaling
function MyCombatMeterScaler:FilterValidSessions(sessions)
    local validSessions = {}
    local cutoffTime = GetServerTime() - (DEFAULT_CONFIG.SCALE_DECAY_DAYS * 24 * 60 * 60)
    
    addon:Trace("MyCombatMeterScaler: Filtering sessions with criteria:")
    addon:Trace("  Minimum duration: %.1fs", DEFAULT_CONFIG.MINIMUM_COMBAT_DURATION)
    addon:Trace("  Maximum age: %d days", DEFAULT_CONFIG.SCALE_DECAY_DAYS)
    addon:Trace("  Cutoff timestamp: %d", cutoffTime)
    
    for i, session in ipairs(sessions) do
        -- Filter criteria
        local duration = session.duration or 0
        local serverTime = session.serverTime or 0
        local eventCount = session.eventCount or 0
        
        local isValidDuration = duration >= DEFAULT_CONFIG.MINIMUM_COMBAT_DURATION
        local isRecentEnough = serverTime >= cutoffTime
        local hasEvents = eventCount > 0
        
        addon:Trace("MyCombatMeterScaler: Session %d - Duration: %.1fs (%s), Age: %s (%s), Events: %d (%s)", 
            i, duration, isValidDuration and "PASS" or "FAIL",
            serverTime > 0 and string.format("%.1f days old", (GetServerTime() - serverTime) / (24 * 60 * 60)) or "unknown",
            isRecentEnough and "PASS" or "FAIL",
            eventCount, hasEvents and "PASS" or "FAIL")
        
        if isValidDuration and isRecentEnough and hasEvents then
            table.insert(validSessions, session)
            addon:Trace("MyCombatMeterScaler: Session %d ACCEPTED", i)
        else
            addon:Trace("MyCombatMeterScaler: Session %d REJECTED", i)
        end
    end
    
    addon:Debug("MyCombatMeterScaler: Filtering complete - %d/%d sessions passed", #validSessions, #sessions)
    return validSessions
end

-- Extract peak DPS/HPS values from a session
function MyCombatMeterScaler:ExtractSessionPeaks(session)
    local duration = session.duration or 1
    local totalDamage = 0
    local totalHealing = 0
    local eventCount = 0
    local damageEvents = 0
    local playerGUID = UnitGUID("player")
    local uniqueSourceGUIDs = {}
    
    addon:Trace("MyCombatMeterScaler: Looking for events from player GUID: %s", tostring(playerGUID))
    
    addon:Trace("MyCombatMeterScaler: ExtractSessionPeaks - Session ID: %s", tostring(session.id))
    addon:Trace("MyCombatMeterScaler: Session has events field: %s", session.events and "YES" or "NO")
    
    -- Try to get actual damage/healing totals if available
    if session.events then
        eventCount = #session.events
        addon:Trace("MyCombatMeterScaler: Session contains %d events", eventCount)
        
        if eventCount == 0 then
            addon:Trace("MyCombatMeterScaler: Session has events table but it's empty")
        else
            -- Show structure of first few events
            -- Removed detailed event structure logging to prevent hangs
            -- Just log a summary instead
            addon:Debug("MyCombatMeterScaler: Session has %d events, examining for player damage...", eventCount)
            
            -- Try to parse events
            for i, event in ipairs(session.events) do
                if type(event) == "table" then
                    -- WoW Combat Log event structure
                    local subevent = event.subevent
                    local sourceGUID = event.sourceGUID
                    local args = event.args
                    
                    -- Track unique source GUIDs for debugging
                    if sourceGUID and not uniqueSourceGUIDs[sourceGUID] then
                        uniqueSourceGUIDs[sourceGUID] = true
                    end
                    
                    if i <= 5 then -- Debug first few events
                        addon:Debug("MyCombatMeterScaler: Event %d - subevent: %s, sourceGUID: %s, hasArgs: %s", 
                            i, tostring(subevent), tostring(sourceGUID), args and "YES" or "NO")
                        addon:Debug("MyCombatMeterScaler: Event %d - GUID match: %s (player: %s)", 
                            i, sourceGUID == playerGUID and "YES" or "NO", tostring(playerGUID))
                    end
                    
                    if subevent and sourceGUID == playerGUID and args then
                        -- Extract amount from args table based on event type
                        local amount = nil
                        
                        if subevent:find("_DAMAGE") then
                            -- Extract damage amount based on specific event type
                            if subevent == "SWING_DAMAGE" then
                                -- For swing damage: args[1] is damage amount (parameter 12 in original)
                                amount = type(args[1]) == "number" and args[1] or nil
                            elseif subevent == "SPELL_DAMAGE" or subevent == "RANGE_DAMAGE" or subevent == "SPELL_PERIODIC_DAMAGE" then
                                -- For spell damage: args[4] is damage amount (parameter 15 in original)
                                -- args[1]=spellId, args[2]=spellName, args[3]=spellSchool, args[4]=amount
                                amount = type(args[4]) == "number" and args[4] or nil
                            else
                                -- For other damage types, try args[4] first, then fallback to search
                                local val1 = type(args[4]) == "number" and args[4] or nil
                                local val2 = type(args[1]) == "number" and args[1] or nil
                                amount = val1 or val2
                                if not amount then
                                    for j = 1, 6 do
                                        if args[j] and type(args[j]) == "number" and args[j] > 0 then
                                            amount = args[j]
                                            break
                                        end
                                    end
                                end
                            end
                        elseif subevent:find("_HEAL") then
                            -- For heal events, damage amount pattern usually applies
                            if subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL" then
                                -- Similar to spell damage structure
                                amount = type(args[4]) == "number" and args[4] or nil
                            else
                                -- Fallback search for heal events
                                for j = 1, 6 do
                                    if args[j] and type(args[j]) == "number" and args[j] > 0 then
                                        amount = args[j]
                                        break
                                    end
                                end
                            end
                        end
                        
                        if amount and type(amount) == "number" and amount > 0 then
                            if subevent:find("_DAMAGE") then
                                totalDamage = totalDamage + amount
                                damageEvents = damageEvents + 1
                                if damageEvents <= 5 then -- Debug first few
                                    addon:Trace("MyCombatMeterScaler: Found damage event: %.0f (%s)", amount, subevent)
                                end
                            elseif subevent:find("_HEAL") then
                                totalHealing = totalHealing + amount
                                addon:Trace("MyCombatMeterScaler: Found healing event: %.0f (%s)", amount, subevent)
                            end
                        end
                    end
                end
            end
        end
    else
        addon:Trace("MyCombatMeterScaler: Session has no events field")
    end
    
    -- Debug logging
    addon:Trace("MyCombatMeterScaler: Session analysis - Duration: %.1fs, Events: %d, Damage events: %d, Total damage: %.0f", 
        duration, eventCount, damageEvents, totalDamage)
    
    -- Show sample of source GUIDs encountered for debugging
    if next(uniqueSourceGUIDs) then
        local guidCount = 0
        addon:Trace("MyCombatMeterScaler: Sample source GUIDs encountered:")
        for guid, _ in pairs(uniqueSourceGUIDs) do
            guidCount = guidCount + 1
            if guidCount <= 5 then
                addon:Trace("  %s", tostring(guid))
            end
        end
        addon:Trace("MyCombatMeterScaler: Total unique source GUIDs: %d", guidCount)
    end
    
    -- If we found damage data, calculate peak
    if damageEvents > 0 then
        local avgDPS = totalDamage / duration
        local peakDPS = avgDPS * 1.5  -- Estimate peak as 150% of average
        local avgHPS = totalHealing / duration
        local peakHPS = avgHPS * 1.5
        
        addon:Trace("MyCombatMeterScaler: Calculated from events - Avg DPS: %.0f, Peak DPS: %.0f", avgDPS, peakDPS)
        return peakDPS, peakHPS
    else
        -- If no event data found, return 0 (will use default scale)
        addon:Trace("MyCombatMeterScaler: No damage events found in session")
        return 0, 0
    end
end

-- Calculate scale from a set of values using percentile + buffer
function MyCombatMeterScaler:CalculateScaleFromValues(values)
    if not values or #values == 0 then
        addon:Debug("MyCombatMeterScaler: No values for scale calculation, using default: %d", DEFAULT_CONFIG.DEFAULT_SCALE)
        return DEFAULT_CONFIG.DEFAULT_SCALE
    end
    
    -- Sort values
    table.sort(values)
    
    -- Debug: Show the values being used
    addon:Trace("MyCombatMeterScaler: Scale calculation from %d values", #values)
    if #values <= 10 then
        addon:Trace("MyCombatMeterScaler: Values: %s", table.concat(values, ", "))
    else
        addon:Trace("MyCombatMeterScaler: Values range: %.0f - %.0f", values[1], values[#values])
    end
    
    -- Calculate percentile index
    local percentileIndex = math.ceil(#values * DEFAULT_CONFIG.PERCENTILE_THRESHOLD)
    percentileIndex = math.max(1, math.min(percentileIndex, #values))
    
    local percentileValue = values[percentileIndex]
    
    -- Add buffer
    local bufferMultiplier = 1 + (scaleData.globalSettings.scaleBuffer / 100)
    local scale = percentileValue * bufferMultiplier
    
    addon:Trace("MyCombatMeterScaler: Percentile value (95th): %.0f, Buffer: %.1f%%, Raw scale: %.0f", 
        percentileValue, scaleData.globalSettings.scaleBuffer, scale)
    
    -- Apply bounds
    scale = math.max(DEFAULT_CONFIG.MIN_SCALE, math.min(DEFAULT_CONFIG.MAX_SCALE, scale))
    
    -- Round to clean values for better UX
    scale = self:RoundToCleanScale(scale)
    
    addon:Trace("MyCombatMeterScaler: Final scale after bounds and rounding: %.0f", scale)
    
    return scale
end

-- Round scale to clean, user-friendly values
function MyCombatMeterScaler:RoundToCleanScale(rawScale)
    -- Define clean scale steps for different ranges
    local cleanSteps = {
        -- Under 10K: round to nearest 1K
        {threshold = 10000, step = 1000},
        -- 10K-100K: round to nearest 5K  
        {threshold = 100000, step = 5000},
        -- 100K-500K: round to nearest 25K
        {threshold = 500000, step = 25000},
        -- 500K-1M: round to nearest 50K
        {threshold = 1000000, step = 50000},
        -- 1M-5M: round to nearest 100K
        {threshold = 5000000, step = 100000},
        -- Above 5M: round to nearest 250K
        {threshold = math.huge, step = 250000}
    }
    
    -- Find appropriate step size
    local step = 1000 -- default
    for _, range in ipairs(cleanSteps) do
        if rawScale <= range.threshold then
            step = range.step
            break
        end
    end
    
    -- Round to nearest step
    local rounded = math.floor((rawScale + step/2) / step) * step
    
    addon:Trace("MyCombatMeterScaler: Rounded %.0f to clean value %.0f (step: %.0f)", rawScale, rounded, step)
    
    return rounded
end

-- =============================================================================
-- SCALE MANAGEMENT
-- =============================================================================

-- Get current scales for the character/spec
function MyCombatMeterScaler:GetCurrentScales()
    if not currentCharacterKey then
        self:UpdateCharacterInfo()
    end
    
    addon:Debug("MyCombatMeterScaler: Getting scales for key: %s", currentCharacterKey or "nil")
    
    local characterData = scaleData.characterScales[currentCharacterKey]
    if not characterData then
        addon:Debug("MyCombatMeterScaler: No character data found, returning default scale: %d", DEFAULT_CONFIG.DEFAULT_SCALE)
        return DEFAULT_CONFIG.DEFAULT_SCALE, DEFAULT_CONFIG.DEFAULT_SCALE
    end
    
    -- Check for manual overrides
    local now = GetServerTime()
    local manualOverride = scaleData.manualOverrides[currentCharacterKey]
    
    if manualOverride and (now - manualOverride.timestamp) < DEFAULT_CONFIG.MANUAL_OVERRIDE_DURATION then
        return manualOverride.dpsScale, manualOverride.hpsScale
    end
    
    addon:Debug("MyCombatMeterScaler: GetCurrentScales returning DPS=%.0f, HPS=%.0f", 
        characterData.dpsScale, characterData.hpsScale)
    return characterData.dpsScale, characterData.hpsScale
end

-- Update scales based on analysis
function MyCombatMeterScaler:UpdateScales(analysis)
    if not analysis or not currentCharacterKey then
        return false
    end
    
    -- Ensure character data exists - create if needed
    local characterData = scaleData.characterScales[currentCharacterKey]
    if not characterData then
        addon:Debug("MyCombatMeterScaler: Creating character data for %s", currentCharacterKey)
        self:UpdateCharacterInfo() -- This creates the character data
        characterData = scaleData.characterScales[currentCharacterKey]
        if not characterData then
            addon:Error("MyCombatMeterScaler: Failed to create character data for %s", currentCharacterKey)
            return false
        end
    end
    
    -- Update scales
    addon:Debug("MyCombatMeterScaler: UpdateScales - Setting DPS scale to %.0f (was %.0f)", 
        analysis.recommendedDPSScale, characterData.dpsScale)
    characterData.dpsScale = analysis.recommendedDPSScale
    characterData.hpsScale = analysis.recommendedHPSScale
    characterData.lastUpdated = GetServerTime()
    characterData.sessionCount = analysis.sessionsAnalyzed
    
    -- Update peak tracking
    if #analysis.dpsValues > 0 then
        characterData.peakValues.dps = math.max(unpack(analysis.dpsValues))
    end
    if #analysis.hpsValues > 0 then
        characterData.peakValues.hps = math.max(unpack(analysis.hpsValues))
    end
    characterData.peakValues.timestamp = GetServerTime()
    
    -- Save to persistent storage
    self:SaveScaleData()
    
    addon:Debug("Scales updated for %s: DPS=%.0f, HPS=%.0f", 
        currentCharacterKey, characterData.dpsScale, characterData.hpsScale)
    
    -- Publish scale update to UI event queue
    self:PublishScaleUpdate(characterData.dpsScale, characterData.hpsScale)
    
    return true
end

-- Set manual scale override
function MyCombatMeterScaler:SetManualScale(dpsScale, hpsScale)
    if not currentCharacterKey then
        self:UpdateCharacterInfo()
    end
    
    -- Validate inputs
    dpsScale = math.max(DEFAULT_CONFIG.MIN_SCALE, math.min(DEFAULT_CONFIG.MAX_SCALE, dpsScale or DEFAULT_CONFIG.DEFAULT_SCALE))
    hpsScale = math.max(DEFAULT_CONFIG.MIN_SCALE, math.min(DEFAULT_CONFIG.MAX_SCALE, hpsScale or DEFAULT_CONFIG.DEFAULT_SCALE))
    
    scaleData.manualOverrides[currentCharacterKey] = {
        dpsScale = dpsScale,
        hpsScale = hpsScale,
        timestamp = GetServerTime()
    }
    
    addon:Debug("Manual scale override set: DPS=%.0f, HPS=%.0f", dpsScale, hpsScale)
    return true
end

-- Clear manual scale override
function MyCombatMeterScaler:ClearManualScale()
    if currentCharacterKey and scaleData.manualOverrides[currentCharacterKey] then
        scaleData.manualOverrides[currentCharacterKey] = nil
        addon:Debug("Manual scale override cleared")
        return true
    end
    return false
end

-- =============================================================================
-- AUTO-SCALING FUNCTIONS
-- =============================================================================

-- Automatically update scales after combat ends
function MyCombatMeterScaler:AutoUpdateAfterCombat(sessionData)
    if not scaleData.globalSettings.autoScaleEnabled then
        return false
    end
    
    if not sessionData or (sessionData.duration or 0) < DEFAULT_CONFIG.MINIMUM_COMBAT_DURATION then
        return false
    end
    
    addon:Info("MyCombatMeterScaler: AutoUpdateAfterCombat - Fresh session data: Peak DPS: %.0f", sessionData.peakDPS or 0)
    
    -- Try historical analysis first
    local analysis = self:AnalyzeSessionHistory()
    
    -- If historical analysis fails or returns poor data, use fresh session data
    if not analysis or analysis.recommendedDPSScale <= DEFAULT_CONFIG.DEFAULT_SCALE then
        addon:Info("MyCombatMeterScaler: Historical analysis failed/inadequate, using fresh session data")
        
        if sessionData.peakDPS and sessionData.peakDPS > 0 then
            -- Create artificial analysis using current session
            local sessionScale = sessionData.peakDPS * 1.3  -- 30% buffer
            
            analysis = {
                sessionsAnalyzed = 1,
                dpsValues = {sessionData.peakDPS},
                hpsValues = {},
                recommendedDPSScale = sessionScale,
                recommendedHPSScale = DEFAULT_CONFIG.DEFAULT_SCALE,
                timestamp = GetServerTime(),
                source = "fresh_session"  -- Mark as coming from fresh data
            }
            
            addon:Info("MyCombatMeterScaler: Created analysis from fresh session - Peak: %.0f, Scale: %.0f", 
                sessionData.peakDPS, sessionScale)
        end
    else
        addon:Info("MyCombatMeterScaler: Using historical analysis - Scale: %.0f", analysis.recommendedDPSScale)
    end
    
    if analysis then
        return self:UpdateScales(analysis)
    end
    
    return false
end

-- Check if scales need updating based on recent performance
function MyCombatMeterScaler:CheckScaleRelevance(currentDPS, currentHPS)
    local dpsScale, hpsScale = self:GetCurrentScales()
    
    -- If current values consistently exceed scale, we might need to update
    local dpsRatio = dpsScale > 0 and (currentDPS / dpsScale) or 0
    local hpsRatio = hpsScale > 0 and (currentHPS / hpsScale) or 0
    
    local scaleNeedsUpdate = false
    local reasons = {}
    
    if dpsRatio > 1.2 then -- Exceeding scale by 20%
        scaleNeedsUpdate = true
        table.insert(reasons, string.format("DPS exceeds scale by %.0f%%", (dpsRatio - 1) * 100))
    end
    
    if hpsRatio > 1.2 then -- Exceeding scale by 20%
        scaleNeedsUpdate = true
        table.insert(reasons, string.format("HPS exceeds scale by %.0f%%", (hpsRatio - 1) * 100))
    end
    
    return scaleNeedsUpdate, reasons
end

-- =============================================================================
-- PERSISTENT STORAGE
-- =============================================================================

-- Save scale data to SavedVariables
function MyCombatMeterScaler:SaveScaleData()
    if not MyUIDB then
        MyUIDB = {}
    end
    
    MyUIDB.combatMeterScales = scaleData
    
    -- Note: Silent save to avoid spam
end

-- Load scale data from SavedVariables
function MyCombatMeterScaler:LoadScaleData()
    if MyUIDB and MyUIDB.combatMeterScales then
        local savedData = MyUIDB.combatMeterScales
        
        -- Merge saved data with defaults
        scaleData.characterScales = savedData.characterScales or {}
        scaleData.lastAnalysis = savedData.lastAnalysis or 0
        scaleData.manualOverrides = savedData.manualOverrides or {}
        
        if savedData.globalSettings then
            for k, v in pairs(savedData.globalSettings) do
                scaleData.globalSettings[k] = v
            end
        end
        
        addon:Debug("Scale data loaded from SavedVariables")
    else
        addon:Debug("No saved scale data found, using defaults")
    end
end

-- =============================================================================
-- UI EVENT PUBLISHING
-- =============================================================================

-- Publish scale update to UI subscribers
function MyCombatMeterScaler:PublishScaleUpdate(dpsScale, hpsScale)
    if addon.UIEventQueue then
        addon.UIEventQueue:Push("SCALE_UPDATE", {
            dpsScale = dpsScale,
            hpsScale = hpsScale,
            character = currentCharacterKey,
            timestamp = GetServerTime()
        })
        addon:Debug("MyCombatMeterScaler: Published scale update - DPS: %.0f, HPS: %.0f", dpsScale, hpsScale)
    else
        addon:Debug("MyCombatMeterScaler: UIEventQueue not available for scale update")
    end
end

-- Request current scale for new subscribers
function MyCombatMeterScaler:RequestCurrentScale()
    -- Ensure we're initialized first
    if not currentCharacterKey then
        self:UpdateCharacterInfo()
    end
    
    local dpsScale, hpsScale = self:GetCurrentScales()
    addon:Debug("MyCombatMeterScaler: RequestCurrentScale returning DPS=%.0f, HPS=%.0f", dpsScale, hpsScale)
    
    -- If we only have default values, try to run an analysis to get real values
    if dpsScale == DEFAULT_CONFIG.DEFAULT_SCALE then
        addon:Debug("MyCombatMeterScaler: Default scale detected, attempting analysis...")
        local analysis = self:AnalyzeSessionHistory()
        if analysis then
            self:UpdateScales(analysis)
            dpsScale, hpsScale = self:GetCurrentScales()
            addon:Debug("MyCombatMeterScaler: After analysis - DPS=%.0f, HPS=%.0f", dpsScale, hpsScale)
        end
    end
    
    self:PublishScaleUpdate(dpsScale, hpsScale)
end

-- =============================================================================
-- CONFIGURATION AND SETTINGS
-- =============================================================================

function MyCombatMeterScaler:SetAutoScaleEnabled(enabled)
    scaleData.globalSettings.autoScaleEnabled = enabled
    self:SaveScaleData()
    addon:Debug("Auto-scaling %s", enabled and "enabled" or "disabled")
end

function MyCombatMeterScaler:IsAutoScaleEnabled()
    return scaleData.globalSettings.autoScaleEnabled
end

function MyCombatMeterScaler:SetHistorySessionCount(count)
    scaleData.globalSettings.historyCount = math.max(5, math.min(25, count))
    self:SaveScaleData()
    addon:Debug("History session count set to: %d", scaleData.globalSettings.historyCount)
end

function MyCombatMeterScaler:GetHistorySessionCount()
    return scaleData.globalSettings.historyCount
end

function MyCombatMeterScaler:SetScaleBuffer(percent)
    scaleData.globalSettings.scaleBuffer = math.max(0, math.min(50, percent))
    self:SaveScaleData()
    addon:Debug("Scale buffer set to: %.0f%%", scaleData.globalSettings.scaleBuffer)
end

function MyCombatMeterScaler:GetScaleBuffer()
    return scaleData.globalSettings.scaleBuffer
end

-- =============================================================================
-- ANALYSIS AND REPORTING
-- =============================================================================

-- Generate scale analysis report
function MyCombatMeterScaler:GenerateScaleReport()
    local analysis = scaleData.analysisCache
    local dpsScale, hpsScale = self:GetCurrentScales()
    
    local lines = {}
    table.insert(lines, "=== Combat Meter Scale Analysis ===")
    table.insert(lines, string.format("Character: %s", currentCharacterKey or "Unknown"))
    table.insert(lines, string.format("Spec: %s", currentSpecName or "Unknown"))
    table.insert(lines, "")
    
    table.insert(lines, "Current Scales:")
    table.insert(lines, string.format("  DPS Scale: %.0f", dpsScale))
    table.insert(lines, string.format("  HPS Scale: %.0f", hpsScale))
    table.insert(lines, "")
    
    -- Manual override info
    local manualOverride = scaleData.manualOverrides[currentCharacterKey]
    if manualOverride then
        local timeRemaining = DEFAULT_CONFIG.MANUAL_OVERRIDE_DURATION - (GetServerTime() - manualOverride.timestamp)
        if timeRemaining > 0 then
            table.insert(lines, string.format("Manual Override Active: %.0f seconds remaining", timeRemaining))
        end
    end
    
    -- Analysis info
    if analysis then
        table.insert(lines, "Recent Analysis:")
        table.insert(lines, string.format("  Sessions Analyzed: %d", analysis.sessionsAnalyzed))
        table.insert(lines, string.format("  Recommended DPS Scale: %.0f", analysis.recommendedDPSScale))
        table.insert(lines, string.format("  Recommended HPS Scale: %.0f", analysis.recommendedHPSScale))
        table.insert(lines, string.format("  Analysis Time: %s", date("%Y-%m-%d %H:%M:%S", analysis.timestamp)))
        
        if #analysis.dpsValues > 0 then
            table.sort(analysis.dpsValues)
            table.insert(lines, string.format("  DPS Range: %.0f - %.0f (median: %.0f)", 
                analysis.dpsValues[1], 
                analysis.dpsValues[#analysis.dpsValues],
                analysis.dpsValues[math.ceil(#analysis.dpsValues / 2)]))
        end
        
        if #analysis.hpsValues > 0 then
            table.sort(analysis.hpsValues)
            table.insert(lines, string.format("  HPS Range: %.0f - %.0f (median: %.0f)", 
                analysis.hpsValues[1], 
                analysis.hpsValues[#analysis.hpsValues],
                analysis.hpsValues[math.ceil(#analysis.hpsValues / 2)]))
        end
    else
        table.insert(lines, "No recent analysis available")
    end
    
    table.insert(lines, "")
    table.insert(lines, "Settings:")
    table.insert(lines, string.format("  Auto-Scale: %s", scaleData.globalSettings.autoScaleEnabled and "Enabled" or "Disabled"))
    table.insert(lines, string.format("  History Sessions: %d", scaleData.globalSettings.historyCount))
    table.insert(lines, string.format("  Scale Buffer: %.0f%%", scaleData.globalSettings.scaleBuffer))
    
    return table.concat(lines, "\n")
end

-- Get status information
function MyCombatMeterScaler:GetStatus()
    local dpsScale, hpsScale = self:GetCurrentScales()
    local hasManualOverride = scaleData.manualOverrides[currentCharacterKey] ~= nil
    
    return {
        currentCharacter = currentCharacterKey,
        currentSpec = currentSpecName,
        dpsScale = dpsScale,
        hpsScale = hpsScale,
        autoScaleEnabled = scaleData.globalSettings.autoScaleEnabled,
        hasManualOverride = hasManualOverride,
        lastAnalysis = scaleData.lastAnalysis,
        historySessionCount = scaleData.globalSettings.historyCount,
        scaleBuffer = scaleData.globalSettings.scaleBuffer
    }
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

-- Force immediate scale analysis and update
function MyCombatMeterScaler:ForceScaleUpdate()
    local analysis = self:AnalyzeSessionHistory()
    if analysis then
        self:UpdateScales(analysis)
        return analysis
    end
    return nil
end

-- Get recommended scales without updating current scales
function MyCombatMeterScaler:GetRecommendedScales()
    local analysis = self:AnalyzeSessionHistory()
    if analysis then
        return analysis.recommendedDPSScale, analysis.recommendedHPSScale
    end
    return nil, nil
end

return MyCombatMeterScaler