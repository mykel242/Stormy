-- WoW API Mock Framework for Unit Testing
-- This provides a mock implementation of the WoW API for testing outside the game

local mock = {}

-- Global state
_G.STORMY_ADDON_NAME = "Stormy"
_G.STORMY_NAMESPACE = {}
-- The addon exposes itself globally as STORMY
_G.STORMY = _G.STORMY_NAMESPACE

-- Mock the addon loading pattern used by WoW
-- When WoW loads addon files, it passes (addonName, addonTable) as varargs
local original_loadfile = loadfile
_G.loadfile = function(filename)
    local fn, err = original_loadfile(filename)
    if not fn then
        return nil, err
    end
    -- Wrap the function to provide addon name and namespace
    return function(...)
        -- If called with arguments, pass them through
        -- Otherwise, provide default addon arguments
        local args = {...}
        if #args > 0 then
            return fn(...)
        else
            return fn("Stormy", _G.STORMY_NAMESPACE)
        end
    end
end

-- Override dofile to pass addon arguments
local original_dofile = dofile
_G.dofile = function(filename)
    local fn, err = loadfile(filename)
    if not fn then
        error("Cannot load file: " .. tostring(filename) .. " - " .. tostring(err))
    end
    return fn("Stormy", _G.STORMY_NAMESPACE)
end

-- Mock frame implementation
local Frame = {}
Frame.__index = Frame

function Frame:new()
    local self = setmetatable({}, Frame)
    self.events = {}
    self.scripts = {}
    self.isShown = true
    self.children = {}
    self.points = {}
    return self
end

function Frame:RegisterEvent(event)
    self.events[event] = true
end

function Frame:UnregisterEvent(event)
    self.events[event] = nil
end

function Frame:UnregisterAllEvents()
    self.events = {}
end

function Frame:SetScript(handler, func)
    self.scripts[handler] = func
end

function Frame:GetScript(handler)
    return self.scripts[handler]
end

function Frame:Show()
    self.isShown = true
end

function Frame:Hide()
    self.isShown = false
end

function Frame:IsShown()
    return self.isShown
end

function Frame:SetPoint(point, relativeFrame, relativePoint, x, y)
    table.insert(self.points, {
        point = point,
        relativeFrame = relativeFrame,
        relativePoint = relativePoint,
        x = x,
        y = y
    })
end

function Frame:ClearAllPoints()
    self.points = {}
end

function Frame:CreateFontString(name, layer, inherits)
    local fontString = {
        text = "",
        SetText = function(self, text) self.text = tostring(text) end,
        GetText = function(self) return self.text end,
        SetFont = function() end,
        SetTextColor = function() end,
        SetJustifyH = function() end,
        SetJustifyV = function() end,
        Show = function() end,
        Hide = function() end,
    }
    return fontString
end

function Frame:CreateTexture(name, layer, inherits)
    local texture = {
        SetTexture = function() end,
        SetColorTexture = function() end,
        SetVertexColor = function() end,
        SetAllPoints = function() end,
        SetPoint = function() end,
        Show = function() end,
        Hide = function() end,
    }
    return texture
end

-- Mock CreateFrame function
function mock.CreateFrame(frameType, name, parent, template)
    local frame = Frame:new()
    frame.frameType = frameType
    frame.name = name
    frame.parent = parent
    frame.template = template
    
    if parent and parent.children then
        table.insert(parent.children, frame)
    end
    
    if name then
        _G[name] = frame
    end
    
    return frame
end

-- Mock time functions
function mock.GetTime()
    return os.clock()
end

function mock.debugprofilestop()
    return os.clock() * 1000
end

-- Mock combat log functions
function mock.CombatLogGetCurrentEventInfo()
    -- Return empty by default, tests can override
    return nil
end

-- Mock unit functions
function mock.UnitGUID(unit)
    return "Player-1234-00000001"
end

function mock.UnitName(unit)
    if unit == "player" then
        return "TestPlayer", "TestRealm"
    elseif unit == "pet" then
        return "TestPet", nil
    end
    return "Unknown", nil
end

function mock.UnitExists(unit)
    return unit == "player" or unit == "pet"
end

function mock.UnitIsUnit(unit1, unit2)
    return unit1 == unit2
end

function mock.UnitIsDead(unit)
    return false
end

function mock.UnitIsDeadOrGhost(unit)
    return false
end

-- Mock spell functions
function mock.GetSpellInfo(spellId)
    local spells = {
        [116] = "Frostbolt",
        [133] = "Fireball",
        [1] = "TestSpell"
    }
    return spells[spellId] or "Unknown Spell", nil, nil, nil, nil, nil, spellId
end

-- Mock print function
function mock.print(...)
    local args = {...}
    local str = ""
    for i = 1, select("#", ...) do
        if i > 1 then str = str .. " " end
        str = str .. tostring(args[i])
    end
    print("[WoW Mock] " .. str)
end

-- Mock SlashCmdList
_G.SlashCmdList = {}
_G.SLASH_STORMY1 = "/stormy"
_G.SLASH_STORMY2 = "/storm"

-- Mock LibStub
_G.LibStub = {
    libs = {},
    New = function(self, name, revision)
        self.libs[name] = self.libs[name] or {}
        return self.libs[name], true
    end,
    GetLibrary = function(self, name, silent)
        if not self.libs[name] and not silent then
            error("Library " .. name .. " not found")
        end
        return self.libs[name]
    end,
    NewLibrary = function(self, name, revision)
        return self:New(name, revision)
    end
}

-- Mock C_Timer
_G.C_Timer = {
    timers = {},
    After = function(delay, callback)
        -- In tests, execute immediately
        callback()
    end,
    NewTicker = function(delay, callback, iterations)
        local ticker = {
            callback = callback,
            iterations = iterations or -1,
            IsCancelled = function() return false end,
            Cancel = function() end
        }
        return ticker
    end
}

-- Mock ChatFrame
_G.DEFAULT_CHAT_FRAME = {
    AddMessage = function(self, msg, r, g, b)
        print("[Chat] " .. tostring(msg))
    end
}

-- Apply all mocks to global namespace
function mock.apply()
    for k, v in pairs(mock) do
        if k ~= "apply" and k ~= "reset" then
            _G[k] = v
        end
    end
end

-- Reset mocks (useful between tests)
function mock.reset()
    -- Reset any stateful mocks here
    _G.SlashCmdList = {}
    _G.C_Timer.timers = {}
end

-- Helper functions for tests
local helpers = {}

-- Count number of entries in a table
function helpers.table_length(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

-- Create a mock addon namespace with required dependencies
function helpers.create_mock_addon()
    local addon = {}
    -- Add any common addon properties here
    return addon
end

-- Load a module at a specific path
function helpers.load_module_at_path(path, addon)
    local full_path = path
    if not full_path:match("^/") then
        -- Relative path - determine the correct base directory
        local base_dir = debug.getinfo(1, "S").source:match("@(.*/)")
        if base_dir then
            -- Remove tests/ from the end to get addon root
            base_dir = base_dir:gsub("tests/$", "")
            full_path = base_dir .. path
        else
            -- Fallback to development directory
            full_path = "/Users/mykel/Development/wow/Stormy/" .. path
        end
    end
    
    -- Load the file with the addon context
    local chunk, err = loadfile(full_path)
    if not chunk then
        error("Failed to load module: " .. full_path .. " - " .. tostring(err))
    end
    
    -- Execute with addon name and namespace
    chunk("Stormy", addon)
    
    return addon
end

-- Merge helpers into mock table
for k, v in pairs(helpers) do
    mock[k] = v
end

-- Automatically apply mocks when spec_helper is loaded
mock.apply()

return mock