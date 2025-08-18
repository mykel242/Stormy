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
addon.VERSION = "1.0.14"
addon.BUILD_DATE = "2025-08-18"

-- =============================================================================
-- SAVED VARIABLES AND CONFIGURATION
-- =============================================================================

-- Default configuration
addon.defaults = {
    enabled = true,
    
    -- Window settings
    showMainWindow = false,
    showHealingWindow = false,
    showDPSPlotWindow = true,
    showHPSPlotWindow = false,
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
    
    if self.EventPool then
        self.EventPool:Initialize()
        -- print("[STORMY] EventPool initialized")
    end
    
    if self.StringPool then
        self.StringPool:Initialize()
        -- print("[STORMY] StringPool initialized")
    end
    
    if self.MemoryProfiler then
        self.MemoryProfiler:Initialize()
        -- print("[STORMY] MemoryProfiler initialized")
    end
    
    if self.SpellCache then
        self.SpellCache:Initialize()
        -- print("[STORMY] SpellCache initialized")
    end
    
    if self.TimingManager then
        self.TimingManager:Initialize()
        -- print("[STORMY] TimingManager initialized")
    end
    
    if self.EventBus then
        self.EventBus:Initialize()
        -- print("[STORMY] EventBus initialized")
    end
    
    if self.PlotStateManager then
        self.PlotStateManager:Initialize()
        -- print("[STORMY] PlotStateManager initialized")
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
    
    -- Initialize MetricsPlot instances (DPS and HPS)
    if self.MetricsPlot then
        -- DPS Plot initialization
        local success, result = pcall(function()
            self.DPSPlot = self.MetricsPlot:New("DPS")
            self.DPSPlot:Initialize()
        end)
        -- HPS Plot initialization
        success, result = pcall(function()
            self.HPSPlot = self.MetricsPlot:New("HPS")
            self.HPSPlot:Initialize()
        end)
    else
        -- MetricsPlot module not found
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
    
    if self.MeterManager and self.DPSPlot then
        self.MeterManager:RegisterMeter("DPSPlot", nil, self.DPSPlot)
        -- DPS plot registered
    end
    
    if self.MeterManager and self.HPSPlot then
        self.MeterManager:RegisterMeter("HPSPlot", nil, self.HPSPlot)
        -- HPS plot registered
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
        if self.db.showDPSPlotWindow and self.DPSPlot then
            self.DPSPlot:Show()
        end
        if self.db.showHPSPlotWindow and self.HPSPlot then
            self.HPSPlot:Show()
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
    
    if self.DPSPlot then
        local isVisible = self.DPSPlot:IsVisible()
        self.db.showDPSPlotWindow = isVisible
    end
    
    if self.HPSPlot then
        local isVisible = self.HPSPlot:IsVisible()
        self.db.showHPSPlotWindow = isVisible
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
    
    if command == "" then
        -- Show help when no command given
        print("STORMY Commands:")
        print("  /stormy dps - Toggle DPS meter")
        print("  /stormy hps - Toggle HPS meter")
        print("  /stormy dpsplot - Toggle DPS plot")
        print("  /stormy hpsplot - Toggle HPS plot")
        print("  /stormy debug - Show debug information")
        print("  /stormy reset - Reset statistics")
        print("  /stormy poolstats - Show pool statistics")
        print("  /stormy plotscale <mode> - Set plot scaling (max|95th|90th|85th)")
        print("  /stormy plotoutliers <on|off> - Toggle outlier indicators")
        print("  /stormy version - Show version")
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
    elseif command == "hps" then
        if addon.MeterManager then
            addon.MeterManager:ToggleMeter("Healing")
        else
            print("[STORMY] HPS meter not available")
        end
    elseif command == "dpsplot" then
        if addon.MeterManager then
            addon.MeterManager:ToggleMeter("DPSPlot")
        else
            print("[STORMY] DPS plot not available")
        end
    elseif command == "hpsplot" then
        if addon.MeterManager then
            addon.MeterManager:ToggleMeter("HPSPlot")
        else
            print("[STORMY] HPS plot not available")
        end
    elseif command == "poolstats" then
        if addon.EventPool then
            addon.EventPool:Debug()
        end
        if addon.TablePool then
            addon.TablePool:Debug()
        end
    elseif command:match("^plotscale%s") then
        -- Plot scaling configuration: /stormy plotscale percentile|max|95th|90th
        local mode = command:match("^plotscale%s+(.+)")
        if mode == "max" then
            -- Use traditional max-value scaling
            if addon.DPSPlot then
                addon.DPSPlot.config.usePercentileScaling = false
                -- Force immediate scale recalculation
                addon.DPSPlot.lastScaleUpdate = 0
                print("[STORMY] DPS Plot: Using max-value scaling")
            end
            if addon.HPSPlot then
                addon.HPSPlot.config.usePercentileScaling = false
                -- Force immediate scale recalculation
                addon.HPSPlot.lastScaleUpdate = 0
                print("[STORMY] HPS Plot: Using max-value scaling")
            end
        elseif mode == "percentile" or mode == "95th" then
            -- Use 95th percentile scaling (default)
            if addon.DPSPlot then
                addon.DPSPlot.config.usePercentileScaling = true
                addon.DPSPlot.config.scalePercentile = 0.95
                addon.DPSPlot.lastScaleUpdate = 0  -- Force recalc
                print("[STORMY] DPS Plot: Using 95th percentile scaling")
            end
            if addon.HPSPlot then
                addon.HPSPlot.config.usePercentileScaling = true
                addon.HPSPlot.config.scalePercentile = 0.95
                addon.HPSPlot.lastScaleUpdate = 0  -- Force recalc
                print("[STORMY] HPS Plot: Using 95th percentile scaling")
            end
        elseif mode == "90th" then
            -- Use 90th percentile scaling
            if addon.DPSPlot then
                addon.DPSPlot.config.usePercentileScaling = true
                addon.DPSPlot.config.scalePercentile = 0.90
                addon.DPSPlot.lastScaleUpdate = 0  -- Force recalc
                print("[STORMY] DPS Plot: Using 90th percentile scaling")
            end
            if addon.HPSPlot then
                addon.HPSPlot.config.usePercentileScaling = true
                addon.HPSPlot.config.scalePercentile = 0.90
                addon.HPSPlot.lastScaleUpdate = 0  -- Force recalc
                print("[STORMY] HPS Plot: Using 90th percentile scaling")
            end
        elseif mode == "85th" then
            -- Use 85th percentile scaling (more aggressive outlier filtering)
            if addon.DPSPlot then
                addon.DPSPlot.config.usePercentileScaling = true
                addon.DPSPlot.config.scalePercentile = 0.85
                addon.DPSPlot.lastScaleUpdate = 0  -- Force recalc
                print("[STORMY] DPS Plot: Using 85th percentile scaling")
            end
            if addon.HPSPlot then
                addon.HPSPlot.config.usePercentileScaling = true
                addon.HPSPlot.config.scalePercentile = 0.85
                addon.HPSPlot.lastScaleUpdate = 0  -- Force recalc
                print("[STORMY] HPS Plot: Using 85th percentile scaling")
            end
        else
            print("[STORMY] Usage: /stormy plotscale <mode>")
            print("  max     - Use maximum value for scaling (outliers affect scale)")
            print("  95th    - Use 95th percentile (ignores top 5% outliers) [DEFAULT]")
            print("  90th    - Use 90th percentile (ignores top 10% outliers)")
            print("  85th    - Use 85th percentile (ignores top 15% outliers)")
        end
    elseif command:match("^plotoutliers%s") then
        -- Outlier indicator toggle: /stormy plotoutliers on|off
        local mode = command:match("^plotoutliers%s+(.+)")
        if mode == "on" then
            if addon.DPSPlot then
                addon.DPSPlot.config.showOutlierIndicators = true
                print("[STORMY] DPS Plot: Outlier indicators enabled")
            end
            if addon.HPSPlot then
                addon.HPSPlot.config.showOutlierIndicators = true
                print("[STORMY] HPS Plot: Outlier indicators enabled")
            end
        elseif mode == "off" then
            if addon.DPSPlot then
                addon.DPSPlot.config.showOutlierIndicators = false
                print("[STORMY] DPS Plot: Outlier indicators disabled")
            end
            if addon.HPSPlot then
                addon.HPSPlot.config.showOutlierIndicators = false
                print("[STORMY] HPS Plot: Outlier indicators disabled")
            end
        else
            print("[STORMY] Usage: /stormy plotoutliers <on|off>")
            print("Shows visual indicators for bars that exceed 2x the scale value")
        end
    else
        print("STORMY Commands:")
        print("  /stormy dps - Toggle DPS meter")
        print("  /stormy hps - Toggle HPS meter")
        print("  /stormy dpsplot - Toggle DPS plot")
        print("  /stormy hpsplot - Toggle HPS plot")
        print("  /stormy debug - Show debug information")
        print("  /stormy reset - Reset statistics")
        print("  /stormy poolstats - Show pool statistics")
        print("  /stormy plotscale <mode> - Set plot scaling (max|95th|90th|85th)")
        print("  /stormy plotoutliers <on|off> - Toggle outlier indicators")
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