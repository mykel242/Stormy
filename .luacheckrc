-- Luacheck configuration for WoW AddOn development
std = "lua51"
max_line_length = 120

-- Ignore common addon patterns
ignore = {
    "211", -- unused local variable
    "212", -- unused argument (common in event handlers)
    "213", -- unused loop variable 
    "231", -- set but never accessed variable
    "311", -- value assigned but never accessed
    "431", -- shadowing upvalue (common in OOP patterns)
    "432", -- shadowing upvalue argument
    "542", -- empty if branch (common for placeholder code)  
    "631", -- line is too long (we'll allow longer lines for readability)
    "611", -- line contains only whitespace
    "612", -- line contains trailing whitespace
    "614", -- trailing whitespace in a comment
}

-- WoW API globals
globals = {
    -- WoW API Functions
    "CreateFrame",
    "GetTime",
    "debugprofilestop",
    "CombatLogGetCurrentEventInfo",
    "UnitGUID",
    "UnitName",
    "UnitExists",
    "UnitIsUnit",
    "UnitIsDead",
    "UnitIsDeadOrGhost",
    "GetSpellInfo",
    "GetNumGroupMembers",
    "IsInInstance", 
    "GetInstanceInfo",
    "GetFrameRate",
    "UnitClass",
    "UnitLevel", 
    "UnitCreatureFamily",
    "UnitClassification",
    "UnitCreatureType", 
    "CreateFont",
    "IsInGroup",
    "IsInRaid",
    "GetZoneText",
    "GetRealmName",
    "GetSpecialization", 
    "GetSpecializationInfo",
    "GetServerTime",
    "GetAddOnMetadata",
    "print",
    "bit",
    
    -- C_AddOns API
    "C_AddOns",
    
    -- C_System API
    "C_System",
    
    -- More UI APIs  
    "UIDropDownMenu_AddButton",
    "UIDropDownMenu_GetSelectedValue",
    "ChatFontNormal",
    
    -- Zone/Map APIs
    "GetRealZoneText",
    "GetMinimapZoneText", 
    "GetSubZoneText",
    "C_Map",
    
    -- System APIs
    "GetBuildInfo",
    "debugstack",
    
    -- Item APIs
    "GetInventoryItemLink",
    "GetDetailedItemLevelInfo",
    "UnitGroupRolesAssigned",
    "date",
    "time",
    "format",
    "string.split",
    "strsplit",
    "strjoin",
    "wipe",
    "tinsert",
    "tremove",
    "tContains",
    "CopyTable",
    "Mixin",
    
    -- WoW UI Elements
    "DEFAULT_CHAT_FRAME",
    "GameFontHighlight",
    "GameFontNormal",
    "UIParent",
    "BackdropTemplateMixin",
    "BackdropTemplate",
    
    -- DropDown APIs
    "UIDropDownMenu_SetWidth",
    "UIDropDownMenu_SetText", 
    "UIDropDownMenu_Initialize",
    "UIDropDownMenu_CreateInfo",
    "UIDropDownMenu_SetSelectedValue",
    
    -- WoW Events and Constants
    "RAID_CLASS_COLORS",
    "COMBATLOG_OBJECT_TYPE_PLAYER",
    "COMBATLOG_OBJECT_TYPE_PET",
    "COMBATLOG_OBJECT_TYPE_GUARDIAN",
    "COMBATLOG_OBJECT_CONTROL_PLAYER",
    "COMBATLOG_OBJECT_REACTION_FRIENDLY",
    "COMBATLOG_OBJECT_AFFILIATION_MINE",
    
    -- Libraries
    "LibStub",
    "AceAddon",
    "AceConsole",
    "AceEvent",
    
    -- Slash Commands
    "SlashCmdList",
    
    -- C_Timer API
    "C_Timer",
    
    -- AddOn specific
    "STORMY_ADDON_NAME",
    "STORMY_NAMESPACE",
    "Stormy",
    "StormyDB",
    
    -- Saved Variables
    "STORMY_SETTINGS",
    "STORMY_CHAR_SETTINGS"
}

-- Ignore unused self warnings in methods
self = false

-- Ignore line length in specific files
files["*.toc"] = {
    max_line_length = false
}

-- Allow unused arguments in event handlers
files["Combat/*.lua"] = {
    unused_args = false
}

-- Allow module pattern
files["**/*.lua"] = {
    allow_defined_top = true
}

-- Ignore unused addonName in addon files (common pattern)
files["**/**.lua"] = {
    ignore = {"addonName"}
}

-- Allow slash command globals
files["STORMY.lua"] = {
    globals = {"SLASH_STORMY1", "SLASH_STORMY2"}
}

files["src/commands/SlashCommands.lua"] = {
    globals = {"SLASH_MYUI1"}
}

files["src/core/MyCombatMeterScaler.lua"] = {
    globals = {"MyUIDB"}
}

-- More lenient for legacy src/ files
files["src/**/*.lua"] = {
    globals = {"petName", "isAutoFollowing", "scrollUpButton", "scrollDownButton", "MyUIDB", "UpdateButtonVisibility"},
    ignore = {"421", "422", "423", "431", "432"} -- Allow variable shadowing and redefinition in legacy code
}

-- Allow longer lines in specific files with complex APIs
files["Combat/EventProcessor.lua"] = {
    max_line_length = 150
}

files["UI/**.lua"] = {
    max_line_length = 150,
    ignore = {"421", "422", "423"} -- allow variable shadowing in UI code
}

files["tests/**.lua"] = {
    max_line_length = false,
    ignore = {"421", "422", "423", "431", "432"} -- Allow shadowing in tests
}