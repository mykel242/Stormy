-- MetadataCollector.lua
-- Context gathering system for combat sessions

local addonName, addon = ...

-- Metadata Collector module
addon.MetadataCollector = {}
local MetadataCollector = addon.MetadataCollector

-- State tracking
local isInitialized = false
local currentMetadata = {}

-- Initialize the metadata collector
function MetadataCollector:Initialize()
    if isInitialized then
        return
    end
    
    -- Create event frame for context changes
    self.frame = CreateFrame("Frame", addonName .. "MetadataCollector")
    self.frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    self.frame:RegisterEvent("GROUP_ROSTER_UPDATE")
    self.frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    self.frame:RegisterEvent("PLAYER_LEVEL_UP")
    self.frame:SetScript("OnEvent", function(frame, event, ...)
        self:OnEvent(event, ...)
    end)
    
    -- Initialize current metadata
    self:RefreshMetadata()
    
    isInitialized = true
    
    addon:Debug("MetadataCollector initialized - tracking context changes")
end

-- Event handler for context changes
function MetadataCollector:OnEvent(event, ...)
    addon:Debug("MetadataCollector: Context changed (" .. event .. ")")
    
    -- Refresh metadata when context changes
    self:RefreshMetadata()
end

-- Collect comprehensive metadata about current context
function MetadataCollector:RefreshMetadata()
    -- Release old metadata tables back to pool if they exist
    if currentMetadata and addon.StorageManager then
        self:ReleaseMetadataTables(currentMetadata)
    end
    
    -- Create new metadata using regular tables (internal data structure)
    currentMetadata = {}
    
    -- Timestamp
    currentMetadata.timestamp = GetTime()
    currentMetadata.serverTime = GetServerTime()
    
    -- Player info using regular tables
    currentMetadata.player = {}
    currentMetadata.player.name = UnitName("player")
    currentMetadata.player.realm = GetRealmName()
    currentMetadata.player.class = UnitClass("player")
    currentMetadata.player.level = UnitLevel("player")
    currentMetadata.player.spec = self:GetPlayerSpecialization()
    currentMetadata.player.itemLevel = self:GetAverageItemLevel()
    
    -- Zone info using regular tables
    currentMetadata.zone = {}
    currentMetadata.zone.name = GetRealZoneText() or GetZoneText() or GetMinimapZoneText() or "Unknown"
    currentMetadata.zone.subzone = GetSubZoneText() or ""
    currentMetadata.zone.mapID = C_Map.GetBestMapForUnit("player")
    currentMetadata.zone.instanceInfo = self:GetInstanceInfo()
    
    -- Group composition
    currentMetadata.group = self:GetGroupComposition()
    
    -- Game version info using regular tables
    currentMetadata.client = {}
    currentMetadata.client.version = GetBuildInfo()
    currentMetadata.client.addonVersion = addon.VERSION
    
    addon:Debug("Metadata refreshed: %s in %s (%s)", 
        currentMetadata.player.name,
        currentMetadata.zone.name,
        currentMetadata.group.type)
end

-- Get player specialization info
function MetadataCollector:GetPlayerSpecialization()
    local specIndex = GetSpecialization()
    if not specIndex then
        -- Use regular table since this is returned to caller
        local specInfo = {}
        specInfo.name = "None"
        specInfo.role = "NONE"
        specInfo.id = 0
        return specInfo
    end
    
    local id, name, description, icon, role = GetSpecializationInfo(specIndex)
    -- Use regular table since this is returned to caller
    local specInfo = {}
    specInfo.name = name
    specInfo.role = role
    specInfo.id = id
    specInfo.icon = icon
    return specInfo
end

-- Get average item level
function MetadataCollector:GetAverageItemLevel()
    local totalLevel = 0
    local itemCount = 0
    
    -- Check equipped items (slots 1-18, excluding shirt/tabard)
    local slots = {1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17,18}
    
    for _, slot in ipairs(slots) do
        local itemLink = GetInventoryItemLink("player", slot)
        if itemLink then
            local itemLevel = GetDetailedItemLevelInfo(itemLink)
            if itemLevel and itemLevel > 0 then
                totalLevel = totalLevel + itemLevel
                itemCount = itemCount + 1
            end
        end
    end
    
    return itemCount > 0 and math.floor(totalLevel / itemCount) or 0
end

-- Get instance information
function MetadataCollector:GetInstanceInfo()
    local name, instanceType, difficultyID, difficultyName, maxPlayers, 
          dynamicDifficulty, isDynamic, instanceID, instanceGroupSize, 
          LfgDungeonID = GetInstanceInfo()
    
    -- Use regular table since this is returned to caller
    local instanceInfo = {}
    instanceInfo.name = name
    instanceInfo.type = instanceType
    instanceInfo.difficultyID = difficultyID
    instanceInfo.difficultyName = difficultyName
    instanceInfo.maxPlayers = maxPlayers
    instanceInfo.instanceID = instanceID
    instanceInfo.isLFG = LfgDungeonID ~= nil
    
    return instanceInfo
end

-- Get group composition details
function MetadataCollector:GetGroupComposition()
    local groupType = "solo"
    local size = 1
    -- Use regular table since this is returned to caller
    local members = {}
    
    if IsInRaid() then
        groupType = "raid"
        size = GetNumGroupMembers()
        
        for i = 1, size do
            local unit = "raid" .. i
            if UnitExists(unit) then
                table.insert(members, self:GetUnitInfo(unit))
            end
        end
    elseif IsInGroup() then
        groupType = "party"
        size = GetNumGroupMembers()
        
        -- Add player
        table.insert(members, self:GetUnitInfo("player"))
        
        -- Add party members
        for i = 1, size - 1 do
            local unit = "party" .. i
            if UnitExists(unit) then
                table.insert(members, self:GetUnitInfo(unit))
            end
        end
    else
        -- Solo
        table.insert(members, self:GetUnitInfo("player"))
    end
    
    -- Use regular table since this is returned to caller
    local groupInfo = {}
    groupInfo.type = groupType
    groupInfo.size = size
    groupInfo.members = members
    groupInfo.roles = self:GetRoleDistribution(members)
    
    return groupInfo
end

-- Get unit information
function MetadataCollector:GetUnitInfo(unit)
    local name = UnitName(unit)
    local class = UnitClass(unit)
    local level = UnitLevel(unit)
    local role = UnitGroupRolesAssigned(unit)
    
    -- Use regular table since this is returned to caller
    local unitInfo = {}
    unitInfo.name = name
    unitInfo.class = class
    unitInfo.level = level
    unitInfo.role = role
    unitInfo.isPlayer = UnitIsUnit(unit, "player")
    
    return unitInfo
end

-- Analyze role distribution in group
function MetadataCollector:GetRoleDistribution(members)
    -- Use regular table since this is returned to caller
    local roles = {}
    roles.TANK = 0
    roles.HEALER = 0
    roles.DAMAGER = 0
    roles.NONE = 0
    
    for _, member in ipairs(members) do
        local role = member.role or "NONE"
        roles[role] = (roles[role] or 0) + 1
    end
    
    return roles
end

-- Public API methods
-- Release metadata tables back to pool
function MetadataCollector:ReleaseMetadataTables(metadata)
    if not metadata or not addon.StorageManager then
        return
    end
    
    -- Release nested tables
    if metadata.player then
        if metadata.player.spec then
            addon.StorageManager:ReleaseTable(metadata.player.spec)
        end
        addon.StorageManager:ReleaseTable(metadata.player)
    end
    
    if metadata.zone then
        if metadata.zone.instanceInfo then
            addon.StorageManager:ReleaseTable(metadata.zone.instanceInfo)
        end
        addon.StorageManager:ReleaseTable(metadata.zone)
    end
    
    if metadata.group then
        if metadata.group.members then
            -- Release each member info table
            for _, member in ipairs(metadata.group.members) do
                addon.StorageManager:ReleaseTable(member)
            end
            addon.StorageManager:ReleaseTable(metadata.group.members)
        end
        if metadata.group.roles then
            addon.StorageManager:ReleaseTable(metadata.group.roles)
        end
        addon.StorageManager:ReleaseTable(metadata.group)
    end
    
    if metadata.client then
        addon.StorageManager:ReleaseTable(metadata.client)
    end
    
    -- Release the main metadata table
    addon.StorageManager:ReleaseTable(metadata)
end

function MetadataCollector:GetCurrentMetadata()
    -- Return deep copy using table pool to prevent modification
    local metadata = addon.StorageManager and addon.StorageManager:GetTable() or {}
    
    -- Use pcall for fault tolerance
    local success, err = pcall(function()
        for k, v in pairs(currentMetadata) do
            if type(v) == "table" then
                -- Create nested table
                local nestedTable = addon.StorageManager and addon.StorageManager:GetTable() or {}
                
                -- Copy nested values safely
                for k2, v2 in pairs(v) do
                    if type(v2) == "table" then
                        -- For deeply nested tables, just copy the reference to avoid complexity
                        nestedTable[k2] = v2
                    else
                        -- Copy simple values
                        nestedTable[k2] = v2
                    end
                end
                
                metadata[k] = nestedTable
            else
                -- Copy simple values
                metadata[k] = v
            end
        end
    end)
    
    if not success then
        if addon.MyLogger then
            addon.MyLogger:Warn("Failed to copy metadata: %s", tostring(err))
        end
        -- Return minimal metadata on error
        return {
            player = {name = UnitName("player") or "Unknown"},
            timestamp = GetTime()
        }
    end
    
    return metadata
end

function MetadataCollector:GetMetadataForCombat(combatId)
    -- Get current metadata snapshot for a combat session
    local metadata = self:GetCurrentMetadata()
    metadata.combatId = combatId
    metadata.captureTime = GetTime()
    
    return metadata
end

-- Release metadata returned by GetCurrentMetadata or GetMetadataForCombat
function MetadataCollector:ReleaseMetadata(metadata)
    self:ReleaseMetadataTables(metadata)
end

function MetadataCollector:IsInInstance()
    return currentMetadata.zone and currentMetadata.zone.instanceInfo and 
           currentMetadata.zone.instanceInfo.type ~= "none"
end

function MetadataCollector:GetInstanceType()
    if currentMetadata.zone and currentMetadata.zone.instanceInfo then
        return currentMetadata.zone.instanceInfo.type
    end
    return "none"
end

function MetadataCollector:GetGroupType()
    return currentMetadata.group and currentMetadata.group.type or "solo"
end

function MetadataCollector:GetStatus()
    return {
        isInitialized = isInitialized,
        lastUpdate = currentMetadata.timestamp,
        zone = currentMetadata.zone and currentMetadata.zone.name or "Unknown",
        groupType = self:GetGroupType(),
        groupSize = currentMetadata.group and currentMetadata.group.size or 1
    }
end

-- Cleanup all metadata tables (for shutdown or reset)
function MetadataCollector:Cleanup()
    if currentMetadata and addon.StorageManager then
        self:ReleaseMetadataTables(currentMetadata)
        currentMetadata = {}
    end
    
    addon:Debug("MetadataCollector: cleaned up all metadata tables")
end

-- Debug summary for slash commands
function MetadataCollector:GetDebugSummary()
    local status = self:GetStatus()
    local meta = currentMetadata
    
    return string.format(
        "MetadataCollector Status:\n" ..
        "  Initialized: %s\n" ..
        "  Current Zone: %s\n" ..
        "  Instance: %s (%s)\n" ..
        "  Group: %s (%d members)\n" ..
        "  Player: %s %s (L%d, iLvl %d)",
        tostring(status.isInitialized),
        status.zone,
        meta.zone and meta.zone.instanceInfo.name or "None",
        meta.zone and meta.zone.instanceInfo.type or "none",
        status.groupType,
        status.groupSize,
        meta.player and meta.player.name or "Unknown",
        meta.player and meta.player.spec.name or "Unknown",
        meta.player and meta.player.level or 0,
        meta.player and meta.player.itemLevel or 0
    )
end