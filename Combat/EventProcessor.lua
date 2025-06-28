-- EventProcessor.lua
-- Zero-allocation combat event processing with aggressive filtering
-- This is the hot path - every optimization matters

local addonName, addon = ...

-- =============================================================================
-- EVENT PROCESSOR MODULE
-- =============================================================================

addon.EventProcessor = {}
local EventProcessor = addon.EventProcessor

-- Constants will be loaded after this module loads
local Constants = nil
local IGNORED_EVENTS = nil
local TRACKABLE_EVENTS = nil
local CONTROL_MASKS = nil
local HasFlag = nil
local IsPlayerControlled = nil

-- Initialize constants cache (called after Constants module loads)
local function CacheConstants()
    if addon.Constants then
        Constants = addon.Constants
        IGNORED_EVENTS = Constants.IGNORED_EVENTS
        TRACKABLE_EVENTS = Constants.TRACKABLE_EVENTS
        CONTROL_MASKS = Constants.CONTROL_MASKS
        HasFlag = Constants.HasFlag
        IsPlayerControlled = Constants.IsPlayerControlled
    end
end

-- Pre-cached player data (updated on login/pet changes)
local playerCache = {
    guid = nil,
    name = nil,
    pets = {} -- [guid] = true for fast lookup
}

-- Event processing state (mutable in place, never allocates)
local processingState = {
    totalEvents = 0,
    processedEvents = 0,
    ignoredEvents = 0,
    playerDamageEvents = 0,
    petDamageEvents = 0,
    lastEventTime = 0
}

-- Circuit breaker state with adaptive limits
local circuitBreaker = {
    eventsThisFrame = 0,
    maxEventsPerFrame = 30,  -- Higher default limit
    frameNumber = 0,
    tripped = false,
    lastWarning = 0,
    
    -- Adaptive scaling
    baseLimit = 25,          -- Solo/normal content (increased)
    raidLimit = 40,          -- Raid content  
    mythicLimit = 50,        -- Mythic+ content
    currentMode = "auto",    -- auto, solo, raid, mythic
    
    -- Performance tracking
    recentFrameLoads = {},   -- Track recent frame event counts
    adaptiveEnabled = true
}

-- Update circuit breaker limits (called after Constants are loaded)
local function UpdateCircuitBreaker()
    if Constants and Constants.PERFORMANCE and Constants.PERFORMANCE.MAX_EVENTS_PER_FRAME then
        circuitBreaker.baseLimit = Constants.PERFORMANCE.MAX_EVENTS_PER_FRAME
        print(string.format("[STORMY] Circuit breaker base limit updated to %d", Constants.PERFORMANCE.MAX_EVENTS_PER_FRAME))
    end
    -- UpdateAdaptiveLimit will be called separately after it's defined
end

-- Detect content type and adjust circuit breaker limit
local function UpdateAdaptiveLimit()
    if not circuitBreaker.adaptiveEnabled or circuitBreaker.currentMode ~= "auto" then
        return
    end
    
    local playerCount = GetNumGroupMembers()
    local inInstance, instanceType = IsInInstance()
    local difficulty = select(3, GetInstanceInfo())
    
    local newLimit = circuitBreaker.baseLimit
    local detectedMode = "solo"
    
    if inInstance then
        if instanceType == "raid" then
            newLimit = circuitBreaker.raidLimit
            detectedMode = "raid"
        elseif instanceType == "party" then
            -- Detect mythic+ by difficulty or keystone
            if difficulty and difficulty >= 23 then -- Mythic difficulty
                newLimit = circuitBreaker.mythicLimit  
                detectedMode = "mythic+"
            else
                newLimit = circuitBreaker.baseLimit + 10 -- Normal dungeon
                detectedMode = "dungeon"
            end
        end
    elseif playerCount > 5 then
        -- Large group outside instance (world bosses, etc)
        newLimit = circuitBreaker.raidLimit
        detectedMode = "group"
    end
    
    if newLimit ~= circuitBreaker.maxEventsPerFrame then
        circuitBreaker.maxEventsPerFrame = newLimit
        print(string.format("[STORMY] Adaptive limit: %s mode, %d events/frame", detectedMode, newLimit))
    end
end

-- =============================================================================
-- CORE EVENT PROCESSING
-- =============================================================================

-- Main event processor - called by COMBAT_LOG_EVENT_UNFILTERED
function EventProcessor:ProcessEvent(...)
    processingState.totalEvents = processingState.totalEvents + 1
    
    -- Circuit breaker check (use time-based frame detection)
    local currentTime = GetTime()
    local currentFrame = math.floor(currentTime * 60) -- Approximate frame at 60fps
    if currentFrame ~= circuitBreaker.frameNumber then
        circuitBreaker.frameNumber = currentFrame
        circuitBreaker.eventsThisFrame = 0
        circuitBreaker.tripped = false
        
        -- Update adaptive limit periodically (every ~20 frames = ~0.33s)
        if currentFrame % 20 == 0 then
            UpdateAdaptiveLimit()
        end
    end
    
    circuitBreaker.eventsThisFrame = circuitBreaker.eventsThisFrame + 1
    if circuitBreaker.eventsThisFrame > circuitBreaker.maxEventsPerFrame then
        if not circuitBreaker.tripped then
            circuitBreaker.tripped = true
            -- Only print warning once per second to avoid spam with stats
            local now = GetTime()
            if not circuitBreaker.lastWarning or now - circuitBreaker.lastWarning > 3.0 then
                print(string.format("[STORMY] Circuit breaker: %d events/frame (limit: %d) - Recent events:", 
                    circuitBreaker.eventsThisFrame, circuitBreaker.maxEventsPerFrame))
                
                -- Debug: Show what events are causing the overload
                local timestamp, eventType = ...
                print(string.format("  Last event: %s", eventType or "unknown"))
                circuitBreaker.lastWarning = now
            end
        end
        return -- Drop events when overwhelmed
    end
    
    -- Extract combat log data (zero allocation)
    local timestamp, eventType, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
          destGUID, destName, destFlags, destRaidFlags, spellId, spellName, spellSchool,
          amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing, isOffHand = ...
    
    processingState.lastEventTime = GetTime()
    
    -- Ensure constants are loaded
    if not Constants then
        CacheConstants()
    end
    
    -- STEP 1: Quick exit for ignored events (fastest possible path)
    if IGNORED_EVENTS and IGNORED_EVENTS[eventType] then
        processingState.ignoredEvents = processingState.ignoredEvents + 1
        return
    end
    
    -- STEP 2: Check if this is a trackable event
    local eventCategory = TRACKABLE_EVENTS and TRACKABLE_EVENTS[eventType]
    if not eventCategory then
        processingState.ignoredEvents = processingState.ignoredEvents + 1
        return
    end
    
    -- STEP 3: Check if source is player-controlled (bitwise operation)
    if IsPlayerControlled and not IsPlayerControlled(sourceFlags) then
        processingState.ignoredEvents = processingState.ignoredEvents + 1
        return
    end
    
    -- STEP 4: Check if source is player-controlled (use EntityTracker if available)
    local isPlayer, isPet = false, false
    
    if addon.EntityTracker then
        isPlayer = addon.EntityTracker:IsPlayer(sourceGUID)
        isPet = addon.EntityTracker:IsPet(sourceGUID)
        
        if not isPlayer and not isPet then
            processingState.ignoredEvents = processingState.ignoredEvents + 1
            return
        end
        
        -- Update last seen time for entity tracking
        addon.EntityTracker:UpdateLastSeen(sourceGUID)
    else
        -- Fallback to simple cache - ensure player GUID is set
        if not playerCache.guid then
            self:UpdatePlayerGUID()
        end
        
        isPlayer = (sourceGUID == playerCache.guid)
        isPet = playerCache.pets[sourceGUID] == true
        
        if not isPlayer and not isPet then
            processingState.ignoredEvents = processingState.ignoredEvents + 1
            return
        end
    end
    
    -- STEP 5: Validate amount (damage/healing must have meaningful value)
    if not amount or amount <= 0 then
        processingState.ignoredEvents = processingState.ignoredEvents + 1
        return
    end
    
    -- STEP 6: Track performance and timing
    addon.TimingManager:TrackEvent()
    processingState.processedEvents = processingState.processedEvents + 1
    
    if isPlayer then
        processingState.playerDamageEvents = processingState.playerDamageEvents + 1
    else
        processingState.petDamageEvents = processingState.petDamageEvents + 1
    end
    
    -- STEP 7: Route to appropriate handler (still zero allocation)
    if eventCategory == "damage" then
        self:ProcessDamageEvent(timestamp, sourceGUID, destGUID, spellId, amount, 
                               critical, isPlayer, isPet)
    elseif eventCategory == "healing" then
        self:ProcessHealingEvent(timestamp, sourceGUID, destGUID, spellId, amount, 
                                critical, isPlayer, isPet)
    end
end

-- Process damage event (zero allocation)
function EventProcessor:ProcessDamageEvent(timestamp, sourceGUID, destGUID, spellId, amount, 
                                          critical, isPlayer, isPet)
    -- Convert timestamp to relative time
    local relativeTime = addon.TimingManager:GetRelativeTime(timestamp)
    
    -- Dispatch to damage accumulator (no table creation)
    addon.DamageAccumulator:AddDamage(relativeTime, sourceGUID, amount, isPlayer, isPet)
    
    -- Dispatch event via event bus (creates minimal event object)
    addon.EventBus:DispatchDamage({
        sourceGUID = sourceGUID,
        amount = amount,
        spellId = spellId,
        critical = critical,
        isPlayer = isPlayer,
        isPet = isPet,
        timestamp = relativeTime
    })
end

-- Process healing event (zero allocation)
function EventProcessor:ProcessHealingEvent(timestamp, sourceGUID, destGUID, spellId, amount, 
                                           critical, isPlayer, isPet)
    -- Convert timestamp to relative time
    local relativeTime = addon.TimingManager:GetRelativeTime(timestamp)
    
    -- Dispatch to healing accumulator (if we add healing tracking later)
    -- For now, just track as damage for DPS meters
    addon.DamageAccumulator:AddHealing(relativeTime, sourceGUID, amount, isPlayer, isPet)
    
    -- Dispatch event via event bus
    addon.EventBus:DispatchHealing({
        sourceGUID = sourceGUID,
        amount = amount,
        spellId = spellId,
        critical = critical,
        isPlayer = isPlayer,
        isPet = isPet,
        timestamp = relativeTime
    })
end

-- =============================================================================
-- PLAYER CACHE MANAGEMENT
-- =============================================================================

-- Update player GUID (called on login, spec change, etc.)
function EventProcessor:UpdatePlayerGUID()
    local newGUID = UnitGUID("player")
    local newName = UnitName("player")
    
    if newGUID ~= playerCache.guid then
        playerCache.guid = newGUID
        playerCache.name = newName
        
        -- Clear pet cache when player changes
        playerCache.pets = {}
        
        print(string.format("[STORMY] Player updated: %s (%s)", newName, newGUID))
    end
end

-- Add pet to tracking
function EventProcessor:AddPet(petGUID, petName)
    if petGUID and petGUID ~= "" then
        playerCache.pets[petGUID] = true
        
        -- Dispatch pet detected event
        addon.EventBus:DispatchPetDetected({
            guid = petGUID,
            name = petName,
            timestamp = GetTime()
        })
        
        print(string.format("[STORMY] Pet detected: %s (%s)", petName or "Unknown", petGUID))
    end
end

-- Remove pet from tracking
function EventProcessor:RemovePet(petGUID)
    if petGUID and playerCache.pets[petGUID] then
        playerCache.pets[petGUID] = nil
        print(string.format("[STORMY] Pet removed: %s", petGUID))
    end
end

-- Clear all pets
function EventProcessor:ClearPets()
    local petCount = 0
    for _ in pairs(playerCache.pets) do
        petCount = petCount + 1
    end
    
    playerCache.pets = {}
    
    if petCount > 0 then
        print(string.format("[STORMY] Cleared %d pets", petCount))
    end
end

-- Get current pets (for debugging)
function EventProcessor:GetTrackedPets()
    local pets = {}
    for guid in pairs(playerCache.pets) do
        table.insert(pets, guid)
    end
    return pets
end

-- =============================================================================
-- MONITORING AND DEBUGGING
-- =============================================================================

-- Get processing statistics
function EventProcessor:GetStats()
    local processedPercent = processingState.totalEvents > 0 and 
                           (processingState.processedEvents / processingState.totalEvents * 100) or 0
    local ignoredPercent = processingState.totalEvents > 0 and 
                          (processingState.ignoredEvents / processingState.totalEvents * 100) or 0
    
    return {
        totalEvents = processingState.totalEvents,
        processedEvents = processingState.processedEvents,
        ignoredEvents = processingState.ignoredEvents,
        playerDamageEvents = processingState.playerDamageEvents,
        petDamageEvents = processingState.petDamageEvents,
        processedPercent = processedPercent,
        ignoredPercent = ignoredPercent,
        lastEventTime = processingState.lastEventTime,
        
        circuitBreaker = {
            eventsThisFrame = circuitBreaker.eventsThisFrame,
            maxEventsPerFrame = circuitBreaker.maxEventsPerFrame,
            tripped = circuitBreaker.tripped
        },
        
        playerCache = {
            playerGUID = playerCache.guid,
            playerName = playerCache.name,
            petCount = self:GetPetCount()
        }
    }
end

-- Get number of tracked pets
function EventProcessor:GetPetCount()
    local count = 0
    for _ in pairs(playerCache.pets) do
        count = count + 1
    end
    return count
end

-- Show recent event types (for debugging)
function EventProcessor:ShowRecentEvents()
    print("=== Recent Combat Log Events ===")
    print(string.format("Total events processed: %d", processingState.totalEvents))
    print(string.format("Player events: %d", processingState.playerDamageEvents))
    print(string.format("Pet events: %d", processingState.petDamageEvents))
    print(string.format("Ignored events: %d", processingState.ignoredEvents))
    print("Enable '/stormy debug' for detailed statistics")
end

-- Set circuit breaker mode
function EventProcessor:SetCircuitBreakerMode(mode)
    if mode == "auto" then
        circuitBreaker.currentMode = "auto"
        circuitBreaker.adaptiveEnabled = true
        UpdateAdaptiveLimit()
        print("[STORMY] Circuit breaker: Auto mode enabled")
    elseif mode == "solo" then
        circuitBreaker.currentMode = "solo"
        circuitBreaker.maxEventsPerFrame = circuitBreaker.baseLimit
        print(string.format("[STORMY] Circuit breaker: Solo mode, %d events/frame", circuitBreaker.maxEventsPerFrame))
    elseif mode == "raid" then
        circuitBreaker.currentMode = "raid"
        circuitBreaker.maxEventsPerFrame = circuitBreaker.raidLimit
        print(string.format("[STORMY] Circuit breaker: Raid mode, %d events/frame", circuitBreaker.maxEventsPerFrame))
    elseif mode == "mythic" then
        circuitBreaker.currentMode = "mythic"
        circuitBreaker.maxEventsPerFrame = circuitBreaker.mythicLimit
        print(string.format("[STORMY] Circuit breaker: Mythic+ mode, %d events/frame", circuitBreaker.maxEventsPerFrame))
    elseif tonumber(mode) then
        local limit = tonumber(mode)
        if limit >= 5 and limit <= 100 then
            circuitBreaker.currentMode = "manual"
            circuitBreaker.maxEventsPerFrame = limit
            print(string.format("[STORMY] Circuit breaker: Manual mode, %d events/frame", limit))
        else
            print("[STORMY] Invalid limit. Use 5-100.")
        end
    else
        print("[STORMY] Usage: /stormy cb auto|solo|raid|mythic|<number>")
        print(string.format("Current: %s mode, %d events/frame", circuitBreaker.currentMode, circuitBreaker.maxEventsPerFrame))
    end
end

-- Debug dump
function EventProcessor:Debug()
    local stats = self:GetStats()
    print("=== EventProcessor Debug ===")
    print(string.format("Total Events: %d", stats.totalEvents))
    print(string.format("Processed: %d (%.1f%%)", stats.processedEvents, stats.processedPercent))
    print(string.format("Ignored: %d (%.1f%%)", stats.ignoredEvents, stats.ignoredPercent))
    print(string.format("Player Events: %d", stats.playerDamageEvents))
    print(string.format("Pet Events: %d", stats.petDamageEvents))
    print(string.format("Tracked Pets: %d", stats.playerCache.petCount))
    
    if stats.circuitBreaker.tripped then
        print("⚠️ Circuit breaker is TRIPPED")
    end
end

-- Reset statistics
function EventProcessor:ResetStats()
    processingState.totalEvents = 0
    processingState.processedEvents = 0
    processingState.ignoredEvents = 0
    processingState.playerDamageEvents = 0
    processingState.petDamageEvents = 0
    processingState.lastEventTime = 0
    
    circuitBreaker.eventsThisFrame = 0
    circuitBreaker.tripped = false
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the event processor
function EventProcessor:Initialize()
    -- Cache constants first
    CacheConstants()
    
    -- Update circuit breaker limits
    UpdateCircuitBreaker()
    
    -- Set initial adaptive limit
    UpdateAdaptiveLimit()
    
    -- Update player cache
    self:UpdatePlayerGUID()
    
    -- Reset statistics
    self:ResetStats()
    
    -- Set up event handlers
    self:SetupEventHandlers()
end

-- Set up WoW event handlers
function EventProcessor:SetupEventHandlers()
    local frame = CreateFrame("Frame", "StormyEventProcessor")
    
    -- Register for combat log events
    frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("UNIT_PET")
    
    frame:SetScript("OnEvent", function(self, event, ...)
        if event == "COMBAT_LOG_EVENT_UNFILTERED" then
            EventProcessor:ProcessEvent(CombatLogGetCurrentEventInfo())
        elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
            EventProcessor:UpdatePlayerGUID()
        elseif event == "UNIT_PET" then
            local unit = ...
            if unit == "player" then
                -- Check for new pet
                local petGUID = UnitGUID("pet")
                if petGUID then
                    local petName = UnitName("pet")
                    EventProcessor:AddPet(petGUID, petName)
                end
            end
        end
    end)
    
    self.frame = frame
    print("[STORMY] EventProcessor frame created and events registered")
end

-- Module ready
EventProcessor.isReady = true

-- Debug: Print when this file loads
print("[STORMY] EventProcessor.lua file loaded successfully")
print("[STORMY] EventProcessor module registered:", addon.EventProcessor ~= nil)