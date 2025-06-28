-- MySimpleCombatDetector.lua
-- Simple, reliable combat detection system
-- Replaces the overly complex multi-system approach

local addonName, addon = ...

-- Self-contained module with internal debugging
local MySimpleCombatDetector = {}
addon.MySimpleCombatDetector = MySimpleCombatDetector

-- Internal debug configuration
local DEBUG_MODE = false  -- Disabled to reduce log spam
local logger = nil -- Injected logger instance

-- Internal debug functions with logger fallback
local function debugPrint(...)
    if logger and logger.Debug then
        logger:Debug(...)
    elseif DEBUG_MODE then
        print("[MySimpleCombatDetector]", ...)
    end
end

local function infoPrint(...)
    if logger and logger.Info then
        logger:Info(...)
    else
        print("[MySimpleCombatDetector]", ...)
    end
end

local function errorPrint(...)
    if logger and logger.Error then
        logger:Error(...)
    else
        print("[MySimpleCombatDetector][ERROR]", ...)
    end
end

-- Simple configuration
local CONFIG = {
    ACTIVITY_TIMEOUT = 4.0,      -- Seconds after last ACTIVE activity to end combat (reduced from 8.0)
    CHECK_INTERVAL = 2.0,        -- How often to check for timeout (reduced for faster detection)
    MIN_DURATION = 3.0,          -- Minimum session duration (reduced for testing)
    MIN_EVENTS = 3,              -- Minimum meaningful events (reduced for testing)
    MIN_ACTIVITY_RATE = 0.2,     -- Minimum events per second (reduced for testing)
    
    -- Session Segmentation Configuration (AGGRESSIVE TESTING SETTINGS)
    SEGMENT_MAX_EVENTS = 50,     -- Max events per segment (TESTING: was 10000)
    SEGMENT_MAX_TIME = 15,       -- Max 15 seconds per segment (TESTING: was 300)
    SEGMENT_ACTIVITY_GAP = 5,    -- New segment after 5s gap in activity (TESTING: was 30)
    SEGMENT_MIN_EVENTS = 5,      -- Minimum events to create a new segment (TESTING: was 100)
}

-- Combat state
local inCombat = false
local combatStartTime = nil
local lastActivityTime = nil
local currentSessionData = nil
local sessionCounter = 0
local timeoutTimer = nil

-- Session Segmentation State
local currentSegment = nil
local segmentCounter = 0
local lastSegmentTime = nil

-- Performance caches
local playerGUID = nil
local playerName = nil
local groupMemberGUIDs = {} -- Cache of group member GUIDs for fast lookup
local currentInstanceType = nil -- Cache current instance type for filtering

-- Pet detection state
local activePetGUIDs = {}  -- GUID -> { name, detectedAt, owner } mapping
local lastPetScan = 0
local PET_SCAN_INTERVAL = 2.0  -- Scan every 2 seconds during combat

-- Quick exit pattern - events we NEVER care about (immediate return)
-- Based on Recount's QuickExitEvents approach for maximum performance
local QUICK_EXIT_EVENTS = {
    -- Environmental and positioning events
    ["ENVIRONMENTAL_DAMAGE"] = true,
    ["SPELL_BUILDING_DAMAGE"] = true,
    ["SPELL_BUILDING_HEAL"] = true,
    
    -- Enchant and enhancement events
    ["ENCHANT_APPLIED"] = true,
    ["ENCHANT_REMOVED"] = true,
    ["SPELL_ENCHANT_APPLIED"] = true,
    ["SPELL_ENCHANT_REMOVED"] = true,
    
    -- Summon events we don't track
    ["SPELL_SUMMON"] = true,
    ["SPELL_CREATE"] = true,
    
    -- Durability and item events
    ["SPELL_DURABILITY_DAMAGE"] = true,
    ["SPELL_DURABILITY_DAMAGE_ALL"] = true,
    
    -- Cast events we don't need for session tracking
    ["SPELL_CAST_START"] = true,
    ["SPELL_CAST_SUCCESS"] = true,
    ["SPELL_CAST_FAILED"] = true,
    
    -- Aura events that create noise
    ["SPELL_AURA_APPLIED_DOSE"] = true,
    ["SPELL_AURA_REMOVED_DOSE"] = true,
    ["SPELL_AURA_REFRESH"] = true,
    ["SPELL_AURA_BROKEN"] = true,
    ["SPELL_AURA_BROKEN_SPELL"] = true,
    
    -- Extra attacks and procs
    ["SPELL_EXTRA_ATTACKS"] = true,
    
    -- Energize events (for session tracking, we focus on damage/healing)
    ["SPELL_ENERGIZE"] = true,
    ["SPELL_PERIODIC_ENERGIZE"] = true,
    
    -- Leech and drain events
    ["SPELL_LEECH"] = true,
    ["SPELL_PERIODIC_LEECH"] = true,
    ["SPELL_DRAIN"] = true,
    ["SPELL_PERIODIC_DRAIN"] = true,
    
    -- Misc events that add noise
    ["SPELL_INSTAKILL"] = true,
    ["DAMAGE_SHIELD"] = true,
    ["DAMAGE_SHIELD_MISSED"] = true,
}

-- Event filtering - meaningful combat events for session tracking
local MEANINGFUL_EVENTS = {
    ["SPELL_DAMAGE"] = true,
    ["SPELL_PERIODIC_DAMAGE"] = true,
    ["SPELL_HEAL"] = true,
    ["SPELL_PERIODIC_HEAL"] = true,
    ["SWING_DAMAGE"] = true,
    ["SWING_MISSED"] = true,
    ["RANGE_DAMAGE"] = true,
    ["RANGE_MISSED"] = true,
    ["SPELL_MISSED"] = true,
    ["SPELL_ABSORBED"] = true,
    ["SPELL_REFLECT"] = true,
    ["UNIT_DIED"] = true,
    ["PARTY_KILL"] = true,
    ["SPELL_INTERRUPT"] = true,
    ["SPELL_DISPEL"] = true,
    ["SPELL_STEAL"] = true,
    ["SPELL_AURA_APPLIED"] = true,  -- Only applied, not other aura noise
    ["SPELL_AURA_REMOVED"] = true,  -- Only removed, not other aura noise
}

-- Events that indicate ACTIVE combat (not passive HOTs/buffs)
local ACTIVE_COMBAT_EVENTS = {
    ["SPELL_DAMAGE"] = true,
    ["SPELL_HEAL"] = true,           -- Direct heals (not periodic)
    ["SWING_DAMAGE"] = true,
    ["SWING_MISSED"] = true,
    ["RANGE_DAMAGE"] = true,
    ["RANGE_MISSED"] = true,
    ["SPELL_MISSED"] = true,
    ["SPELL_ABSORBED"] = true,
    ["SPELL_REFLECT"] = true,
    ["UNIT_DIED"] = true,
    ["PARTY_KILL"] = true,
    ["SPELL_INTERRUPT"] = true,
    ["SPELL_DISPEL"] = true,
    ["SPELL_STEAL"] = true,
    -- Note: Excludes SPELL_PERIODIC_* and most aura events
}

-- Common HOT/DOT spells that shouldn't extend combat
local PASSIVE_SPELL_PATTERNS = {
    -- Druid HOTs
    "Rejuvenation",
    "Regrowth",
    "Lifebloom", 
    "Wild Growth",
    "Tranquility",
    
    -- Priest HOTs
    "Renew",
    "Prayer of Mending",
    "Circle of Healing",
    "Guardian Spirit",
    "Power Word: Shield",
    
    -- Paladin HOTs
    "Beacon of Light",
    "Flash of Light",
    "Holy Light",
    
    -- Shaman HOTs
    "Healing Stream",
    "Riptide",
    
    -- Death Knight
    "Death Pact",
    "Vampiric Blood",
    
    -- Consumables and buffs
    "Food",
    "Flask",
    "Elixir",
    "Well Fed",
    "Rested",
    "Bandage",
    "Potion",
    
    -- Common passive effects
    "Regeneration",
    "Health Funnel",
    "Life Steal",
    "Vampiric",
}

-- Combat log object flags for entity filtering (from Recount's approach)
local COMBATLOG_OBJECT_TYPE_PLAYER = 0x00000400
local COMBATLOG_OBJECT_TYPE_NPC = 0x00000800  
local COMBATLOG_OBJECT_TYPE_PET = 0x00001000
local COMBATLOG_OBJECT_TYPE_GUARDIAN = 0x00002000
local COMBATLOG_OBJECT_TYPE_OBJECT = 0x00004000

local COMBATLOG_OBJECT_CONTROL_PLAYER = 0x00000100
local COMBATLOG_OBJECT_CONTROL_NPC = 0x00000200

local COMBATLOG_OBJECT_AFFILIATION_MINE = 0x00000001
local COMBATLOG_OBJECT_AFFILIATION_PARTY = 0x00000002  
local COMBATLOG_OBJECT_AFFILIATION_RAID = 0x00000004
local COMBATLOG_OBJECT_AFFILIATION_OUTSIDER = 0x00000008

-- Irrelevant entity patterns (names that indicate unimportant entities)
local IRRELEVANT_ENTITY_PATTERNS = {
    "Totem$",           -- Totems
    "Spirit$",          -- Spirit wolves, etc.
    "Clone$",           -- Mirror images, etc.
    "Image$",           -- Mirror images
    "Reflection$",      -- Various reflections
    "Statue$",          -- Healing statues
    "Trap$",            -- Hunter traps
    "Ward$",            -- Various wards
    "Banner$",          -- Warrior banners
    "Crystal$",         -- Various crystals
    "Orb$",             -- Various orbs
    "Beacon$",          -- Light beacons
    "Portal$",          -- Portals
    "Gateway$",         -- Demonic gateways
}

-- Initialize the detector
function MySimpleCombatDetector:Initialize(injectedLogger)
    -- Inject logger and validate it exists with required methods
    assert(injectedLogger, "MySimpleCombatDetector requires a logger instance")
    assert(type(injectedLogger.Debug) == "function", "Logger must have Debug method")
    assert(type(injectedLogger.Info) == "function", "Logger must have Info method")
    assert(type(injectedLogger.Error) == "function", "Logger must have Error method")
    
    logger = injectedLogger
    
    logger:Debug("MySimpleCombatDetector Initialize() called")
    
    if self.initialized then
        debugPrint("Already initialized, skipping")
        return
    end

    -- Create event frame
    self.frame = CreateFrame("Frame", addonName .. "MySimpleCombatDetector")
    debugPrint("Event frame created")
    
    -- Register for WoW combat state events
    self.frame:RegisterEvent("PLAYER_REGEN_DISABLED")  -- Entered combat
    self.frame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- Left combat
    self.frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    debugPrint("Events registered: PLAYER_REGEN_DISABLED, PLAYER_REGEN_ENABLED, COMBAT_LOG_EVENT_UNFILTERED")
    
    -- Set up event handler
    self.frame:SetScript("OnEvent", function(frame, event, ...)
        self:OnEvent(event, ...)
    end)
    debugPrint("Event handler script set")
    
    self.initialized = true
    
    -- Cache player information for performance
    self:RefreshPlayerCache()
    
    debugPrint("Initialization complete")
end

-- Cache player and group information for performance
function MySimpleCombatDetector:RefreshPlayerCache()
    playerGUID = UnitGUID("player")
    playerName = UnitName("player")
    
    -- Cache instance information for filtering
    local name, instanceType, difficultyID, difficultyName, maxPlayers, 
          dynamicDifficulty, isDynamic, instanceID, instanceGroupSize, LfgDungeonID = GetInstanceInfo()
    currentInstanceType = instanceType
    
    -- Clear and rebuild group member cache
    wipe(groupMemberGUIDs)
    
    if IsInGroup() then
        for i = 1, GetNumGroupMembers() do
            local unit = IsInRaid() and "raid"..i or "party"..i
            if UnitExists(unit) then
                local memberGUID = UnitGUID(unit)
                if memberGUID then
                    groupMemberGUIDs[memberGUID] = true
                end
            end
        end
    end
    
    debugPrint("Player cache refreshed: playerGUID=%s, %d group members, instance=%s", 
        playerGUID or "nil", self:TableSize(groupMemberGUIDs), currentInstanceType or "none")
end

-- Check if a spell is a passive HOT/buff that shouldn't extend combat
function MySimpleCombatDetector:IsPassiveSpell(spellName)
    if not spellName then
        return false
    end
    
    for _, pattern in ipairs(PASSIVE_SPELL_PATTERNS) do
        if string.find(spellName, pattern) then
            return true
        end
    end
    
    return false
end

-- Determine if an entity is relevant for combat tracking
function MySimpleCombatDetector:IsRelevantEntity(guid, name, flags)
    if not guid then
        return false
    end
    
    -- Always track players
    if flags and bit.band(flags, COMBATLOG_OBJECT_TYPE_PLAYER) ~= 0 then
        return true
    end
    
    -- Track player-controlled pets/guardians
    if flags and bit.band(flags, COMBATLOG_OBJECT_CONTROL_PLAYER) ~= 0 then
        return true
    end
    
    -- Track friendly/party/raid affiliated entities
    if flags then
        local affiliation = bit.band(flags, 0x0000000F) -- Affiliation mask
        if affiliation == COMBATLOG_OBJECT_AFFILIATION_MINE or
           affiliation == COMBATLOG_OBJECT_AFFILIATION_PARTY or
           affiliation == COMBATLOG_OBJECT_AFFILIATION_RAID then
            return true
        end
    end
    
    -- Filter out irrelevant entities by name pattern
    if name then
        for _, pattern in ipairs(IRRELEVANT_ENTITY_PATTERNS) do
            if string.match(name, pattern) then
                return false
            end
        end
    end
    
    -- Track NPCs in combat encounters (but not irrelevant objects)
    if flags and bit.band(flags, COMBATLOG_OBJECT_TYPE_NPC) ~= 0 then
        return true
    end
    
    -- Default: don't track objects, totems, etc.
    return false
end

-- Utility function to get table size
function MySimpleCombatDetector:TableSize(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

-- Check if current instance type is worth tracking
function MySimpleCombatDetector:IsInstanceWorthTracking()
    -- Always track in these instances
    if currentInstanceType == "raid" or 
       currentInstanceType == "party" or 
       currentInstanceType == "scenario" then
        return true
    end
    
    -- Track world content only if in a group (world bosses, etc.)
    if currentInstanceType == "none" and IsInGroup() then
        return true
    end
    
    -- Don't track in cities, battlegrounds without configuration
    if currentInstanceType == "pvp" then
        return false -- Could be configurable later
    end
    
    -- Default: track solo world content (leveling, questing)
    return true
end

-- ============================================================================
-- PET DETECTION SYSTEM
-- ============================================================================

-- Scan for active pets (called frequently during combat)  
function MySimpleCombatDetector:ScanActivePets()
    local currentTime = GetTime()
    if currentTime - lastPetScan < PET_SCAN_INTERVAL then
        return false  -- Don't scan too frequently
    end
    lastPetScan = currentTime
    
    local foundNewPets = false
    
    -- Ensure we have current player info
    if not playerName then
        playerName = UnitName("player")
    end
    
    -- Method 1: Scan player's main pet using UnitGUID (traditional pets)
    local playerPetGUID = UnitGUID("pet")
    if playerPetGUID and not activePetGUIDs[playerPetGUID] then
        local petName = UnitName("pet") or "Unknown Pet"
        activePetGUIDs[playerPetGUID] = {
            name = petName,
            detectedAt = currentTime,
            owner = playerName
        }
        foundNewPets = true
        
        -- Pet detection notification
        print(string.format("|cFF00FF00[PET DETECTED]|r %s summoned: %s", playerName, petName))
        if addon.MyLogger then
            addon.MyLogger:Info("[PET DETECTED] %s summoned: %s (GUID: %s)", playerName, petName, playerPetGUID)
        end
    end
    
    -- Method 2: Combat log flag-based detection happens in ProcessCombatLogEvent
    -- This catches ephemeral pets/guardians that don't show up via UnitGUID("pet")
    
    return foundNewPets
end

-- Check for pets via combat log flags (Method 2 - catches ephemeral pets/guardians)
function MySimpleCombatDetector:CheckForPetViaFlags(sourceGUID, sourceName, sourceFlags)
    if not sourceGUID or not sourceName or not sourceFlags then
        return
    end
    
    -- Skip if already tracking this pet
    if activePetGUIDs[sourceGUID] then
        return
    end
    
    -- Ensure we have current player info
    if not playerName then
        playerName = UnitName("player")
    end
    
    
    -- Check for player-owned pets/guardians using combat log flags
    local isMyPet = bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) ~= 0 and
                    (bit.band(sourceFlags, COMBATLOG_OBJECT_TYPE_PET) ~= 0 or
                     bit.band(sourceFlags, COMBATLOG_OBJECT_TYPE_GUARDIAN) ~= 0)
    
    if isMyPet then
        local currentTime = GetTime()
        activePetGUIDs[sourceGUID] = {
            name = sourceName,
            detectedAt = currentTime,
            owner = playerName,
            type = bit.band(sourceFlags, COMBATLOG_OBJECT_TYPE_PET) ~= 0 and "Pet" or "Guardian"
        }
        
        -- Pet detection notification (moved to trace)
        if logger and logger.Trace then
            logger:Trace("[PET DETECTED] %s summoned: %s (%s) via combat log flags (GUID: %s, flags: 0x%08X)", 
                playerName, sourceName, activePetGUIDs[sourceGUID].type, sourceGUID, sourceFlags)
        end
    end
end

-- REMOVED: Pet spell ID mappings - we don't need spell tables!
-- The generalized solution uses GUID-based detection instead

-- Check if a GUID belongs to a known pet
function MySimpleCombatDetector:IsKnownPet(sourceGUID)
    if not sourceGUID then
        return nil
    end
    
    local petInfo = activePetGUIDs[sourceGUID]
    return petInfo and petInfo.owner or nil
end

-- GENERALIZED: Check if damage event is from a known pet GUID
-- No spell tables needed - just GUID-based detection!
function MySimpleCombatDetector:IsPetDamage(sourceGUID, spellId, spellName)
    -- Simple and generalized: Is this GUID a known pet?
    if sourceGUID and activePetGUIDs[sourceGUID] then
        return true, activePetGUIDs[sourceGUID].name
    end
    
    -- That's it! No spell tables, no complex logic
    -- If the sourceGUID is a pet, it's pet damage
    return false, nil
end

-- Get active pets for debugging
function MySimpleCombatDetector:GetActivePets()
    return activePetGUIDs
end

-- Public method to force a pet scan (for testing)
function MySimpleCombatDetector:ForcePetScan()
    lastPetScan = 0  -- Reset timer to force scan
    return self:ScanActivePets()
end

-- Clear pet tracking (called on combat start)
function MySimpleCombatDetector:ClearPetTracking()
    wipe(activePetGUIDs)
    lastPetScan = 0
end

-- ============================================================================
-- SESSION SEGMENTATION SYSTEM
-- ============================================================================

-- Create a new segment for the current session
function MySimpleCombatDetector:CreateNewSegment()
    if not currentSessionData then
        errorPrint("CreateNewSegment called with no currentSessionData!")
        return nil
    end
    
    if not currentSessionData.id then
        errorPrint("CreateNewSegment: currentSessionData.id is nil!")
        -- Log the current session data for debugging
        local sessionInfo = string.format("Session data: startTime=%s, zone=%s, player=%s", 
            tostring(currentSessionData.startTime), 
            tostring(currentSessionData.zone), 
            tostring(currentSessionData.player))
        errorPrint(sessionInfo)
        -- Don't create segment if session ID is invalid
        return nil
    end
    
    segmentCounter = segmentCounter + 1
    local currentTime = GetTime()
    
    -- Create segment using specialized factory method
    local segment = addon.StorageManager and addon.StorageManager:GetSegmentTable() or {}
    
    -- Ensure all required fields are initialized with fault tolerance
    segment.id = string.format("%s-seg%d", currentSessionData.id or "unknown", segmentCounter)
    segment.segmentIndex = segmentCounter
    segment.startTime = lastSegmentTime or combatStartTime or GetTime()
    segment.endTime = nil  -- Will be set when segment is finalized
    segment.events = addon.StorageManager and addon.StorageManager:GetTable("segment-events") or {}
    segment.eventCount = 0  -- Already initialized to 0 by factory, but explicit for clarity
    segment.isActive = true
    
    -- Validate critical fields
    if not segment.startTime then
        errorPrint("CRITICAL: segment.startTime is nil after initialization!")
        segment.startTime = GetTime()
    end
    if not segment.events then
        errorPrint("CRITICAL: segment.events is nil after initialization!")
        segment.events = {}
    end
    
    debugPrint("Created new segment: %s", segment.id)
    return segment
end

-- Finalize the current segment and prepare for next one
function MySimpleCombatDetector:FinalizeCurrentSegment()
    if not currentSegment or not currentSessionData then
        return
    end
    
    local currentTime = GetTime()
    currentSegment.endTime = currentTime
    
    -- Calculate duration with safety check for startTime
    if currentSegment.startTime then
        currentSegment.duration = currentSegment.endTime - currentSegment.startTime
    else
        -- If no startTime, use a minimal duration
        currentSegment.duration = 0
        debugPrint("Warning: Segment has no startTime, using 0 duration")
    end
    
    currentSegment.isActive = false
    
    -- Only store segments that meet minimum criteria
    if currentSegment.eventCount and currentSegment.eventCount >= CONFIG.SEGMENT_MIN_EVENTS then
        -- Add segment to session's segment list
        if not currentSessionData.segments then
            currentSessionData.segments = addon.StorageManager and addon.StorageManager:GetTable() or {}
        end
        
        table.insert(currentSessionData.segments, currentSegment)
        currentSessionData.segmentCount = (currentSessionData.segmentCount or 0) + 1
        
        debugPrint("Finalized segment %s: %.1fs, %d events", 
            currentSegment.id, currentSegment.duration, currentSegment.eventCount)
    else
        -- Return inadequate segment tables to pool
        if addon.StorageManager then
            addon.StorageManager:ReleaseTable(currentSegment.events)
            addon.StorageManager:ReleaseTable(currentSegment)
        end
        debugPrint("Discarded segment %s: insufficient events (%d < %d)", 
            currentSegment.id, currentSegment.eventCount or 0, CONFIG.SEGMENT_MIN_EVENTS)
    end
    
    lastSegmentTime = currentTime
    currentSegment = nil
end

-- Check if we need to create a new segment based on time/events/activity
function MySimpleCombatDetector:ShouldCreateNewSegment()
    if not currentSegment then
        return true  -- No current segment, definitely need one
    end
    
    local currentTime = GetTime()
    
    -- Check event count limit
    if currentSegment.eventCount and currentSegment.eventCount >= CONFIG.SEGMENT_MAX_EVENTS then
        debugPrint("Segment event limit reached: %d >= %d", 
            currentSegment.eventCount, CONFIG.SEGMENT_MAX_EVENTS)
        return true
    end
    
    -- Check time limit (with safety check for startTime)
    if currentSegment.startTime then
        local segmentDuration = currentTime - currentSegment.startTime
        if segmentDuration >= CONFIG.SEGMENT_MAX_TIME then
            debugPrint("Segment time limit reached: %.1fs >= %.1fs", 
                segmentDuration, CONFIG.SEGMENT_MAX_TIME)
            return true
        end
    else
        -- If no startTime, segment is invalid
        debugPrint("Segment has no startTime, marking for replacement")
        return true
    end
    
    -- Check activity gap (if there was a long pause in combat)
    if lastActivityTime and currentSegment.eventCount and currentSegment.eventCount > 0 then
        local timeSinceLastActivity = currentTime - lastActivityTime
        if timeSinceLastActivity >= CONFIG.SEGMENT_ACTIVITY_GAP then
            debugPrint("Activity gap detected: %.1fs >= %.1fs", 
                timeSinceLastActivity, CONFIG.SEGMENT_ACTIVITY_GAP)
            return true
        end
    end
    
    return false
end

-- ============================================================================
-- END SESSION SEGMENTATION SYSTEM
-- ============================================================================

-- Main event handler
function MySimpleCombatDetector:OnEvent(event, ...)
    if event == "PLAYER_REGEN_DISABLED" then
        debugPrint("PLAYER_REGEN_DISABLED - calling StartCombat()")
        self:StartCombat()
    elseif event == "PLAYER_REGEN_ENABLED" then
        debugPrint("PLAYER_REGEN_ENABLED - calling BeginCombatTimeout()")
        self:BeginCombatTimeout()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        -- Only process combat log events if we're tracking combat
        if inCombat then
            -- Get the combat log event info properly
            local eventInfo = {CombatLogGetCurrentEventInfo()}
            self:ProcessCombatEvent(unpack(eventInfo))
        end
    end
end

-- Start a new combat session
function MySimpleCombatDetector:StartCombat()
    debugPrint("StartCombat() called")
    
    -- Cancel any existing timeout
    self:CancelTimeout()
    
    -- If already in combat, don't restart
    if inCombat then
        debugPrint("Already in combat, ignoring start")
        return
    end
    
    -- Safety: clear any leftover session data
    if currentSessionData then
        errorPrint("WARNING: currentSessionData exists at combat start - cleaning up!")
        currentSessionData = nil
    end
    
    -- Refresh cache first to get current instance type
    self:RefreshPlayerCache()
    
    -- Check if current instance is worth tracking
    if not self:IsInstanceWorthTracking() then
        debugPrint("Instance type '%s' not worth tracking, ignoring combat", currentInstanceType or "unknown")
        return
    end
    
    -- Start MyTimestampManager combat tracking
    if addon.MyTimestampManager then
        -- Get the current combat log timestamp for proper timing
        local logTimestamp = select(1, CombatLogGetCurrentEventInfo())
        addon.MyTimestampManager:StartCombat(logTimestamp)
        combatStartTime = addon.MyTimestampManager:GetTimestampData().combatStartTime
    else
        combatStartTime = GetTime()
    end
    
    -- Generate simplified session ID (realm/character are implicit in WTF storage)
    sessionCounter = sessionCounter + 1
    
    -- Validate combatStartTime
    if not combatStartTime or combatStartTime <= 0 then
        errorPrint("Invalid combatStartTime: %s", tostring(combatStartTime))
        combatStartTime = GetTime()
    end
    
    local timestamp = math.floor(combatStartTime * 1000) -- Convert to milliseconds for precision
    
    -- Create shorter, more readable session ID: timestamp-counter
    local baseId = string.format("%d-%03d", timestamp, sessionCounter)
    
    -- Generate checksum for validation (simple hash of the base ID)
    local checksum = 0
    for i = 1, #baseId do
        checksum = checksum + string.byte(baseId, i)
    end
    checksum = checksum % 1000 -- Keep it to 3 digits
    
    local sessionId = string.format("%s-%03d", baseId, checksum)
    
    -- Validate sessionId
    if not sessionId or sessionId == "" then
        errorPrint("Failed to generate sessionId!")
        sessionId = string.format("fallback-%d-%d", GetTime(), sessionCounter)
    end
    
    -- Generate 4-character alphanumeric hash for easy typing
    local sessionHash = self:GenerateSessionHash(sessionId)
    
    -- Initialize combat state
    inCombat = true
    lastActivityTime = combatStartTime
    
    -- Publish combat state change to message queue
    self:PublishCombatStateChange(true)
    
    -- Initialize segmentation state
    segmentCounter = 0
    lastSegmentTime = combatStartTime
    currentSegment = nil
    
    -- Create session data structure using specialized factory
    currentSessionData = addon.StorageManager and addon.StorageManager:GetSessionTable() or {}
    
    -- Ensure sessionId is valid before assigning
    if not sessionId then
        errorPrint("CRITICAL: sessionId is nil in StartCombat!")
        sessionId = string.format("emergency-%d", GetTime())
    end
    
    currentSessionData.id = sessionId
    currentSessionData.hash = sessionHash  -- Short 4-char hash for easy reference
    currentSessionData.startTime = combatStartTime or GetTime()  -- Absolute failsafe
    currentSessionData.endTime = nil
    currentSessionData.eventCount = 0
    currentSessionData.events = addon.StorageManager and addon.StorageManager:GetTable("events") or {}
    currentSessionData.guidMap = addon.StorageManager and addon.StorageManager:GetTable("guidmap") or {}  -- GUID -> name mapping for efficient storage
    currentSessionData.zone = GetZoneText() or "Unknown"
    currentSessionData.instance = GetInstanceInfo() or GetZoneText() or "Unknown"
    currentSessionData.player = playerName or "Unknown"
    currentSessionData.playerClass = UnitClass("player") or "Unknown"
    currentSessionData.playerLevel = UnitLevel("player") or 80
    currentSessionData.groupType = IsInRaid() and "raid" or IsInGroup() and "party" or "solo"
    currentSessionData.groupSize = GetNumGroupMembers() or 1
    
    -- Initialize segmentation metadata
    currentSessionData.segments = nil  -- Will be created when first segment is finalized
    currentSessionData.segmentCount = 0
    currentSessionData.isSegmented = true
    
    -- Create initial segment
    currentSegment = self:CreateNewSegment()
    
    -- Initialize pet tracking
    self:ClearPetTracking()
    self:ScanActivePets()  -- Initial pet scan
    
    debugPrint("Combat started: %s [%s] (cached %d group members, segmentation enabled)", sessionId, sessionHash, self:TableSize(groupMemberGUIDs))
end

-- Begin combat timeout when player leaves WoW combat
function MySimpleCombatDetector:BeginCombatTimeout()
    if not inCombat then
        return
    end
    
    debugPrint("Player left WoW combat, starting activity timeout")
    
    -- Start timeout timer
    self:StartTimeoutTimer()
end

-- Process combat log events
function MySimpleCombatDetector:ProcessCombatEvent(...)
    local timestamp, eventType, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
          destGUID, destName, destFlags, destRaidFlags = ...
    
    -- PHASE 1: Quick exit for events we never care about (maximum performance)
    if QUICK_EXIT_EVENTS[eventType] then
        return
    end
    
    -- PHASE 2: Only process if we're tracking combat
    if not inCombat or not currentSessionData then
        return
    end
    
    -- PHASE 2.5: Scan for new pets during combat (frequent rescanning)  
    self:ScanActivePets()
    
    -- PHASE 3: Filter for meaningful combat events only
    if not MEANINGFUL_EVENTS[eventType] then
        return
    end
    
    -- PHASE 4: Entity filtering - reject irrelevant entity types
    -- Skip events involving totems, guardians we don't care about, etc.
    if not self:IsRelevantEntity(sourceGUID, sourceName, sourceFlags) and 
       not self:IsRelevantEntity(destGUID, destName, destFlags) then
        return
    end
    
    -- PHASE 4.5: Check for new pets BEFORE GUID filtering (critical for detection)
    if sourceGUID and sourceName and sourceFlags then
        self:CheckForPetViaFlags(sourceGUID, sourceName, sourceFlags)
    end
    if destGUID and destName and destFlags then
        self:CheckForPetViaFlags(destGUID, destName, destFlags)
    end
    
    -- PHASE 5: Fast player/group member check using cached GUIDs
    local isPlayerEvent = (sourceGUID == playerGUID) or (destGUID == playerGUID)
    
    -- For group play, check cached group member GUIDs (much faster than UnitExists loop)
    if not isPlayerEvent and next(groupMemberGUIDs) then
        isPlayerEvent = groupMemberGUIDs[sourceGUID] or groupMemberGUIDs[destGUID]
    end
    
    -- Also include events from known player pets/guardians
    if not isPlayerEvent and sourceGUID and activePetGUIDs[sourceGUID] then
        isPlayerEvent = true
        debugPrint("Accepting event from known pet: %s (%s)", activePetGUIDs[sourceGUID].name, sourceGUID)
    end
    
    if not isPlayerEvent then
        return
    end
    
    -- Add names to GUID map if not already present
    if currentSessionData.guidMap then
        if sourceGUID and sourceName and sourceName ~= "nil" then
            if not currentSessionData.guidMap[sourceGUID] then
                currentSessionData.guidMap[sourceGUID] = sourceName
            end
        end
        
        if destGUID and destName and destName ~= "nil" then
            if not currentSessionData.guidMap[destGUID] then
                currentSessionData.guidMap[destGUID] = destName
            end
        end
    else
        errorPrint("currentSessionData.guidMap is nil in ProcessCombatEvent!")
    end
    
    -- Removed: Per-event debug logging caused massive spam
    
    -- Smart activity detection - only reset timer for ACTIVE combat events
    local shouldResetActivityTimer = false
    
    if sourceGUID == playerGUID then
        -- Player is source - check if this is active combat
        if ACTIVE_COMBAT_EVENTS[eventType] then
            shouldResetActivityTimer = true
        elseif eventType == "SPELL_PERIODIC_DAMAGE" or eventType == "SPELL_PERIODIC_HEAL" then
            -- For periodic spells, check if it's a passive HOT/DOT
            local spellName = select(13, ...) -- Spell name is parameter 13
            if not self:IsPassiveSpell(spellName) then
                shouldResetActivityTimer = true
                debugPrint("Active periodic spell: %s", spellName or "unknown")
            else
                debugPrint("Passive spell ignored: %s", spellName or "unknown")
            end
        elseif eventType == "SPELL_AURA_APPLIED" then
            -- For aura applied, only reset for combat-relevant auras (buffs/debuffs during combat)
            local spellName = select(13, ...) -- Spell name is parameter 13
            if not self:IsPassiveSpell(spellName) and not string.find(spellName or "", "Food") then
                shouldResetActivityTimer = true
                debugPrint("Active aura applied: %s", spellName or "unknown")
            else
                debugPrint("Passive aura applied ignored: %s", spellName or "unknown")
            end
        elseif eventType == "SPELL_AURA_REMOVED" then
            -- For aura removed, be EXTREMELY restrictive - almost never reset timer
            local spellName = select(13, ...) -- Spell name is parameter 13
            -- Only reset timer for removal of critical combat control effects
            -- Most buff/debuff removals should NOT extend combat
            if spellName and (string.find(spellName, "Stun") or string.find(spellName, "Fear") or 
                             string.find(spellName, "Root") or string.find(spellName, "Silence") or
                             string.find(spellName, "Polymorph") or string.find(spellName, "Banish")) then
                shouldResetActivityTimer = true
                debugPrint("Critical CC aura removed: %s", spellName or "unknown")
            else
                -- Log all the buffs we're ignoring to see what's extending combat
                debugPrint("Buff removal ignored: %s", spellName or "unknown")
            end
        end
    elseif destGUID == playerGUID then
        -- Player is target - be selective about what counts as activity
        if eventType:find("DAMAGE") then
            -- Incoming damage always counts as activity
            shouldResetActivityTimer = true
            debugPrint("Incoming damage activity: %s", eventType)
        elseif eventType:find("HEAL") and eventType == "SPELL_HEAL" then
            -- Only direct heals, not periodic heals
            shouldResetActivityTimer = true
            debugPrint("Incoming direct heal activity: %s", eventType)
        elseif eventType == "SPELL_AURA_APPLIED" then
            -- Debuffs applied to player could be combat activity
            local spellName = select(13, ...)
            if spellName and (string.find(spellName, "Stun") or string.find(spellName, "Fear") or 
                             string.find(spellName, "Root") or string.find(spellName, "Silence") or
                             string.find(spellName, "Polymorph") or string.find(spellName, "Curse") or
                             string.find(spellName, "Poison") or string.find(spellName, "Disease")) then
                shouldResetActivityTimer = true
                debugPrint("Hostile debuff applied to player: %s", spellName or "unknown")
            else
                debugPrint("Buff applied to player ignored: %s", spellName or "unknown")
            end
        else
            -- Don't reset timer for other events targeting player (like aura removals from creatures)
            debugPrint("Player-targeted event ignored: %s", eventType)
        end
    end
    
    if shouldResetActivityTimer then
        lastActivityTime = GetTime()
        debugPrint("Activity timer reset: %s", eventType)
    end
    
    -- Calculate relative timestamp using TimestampManager
    local relativeTime = 0
    if addon.MyTimestampManager then
        relativeTime = addon.MyTimestampManager:GetRelativeTime(timestamp)
    else
        -- Fallback to manual calculation
        relativeTime = timestamp and combatStartTime and (timestamp - combatStartTime) or 0
    end
    
    -- Check if we need to create a new segment
    if self:ShouldCreateNewSegment() then
        self:FinalizeCurrentSegment()
        currentSegment = self:CreateNewSegment()
        -- Check if segment creation failed
        if not currentSegment then
            errorPrint("Failed to create new segment, skipping event")
            return
        end
        -- Segment creation already logged in CreateNewSegment() function
    end
    
    -- Store event data using specialized factory for efficiency
    local eventData = addon.StorageManager and addon.StorageManager:GetEventTable() or {}
    eventData.time = relativeTime           -- Relative time from combat start
    eventData.subevent = eventType
    eventData.sourceGUID = sourceGUID
    eventData.destGUID = destGUID
    -- Names are resolved from guidMap during export
    
    -- Store combat log args (parameters 12+ contain spell/damage data)
    local args = {}
    for i = 12, select('#', ...) do
        args[i-11] = select(i, ...)
    end
    eventData.args = args
    
    -- Add event to current segment (primary storage)
    if currentSegment then
        -- Ensure events table exists
        if not currentSegment.events then
            currentSegment.events = addon.StorageManager and addon.StorageManager:GetTable("segment-events") or {}
            debugPrint("Warning: currentSegment.events was nil, recreated")
        end
        table.insert(currentSegment.events, eventData)
        currentSegment.eventCount = (currentSegment.eventCount or 0) + 1
        
        -- Removed: Even throttled segment counting caused spam during intense combat
    end
    
    -- Also add to main session events for backward compatibility during transition
    if currentSessionData.events then
        table.insert(currentSessionData.events, eventData)
        currentSessionData.eventCount = currentSessionData.eventCount + 1
    else
        errorPrint("currentSessionData.events is nil when adding event!")
    end
    
    -- Publish events to message queue for real-time components (like combat meter)
    -- Pass all parameters from the combat log event
    self:PublishEventToMessageQueue(...)
    
    -- Publish RAW events for EntityMapWindow debugging
    self:PublishRawEventToMessageQueue(...)
end

-- =============================================================================
-- MESSAGE QUEUE INTEGRATION
-- =============================================================================

-- Publish combat events to message queue for real-time components
function MySimpleCombatDetector:PublishEventToMessageQueue(...)
    if not addon.CombatEventQueue then
        return -- Combat event queue not available
    end
    
    -- Extract all combat log parameters
    local timestamp, eventType, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
          destGUID, destName, destFlags, destRaidFlags = ...
          
    -- Pet detection via combat log flags (Method 2 - catches ephemeral pets/guardians)
    if sourceGUID and sourceName and sourceFlags and inCombat then
        self:CheckForPetViaFlags(sourceGUID, sourceName, sourceFlags)
    end
    
    -- Removed debug spam that was too verbose
          
    local amount = 0
    
    -- Parse damage events with proper combat log structure
    if eventType:find("DAMAGE") then
        if eventType == "SWING_DAMAGE" then
            -- For swing damage: parameter 12 is the damage amount
            amount = select(12, ...) or 0
            -- Removed: too verbose for normal operation
        elseif eventType == "SPELL_DAMAGE" or eventType == "RANGE_DAMAGE" or eventType == "SPELL_PERIODIC_DAMAGE" then
            -- For spell damage: params are spellId(12), spellName(13), spellSchool(14), amount(15)
            local spellId = select(12, ...)
            local spellName = select(13, ...)
            local spellSchool = select(14, ...)
            amount = select(15, ...) or 0
            -- Removed: too verbose for normal operation
        else
            -- For other damage types, try parameter 15
            amount = select(15, ...) or 0
            -- Removed: too verbose for normal operation
        end
        
        -- Convert to number
        amount = tonumber(amount) or 0
        
        -- Sanity check: damage should be between 1 and 10 million (reasonable for retail WoW)
        if amount > 10000000 then
            debugPrint("Rejected unrealistic damage amount: %d (eventType: %s)", amount, eventType)
            amount = 0
        end
        
        if amount > 0 then
            -- Extract spell information for damage events
            local spellId, spellName = nil, nil
            if eventType ~= "SWING_DAMAGE" then
                spellId = select(12, ...)
                spellName = select(13, ...)
            end
            
            if addon.CombatEventQueue and addon.CombatEventQueue.Push then
                -- Pet damage tracking (moved to trace)
                if activePetGUIDs[sourceGUID] and logger and logger.Trace then
                    logger:Trace("Publishing pet damage: %s (%d) from %s", 
                        tostring(spellName), amount, activePetGUIDs[sourceGUID].name)
                end
                
                -- Debug moved to trace level
                
                addon.CombatEventQueue:Push("DAMAGE_EVENT", {
                    eventType = eventType,
                    amount = amount,
                    source = sourceGUID,
                    sourceName = sourceName,
                    target = destGUID,
                    sourceFlags = sourceFlags,
                    timestamp = timestamp,
                    spellId = spellId,
                    spellName = spellName
                })
                -- Trace level to reduce log noise during normal operation
                if logger and logger.Trace then
                    logger:Trace("Published DAMAGE_EVENT: %s -> %s, amount: %d", sourceGUID or "nil", destGUID or "nil", amount)
                end
            else
                debugPrint("ERROR: CombatEventQueue not available for DAMAGE_EVENT")
            end
        else
            -- Debug log when no damage amount found
            debugPrint("No damage amount found for event: %s", eventType)
        end
    end
    
    -- Parse healing events with proper combat log structure
    if eventType:find("HEAL") then
        -- For heal events: spellId(12), spellName(13), spellSchool(14), amount(15), overhealing(16), absorbed(17), critical(18)
        local spellId = select(12, ...)
        local spellName = select(13, ...)
        local spellSchool = select(14, ...)
        amount = select(15, ...) or 0
        -- Removed: too verbose for normal operation
        
        -- Convert to number
        amount = tonumber(amount) or 0
        
        -- Sanity check: healing should be between 1 and 10 million (reasonable for retail WoW)
        if amount > 10000000 then
            debugPrint("Rejected unrealistic heal amount: %d (eventType: %s)", amount, eventType)
            amount = 0
        end
        
        if amount > 0 then
            -- Debug moved to trace level
            
            if addon.CombatEventQueue and addon.CombatEventQueue.Push then
                addon.CombatEventQueue:Push("HEAL_EVENT", {
                    eventType = eventType,
                    amount = amount,
                    source = sourceGUID,
                    sourceName = sourceName,
                    target = destGUID,
                    sourceFlags = sourceFlags,
                    timestamp = timestamp,
                    spellId = spellId,
                    spellName = spellName
                })
                -- Trace level to reduce log noise during normal operation  
                if logger and logger.Trace then
                    logger:Trace("Published HEAL_EVENT: %s -> %s, amount: %d", sourceGUID or "nil", destGUID or "nil", amount)
                end
            else
                debugPrint("ERROR: CombatEventQueue not available for HEAL_EVENT")
            end
        else
            -- Debug log when no heal amount found
            debugPrint("No heal amount found for event: %s", eventType)
        end
    end
end

-- Publish raw combat events for EntityMapWindow debugging
function MySimpleCombatDetector:PublishRawEventToMessageQueue(...)
    if not addon.CombatEventQueue then
        return -- Combat event queue not available
    end
    
    -- Extract all combat log parameters
    local timestamp, eventType, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
          destGUID, destName, destFlags, destRaidFlags = ...
    
    
    -- Publish ALL events (unfiltered) for EntityMapWindow debugging
    if addon.CombatEventQueue and addon.CombatEventQueue.Push then
        addon.CombatEventQueue:Push("RAW_COMBAT_EVENT", {
            timestamp = timestamp,
            eventType = eventType,
            sourceGUID = sourceGUID,
            sourceName = sourceName,
            sourceFlags = sourceFlags,
            destGUID = destGUID,
            destName = destName,
            destFlags = destFlags
        })
    end
end

-- Publish combat state changes
function MySimpleCombatDetector:PublishCombatStateChange(inCombatState)
    if not addon.CombatEventQueue then
        return
    end
    
    addon.CombatEventQueue:Push("COMBAT_STATE_CHANGED", {
        inCombat = inCombatState,
        startTime = combatStartTime,
        timestamp = GetTime(),
        sessionId = currentSessionData and currentSessionData.id or nil
    })
end

-- Start the activity timeout timer
function MySimpleCombatDetector:StartTimeoutTimer()
    -- Cancel any existing timer
    self:CancelTimeout()
    
    -- Create new timer that checks every CHECK_INTERVAL seconds
    timeoutTimer = C_Timer.NewTicker(CONFIG.CHECK_INTERVAL, function()
        self:CheckActivityTimeout()
    end)
end

-- Check if we should end combat due to inactivity
function MySimpleCombatDetector:CheckActivityTimeout()
    if not inCombat or not lastActivityTime then
        self:CancelTimeout()
        return
    end
    
    local timeSinceActivity = GetTime() - lastActivityTime
    
    if timeSinceActivity >= CONFIG.ACTIVITY_TIMEOUT then
        debugPrint("Combat timeout reached: %.1fs since last activity", timeSinceActivity)
        self:EndCombat()
    else
        addon:Trace("Combat continues: %.1fs since last activity", timeSinceActivity)
    end
end

-- End the current combat session
function MySimpleCombatDetector:EndCombat()
    if not inCombat or not currentSessionData then
        debugPrint("EndCombat called but no active session")
        return
    end
    
    -- Cancel timeout timer
    self:CancelTimeout()
    
    -- Finalize current segment before ending combat
    if currentSegment then
        self:FinalizeCurrentSegment()
    end
    
    -- End TimestampManager combat tracking
    if addon.MyTimestampManager then
        addon.MyTimestampManager:EndCombat()
        currentSessionData.endTime = addon.MyTimestampManager:GetTimestampData().combatEndTime
    else
        currentSessionData.endTime = GetTime()
    end
    
    -- Calculate duration and validate session with fault tolerance
    local duration = 0
    if currentSessionData.startTime and currentSessionData.endTime then
        duration = currentSessionData.endTime - currentSessionData.startTime
    else
        -- Fallback: estimate duration from first and last event if available
        debugPrint("Warning: Missing startTime or endTime, using fallback duration")
        duration = 1  -- Minimum duration to avoid division by zero
    end
    
    currentSessionData.duration = duration  -- Explicitly store duration
    local eventCount = currentSessionData.eventCount or 0
    local activityRate = duration > 0 and (eventCount / duration) or 0
    
    debugPrint("Combat ended: %s (%.1fs, %d events, %.2f events/sec, %d segments)", 
        currentSessionData.id or "unknown", duration, eventCount, activityRate, currentSessionData.segmentCount or 0)
    
    -- Check if session meets minimum criteria
    if duration >= CONFIG.MIN_DURATION and 
       eventCount >= CONFIG.MIN_EVENTS and 
       activityRate >= CONFIG.MIN_ACTIVITY_RATE then
        
        -- Store the session (StorageManager will create safe copies)
        self:StoreSession(currentSessionData)
        
        -- Trigger auto-scaling update with fresh session data
        if addon.MyCombatMeterScaler then
            -- Create session data for scaler with calculated peak values
            local sessionDataForScaler = {
                duration = duration,
                eventCount = eventCount,
                peakDPS = self:CalculateSessionPeakDPS(currentSessionData),
                peakHPS = self:CalculateSessionPeakHPS(currentSessionData),
                id = currentSessionData.id
            }
            
            debugPrint("Triggering auto-scale update with session data: Peak DPS: %.0f", sessionDataForScaler.peakDPS or 0)
            addon.MyCombatMeterScaler:AutoUpdateAfterCombat(sessionDataForScaler)
        else
            debugPrint("MyCombatMeterScaler not available for auto-update")
        end
        
        infoPrint("Session stored: %s", currentSessionData.id)
    else
        debugPrint("Session discarded: insufficient activity (%s)", currentSessionData.id)
    end
    
    -- Publish combat state change to message queue before resetting
    self:PublishCombatStateChange(false)
    
    -- Clean up pooled tables before resetting (for both stored and discarded sessions)
    if currentSessionData then
        self:CleanupSessionTables(currentSessionData)
    end
    
    -- Clean up current segment if it wasn't added to session
    if currentSegment and currentSegment.events then
        for _, eventData in ipairs(currentSegment.events) do
            if eventData then
                addon.StorageManager:ReleaseTable(eventData)
            end
        end
        addon.StorageManager:ReleaseTable(currentSegment.events)
        addon.StorageManager:ReleaseTable(currentSegment)
    end
    
    -- Reset combat state including segmentation
    inCombat = false
    combatStartTime = nil
    lastActivityTime = nil
    currentSessionData = nil
    currentSegment = nil
    segmentCounter = 0
    lastSegmentTime = nil
end

-- Store the completed session
function MySimpleCombatDetector:StoreSession(sessionData)
    if addon.StorageManager then
        addon.StorageManager:StoreCombatSession(sessionData)
    else
        errorPrint("StorageManager not available - session lost")
    end
end

-- Clean up pooled tables for discarded sessions
function MySimpleCombatDetector:CleanupSessionTables(sessionData)
    if not sessionData or not addon.StorageManager then
        return
    end
    
    -- Clean up segments first
    if sessionData.segments then
        for _, segment in ipairs(sessionData.segments) do
            if segment then
                -- Clean up events in this segment
                if segment.events then
                    for _, eventData in ipairs(segment.events) do
                        if eventData then
                            addon.StorageManager:ReleaseTable(eventData)
                        end
                    end
                    addon.StorageManager:ReleaseTable(segment.events)
                end
                -- Release the segment itself
                addon.StorageManager:ReleaseTable(segment)
            end
        end
        -- Release the segments array
        addon.StorageManager:ReleaseTable(sessionData.segments)
    end
    
    -- Return individual event tables to pool
    if sessionData.events then
        for _, eventData in ipairs(sessionData.events) do
            if eventData then
                addon.StorageManager:ReleaseTable(eventData)
            end
        end
        -- Return the events array itself
        addon.StorageManager:ReleaseTable(sessionData.events)
    end
    
    -- Return the guidMap table to pool
    if sessionData.guidMap then
        addon.StorageManager:ReleaseTable(sessionData.guidMap)
    end
    
    -- Return the main session data table to pool
    addon.StorageManager:ReleaseTable(sessionData)
    
    debugPrint("Cleaned up pooled tables for discarded session")
end

-- Cancel the timeout timer
function MySimpleCombatDetector:CancelTimeout()
    if timeoutTimer then
        timeoutTimer:Cancel()
        timeoutTimer = nil
    end
end

-- Public API methods
function MySimpleCombatDetector:IsInCombat()
    return inCombat
end

function MySimpleCombatDetector:GetCurrentSession()
    return currentSessionData
end

function MySimpleCombatDetector:ForceEndCombat()
    if inCombat then
        self:EndCombat()
    end
end

-- Debug method to check current state
function MySimpleCombatDetector:GetDebugInfo()
    return {
        inCombat = inCombat,
        sessionId = currentSessionData and currentSessionData.id or nil,
        duration = currentSessionData and (GetTime() - currentSessionData.startTime) or 0,
        eventCount = currentSessionData and currentSessionData.eventCount or 0,
        timeSinceActivity = lastActivityTime and (GetTime() - lastActivityTime) or 0,
        hasTimer = timeoutTimer ~= nil
    }
end

-- Generate 4-character alphanumeric hash from session ID
function MySimpleCombatDetector:GenerateSessionHash(sessionId)
    local hash = 0
    local chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"  -- 36 characters (base36)
    
    -- Create a simple hash from the session ID
    for i = 1, #sessionId do
        hash = hash + string.byte(sessionId, i) * (i * 31)
    end
    
    -- Convert to 4-character base36 string
    local result = ""
    for i = 1, 4 do
        local remainder = hash % 36
        result = string.sub(chars, remainder + 1, remainder + 1) .. result
        hash = math.floor(hash / 36)
    end
    
    return result
end

-- Calculate peak DPS from session events
function MySimpleCombatDetector:CalculateSessionPeakDPS(sessionData)
    if not sessionData or not sessionData.events or sessionData.duration <= 0 then
        return 0
    end
    
    local totalDamage = 0
    local playerGUID = UnitGUID("player")
    
    -- Sum all damage events where player is the source
    for _, event in ipairs(sessionData.events) do
        if event.sourceGUID == playerGUID and event.subevent and event.subevent:find("DAMAGE") then
            if event.args and #event.args > 0 then
                local amount = 0
                if event.subevent == "SWING_DAMAGE" then
                    amount = event.args[1] or 0
                elseif event.subevent == "SPELL_DAMAGE" or event.subevent == "RANGE_DAMAGE" or event.subevent == "SPELL_PERIODIC_DAMAGE" then
                    amount = event.args[4] or 0
                else
                    amount = event.args[4] or event.args[1] or 0
                end
                
                amount = tonumber(amount) or 0
                if amount > 0 and amount < 10000000 then -- Sanity check
                    totalDamage = totalDamage + amount
                end
            end
        end
    end
    
    -- Calculate average DPS and estimate peak as 150% of average
    local avgDPS = totalDamage / sessionData.duration
    local peakDPS = avgDPS * 1.5
    
    debugPrint("Session peak DPS calculation: %d total damage / %.1fs = %.0f avg DPS, %.0f peak DPS", 
        totalDamage, sessionData.duration, avgDPS, peakDPS)
    
    return peakDPS
end

-- Calculate peak HPS from session events
function MySimpleCombatDetector:CalculateSessionPeakHPS(sessionData)
    if not sessionData or not sessionData.events or sessionData.duration <= 0 then
        return 0
    end
    
    local totalHealing = 0
    local playerGUID = UnitGUID("player")
    
    -- Sum all healing events where player is the source
    for _, event in ipairs(sessionData.events) do
        if event.sourceGUID == playerGUID and event.subevent and event.subevent:find("HEAL") then
            if event.args and #event.args > 0 then
                local amount = event.args[4] or 0 -- Healing amount is typically at args[4]
                amount = tonumber(amount) or 0
                if amount > 0 and amount < 10000000 then -- Sanity check
                    totalHealing = totalHealing + amount
                end
            end
        end
    end
    
    -- Calculate average HPS and estimate peak as 150% of average
    local avgHPS = totalHealing / sessionData.duration
    local peakHPS = avgHPS * 1.5
    
    debugPrint("Session peak HPS calculation: %d total healing / %.1fs = %.0f avg HPS, %.0f peak HPS", 
        totalHealing, sessionData.duration, avgHPS, peakHPS)
    
    return peakHPS
end

-- Session ID validation helper
function MySimpleCombatDetector:ValidateSessionId(sessionId)
    if not sessionId or type(sessionId) ~= "string" then
        return false, "Invalid session ID format"
    end
    
    -- Extract parts: timestamp-counter-checksum
    local parts = {}
    for part in sessionId:gmatch("[^-]+") do
        table.insert(parts, part)
    end
    
    if #parts ~= 3 then
        return false, "Session ID must have 3 parts separated by dashes"
    end
    
    -- Reconstruct base ID without checksum
    local baseId = string.format("%s-%s", parts[1], parts[2])
    
    -- Calculate expected checksum
    local expectedChecksum = 0
    for i = 1, #baseId do
        expectedChecksum = expectedChecksum + string.byte(baseId, i)
    end
    expectedChecksum = expectedChecksum % 1000
    
    -- Compare with provided checksum
    local providedChecksum = tonumber(parts[3])
    if expectedChecksum == providedChecksum then
        return true, "Session ID is valid"
    else
        return false, string.format("Checksum mismatch: expected %03d, got %03d", expectedChecksum, providedChecksum)
    end
end

-- Configuration methods
function MySimpleCombatDetector:GetConfig()
    return CONFIG
end

-- Enable/disable internal debug mode
function MySimpleCombatDetector:SetInternalDebug(enabled)
    DEBUG_MODE = enabled
    debugPrint("Internal debug mode:", enabled and "enabled" or "disabled")
end

return MySimpleCombatDetector