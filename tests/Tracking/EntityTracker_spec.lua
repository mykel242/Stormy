require("tests.spec_helper").apply()

describe("EntityTracker", function()
    local EntityTracker
    local addon
    
    before_each(function()
        -- Reset global state
        _G.STORMY_NAMESPACE = {}
        addon = _G.STORMY_NAMESPACE
        
        -- Mock bit operations (WoW provides these)
        _G.bit = {
            band = function(a, b) return a & b end,
            bor = function(a, b) return a | b end,
            lshift = function(a, b) return a << b end,
            rshift = function(a, b) return a >> b end,
        }
        
        -- Load EntityTracker
        dofile("Tracking/EntityTracker.lua")
        EntityTracker = addon.EntityTracker
        
        -- Initialize with minimal setup
        EntityTracker:UpdatePlayer()
    end)
    
    describe("CheckPetByCombatFlags", function()
        it("should return false for nil inputs", function()
            assert.is_false(EntityTracker:CheckPetByCombatFlags(nil, nil, nil))
            assert.is_false(EntityTracker:CheckPetByCombatFlags("guid", "name", nil))
            assert.is_false(EntityTracker:CheckPetByCombatFlags(nil, "name", 0x1234))
        end)
        
        it("should return true for already tracked pets", function()
            local petGUID = "Pet-0-1234-5678"
            
            -- Add pet first
            EntityTracker:AddPet(petGUID, "TestPet", "Pet")
            
            -- Should return true since pet is already tracked
            local result = EntityTracker:CheckPetByCombatFlags(petGUID, "TestPet", 0x1000)
            assert.is_true(result)
        end)
        
        it("should detect pets using combat flags", function()
            local petGUID = "Pet-0-1234-5678"
            local petName = "TestPet"
            
            -- COMBATLOG_OBJECT_TYPE_PET = 0x00001000
            -- COMBATLOG_OBJECT_AFFILIATION_MINE = 0x00000001
            local petFlags = 0x00001000 | 0x00000001  -- Pet + Mine
            
            local result = EntityTracker:CheckPetByCombatFlags(petGUID, petName, petFlags)
            assert.is_true(result)
            
            -- Should now be tracked as a pet
            assert.is_true(EntityTracker:IsPet(petGUID))
        end)
        
        it("should detect guardians using combat flags", function()
            local guardianGUID = "Guardian-0-1234-5678"
            local guardianName = "Death Knight Ghoul"
            
            -- COMBATLOG_OBJECT_TYPE_GUARDIAN = 0x00002000
            -- COMBATLOG_OBJECT_AFFILIATION_MINE = 0x00000001
            local guardianFlags = 0x00002000 | 0x00000001  -- Guardian + Mine
            
            local result = EntityTracker:CheckPetByCombatFlags(guardianGUID, guardianName, guardianFlags)
            assert.is_true(result)
            
            -- Should now be tracked as a pet (guardians are treated as pets)
            assert.is_true(EntityTracker:IsPet(guardianGUID))
        end)
        
        it("should not detect pets without MINE affiliation", function()
            local petGUID = "Pet-0-1234-5678"
            local petName = "OtherPlayerPet"
            
            -- COMBATLOG_OBJECT_TYPE_PET = 0x00001000
            -- Missing COMBATLOG_OBJECT_AFFILIATION_MINE flag
            local petFlags = 0x00001000  -- Pet but not mine
            
            local result = EntityTracker:CheckPetByCombatFlags(petGUID, petName, petFlags)
            assert.is_false(result)
            
            -- Should not be tracked
            assert.is_false(EntityTracker:IsPet(petGUID))
        end)
        
        it("should not detect non-pet entities", function()
            local npcGUID = "NPC-0-1234-5678"
            local npcName = "Training Dummy"
            
            -- COMBATLOG_OBJECT_TYPE_NPC = 0x00000400
            -- COMBATLOG_OBJECT_AFFILIATION_OUTSIDER = 0x00000008
            local npcFlags = 0x00000400 | 0x00000008  -- NPC + Outsider
            
            local result = EntityTracker:CheckPetByCombatFlags(npcGUID, npcName, npcFlags)
            assert.is_false(result)
            
            -- Should not be tracked
            assert.is_false(EntityTracker:IsPet(npcGUID))
        end)
        
        it("should handle unknown pet names gracefully", function()
            local petGUID = "Pet-0-1234-5678"
            
            -- COMBATLOG_OBJECT_TYPE_PET + COMBATLOG_OBJECT_AFFILIATION_MINE
            local petFlags = 0x00001000 | 0x00000001
            
            -- Test with nil name
            local result = EntityTracker:CheckPetByCombatFlags(petGUID, nil, petFlags)
            assert.is_true(result)
            
            -- Should be tracked with default name
            assert.is_true(EntityTracker:IsPet(petGUID))
            local pets = EntityTracker:GetActivePets()
            assert.equals("Unknown", pets[petGUID].name)
        end)
        
        it("should handle mixed pet and guardian flags correctly", function()
            local entityGUID = "Entity-0-1234-5678"
            local entityName = "TestEntity"
            
            -- Both pet and guardian flags (should still work)
            local mixedFlags = 0x00001000 | 0x00002000 | 0x00000001  -- Pet + Guardian + Mine
            
            local result = EntityTracker:CheckPetByCombatFlags(entityGUID, entityName, mixedFlags)
            assert.is_true(result)
            
            -- Should be tracked
            assert.is_true(EntityTracker:IsPet(entityGUID))
        end)
    end)
    
    describe("Pet tracking integration", function()
        it("should dispatch events when pets are detected via combat flags", function()
            local petGUID = "Pet-0-1234-5678"
            local petName = "CombatFlagPet"
            local petFlags = 0x00001000 | 0x00000001  -- Pet + Mine
            
            -- Track event dispatches (simplified mock)
            local eventDispatched = false
            local originalDispatch = addon.EventBus and addon.EventBus.DispatchPetDetected
            if addon.EventBus then
                addon.EventBus.DispatchPetDetected = function(self, event)
                    eventDispatched = true
                    assert.equals(petGUID, event.guid)
                    assert.equals(petName, event.name)
                    assert.is_true(event.isNewDetection)
                end
            end
            
            EntityTracker:CheckPetByCombatFlags(petGUID, petName, petFlags)
            
            -- Should have dispatched event if EventBus exists
            if addon.EventBus then
                assert.is_true(eventDispatched)
                -- Restore original function
                addon.EventBus.DispatchPetDetected = originalDispatch
            end
        end)
        
        it("should update statistics when detecting new pets", function()
            local initialStats = EntityTracker:GetStats()
            local initialPetCount = initialStats.tracking.petsDetected
            
            local petGUID = "Pet-0-1234-5678"
            local petFlags = 0x00001000 | 0x00000001  -- Pet + Mine
            
            EntityTracker:CheckPetByCombatFlags(petGUID, "NewPet", petFlags)
            
            local newStats = EntityTracker:GetStats()
            assert.equals(initialPetCount + 1, newStats.tracking.petsDetected)
            assert.equals(1, newStats.tracking.activePets)
        end)
    end)
end)