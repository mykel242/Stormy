-- EntityTracker.lua
-- Lightweight GUID management and pet detection for performance-focused tracking
-- Handles player, pet, and guardian GUID caching with minimal overhead

local addonName, addon = ...

-- =============================================================================
-- ENTITY TRACKER MODULE
-- =============================================================================

addon.EntityTracker = {}
local EntityTracker = addon.EntityTracker

-- Entity tracking state (mutable for performance)
local trackingState = {
    -- Player data
    playerGUID = nil,
    playerName = nil,
    playerClass = nil,
    playerLevel = nil,
    
    -- Pet tracking
    activePets = {},        -- [guid] = { name, type, detectTime, lastSeen }
    petHistory = {},        -- [guid] = { name, dismissTime } for recent dismissals
    
    -- Guardian tracking (temporary summons like totems)
    activeGuardians = {},   -- [guid] = { name, spellId, detectTime, lastSeen }
    
    -- GUID to name cache (weak references for memory management)
    guidCache = setmetatable({}, { __mode = "v" }),
    
    -- Statistics
    totalEntitiesTracked = 0,
    petsDetected = 0,
    guardiansDetected = 0,
    lastScanTime = 0,
    lastCleanupTime = 0
}

-- Configuration
local CONFIG = {
    PET_TIMEOUT = 30,           -- Remove pets not seen for 30 seconds
    GUARDIAN_TIMEOUT = 60,      -- Remove guardians not seen for 60 seconds
    CACHE_CLEANUP_INTERVAL = 60, -- Clean cache every 60 seconds
    MAX_CACHE_SIZE = 1000,      -- Maximum cached entities
    SCAN_INTERVAL = 2.0         -- Pet scan interval during activity
}

-- =============================================================================
-- CORE ENTITY TRACKING
-- =============================================================================

-- Update player information
function EntityTracker:UpdatePlayer()
    local newGUID = UnitGUID("player")
    local newName = UnitName("player")
    
    if newGUID and newGUID ~= trackingState.playerGUID then
        trackingState.playerGUID = newGUID
        trackingState.playerName = newName
        trackingState.playerClass = UnitClass("player")
        trackingState.playerLevel = UnitLevel("player")
        
        -- Clear pet tracking when player changes
        self:ClearAllPets()
        
        -- Cache the player
        self:CacheEntity(newGUID, newName, "Player")
        
        -- print(string.format("[STORMY] Player updated: %s (%s)", newName, newGUID))
        
        -- Dispatch event
        addon.EventBus:Dispatch("PLAYER_UPDATED", {
            guid = newGUID,
            name = newName,
            class = trackingState.playerClass,
            level = trackingState.playerLevel
        })
    end
    
    return trackingState.playerGUID, trackingState.playerName
end

-- Add or update a pet
function EntityTracker:AddPet(petGUID, petName, petType)
    if not petGUID or petGUID == "" then
        return false
    end
    
    local now = GetTime()
    local isNewPet = not trackingState.activePets[petGUID]
    
    -- Add to active pets
    trackingState.activePets[petGUID] = {
        name = petName or "Unknown Pet",
        type = petType or "Pet",
        detectTime = isNewPet and now or trackingState.activePets[petGUID].detectTime,
        lastSeen = now
    }
    
    -- Cache the entity
    self:CacheEntity(petGUID, petName, petType or "Pet")
    
    -- Update statistics
    if isNewPet then
        trackingState.petsDetected = trackingState.petsDetected + 1
        trackingState.totalEntitiesTracked = trackingState.totalEntitiesTracked + 1
        
        -- print(string.format("[STORMY] Pet detected: %s (%s)", petName or "Unknown", petGUID))
        
        -- Dispatch event
        addon.EventBus:DispatchPetDetected({
            guid = petGUID,
            name = petName,
            type = petType,
            isNewDetection = true
        })
    end
    
    return true
end

-- Add or update a guardian (totem, statue, etc.)
function EntityTracker:AddGuardian(guardianGUID, guardianName, spellId)
    if not guardianGUID or guardianGUID == "" then
        return false
    end
    
    local now = GetTime()
    local isNewGuardian = not trackingState.activeGuardians[guardianGUID]
    
    -- Add to active guardians
    trackingState.activeGuardians[guardianGUID] = {
        name = guardianName or "Unknown Guardian",
        spellId = spellId,
        detectTime = isNewGuardian and now or trackingState.activeGuardians[guardianGUID].detectTime,
        lastSeen = now
    }
    
    -- Cache the entity
    self:CacheEntity(guardianGUID, guardianName, "Guardian")
    
    -- Update statistics
    if isNewGuardian then
        trackingState.guardiansDetected = trackingState.guardiansDetected + 1
        trackingState.totalEntitiesTracked = trackingState.totalEntitiesTracked + 1
        
        -- print(string.format("[STORMY] Guardian detected: %s (%s)", guardianName or "Unknown", guardianGUID))
        
        -- Dispatch event
        addon.EventBus:Dispatch("GUARDIAN_DETECTED", {
            guid = guardianGUID,
            name = guardianName,
            spellId = spellId,
            isNewDetection = true
        })
    end
    
    return true
end

-- Remove a pet (when dismissed or timed out)
function EntityTracker:RemovePet(petGUID)
    local pet = trackingState.activePets[petGUID]
    if pet then
        -- Move to history for potential re-detection
        trackingState.petHistory[petGUID] = {
            name = pet.name,
            dismissTime = GetTime()
        }
        
        trackingState.activePets[petGUID] = nil
        
        -- print(string.format("[STORMY] Pet removed: %s (%s)", pet.name, petGUID))
        
        -- Dispatch event
        addon.EventBus:Dispatch("PET_REMOVED", {
            guid = petGUID,
            name = pet.name
        })
        
        return true
    end
    
    return false
end

-- Remove a guardian
function EntityTracker:RemoveGuardian(guardianGUID)
    local guardian = trackingState.activeGuardians[guardianGUID]
    if guardian then
        trackingState.activeGuardians[guardianGUID] = nil
        
        -- print(string.format("[STORMY] Guardian removed: %s (%s)", guardian.name, guardianGUID))
        
        -- Dispatch event
        addon.EventBus:Dispatch("GUARDIAN_REMOVED", {
            guid = guardianGUID,
            name = guardian.name
        })
        
        return true
    end
    
    return false
end

-- =============================================================================
-- ENTITY IDENTIFICATION
-- =============================================================================

-- Check if a GUID belongs to the player
function EntityTracker:IsPlayer(guid)
    return guid == trackingState.playerGUID
end

-- Check if a GUID belongs to a tracked pet
function EntityTracker:IsPet(guid)
    return trackingState.activePets[guid] ~= nil
end

-- Check if a GUID belongs to a tracked guardian
function EntityTracker:IsGuardian(guid)
    return trackingState.activeGuardians[guid] ~= nil
end

-- Check if a GUID belongs to any player-controlled entity
function EntityTracker:IsPlayerControlled(guid)
    return self:IsPlayer(guid) or self:IsPet(guid) or self:IsGuardian(guid)
end

-- Get entity type for a GUID
function EntityTracker:GetEntityType(guid)
    if self:IsPlayer(guid) then
        return "player"
    elseif self:IsPet(guid) then
        return "pet"
    elseif self:IsGuardian(guid) then
        return "guardian"
    else
        return "unknown"
    end
end

-- Get entity name for a GUID (with caching)
function EntityTracker:GetEntityName(guid)
    -- Check direct tracking first
    if guid == trackingState.playerGUID then
        return trackingState.playerName
    end
    
    local pet = trackingState.activePets[guid]
    if pet then
        return pet.name
    end
    
    local guardian = trackingState.activeGuardians[guid]
    if guardian then
        return guardian.name
    end
    
    -- Check cache
    local cached = trackingState.guidCache[guid]
    if cached then
        return cached.name
    end
    
    -- Return GUID as fallback
    return guid
end

-- =============================================================================
-- ACTIVE SCANNING AND DETECTION
-- =============================================================================

-- Scan for current player pet
function EntityTracker:ScanPlayerPet()
    local petGUID = UnitGUID("pet")
    if petGUID then
        local petName = UnitName("pet")
        local petFamily = UnitCreatureFamily("pet") or "Pet"
        self:AddPet(petGUID, petName, petFamily)
        return true
    end
    return false
end

-- Scan for all group pets (if in party/raid)
function EntityTracker:ScanGroupPets()
    local found = 0
    
    -- Don't track other players' pets - only our own
    -- This keeps the system focused and performant
    
    return found
end

-- Periodic scan for pets and guardians
function EntityTracker:PeriodicScan()
    local now = GetTime()
    
    -- Throttle scanning
    if now - trackingState.lastScanTime < CONFIG.SCAN_INTERVAL then
        return
    end
    
    trackingState.lastScanTime = now
    
    -- Scan for player pet
    self:ScanPlayerPet()
    
    -- Update last seen times for active entities based on combat events
    -- (This will be called by EventProcessor when it sees events)
end

-- Update last seen time for an entity (called by EventProcessor)
function EntityTracker:UpdateLastSeen(guid)
    local now = GetTime()
    
    local pet = trackingState.activePets[guid]
    if pet then
        pet.lastSeen = now
        return
    end
    
    local guardian = trackingState.activeGuardians[guid]
    if guardian then
        guardian.lastSeen = now
        return
    end
end

-- =============================================================================
-- MAINTENANCE AND CLEANUP
-- =============================================================================

-- Remove timed-out entities
function EntityTracker:CleanupTimedOutEntities()
    local now = GetTime()
    local removedPets = 0
    local removedGuardians = 0
    
    -- Remove timed-out pets
    for guid, pet in pairs(trackingState.activePets) do
        if now - pet.lastSeen > CONFIG.PET_TIMEOUT then
            self:RemovePet(guid)
            removedPets = removedPets + 1
        end
    end
    
    -- Remove timed-out guardians
    for guid, guardian in pairs(trackingState.activeGuardians) do
        if now - guardian.lastSeen > CONFIG.GUARDIAN_TIMEOUT then
            self:RemoveGuardian(guid)
            removedGuardians = removedGuardians + 1
        end
    end
    
    -- Clean pet history (remove very old entries)
    for guid, history in pairs(trackingState.petHistory) do
        if now - history.dismissTime > 300 then -- 5 minutes
            trackingState.petHistory[guid] = nil
        end
    end
    
    return removedPets + removedGuardians
end

-- Cache cleanup
function EntityTracker:CleanupCache()
    local cacheSize = 0
    for _ in pairs(trackingState.guidCache) do
        cacheSize = cacheSize + 1
    end
    
    -- If cache is too large, clear it (weak references will handle most cleanup)
    if cacheSize > CONFIG.MAX_CACHE_SIZE then
        trackingState.guidCache = setmetatable({}, { __mode = "v" })
        return cacheSize
    end
    
    return 0
end

-- Cache an entity
function EntityTracker:CacheEntity(guid, name, entityType)
    if guid and name then
        trackingState.guidCache[guid] = {
            name = name,
            type = entityType,
            cached = GetTime()
        }
    end
end

-- Periodic maintenance
function EntityTracker:Maintenance()
    local now = GetTime()
    
    if now - trackingState.lastCleanupTime > CONFIG.CACHE_CLEANUP_INTERVAL then
        local removedEntities = self:CleanupTimedOutEntities()
        local clearedCache = self:CleanupCache()
        
        trackingState.lastCleanupTime = now
        
        if removedEntities > 0 or clearedCache > 0 then
            -- print(string.format("[STORMY] Cleanup: %d entities, %d cache entries", 
            --     removedEntities, clearedCache))
        end
    end
end

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================

-- Get all active pets
function EntityTracker:GetActivePets()
    local pets = {}
    for guid, pet in pairs(trackingState.activePets) do
        pets[guid] = {
            name = pet.name,
            type = pet.type,
            detectTime = pet.detectTime,
            lastSeen = pet.lastSeen,
            age = GetTime() - pet.detectTime
        }
    end
    return pets
end

-- Get all active guardians
function EntityTracker:GetActiveGuardians()
    local guardians = {}
    for guid, guardian in pairs(trackingState.activeGuardians) do
        guardians[guid] = {
            name = guardian.name,
            spellId = guardian.spellId,
            detectTime = guardian.detectTime,
            lastSeen = guardian.lastSeen,
            age = GetTime() - guardian.detectTime
        }
    end
    return guardians
end

-- Clear all pets
function EntityTracker:ClearAllPets()
    local count = 0
    for guid in pairs(trackingState.activePets) do
        self:RemovePet(guid)
        count = count + 1
    end
    return count
end

-- Clear all guardians
function EntityTracker:ClearAllGuardians()
    local count = 0
    for guid in pairs(trackingState.activeGuardians) do
        self:RemoveGuardian(guid)
        count = count + 1
    end
    return count
end

-- =============================================================================
-- DEBUGGING AND MONITORING
-- =============================================================================

-- Get tracking statistics
function EntityTracker:GetStats()
    local activePetCount = 0
    local activeGuardianCount = 0
    local cacheSize = 0
    
    for _ in pairs(trackingState.activePets) do
        activePetCount = activePetCount + 1
    end
    
    for _ in pairs(trackingState.activeGuardians) do
        activeGuardianCount = activeGuardianCount + 1
    end
    
    for _ in pairs(trackingState.guidCache) do
        cacheSize = cacheSize + 1
    end
    
    return {
        player = {
            guid = trackingState.playerGUID,
            name = trackingState.playerName,
            class = trackingState.playerClass,
            level = trackingState.playerLevel
        },
        
        tracking = {
            activePets = activePetCount,
            activeGuardians = activeGuardianCount,
            totalEntitiesTracked = trackingState.totalEntitiesTracked,
            petsDetected = trackingState.petsDetected,
            guardiansDetected = trackingState.guardiansDetected
        },
        
        cache = {
            size = cacheSize,
            maxSize = CONFIG.MAX_CACHE_SIZE
        },
        
        timing = {
            lastScanTime = trackingState.lastScanTime,
            lastCleanupTime = trackingState.lastCleanupTime
        }
    }
end

-- Debug information
function EntityTracker:Debug()
    local stats = self:GetStats()
    print("=== EntityTracker Debug ===")
    print(string.format("Player: %s (%s)", stats.player.name or "Unknown", stats.player.guid or "None"))
    print(string.format("Active Pets: %d", stats.tracking.activePets))
    print(string.format("Active Guardians: %d", stats.tracking.activeGuardians))
    print(string.format("Total Tracked: %d", stats.tracking.totalEntitiesTracked))
    print(string.format("Cache: %d/%d entries", stats.cache.size, stats.cache.maxSize))
    
    -- Show active entities
    if stats.tracking.activePets > 0 then
        print("Active Pets:")
        for guid, pet in pairs(self:GetActivePets()) do
            print(string.format("  %s: %s (%.1fs ago)", pet.name, guid, GetTime() - pet.lastSeen))
        end
    end
    
    if stats.tracking.activeGuardians > 0 then
        print("Active Guardians:")
        for guid, guardian in pairs(self:GetActiveGuardians()) do
            print(string.format("  %s: %s (%.1fs ago)", guardian.name, guid, GetTime() - guardian.lastSeen))
        end
    end
end

-- =============================================================================
-- EVENT HANDLING
-- =============================================================================

-- Set up WoW event handlers
function EntityTracker:SetupEventHandlers()
    local frame = CreateFrame("Frame", "StormyEntityTracker")
    
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("UNIT_PET")
    frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    
    frame:SetScript("OnEvent", function(self, event, ...)
        if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
            EntityTracker:UpdatePlayer()
            EntityTracker:ScanPlayerPet()
        elseif event == "UNIT_PET" then
            local unit = ...
            if unit == "player" then
                EntityTracker:ScanPlayerPet()
            end
        elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
            -- Pet might change with spec
            EntityTracker:ScanPlayerPet()
        end
    end)
    
    self.frame = frame
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the entity tracker
function EntityTracker:Initialize()
    -- Set up event handlers
    self:SetupEventHandlers()
    
    -- Update player immediately if possible
    self:UpdatePlayer()
    
    -- Set up periodic maintenance
    local maintenanceTimer = C_Timer.NewTicker(CONFIG.CACHE_CLEANUP_INTERVAL, function()
        self:Maintenance()
    end)
    
    local scanTimer = C_Timer.NewTicker(CONFIG.SCAN_INTERVAL, function()
        self:PeriodicScan()
    end)
    
    self.maintenanceTimer = maintenanceTimer
    self.scanTimer = scanTimer
    
    -- print("[STORMY] EntityTracker initialized")
end

-- Module ready
EntityTracker.isReady = true