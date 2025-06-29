-- DamageMeter.lua
-- MVP damage meter UI with activity bar and custom typography
-- Phase 1: Core visual updates with custom font and activity bar

local addonName, addon = ...

-- =============================================================================
-- DAMAGE METER UI MODULE
-- =============================================================================

addon.DamageMeter = {}
local DamageMeter = addon.DamageMeter

-- UI Configuration
local UI_CONFIG = {
    WINDOW_WIDTH = 380,
    WINDOW_HEIGHT = 140,
    UPDATE_RATE = 250,      -- 4 FPS for smooth activity bar
    BACKGROUND_ALPHA = 0.95,
    
    -- Typography
    FONT_PATH = "Interface\\AddOns\\Stormy\\assets\\SCP-SB.ttf",
    FONT_SIZE_LARGE = 48,   -- Main DPS number
    FONT_SIZE_MEDIUM = 14,  -- Scale indicator
    FONT_SIZE_SMALL = 12,   -- Peak value
    
    -- Activity Bar
    ACTIVITY_SEGMENTS = 20,
    SEGMENT_WIDTH = 16,
    SEGMENT_HEIGHT = 8,
    SEGMENT_SPACING = 2,
    
    -- Colors
    COLOR_BACKGROUND = {0, 0, 0, 0.95},
    COLOR_TEXT_PRIMARY = {1, 1, 1, 1},
    COLOR_TEXT_SECONDARY = {0.7, 0.7, 0.7, 1},
    COLOR_TEXT_DIM = {0.5, 0.5, 0.5, 1},
    COLOR_DPS = {1, 0.2, 0.2, 1},  -- Red for DPS
    COLOR_HPS = {0.2, 1, 0.2, 1},  -- Green for HPS
    
    -- Activity colors (gradient)
    COLOR_ACTIVITY_LOW = {0, 0.8, 0, 1},      -- Green
    COLOR_ACTIVITY_MED = {1, 1, 0, 1},        -- Yellow
    COLOR_ACTIVITY_HIGH = {1, 0.5, 0, 1},     -- Orange
    COLOR_ACTIVITY_MAX = {1, 0, 0, 1},        -- Red
}

-- UI State
local uiState = {
    mainFrame = nil,
    isVisible = false,
    lastUpdate = 0,
    updateTimer = nil,
    
    -- Auto-scaling
    autoScale = true,
    currentScale = 1,
    scaleUnit = "",
    
    -- Time window mode
    windowMode = "CURRENT",  -- CURRENT (5s), SHORT (15s), MEDIUM (30s), LONG (60s)
    windowSeconds = 5,
    
    -- Peak tracking
    sessionPeak = 0,      -- Never decays (session-wide)
    recentPeak = 0,       -- Decaying peak (from DamageAccumulator)
    
    -- Scale update tracking
    lastScaleUpdate = 0,
    lastScaleValue = "1K",
    currentScaleMax = 1000,  -- The actual numeric value of the scale
    hasScaledOutOfCombat = false,  -- Tracks if we've already scaled once out of combat
    
    -- Display elements
    activityBar = {},     -- Activity bar segments
    mainNumberText = nil,
    scaleText = nil,
    peakText = nil,
    modeText = nil,
    closeButton = nil,
}

-- =============================================================================
-- CUSTOM FONTS
-- =============================================================================

-- Create custom font objects
local function CreateCustomFonts()
    -- Large number font
    local largeFont = CreateFont("StormyLargeNumberFont")
    largeFont:SetFont(UI_CONFIG.FONT_PATH, UI_CONFIG.FONT_SIZE_LARGE, "OUTLINE")
    
    -- Medium font
    local mediumFont = CreateFont("StormyMediumFont")
    mediumFont:SetFont(UI_CONFIG.FONT_PATH, UI_CONFIG.FONT_SIZE_MEDIUM, "OUTLINE")
    
    -- Small font
    local smallFont = CreateFont("StormySmallFont")
    smallFont:SetFont(UI_CONFIG.FONT_PATH, UI_CONFIG.FONT_SIZE_SMALL, "OUTLINE")
    
    return largeFont, mediumFont, smallFont
end

-- =============================================================================
-- UI CREATION
-- =============================================================================

-- Create the main damage meter window
function DamageMeter:CreateMainWindow()
    if uiState.mainFrame then
        return uiState.mainFrame
    end
    
    -- Create custom fonts
    local largeFont, mediumFont, smallFont = CreateCustomFonts()
    
    -- Create main frame (no template for custom look)
    local frame = CreateFrame("Frame", "StormyDamageMeter", UIParent)
    frame:SetSize(UI_CONFIG.WINDOW_WIDTH, UI_CONFIG.WINDOW_HEIGHT)
    frame:SetPoint("CENTER", 100, 0)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(10)
    
    -- Custom background
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(UI_CONFIG.COLOR_BACKGROUND))
    
    -- Make it movable
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Save position
        if addon.db then
            local point, _, relativePoint, x, y = self:GetPoint()
            addon.db.windowPosition = { point = point, relativePoint = relativePoint, x = x, y = y }
        end
    end)
    
    -- Create display elements
    self:CreateActivityBar(frame)
    self:CreateDisplayElements(frame, largeFont, mediumFont, smallFont)
    self:CreateCloseButton(frame)
    
    uiState.mainFrame = frame
    frame:Hide() -- Start hidden
    
    return frame
end

-- Create activity bar
function DamageMeter:CreateActivityBar(parent)
    local barWidth = UI_CONFIG.ACTIVITY_SEGMENTS * (UI_CONFIG.SEGMENT_WIDTH + UI_CONFIG.SEGMENT_SPACING) - UI_CONFIG.SEGMENT_SPACING
    local xStart = (UI_CONFIG.WINDOW_WIDTH - barWidth) / 2
    
    for i = 1, UI_CONFIG.ACTIVITY_SEGMENTS do
        local segment = parent:CreateTexture(nil, "ARTWORK")
        segment:SetSize(UI_CONFIG.SEGMENT_WIDTH, UI_CONFIG.SEGMENT_HEIGHT)
        
        local xPos = xStart + (i - 1) * (UI_CONFIG.SEGMENT_WIDTH + UI_CONFIG.SEGMENT_SPACING)
        segment:SetPoint("TOPLEFT", parent, "TOPLEFT", xPos, -15)
        
        segment:SetColorTexture(0.2, 0.2, 0.2, 1) -- Default dark gray
        
        uiState.activityBar[i] = segment
    end
end

-- Create display text elements
function DamageMeter:CreateDisplayElements(parent, largeFont, mediumFont, smallFont)
    -- Main DPS/HPS number
    uiState.mainNumberText = parent:CreateFontString(nil, "OVERLAY")
    uiState.mainNumberText:SetFontObject(largeFont)
    uiState.mainNumberText:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, -35)
    uiState.mainNumberText:SetText("0")
    uiState.mainNumberText:SetTextColor(unpack(UI_CONFIG.COLOR_DPS))
    
    -- Scale indicator (e.g., "275K (auto)")
    uiState.scaleText = parent:CreateFontString(nil, "OVERLAY")
    uiState.scaleText:SetFontObject(mediumFont)
    uiState.scaleText:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, -85)
    uiState.scaleText:SetText("1 (auto)")
    uiState.scaleText:SetTextColor(unpack(UI_CONFIG.COLOR_TEXT_SECONDARY))
    
    -- Peak value
    uiState.peakText = parent:CreateFontString(nil, "OVERLAY")
    uiState.peakText:SetFontObject(smallFont)
    uiState.peakText:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, -105)
    uiState.peakText:SetText("0 peak")
    uiState.peakText:SetTextColor(unpack(UI_CONFIG.COLOR_TEXT_DIM))
    
    -- Time window indicator (bottom right) - make it clickable
    local windowButton = CreateFrame("Button", nil, parent)
    windowButton:SetSize(60, 20)
    windowButton:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -15, 10)
    windowButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    
    uiState.modeText = windowButton:CreateFontString(nil, "OVERLAY")
    uiState.modeText:SetFontObject(smallFont)
    uiState.modeText:SetAllPoints()
    uiState.modeText:SetText("5 sec")
    uiState.modeText:SetTextColor(unpack(UI_CONFIG.COLOR_TEXT_DIM))
    
    -- Highlight on hover
    windowButton:SetScript("OnEnter", function()
        uiState.modeText:SetTextColor(unpack(UI_CONFIG.COLOR_TEXT_SECONDARY))
    end)
    windowButton:SetScript("OnLeave", function()
        uiState.modeText:SetTextColor(unpack(UI_CONFIG.COLOR_TEXT_DIM))
    end)
    
    -- Click to cycle windows
    windowButton:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            DamageMeter:CycleWindowMode(1)
        else
            DamageMeter:CycleWindowMode(-1)
        end
    end)
    
    uiState.windowButton = windowButton
    
    -- DPS label (top right)
    uiState.labelText = parent:CreateFontString(nil, "OVERLAY")
    uiState.labelText:SetFontObject(mediumFont)
    uiState.labelText:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -20, -15)
    uiState.labelText:SetText("DPS")
    uiState.labelText:SetTextColor(unpack(UI_CONFIG.COLOR_DPS))
end

-- Create custom close button
function DamageMeter:CreateCloseButton(parent)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(16, 16)
    button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -5, -5)
    
    -- X texture
    button:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    button:SetHighlightTexture("Interface\\Buttons\\UI-StopButton")
    button:GetHighlightTexture():SetAlpha(0.5)
    
    button:SetScript("OnClick", function()
        DamageMeter:Hide()
    end)
    
    uiState.closeButton = button
end

-- =============================================================================
-- NUMBER FORMATTING AND SCALING
-- =============================================================================

-- Format number with auto-scaling
function DamageMeter:FormatNumberWithScale(value)
    if not value or value == 0 then
        return "0", 1, ""
    end
    
    local absValue = math.abs(value)
    local scale, unit
    
    if absValue >= 1000000000 then
        scale = 1000000000
        unit = "B"
    elseif absValue >= 1000000 then
        scale = 1000000
        unit = "M"
    elseif absValue >= 1000 then
        scale = 1000
        unit = "K"
    else
        scale = 1
        unit = ""
    end
    
    local scaledValue = value / scale
    local formatted
    
    -- Always format with max 1 decimal place
    if scaledValue >= 100 then
        formatted = string.format("%.0f", scaledValue)
    else
        formatted = string.format("%.1f", scaledValue)
        -- Remove trailing .0
        formatted = formatted:gsub("%.0$", "")
    end
    
    return formatted, scale, unit
end

-- Get intelligent scale based on peak values
function DamageMeter:GetIntelligentScale()
    -- Use the higher of recent peak or 75% of session peak as reference
    local referencePeak = math.max(uiState.recentPeak, uiState.sessionPeak * 0.75)
    
    -- If we have no meaningful peak yet, use current value
    if referencePeak < 1000 then
        referencePeak = math.max(1000, uiState.currentValue or 0)
    end
    
    -- Add 25% headroom to the reference peak
    local targetScale = referencePeak * 1.25
    
    -- Round to sensible scale increments
    local scaleValue
    if targetScale >= 2000000000 then
        -- 2B+: round to nearest 500M (2B, 2.5B, 3B, etc.)
        scaleValue = math.ceil(targetScale / 500000000) * 500000000
    elseif targetScale >= 1000000000 then
        -- 1B-2B: round to nearest 250M (1B, 1.25B, 1.5B, 1.75B, 2B)
        scaleValue = math.ceil(targetScale / 250000000) * 250000000
    elseif targetScale >= 500000000 then
        -- 500M-1B: round to nearest 100M (500M, 600M, 700M, 800M, 900M, 1B)
        scaleValue = math.ceil(targetScale / 100000000) * 100000000
    elseif targetScale >= 100000000 then
        -- 100M-500M: round to nearest 50M (100M, 150M, 200M, etc.)
        scaleValue = math.ceil(targetScale / 50000000) * 50000000
    elseif targetScale >= 10000000 then
        -- 10M-100M: round to nearest 10M (10M, 20M, 30M, etc.)
        scaleValue = math.ceil(targetScale / 10000000) * 10000000
    elseif targetScale >= 1000000 then
        -- 1M-10M: round to nearest 1M (1M, 2M, 3M, etc.)
        scaleValue = math.ceil(targetScale / 1000000) * 1000000
    elseif targetScale >= 500000 then
        -- 500K-1M: round to nearest 100K (500K, 600K, 700K, 800K, 900K, 1M)
        scaleValue = math.ceil(targetScale / 100000) * 100000
    elseif targetScale >= 100000 then
        -- 100K-500K: round to nearest 50K (100K, 150K, 200K, etc.)
        scaleValue = math.ceil(targetScale / 50000) * 50000
    elseif targetScale >= 10000 then
        -- 10K-100K: round to nearest 10K (10K, 20K, 30K, etc.)
        scaleValue = math.ceil(targetScale / 10000) * 10000
    else
        -- Under 10K: round to nearest 5K (5K, 10K)
        scaleValue = math.max(5000, math.ceil(targetScale / 5000) * 5000)
    end
    
    -- Format the scale value
    local formatted, _, unit = self:FormatNumberWithScale(scaleValue)
    return formatted .. unit, scaleValue
end

-- =============================================================================
-- UI UPDATES
-- =============================================================================

-- Update activity bar based on current DPS relative to scale
function DamageMeter:UpdateActivityBar(currentDPS)
    -- Calculate how full the bar should be based on current DPS vs scale
    local fillPercent = 0
    if uiState.currentScaleMax > 0 then
        fillPercent = math.min(1, currentDPS / uiState.currentScaleMax)
    end
    
    local activeSegments = math.floor(fillPercent * UI_CONFIG.ACTIVITY_SEGMENTS + 0.5)
    
    for i = 1, UI_CONFIG.ACTIVITY_SEGMENTS do
        local segment = uiState.activityBar[i]
        if i <= activeSegments then
            -- Calculate color based on position
            local percent = i / UI_CONFIG.ACTIVITY_SEGMENTS
            local r, g, b
            
            if percent <= 0.33 then
                -- Green to yellow
                local t = percent / 0.33
                r = UI_CONFIG.COLOR_ACTIVITY_LOW[1] + (UI_CONFIG.COLOR_ACTIVITY_MED[1] - UI_CONFIG.COLOR_ACTIVITY_LOW[1]) * t
                g = UI_CONFIG.COLOR_ACTIVITY_LOW[2] + (UI_CONFIG.COLOR_ACTIVITY_MED[2] - UI_CONFIG.COLOR_ACTIVITY_LOW[2]) * t
                b = UI_CONFIG.COLOR_ACTIVITY_LOW[3] + (UI_CONFIG.COLOR_ACTIVITY_MED[3] - UI_CONFIG.COLOR_ACTIVITY_LOW[3]) * t
            elseif percent <= 0.66 then
                -- Yellow to orange
                local t = (percent - 0.33) / 0.33
                r = UI_CONFIG.COLOR_ACTIVITY_MED[1] + (UI_CONFIG.COLOR_ACTIVITY_HIGH[1] - UI_CONFIG.COLOR_ACTIVITY_MED[1]) * t
                g = UI_CONFIG.COLOR_ACTIVITY_MED[2] + (UI_CONFIG.COLOR_ACTIVITY_HIGH[2] - UI_CONFIG.COLOR_ACTIVITY_MED[2]) * t
                b = UI_CONFIG.COLOR_ACTIVITY_MED[3] + (UI_CONFIG.COLOR_ACTIVITY_HIGH[3] - UI_CONFIG.COLOR_ACTIVITY_MED[3]) * t
            else
                -- Orange to red
                local t = (percent - 0.66) / 0.34
                r = UI_CONFIG.COLOR_ACTIVITY_HIGH[1] + (UI_CONFIG.COLOR_ACTIVITY_MAX[1] - UI_CONFIG.COLOR_ACTIVITY_HIGH[1]) * t
                g = UI_CONFIG.COLOR_ACTIVITY_HIGH[2] + (UI_CONFIG.COLOR_ACTIVITY_MAX[2] - UI_CONFIG.COLOR_ACTIVITY_HIGH[2]) * t
                b = UI_CONFIG.COLOR_ACTIVITY_HIGH[3] + (UI_CONFIG.COLOR_ACTIVITY_MAX[3] - UI_CONFIG.COLOR_ACTIVITY_HIGH[3]) * t
            end
            
            segment:SetColorTexture(r, g, b, 1)
        else
            -- Inactive segment
            segment:SetColorTexture(0.2, 0.2, 0.2, 1)
        end
    end
end

-- Update display with current data
function DamageMeter:UpdateDisplay()
    if not uiState.mainFrame or not uiState.isVisible then
        return
    end
    
    local now = GetTime()
    
    -- Throttle updates
    if now - uiState.lastUpdate < (UI_CONFIG.UPDATE_RATE / 1000) then
        return
    end
    
    uiState.lastUpdate = now
    
    -- Get current damage data
    local displayData = {}
    local currentValue = 0
    
    if addon.DamageAccumulator then
        -- Get raw display data for activity and peaks
        displayData = addon.DamageAccumulator:GetDisplayData()
        
        -- Calculate DPS for the selected window
        local windowData = addon.DamageAccumulator:GetWindowTotals(uiState.windowSeconds)
        currentValue = windowData and windowData.dps or 0
    end
    
    -- Get peak values
    local recentPeakValue = displayData.peakDPS or 0  -- This is the decaying peak from DamageAccumulator
    
    -- Update peaks and current value
    uiState.recentPeak = recentPeakValue
    uiState.currentValue = currentValue
    if currentValue > uiState.sessionPeak then
        uiState.sessionPeak = currentValue
    end
    
    -- Format main number with auto-scaling
    local formatted, scale, unit = self:FormatNumberWithScale(currentValue)
    uiState.currentScale = scale
    uiState.scaleUnit = unit
    
    -- Update main number
    if uiState.mainNumberText then
        -- Split number at decimal point for styling
        local whole, decimal = formatted:match("^(%d+)%.?(%d*)$")
        if decimal and decimal ~= "" then
            uiState.mainNumberText:SetText(whole .. "." .. decimal .. unit)
        else
            uiState.mainNumberText:SetText(whole .. unit)
        end
    end
    
    -- Update scale indicator with timing logic
    if uiState.scaleText then
        local activityLevel = displayData.activityLevel or 0
        local timeSinceLastUpdate = now - uiState.lastScaleUpdate
        local shouldUpdateScale = false
        
        -- Calculate what the new scale would be
        local newScaleText, newScaleValue = self:GetIntelligentScale()
        
        -- Determine if we should update the scale
        if uiState.lastScaleUpdate == 0 then
            -- First time
            shouldUpdateScale = true
        elseif newScaleValue > uiState.currentScaleMax then
            -- Scale needs to go UP - update immediately for better responsiveness
            shouldUpdateScale = true
        elseif newScaleValue < uiState.currentScaleMax then
            -- Scale needs to go DOWN
            if activityLevel < 0.1 then
                -- Out of combat - scale once based on recent peak, then stop
                if not uiState.hasScaledOutOfCombat and timeSinceLastUpdate > 5 then
                    shouldUpdateScale = true
                end
            elseif activityLevel >= 0.1 and timeSinceLastUpdate > 5 then
                -- In combat: allow scaling down every 5 seconds
                shouldUpdateScale = true
                -- Reset out-of-combat flag since we're back in combat
                uiState.hasScaledOutOfCombat = false
            end
        else
            -- Scale is the same - no update needed unless it's been a while
            if timeSinceLastUpdate > 60 then
                -- Refresh every minute regardless
                shouldUpdateScale = true
            end
        end
        
        if shouldUpdateScale then
            uiState.lastScaleValue = newScaleText
            uiState.currentScaleMax = newScaleValue
            uiState.lastScaleUpdate = now
            uiState.scaleText:SetText(newScaleText .. " scale")
            
            -- Mark that we've scaled out of combat if we're out of combat
            if activityLevel < 0.1 then
                uiState.hasScaledOutOfCombat = true
            end
        else
            -- Keep showing the last scale value
            uiState.scaleText:SetText(uiState.lastScaleValue .. " scale")
        end
    end
    
    -- Update peak text - show both recent and session peaks
    if uiState.peakText then
        local sessionFormatted = "0"
        local recentFormatted = "0"
        local sessionUnit = ""
        local recentUnit = ""
        
        if uiState.sessionPeak > 0 then
            local fmt, _, unit = self:FormatNumberWithScale(uiState.sessionPeak)
            sessionFormatted = fmt
            sessionUnit = unit
        end
        
        if uiState.recentPeak > 0 then
            local fmt, _, unit = self:FormatNumberWithScale(uiState.recentPeak)
            recentFormatted = fmt
            recentUnit = unit
        end
        
        -- Show as "Recent: 123.4K  Peak: 156.7K"
        uiState.peakText:SetText(string.format("Recent: %s%s  Peak: %s%s", 
            recentFormatted, recentUnit, sessionFormatted, sessionUnit))
    end
    
    -- Update activity bar based on current DPS vs scale
    self:UpdateActivityBar(currentValue)
end

-- Start periodic updates
function DamageMeter:StartUpdates()
    if uiState.updateTimer then
        return
    end
    
    uiState.updateTimer = C_Timer.NewTicker(UI_CONFIG.UPDATE_RATE / 1000, function()
        self:UpdateDisplay()
    end)
end

-- Stop periodic updates
function DamageMeter:StopUpdates()
    if uiState.updateTimer then
        uiState.updateTimer:Cancel()
        uiState.updateTimer = nil
    end
end

-- =============================================================================
-- WINDOW MANAGEMENT
-- =============================================================================

-- Show the damage meter
function DamageMeter:Show()
    if not uiState.mainFrame then
        self:CreateMainWindow()
    end
    
    -- Restore position if saved
    if addon.db and addon.db.windowPosition then
        self:RestorePosition(addon.db.windowPosition)
    end
    
    uiState.mainFrame:Show()
    uiState.isVisible = true
    
    self:StartUpdates()
    self:UpdateDisplay() -- Immediate update
    
    -- Save state
    if addon.db then
        addon.db.showMainWindow = true
    end
end

-- Hide the damage meter
function DamageMeter:Hide()
    if uiState.mainFrame then
        uiState.mainFrame:Hide()
    end
    
    uiState.isVisible = false
    self:StopUpdates()
    
    -- Save state
    if addon.db then
        addon.db.showMainWindow = false
    end
end

-- Toggle visibility
function DamageMeter:Toggle()
    if uiState.isVisible then
        self:Hide()
    else
        self:Show()
    end
end

-- Cycle through window modes
function DamageMeter:CycleWindowMode(direction)
    local modes = {
        {name = "CURRENT", seconds = 5, label = "5 sec"},
        {name = "SHORT", seconds = 15, label = "15 sec"},
        {name = "MEDIUM", seconds = 30, label = "30 sec"},
        {name = "LONG", seconds = 60, label = "60 sec"}
    }
    
    -- Find current mode index
    local currentIndex = 1
    for i, mode in ipairs(modes) do
        if mode.name == uiState.windowMode then
            currentIndex = i
            break
        end
    end
    
    -- Calculate new index
    local newIndex = currentIndex + direction
    if newIndex > #modes then
        newIndex = 1
    elseif newIndex < 1 then
        newIndex = #modes
    end
    
    -- Update state
    local newMode = modes[newIndex]
    uiState.windowMode = newMode.name
    uiState.windowSeconds = newMode.seconds
    
    -- Update display
    if uiState.modeText then
        uiState.modeText:SetText(newMode.label)
    end
    
    -- Force immediate recalculation
    self:ForceUpdate()
end

-- Check if visible
function DamageMeter:IsVisible()
    return uiState.isVisible and uiState.mainFrame and uiState.mainFrame:IsShown()
end

-- Get window position (for saving)
function DamageMeter:GetPosition()
    if not uiState.mainFrame then
        return nil
    end
    
    local point, relativeTo, relativePoint, xOfs, yOfs = uiState.mainFrame:GetPoint()
    return {
        point = point,
        relativePoint = relativePoint,
        x = xOfs,
        y = yOfs
    }
end

-- Restore window position
function DamageMeter:RestorePosition(position)
    if not uiState.mainFrame or not position then
        return
    end
    
    uiState.mainFrame:ClearAllPoints()
    uiState.mainFrame:SetPoint(
        position.point or "CENTER",
        UIParent,
        position.relativePoint or "CENTER",
        position.x or 0,
        position.y or 0
    )
end

-- =============================================================================
-- DEBUGGING
-- =============================================================================

-- Force immediate update
function DamageMeter:ForceUpdate()
    uiState.lastUpdate = 0 -- Reset throttle
    self:UpdateDisplay()
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the damage meter UI
function DamageMeter:Initialize()
    -- Create the main window (but keep it hidden)
    self:CreateMainWindow()
    
    -- Set up event subscriptions
    if addon.EventBus then
        -- Subscribe to damage events for immediate feedback
        addon.EventBus:SubscribeToDamage(function(event)
            -- Could add hit flash or immediate update here
        end, "DamageMeterUI")
    end
    
    -- print("[STORMY] DamageMeter UI initialized (Phase 1)")
end

-- Module ready
DamageMeter.isReady = true