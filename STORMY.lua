-- STORMY.lua
-- Main initialization file for STORMY addon
-- High-performance real-time damage tracking

-- Create addon namespace
local addonName, addon = ...

-- Expose addon globally for debugging
_G.STORMY = addon

-- Set startup time for performance tracking
addon.startTime = GetTime()

-- Cache busting - force reload modules
addon._loadTime = GetTime()
addon._buildHash = "20250628_" .. math.random(1000, 9999)

-- =============================================================================
-- ADDON METADATA
-- =============================================================================

addon.ADDON_NAME = addonName
addon.VERSION = "1.0.0"
addon.BUILD_DATE = "2025-06-28"

-- =============================================================================
-- SAVED VARIABLES AND CONFIGURATION
-- =============================================================================

-- Default configuration
addon.defaults = {
    enabled = true,
    
    -- Window settings
    showMainWindow = false,
    showHealingWindow = false,
    windowPosition = { point = "CENTER", x = 0, y = 0 },
    windowScale = 1.0,
    
    -- Performance settings
    updateRate = 250,           -- UI update rate in milliseconds
    maxEventsPerFrame = 10,     -- Circuit breaker threshold
    
    -- Display settings
    showPetDamage = true,       -- Include pet damage in totals
    showCriticals = true,       -- Highlight critical hits
    minDamageToShow = 100,      -- Minimum damage to display
    
    -- Scaling settings
    autoScale = true,           -- Automatic scale adjustment
    manualScale = 100000,       -- Manual scale value
    scaleSmoothing = 0.9        -- Scale change smoothing
}

-- =============================================================================
-- ADDON LIFECYCLE
-- =============================================================================

-- Create main addon frame
addon.frame = CreateFrame("Frame", addonName .. "MainFrame")

-- Initialize function
function addon:OnInitialize()
    -- Load saved variables or set defaults
    if StormyDB == nil then
        StormyDB = {}
    end
    
    -- Merge defaults with saved settings
    for key, value in pairs(self.defaults) do
        if StormyDB[key] == nil then
            StormyDB[key] = value
        end
    end
    
    self.db = StormyDB
    
    -- Initialize core modules in dependency order
    -- print(string.format("[STORMY] Initializing v%s...", self.VERSION))
    -- print(string.format("[STORMY] Build: %s", addon._buildHash))
    
    -- Module availability checked
    
    -- Core foundation
    if self.TablePool then
        self.TablePool:Initialize()
        -- print("[STORMY] TablePool initialized")
    end
    
    if self.TimingManager then
        self.TimingManager:Initialize()
        -- print("[STORMY] TimingManager initialized")
    end
    
    if self.EventBus then
        self.EventBus:Initialize()
        -- print("[STORMY] EventBus initialized")
    end
    
    -- Combat processing
    if self.EventProcessor then
        local success, error = pcall(function()
            self.EventProcessor:Initialize()
        end)
        if success then
            -- print("[STORMY] EventProcessor initialized")
        else
            -- print("[STORMY] ERROR: EventProcessor initialization failed:", error)
        end
    else
        -- print("[STORMY] ERROR: EventProcessor module not found!")
    end
    
    -- Data tracking
    if self.EntityTracker then
        self.EntityTracker:Initialize()
        -- print("[STORMY] EntityTracker initialized")
    else
        -- print("[STORMY] EntityTracker not available")
    end
    
    if self.RingBuffer then
        self.RingBuffer:Initialize()
        -- print("[STORMY] RingBuffer initialized")
    else
        -- print("[STORMY] RingBuffer not available")
    end
    
    
    -- Meter framework
    if self.MeterManager then
        -- MeterManager initialization
        self.MeterManager:Initialize()
    else
        -- MeterManager module not found
    end
    
    -- Initialize HealingAccumulator (create instance)
    if self.HealingAccumulator then
        -- HealingAccumulator initialization
        local success, result = pcall(function()
            self.HealingAccumulator = self.HealingAccumulator:New()
            self.HealingAccumulator:Initialize()
        end)
    else
        -- HealingAccumulator module not found
    end
    
    -- Initialize HealingMeter (create instance)
    if self.HealingMeter then
        -- HealingMeter initialization
        local success, result = pcall(function()
            self.HealingMeter = self.HealingMeter:New()
            self.HealingMeter:Initialize()
        end)
    else
        -- HealingMeter module not found
    end
    
    
    -- Initialize DamageMeter (create instance)
    if self.DamageMeter then
        -- DamageMeter initialization
        local success, result = pcall(function()
            self.DamageMeter = self.DamageMeter:New()
            self.DamageMeter:Initialize()
        end)
    else
        -- DamageMeter module not found
    end
    
    -- Initialize DamageAccumulator (create instance)
    if self.DamageAccumulator then
        -- DamageAccumulator initialization
        local success, result = pcall(function()
            self.DamageAccumulator = self.DamageAccumulator:New()
            self.DamageAccumulator:Initialize()
        end)
    else
        -- DamageAccumulator module not found
    end
    
    -- Register meters with MeterManager (after all components are initialized)
    if self.MeterManager and self.DamageAccumulator and self.DamageMeter then
        self.MeterManager:RegisterMeter("Damage", self.DamageAccumulator, self.DamageMeter)
        -- Damage meter registered
    else
        -- Failed to register Damage meter
    end
    
    if self.MeterManager and self.HealingAccumulator and self.HealingMeter then
        self.MeterManager:RegisterMeter("Healing", self.HealingAccumulator, self.HealingMeter)
        -- Healing meter registered
    else
        -- Failed to register Healing meter
    end
    
    -- print("[STORMY] Initialization complete!")
end

-- Enable function
function addon:OnEnable()
    if self.db.enabled then
        -- print(string.format("[STORMY] %s is now active!", addonName))
        
        -- Combat detection is handled automatically by EventProcessor
        -- No manual start needed
        
        -- Show UI if configured
        if self.db.showMainWindow and self.DamageMeter then
            self.DamageMeter:Show()
        end
        if self.db.showHealingWindow and self.HealingMeter then
            self.HealingMeter:Show()
        end
    end
end

-- Disable function
function addon:OnDisable()
    -- Save any state that needs persistence
    if self.DamageMeter then
        local isVisible = self.DamageMeter:IsVisible()
        self.db.showMainWindow = isVisible
        
        if isVisible and self.DamageMeter.GetPosition then
            self.db.windowPosition = self.DamageMeter:GetPosition()
        end
    end
    
    if self.HealingMeter then
        local isVisible = self.HealingMeter:IsVisible()
        self.db.showHealingWindow = isVisible
    end
    
    -- print("[STORMY] Disabled and state saved")
end

-- =============================================================================
-- SLASH COMMANDS
-- =============================================================================

-- Simple slash command handler
SLASH_STORMY1 = "/stormy"
SlashCmdList["STORMY"] = function(msg)
    local command = string.lower(msg or "")
    
    if command == "show" or command == "" then
        if addon.DamageMeter then
            addon.DamageMeter:Toggle()
        else
            -- print("[STORMY] Damage meter not available")
        end
    elseif command == "debug" then
        print("=== STORMY Debug Information ===")
        print(string.format("Version: %s", addon.VERSION))
        print(string.format("Uptime: %.1fs", GetTime() - addon.startTime))
        
        if addon.EventProcessor then
            addon.EventProcessor:Debug()
        end
        if addon.TimingManager then
            addon.TimingManager:Debug()
        end
        if addon.EventBus then
            addon.EventBus:Debug()
        end
        if addon.TablePool then
            addon.TablePool:Debug()
        end
    elseif command == "reset" then
        if addon.EventProcessor then
            addon.EventProcessor:ResetStats()
            print("[STORMY] Statistics reset")
        end
    elseif command == "version" then
        print(string.format("[STORMY] Version %s (Build: %s)", addon.VERSION, addon.BUILD_DATE))
    elseif command == "dps" then
        if addon.MeterManager then
            addon.MeterManager:ToggleMeter("Damage")
        else
            print("[STORMY] DPS meter not available")
        end
    elseif command == "dpsdebug" then
        if addon.DamageAccumulator then
            local stats = addon.DamageAccumulator:GetStats()
            print("=== DPS Debug ===")
            print(string.format("Current DPS: %.0f", stats.currentDPS))
            print(string.format("Time since last event: %.1fs", stats.timeSinceLastEvent))
            print(string.format("Activity level: %.1f%%", stats.activityLevel * 100))
            print(string.format("5s window damage: %.0f", stats.current.damage))
            print(string.format("5s window DPS: %.0f", stats.current.dps))
            
            -- Force window recalculation
            addon.DamageAccumulator:UpdateCurrentValues()
            local newStats = addon.DamageAccumulator:GetStats()
            print(string.format("After recalc - Current DPS: %.0f", newStats.currentDPS))
            
            -- Check what UI gets
            local displayData = addon.DamageAccumulator:GetDisplayData()
            print(string.format("UI Display Data - Current DPS: %s", displayData.currentDPS))
            
            -- Force UI update
            if addon.DamageMeter then
                addon.DamageMeter:ForceUpdate()
                print("Forced UI update")
            end
            
            -- Circuit breaker stats
            if addon.EventProcessor then
                local cbStats = addon.EventProcessor:GetStats().circuitBreaker
                print(string.format("Circuit breaker: Max %d/frame, Currently tripped: %s", 
                    cbStats.maxEventsPerFrame, tostring(cbStats.tripped)))
            end
        end
    elseif command == "hps" then
        if addon.MeterManager then
            addon.MeterManager:ToggleMeter("Healing")
        else
            print("[STORMY] HPS meter not available")
        end
    elseif command:match("^cb%s") then
        -- Circuit breaker commands: /stormy cb auto|solo|raid|mythic|<number>
        local mode = command:match("^cb%s+(.+)")
        if addon.EventProcessor then
            addon.EventProcessor:SetCircuitBreakerMode(mode)
        end
    elseif command == "events" then
        if addon.EventProcessor then
            addon.EventProcessor:ShowRecentEvents()
        end
    else
        print("STORMY Commands:")
        print("  /stormy - Toggle damage meter")
        print("  /stormy show - Toggle damage meter")
        print("  /stormy dps - Toggle DPS meter")
        print("  /stormy hps - Toggle HPS meter")
        print("  /stormy debug - Show debug information")
        print("  /stormy reset - Reset statistics")
        print("  /stormy dpsdebug - Debug DPS calculations")
        print("  /stormy cb <mode> - Circuit breaker: auto|solo|raid|mythic|<number>")
        print("  /stormy events - Show recent event types")
        print("  /stormy version - Show version")
    end
end

-- =============================================================================
-- EVENT HANDLING
-- =============================================================================

-- Main event handler
local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == addonName then
            addon:OnInitialize()
        end
    elseif event == "PLAYER_LOGIN" then
        addon:OnEnable()
    elseif event == "PLAYER_LOGOUT" then
        addon:OnDisable()
    end
end

-- Register events
addon.frame:RegisterEvent("ADDON_LOADED")
addon.frame:RegisterEvent("PLAYER_LOGIN")
addon.frame:RegisterEvent("PLAYER_LOGOUT")
addon.frame:SetScript("OnEvent", OnEvent)

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================

-- Get addon version
function addon:GetVersion()
    return self.VERSION
end

-- Check if addon is ready
function addon:IsReady()
    return self.TablePool and self.TablePool.isReady and
           self.TimingManager and self.TimingManager.isReady and
           self.EventBus and self.EventBus.isReady and
           self.EventProcessor and self.EventProcessor.isReady
end

-- Get overall statistics
function addon:GetStats()
    local stats = {
        version = self.VERSION,
        uptime = GetTime() - self.startTime,
        isReady = self:IsReady()
    }
    
    if self.EventProcessor then
        stats.eventProcessor = self.EventProcessor:GetStats()
    end
    
    if self.TimingManager then
        stats.timing = self.TimingManager:GetState()
    end
    
    if self.EventBus then
        stats.eventBus = self.EventBus:GetStats()
    end
    
    if self.TablePool then
        stats.tablePool = self.TablePool:GetStats()
    end
    
    return stats
end

-- Performance monitoring
function addon:GetPerformanceInfo()
    local luaMemory = collectgarbage("count")
    
    return {
        luaMemoryKB = luaMemory,
        luaMemoryMB = luaMemory / 1024,
        uptime = GetTime() - self.startTime,
        frameRate = GetFrameRate()
    }
end

-- Emergency reset
function addon:EmergencyReset()
    -- print("[STORMY] Emergency reset initiated...")
    
    if self.EventProcessor then
        self.EventProcessor:ResetStats()
    end
    
    if self.TablePool then
        self.TablePool:Clear()
    end
    
    if self.EventBus then
        self.EventBus:Clear()
    end
    
    collectgarbage("collect")
    
    -- print("[STORMY] Emergency reset complete")
end

-- print(string.format("[STORMY] Loaded v%s", addon.VERSION))