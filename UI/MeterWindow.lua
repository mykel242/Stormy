-- MeterWindow.lua
-- Base class for meter windows with activity bar and custom typography
-- Provides common UI functionality for damage, healing, damage taken, and other meters

local addonName, addon = ...

-- =============================================================================
-- METER WINDOW BASE CLASS
-- =============================================================================

addon.MeterWindow = {}
local MeterWindow = addon.MeterWindow

-- Base UI Configuration (can be overridden by subclasses)
local UI_CONFIG = {
    WINDOW_WIDTH = 380,
    WINDOW_HEIGHT = 140,
    UPDATE_RATE = 250,      -- 4 FPS for smooth activity bar
    BACKGROUND_ALPHA = 0.95,
    
    -- Typography
    FONT_PATH = "Interface\\AddOns\\Stormy\\assets\\SCP-SB.ttf",
    FONT_SIZE_LARGE = 48,   -- Main number
    FONT_SIZE_MEDIUM = 14,  -- Scale indicator
    FONT_SIZE_SMALL = 12,   -- Peak value
    
    -- Activity Bar
    ACTIVITY_SEGMENTS = 20,
    SEGMENT_WIDTH = 16,
    SEGMENT_HEIGHT = 8,
    SEGMENT_SPACING = 2,
    
    -- Colors
    COLOR_BACKGROUND = {0, 0, 0, 0.5},
    COLOR_TEXT_PRIMARY = {1, 1, 1, 1},
    COLOR_TEXT_SECONDARY = {0.7, 0.7, 0.7, 1},
    COLOR_TEXT_DIM = {0.5, 0.5, 0.5, 1},
    
    -- Activity colors (gradient)
    COLOR_ACTIVITY_LOW = {0, 0.8, 0, 1},      -- Green
    COLOR_ACTIVITY_MED = {1, 1, 0, 1},        -- Yellow
    COLOR_ACTIVITY_HIGH = {1, 0.5, 0, 1},     -- Orange
    COLOR_ACTIVITY_MAX = {1, 0, 0, 1},        -- Red
}

-- =============================================================================
-- BASE METER WINDOW CLASS
-- =============================================================================

function MeterWindow:New(meterType, config)
    -- Merge config with defaults
    local windowConfig = {}
    for k, v in pairs(UI_CONFIG) do
        windowConfig[k] = v
    end
    if config then
        for k, v in pairs(config) do
            windowConfig[k] = v
        end
    end
    
    local instance = {
        meterType = meterType,
        config = windowConfig,
        
        -- UI State
        state = {
            mainFrame = nil,
            isVisible = false,
            lastUpdate = 0,
            updateTimer = nil,
            
            -- Auto-scaling
            autoScale = true,
            currentScale = 1,
            scaleUnit = "",
            
            -- Time window mode
            windowMode = "SHORT",  -- CURRENT (5s), SHORT (15s), MEDIUM (30s), LONG (60s)
            windowSeconds = 15,
            
            -- Peak tracking
            sessionPeak = 0,      -- Never decays (session-wide)
            recentPeak = 0,       -- Decaying peak (from accumulator)
            
            -- Scale update tracking
            lastScaleUpdate = 0,
            lastScaleValue = "1K",
            currentScaleMax = 1000,  -- The actual numeric value of the scale
            wasOutOfCombat = true,  -- Tracks combat state transitions
            
            -- Display elements
            activityBar = {},     -- Activity bar segments
            mainNumberText = nil,
            scaleText = nil,
            peakText = nil,
            modeText = nil,
            closeButton = nil,
            labelText = nil,
            petText = nil,
        }
    }
    
    -- Copy methods to instance
    for k, v in pairs(self) do
        if type(v) == "function" and k ~= "New" then
            instance[k] = v
        end
    end
    
    return instance
end

-- =============================================================================
-- CUSTOM FONTS
-- =============================================================================

-- Create custom font objects
function MeterWindow:CreateCustomFonts()
    -- Large number font
    local largeFont = CreateFont(self.meterType .. "LargeNumberFont")
    largeFont:SetFont(self.config.FONT_PATH, self.config.FONT_SIZE_LARGE, "OUTLINE")
    
    -- Medium font
    local mediumFont = CreateFont(self.meterType .. "MediumFont")
    mediumFont:SetFont(self.config.FONT_PATH, self.config.FONT_SIZE_MEDIUM, "OUTLINE")
    
    -- Small font
    local smallFont = CreateFont(self.meterType .. "SmallFont")
    smallFont:SetFont(self.config.FONT_PATH, self.config.FONT_SIZE_SMALL, "OUTLINE")
    
    return largeFont, mediumFont, smallFont
end

-- =============================================================================
-- UI CREATION
-- =============================================================================

-- Create the main meter window
function MeterWindow:CreateMainWindow()
    if self.state.mainFrame then
        return self.state.mainFrame
    end
    
    -- Create custom fonts
    local largeFont, mediumFont, smallFont = self:CreateCustomFonts()
    
    -- Create main frame (no template for custom look)
    local frameName = "Stormy" .. self.meterType .. "Meter"
    local frame = CreateFrame("Frame", frameName, UIParent)
    frame:SetSize(self.config.WINDOW_WIDTH, self.config.WINDOW_HEIGHT)
    frame:SetPoint("CENTER", 100, 0)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(10)
    
    -- Custom background
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(self.config.COLOR_BACKGROUND))
    
    -- Make it movable
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(frameSelf)
        frameSelf:StopMovingOrSizing()
        -- Save position
        if addon.db then
            local point, _, relativePoint, x, y = frameSelf:GetPoint()
            local positionKey = self.meterType .. "WindowPosition"
            addon.db[positionKey] = { point = point, relativePoint = relativePoint, x = x, y = y }
        end
    end)
    
    -- Create display elements
    self:CreateActivityBar(frame)
    self:CreateDisplayElements(frame, largeFont, mediumFont, smallFont)
    self:CreateCloseButton(frame)
    
    self.state.mainFrame = frame
    frame:Hide() -- Start hidden
    
    return frame
end

-- Create activity bar
function MeterWindow:CreateActivityBar(parent)
    local barWidth = self.config.ACTIVITY_SEGMENTS * (self.config.SEGMENT_WIDTH + self.config.SEGMENT_SPACING) - self.config.SEGMENT_SPACING
    local xStart = (self.config.WINDOW_WIDTH - barWidth) / 2
    
    for i = 1, self.config.ACTIVITY_SEGMENTS do
        local segment = parent:CreateTexture(nil, "ARTWORK")
        segment:SetSize(self.config.SEGMENT_WIDTH, self.config.SEGMENT_HEIGHT)
        
        local xPos = xStart + (i - 1) * (self.config.SEGMENT_WIDTH + self.config.SEGMENT_SPACING)
        segment:SetPoint("TOPLEFT", parent, "TOPLEFT", xPos, -15)
        
        segment:SetColorTexture(0.2, 0.2, 0.2, 1) -- Default dark gray
        
        self.state.activityBar[i] = segment
    end
end

-- Create display text elements (to be customized by subclasses)
function MeterWindow:CreateDisplayElements(parent, largeFont, mediumFont, smallFont)
    -- Main number - color will be set by subclass
    self.state.mainNumberText = parent:CreateFontString(nil, "OVERLAY")
    self.state.mainNumberText:SetFontObject(largeFont)
    self.state.mainNumberText:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, -35)
    self.state.mainNumberText:SetText("0")
    self.state.mainNumberText:SetTextColor(unpack(self.config.COLOR_TEXT_PRIMARY))
    
    -- Scale indicator (e.g., "275K (auto)")
    self.state.scaleText = parent:CreateFontString(nil, "OVERLAY")
    self.state.scaleText:SetFontObject(mediumFont)
    self.state.scaleText:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, -85)
    self.state.scaleText:SetText("1 (auto)")
    self.state.scaleText:SetTextColor(unpack(self.config.COLOR_TEXT_SECONDARY))
    
    -- Peak value
    self.state.peakText = parent:CreateFontString(nil, "OVERLAY")
    self.state.peakText:SetFontObject(smallFont)
    self.state.peakText:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, -105)
    self.state.peakText:SetText("0 peak")
    self.state.peakText:SetTextColor(unpack(self.config.COLOR_TEXT_DIM))
    
    -- Pet indicator
    self.state.petText = parent:CreateFontString(nil, "OVERLAY")
    self.state.petText:SetFontObject(smallFont)
    self.state.petText:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 20, 10)
    self.state.petText:SetText("")
    self.state.petText:SetTextColor(unpack(self.config.COLOR_TEXT_SECONDARY))
    
    -- Time window indicator (bottom right) - make it clickable
    local windowButton = CreateFrame("Button", nil, parent)
    windowButton:SetSize(60, 20)
    windowButton:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -15, 10)
    windowButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    
    self.state.modeText = windowButton:CreateFontString(nil, "OVERLAY")
    self.state.modeText:SetFontObject(smallFont)
    self.state.modeText:SetAllPoints()
    self.state.modeText:SetText("15 sec")  -- Match default windowSeconds
    self.state.modeText:SetTextColor(unpack(self.config.COLOR_TEXT_DIM))
    
    -- Highlight on hover
    windowButton:SetScript("OnEnter", function()
        self.state.modeText:SetTextColor(unpack(self.config.COLOR_TEXT_SECONDARY))
    end)
    windowButton:SetScript("OnLeave", function()
        self.state.modeText:SetTextColor(unpack(self.config.COLOR_TEXT_DIM))
    end)
    
    -- Click to cycle windows
    windowButton:SetScript("OnClick", function(frameSelf, button)
        if button == "LeftButton" then
            self:CycleWindowMode(1)
        else
            self:CycleWindowMode(-1)
        end
    end)
    
    self.state.windowButton = windowButton
    
    -- Meter label (top right) - to be set by subclass
    self.state.labelText = parent:CreateFontString(nil, "OVERLAY")
    self.state.labelText:SetFontObject(mediumFont)
    self.state.labelText:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -20, -15)
    self.state.labelText:SetText(self.meterType:upper())
    self.state.labelText:SetTextColor(unpack(self.config.COLOR_TEXT_PRIMARY))
    
    -- Allow subclasses to customize display elements
    if self.CustomizeDisplayElements then
        self:CustomizeDisplayElements(parent, largeFont, mediumFont, smallFont)
    end
end

-- Create custom close button
function MeterWindow:CreateCloseButton(parent)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(16, 16)
    button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -5, -5)
    
    -- X texture
    button:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    button:SetHighlightTexture("Interface\\Buttons\\UI-StopButton")
    button:GetHighlightTexture():SetAlpha(0.5)
    
    button:SetScript("OnClick", function()
        self:Hide()
    end)
    
    self.state.closeButton = button
end

-- =============================================================================
-- NUMBER FORMATTING AND SCALING
-- =============================================================================

-- Format number with auto-scaling
function MeterWindow:FormatNumberWithScale(value)
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
function MeterWindow:GetIntelligentScale()
    local activityLevel = 0
    if self.GetActivityLevel then
        activityLevel = self:GetActivityLevel()
    end
    
    -- Different scaling logic based on activity
    local referencePeak
    if activityLevel > 0.1 then
        -- In combat: use recent peak primarily, with session peak as fallback
        referencePeak = math.max(self.state.recentPeak, self.state.sessionPeak * 0.5)
    else
        -- Out of combat: use much lower reference to allow scale to drop
        -- Use recent peak only, or current value + small buffer
        referencePeak = math.max(self.state.recentPeak, (self.state.currentValue or 0) * 2)
        -- But don't go below 10% of session peak to avoid too much jumping
        local minScale = self.state.sessionPeak * 0.1
        if minScale > 1000 then
            referencePeak = math.max(referencePeak, minScale)
        end
    end
    
    -- If we have no meaningful peak yet, use current value
    if referencePeak < 1000 then
        referencePeak = math.max(1000, self.state.currentValue or 0)
    end
    
    -- Add headroom based on activity
    local headroomMultiplier = activityLevel > 0.1 and 1.25 or 1.1
    local targetScale = referencePeak * headroomMultiplier
    
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

-- Update activity bar based on current metric relative to scale
function MeterWindow:UpdateActivityBar(currentMetric)
    -- Calculate how full the bar should be based on current metric vs scale
    local fillPercent = 0
    if self.state.currentScaleMax > 0 then
        fillPercent = math.min(1, currentMetric / self.state.currentScaleMax)
    end
    
    local activeSegments = math.floor(fillPercent * self.config.ACTIVITY_SEGMENTS + 0.5)
    
    for i = 1, self.config.ACTIVITY_SEGMENTS do
        local segment = self.state.activityBar[i]
        if i <= activeSegments then
            -- Calculate color based on position
            local percent = i / self.config.ACTIVITY_SEGMENTS
            local r, g, b
            
            if percent <= 0.33 then
                -- Green to yellow
                local t = percent / 0.33
                r = self.config.COLOR_ACTIVITY_LOW[1] + (self.config.COLOR_ACTIVITY_MED[1] - self.config.COLOR_ACTIVITY_LOW[1]) * t
                g = self.config.COLOR_ACTIVITY_LOW[2] + (self.config.COLOR_ACTIVITY_MED[2] - self.config.COLOR_ACTIVITY_LOW[2]) * t
                b = self.config.COLOR_ACTIVITY_LOW[3] + (self.config.COLOR_ACTIVITY_MED[3] - self.config.COLOR_ACTIVITY_LOW[3]) * t
            elseif percent <= 0.66 then
                -- Yellow to orange
                local t = (percent - 0.33) / 0.33
                r = self.config.COLOR_ACTIVITY_MED[1] + (self.config.COLOR_ACTIVITY_HIGH[1] - self.config.COLOR_ACTIVITY_MED[1]) * t
                g = self.config.COLOR_ACTIVITY_MED[2] + (self.config.COLOR_ACTIVITY_HIGH[2] - self.config.COLOR_ACTIVITY_MED[2]) * t
                b = self.config.COLOR_ACTIVITY_MED[3] + (self.config.COLOR_ACTIVITY_HIGH[3] - self.config.COLOR_ACTIVITY_MED[3]) * t
            else
                -- Orange to red
                local t = (percent - 0.66) / 0.34
                r = self.config.COLOR_ACTIVITY_HIGH[1] + (self.config.COLOR_ACTIVITY_MAX[1] - self.config.COLOR_ACTIVITY_HIGH[1]) * t
                g = self.config.COLOR_ACTIVITY_HIGH[2] + (self.config.COLOR_ACTIVITY_MAX[2] - self.config.COLOR_ACTIVITY_HIGH[2]) * t
                b = self.config.COLOR_ACTIVITY_HIGH[3] + (self.config.COLOR_ACTIVITY_MAX[3] - self.config.COLOR_ACTIVITY_HIGH[3]) * t
            end
            
            segment:SetColorTexture(r, g, b, 1)
        else
            -- Inactive segment
            segment:SetColorTexture(0.2, 0.2, 0.2, 1)
        end
    end
end

-- Update display with current data (to be customized by subclasses)
function MeterWindow:UpdateDisplay()
    if not self.state.mainFrame or not self.state.isVisible then
        return
    end
    
    local now = GetTime()
    
    -- Throttle updates
    if now - self.state.lastUpdate < (self.config.UPDATE_RATE / 1000) then
        return
    end
    
    self.state.lastUpdate = now
    
    -- Subclasses should override this method to provide actual data
    local currentValue = 0
    local displayData = {}
    
    if self.GetDisplayData then
        displayData = self:GetDisplayData()
        currentValue = displayData.currentMetric or 0
    end
    
    -- Update main number
    if self.state.mainNumberText then
        local formatted, scale, unit = self:FormatNumberWithScale(currentValue)
        self.state.mainNumberText:SetText(formatted .. unit)
    end
    
    -- Update activity bar
    self:UpdateActivityBar(currentValue)
    
    -- Allow subclasses to add custom update logic
    if self.CustomUpdateDisplay then
        self:CustomUpdateDisplay(currentValue, displayData)
    end
end

-- Start periodic updates
function MeterWindow:StartUpdates()
    if self.state.updateTimer then
        return
    end
    
    self.state.updateTimer = C_Timer.NewTicker(self.config.UPDATE_RATE / 1000, function()
        self:UpdateDisplay()
    end)
end

-- Stop periodic updates
function MeterWindow:StopUpdates()
    if self.state.updateTimer then
        self.state.updateTimer:Cancel()
        self.state.updateTimer = nil
    end
end

-- =============================================================================
-- WINDOW MANAGEMENT
-- =============================================================================

-- Show the meter
function MeterWindow:Show()
    if not self.state.mainFrame then
        self:CreateMainWindow()
    end
    
    -- Restore position if saved
    if addon.db then
        local positionKey = self.meterType .. "WindowPosition"
        if addon.db[positionKey] then
            self:RestorePosition(addon.db[positionKey])
        end
    end
    
    self.state.mainFrame:Show()
    self.state.isVisible = true
    
    self:StartUpdates()
    self:UpdateDisplay() -- Immediate update
    
    -- Save state
    if addon.db then
        local showKey = "show" .. self.meterType .. "Window"
        addon.db[showKey] = true
    end
end

-- Hide the meter
function MeterWindow:Hide()
    if self.state.mainFrame then
        self.state.mainFrame:Hide()
    end
    
    self.state.isVisible = false
    self:StopUpdates()
    
    -- Save state
    if addon.db then
        local showKey = "show" .. self.meterType .. "Window"
        addon.db[showKey] = false
    end
end

-- Toggle visibility
function MeterWindow:Toggle()
    if self.state.isVisible then
        self:Hide()
    else
        self:Show()
    end
end

-- Cycle through window modes
function MeterWindow:CycleWindowMode(direction)
    local modes = {
        {name = "CURRENT", seconds = 5, label = "5 sec"},
        {name = "SHORT", seconds = 15, label = "15 sec"},
        {name = "MEDIUM", seconds = 30, label = "30 sec"},
        {name = "LONG", seconds = 60, label = "60 sec"}
    }
    
    -- Find current mode index
    local currentIndex = 1
    for i, mode in ipairs(modes) do
        if mode.name == self.state.windowMode then
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
    self.state.windowMode = newMode.name
    self.state.windowSeconds = newMode.seconds
    
    -- Update display
    if self.state.modeText then
        self.state.modeText:SetText(newMode.label)
    end
    
    -- Force immediate recalculation
    self:ForceUpdate()
end

-- Check if visible
function MeterWindow:IsVisible()
    return self.state.isVisible and self.state.mainFrame and self.state.mainFrame:IsShown()
end

-- Get window position (for saving)
function MeterWindow:GetPosition()
    if not self.state.mainFrame then
        return nil
    end
    
    local point, relativeTo, relativePoint, xOfs, yOfs = self.state.mainFrame:GetPoint()
    return {
        point = point,
        relativePoint = relativePoint,
        x = xOfs,
        y = yOfs
    }
end

-- Restore window position
function MeterWindow:RestorePosition(position)
    if not self.state.mainFrame or not position then
        return
    end
    
    self.state.mainFrame:ClearAllPoints()
    self.state.mainFrame:SetPoint(
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
function MeterWindow:ForceUpdate()
    self.state.lastUpdate = 0 -- Reset throttle
    self:UpdateDisplay()
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the meter window
function MeterWindow:Initialize()
    -- Create the main window (but keep it hidden)
    self:CreateMainWindow()
    
    -- Allow subclasses to add custom initialization
    if self.CustomInitialize then
        self:CustomInitialize()
    end
end

-- Module ready
MeterWindow.isReady = true

return MeterWindow