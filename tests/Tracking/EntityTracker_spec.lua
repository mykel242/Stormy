require("tests.spec_helper").apply()

describe("EntityTracker", function()
    local EntityTracker
    local addon
    local mockEventBus
    
    before_each(function()
        -- Reset global state
        _G.STORMY_NAMESPACE = {}
        addon = _G.STORMY_NAMESPACE
        
        -- Mock EventBus first
        mockEventBus = {
            Dispatch = function() end,
            DispatchPetDetected = function() end
        }
        addon.EventBus = mockEventBus
        
        -- Load dependencies
        dofile("Core/TablePool.lua")
        dofile("Tracking/EntityTracker.lua")
        EntityTracker = addon.EntityTracker
        
        -- Initialize the tracker
        EntityTracker:Initialize()
    end)
    
    describe("initialization", function()
        it("should have required methods", function()
            assert.is_not_nil(EntityTracker)
            assert.is_function(EntityTracker.UpdatePlayer)
            assert.is_function(EntityTracker.AddPet)
            assert.is_function(EntityTracker.CheckPetByCombatFlags)
            assert.is_function(EntityTracker.IsPlayer)
            assert.is_function(EntityTracker.IsPet)
            assert.is_function(EntityTracker.IsPlayerControlled)
        end)
        
        it("should initialize properly", function()
            local stats = EntityTracker:GetStats()
            assert.is_not_nil(stats)
            assert.is_not_nil(stats.player)
            assert.is_not_nil(stats.tracking)
        end)
    end)
    
    describe("player tracking", function()
        it("should track player GUID", function()
            EntityTracker:UpdatePlayer()
            local stats = EntityTracker:GetStats()
            assert.is_not_nil(stats.player.guid)
            assert.equals("Player-1234-00000001", stats.player.guid)
        end)
        
        it("should identify player GUID correctly", function()
            EntityTracker:UpdatePlayer()
            assert.is_true(EntityTracker:IsPlayer("Player-1234-00000001"))
            assert.is_false(EntityTracker:IsPlayer("Pet-1234-00000002"))
        end)
    end)
    
    describe("pet detection", function()
        it("should add pets manually", function()
            local petGUID = "Pet-1234-00000002"
            local petName = "TestPet"
            
            local result = EntityTracker:AddPet(petGUID, petName, "Pet")
            assert.is_true(result)
            assert.is_true(EntityTracker:IsPet(petGUID))
            
            local stats = EntityTracker:GetStats()
            assert.equals(1, stats.tracking.activePets)
        end)
        
        it("should not add invalid pets", function()
            -- Test nil GUID
            local result = EntityTracker:AddPet(nil, "TestPet", "Pet")
            assert.is_false(result)
            
            -- Test empty GUID
            result = EntityTracker:AddPet("", "TestPet", "Pet")
            assert.is_false(result)
            
            local stats = EntityTracker:GetStats()
            assert.equals(0, stats.tracking.activePets)
        end)
        
        it("should remove pets", function()
            local petGUID = "Pet-1234-00000002"
            EntityTracker:AddPet(petGUID, "TestPet", "Pet")
            
            assert.is_true(EntityTracker:IsPet(petGUID))
            
            local result = EntityTracker:RemovePet(petGUID)
            assert.is_true(result)
            assert.is_false(EntityTracker:IsPet(petGUID))
        end)
        
        it("should get active pets", function()
            EntityTracker:AddPet("Pet-1234-00000002", "Pet1", "Pet")
            EntityTracker:AddPet("Pet-1234-00000003", "Pet2", "Guardian")
            
            local activePets = EntityTracker:GetActivePets()
            assert.is_not_nil(activePets)
            assert.is_not_nil(activePets["Pet-1234-00000002"])
            assert.is_not_nil(activePets["Pet-1234-00000003"])
            assert.equals("Pet1", activePets["Pet-1234-00000002"].name)
            assert.equals("Pet2", activePets["Pet-1234-00000003"].name)
        end)
    end)
    
    describe("CheckPetByCombatFlags", function()
        it("should return false for invalid parameters", function()
            -- Test nil GUID
            local result = EntityTracker:CheckPetByCombatFlags(nil, "TestPet", 0x00001001)
            assert.is_false(result)
            
            -- Test nil flags
            result = EntityTracker:CheckPetByCombatFlags("Pet-1234-00000002", "TestPet", nil)
            assert.is_false(result)
        end)
        
        it("should detect pets by combat flags", function()
            local petGUID = "Pet-1234-00000002"
            local petName = "TestPet"
            
            -- Combat flags: COMBATLOG_OBJECT_AFFILIATION_MINE (0x00000001) + COMBATLOG_OBJECT_TYPE_PET (0x00001000)
            local petFlags = 0x00001001
            
            local result = EntityTracker:CheckPetByCombatFlags(petGUID, petName, petFlags)
            assert.is_true(result)
            assert.is_true(EntityTracker:IsPet(petGUID))
            
            local stats = EntityTracker:GetStats()
            assert.equals(1, stats.tracking.activePets)
        end)
        
        it("should detect guardians by combat flags", function()
            local guardianGUID = "Guardian-1234-00000003"
            local guardianName = "TestGuardian"
            
            -- Combat flags: COMBATLOG_OBJECT_AFFILIATION_MINE (0x00000001) + COMBATLOG_OBJECT_TYPE_GUARDIAN (0x00002000)
            local guardianFlags = 0x00002001
            
            local result = EntityTracker:CheckPetByCombatFlags(guardianGUID, guardianName, guardianFlags)
            assert.is_true(result)
            assert.is_true(EntityTracker:IsPet(guardianGUID))
            
            local stats = EntityTracker:GetStats()
            assert.equals(1, stats.tracking.activePets)
        end)
        
        it("should not detect non-player-controlled entities", function()
            local enemyGUID = "Enemy-1234-00000004"
            local enemyName = "EnemyPet"
            
            -- Combat flags: COMBATLOG_OBJECT_TYPE_PET (0x00001000) without COMBATLOG_OBJECT_AFFILIATION_MINE
            local enemyFlags = 0x00001000
            
            local result = EntityTracker:CheckPetByCombatFlags(enemyGUID, enemyName, enemyFlags)
            assert.is_false(result)
            assert.is_false(EntityTracker:IsPet(enemyGUID))
            
            local stats = EntityTracker:GetStats()
            assert.equals(0, stats.tracking.activePets)
        end)
        
        it("should return true for already tracked pets", function()
            local petGUID = "Pet-1234-00000002"
            EntityTracker:AddPet(petGUID, "TestPet", "Pet")
            
            -- Should return true even with different flags since it's already tracked
            local result = EntityTracker:CheckPetByCombatFlags(petGUID, "TestPet", 0)
            assert.is_true(result)
        end)
    end)
    
    describe("guardian tracking", function()
        it("should add guardians", function()
            local guardianGUID = "Guardian-1234-00000003"
            local guardianName = "TestGuardian"
            local spellId = 12345
            
            local result = EntityTracker:AddGuardian(guardianGUID, guardianName, spellId)
            assert.is_true(result)
            assert.is_true(EntityTracker:IsGuardian(guardianGUID))
            
            local stats = EntityTracker:GetStats()
            assert.equals(1, stats.tracking.activeGuardians)
        end)
        
        it("should remove guardians", function()
            local guardianGUID = "Guardian-1234-00000003"
            EntityTracker:AddGuardian(guardianGUID, "TestGuardian", 12345)
            
            assert.is_true(EntityTracker:IsGuardian(guardianGUID))
            
            local result = EntityTracker:RemoveGuardian(guardianGUID)
            assert.is_true(result)
            assert.is_false(EntityTracker:IsGuardian(guardianGUID))
        end)
    end)
    
    describe("entity identification", function()
        it("should identify player-controlled entities", function()
            EntityTracker:UpdatePlayer()
            EntityTracker:AddPet("Pet-1234-00000002", "TestPet", "Pet")
            EntityTracker:AddGuardian("Guardian-1234-00000003", "TestGuardian", 12345)
            
            assert.is_true(EntityTracker:IsPlayerControlled("Player-1234-00000001"))
            assert.is_true(EntityTracker:IsPlayerControlled("Pet-1234-00000002"))
            assert.is_true(EntityTracker:IsPlayerControlled("Guardian-1234-00000003"))
            assert.is_false(EntityTracker:IsPlayerControlled("Enemy-1234-00000004"))
        end)
        
        it("should return correct entity types", function()
            EntityTracker:UpdatePlayer()
            EntityTracker:AddPet("Pet-1234-00000002", "TestPet", "Pet")
            EntityTracker:AddGuardian("Guardian-1234-00000003", "TestGuardian", 12345)
            
            assert.equals("player", EntityTracker:GetEntityType("Player-1234-00000001"))
            assert.equals("pet", EntityTracker:GetEntityType("Pet-1234-00000002"))
            assert.equals("guardian", EntityTracker:GetEntityType("Guardian-1234-00000003"))
            assert.equals("unknown", EntityTracker:GetEntityType("Enemy-1234-00000004"))
        end)
        
        it("should return entity names", function()
            EntityTracker:UpdatePlayer()
            EntityTracker:AddPet("Pet-1234-00000002", "TestPet", "Pet")
            EntityTracker:AddGuardian("Guardian-1234-00000003", "TestGuardian", 12345)
            
            assert.equals("TestPlayer", EntityTracker:GetEntityName("Player-1234-00000001"))
            assert.equals("TestPet", EntityTracker:GetEntityName("Pet-1234-00000002"))
            assert.equals("TestGuardian", EntityTracker:GetEntityName("Guardian-1234-00000003"))
            
            -- Should return GUID for unknown entities
            assert.equals("Unknown-1234-00000004", EntityTracker:GetEntityName("Unknown-1234-00000004"))
        end)
    end)
    
    describe("maintenance", function()
        it("should clear all pets", function()
            EntityTracker:AddPet("Pet-1234-00000002", "Pet1", "Pet")
            EntityTracker:AddPet("Pet-1234-00000003", "Pet2", "Pet")
            
            local stats = EntityTracker:GetStats()
            assert.equals(2, stats.tracking.activePets)
            
            local count = EntityTracker:ClearAllPets()
            assert.equals(2, count)
            
            stats = EntityTracker:GetStats()
            assert.equals(0, stats.tracking.activePets)
        end)
        
        it("should clear all guardians", function()
            EntityTracker:AddGuardian("Guardian-1234-00000003", "Guardian1", 12345)
            EntityTracker:AddGuardian("Guardian-1234-00000004", "Guardian2", 12346)
            
            local stats = EntityTracker:GetStats()
            assert.equals(2, stats.tracking.activeGuardians)
            
            local count = EntityTracker:ClearAllGuardians()
            assert.equals(2, count)
            
            stats = EntityTracker:GetStats()
            assert.equals(0, stats.tracking.activeGuardians)
        end)
    end)
end)