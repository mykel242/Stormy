-- DamageMeter.lua
-- Simple damage meter UI for testing STORMY core functionality
-- Basic display with throttled updates

local addonName, addon = ...

-- =============================================================================
-- DAMAGE METER UI MODULE
-- =============================================================================

addon.DamageMeter = {}
local DamageMeter = addon.DamageMeter

-- UI Configuration
local UI_CONFIG = {
    WINDOW_WIDTH = 300,
    WINDOW_HEIGHT = 200,
    UPDATE_RATE = 500,      -- 2 FPS for testing
    BACKGROUND_ALPHA = 0.8,
    FONT_SIZE = 12
}

-- UI State
local uiState = {
    mainFrame = nil,
    isVisible = false,
    lastUpdate = 0,
    updateTimer = nil,
    
    -- Display elements
    titleText = nil,
    currentDPSText = nil,
    peakDPSText = nil,
    totalDamageText = nil,
    activityText = nil,
    statsText = nil
}

-- =============================================================================
-- UI CREATION
-- =============================================================================

-- Create the main damage meter window
function DamageMeter:CreateMainWindow()
    if uiState.mainFrame then
        return uiState.mainFrame
    end
    
    -- Create main frame
    local frame = CreateFrame("Frame", "StormyDamageMeter", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(UI_CONFIG.WINDOW_WIDTH, UI_CONFIG.WINDOW_HEIGHT)
    frame:SetPoint("CENTER", 100, 0)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(10)
    
    -- Set title
    frame.TitleText:SetText("STORMY Damage Meter")
    
    -- Make it movable
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    
    -- Close button
    frame.CloseButton:SetScript("OnClick", function()
        self:Hide()
    end)
    
    -- Create display elements
    self:CreateDisplayElements(frame)
    
    uiState.mainFrame = frame
    frame:Hide() -- Start hidden
    
    return frame
end

-- Create display text elements
function DamageMeter:CreateDisplayElements(parent)
    local yOffset = -40
    local lineHeight = 20
    
    -- Title/Status
    uiState.titleText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    uiState.titleText:SetPoint("TOP", parent, "TOP", 0, yOffset)
    uiState.titleText:SetText("STORMY v" .. addon.VERSION)
    yOffset = yOffset - lineHeight
    
    -- Current DPS
    uiState.currentDPSText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    uiState.currentDPSText:SetPoint("TOP", parent, "TOP", 0, yOffset)
    uiState.currentDPSText:SetText("Current DPS: 0")
    uiState.currentDPSText:SetTextColor(1.0, 0.8, 0.0) -- Gold
    yOffset = yOffset - lineHeight - 5
    
    -- Peak DPS
    uiState.peakDPSText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    uiState.peakDPSText:SetPoint("TOP", parent, "TOP", 0, yOffset)
    uiState.peakDPSText:SetText("Peak DPS: 0")
    uiState.peakDPSText:SetTextColor(1.0, 0.4, 0.4) -- Red
    yOffset = yOffset - lineHeight
    
    -- Total Damage
    uiState.totalDamageText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    uiState.totalDamageText:SetPoint("TOP", parent, "TOP", 0, yOffset)
    uiState.totalDamageText:SetText("Total Damage: 0")
    uiState.totalDamageText:SetTextColor(0.8, 0.8, 1.0) -- Light blue
    yOffset = yOffset - lineHeight
    
    -- Activity indicator
    uiState.activityText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    uiState.activityText:SetPoint("TOP", parent, "TOP", 0, yOffset)
    uiState.activityText:SetText("Activity: Idle")
    uiState.activityText:SetTextColor(0.6, 0.6, 0.6) -- Gray
    yOffset = yOffset - lineHeight - 5
    
    -- Stats/Debug info
    uiState.statsText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    uiState.statsText:SetPoint("TOP", parent, "TOP", 0, yOffset)
    uiState.statsText:SetText("Events: 0 | Entities: 0")
    uiState.statsText:SetTextColor(0.7, 0.7, 0.7) -- Light gray
end

-- =============================================================================
-- UI UPDATES
-- =============================================================================

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
    if addon.DamageAccumulator then
        displayData = addon.DamageAccumulator:GetDisplayData()
    end
    
    -- Update current DPS
    if uiState.currentDPSText then
        local dpsText = string.format("Current DPS: %s", self:FormatNumber(displayData.currentDPS or 0))
        uiState.currentDPSText:SetText(dpsText)
    end
    
    -- Update peak DPS
    if uiState.peakDPSText then
        local peakText = string.format("Peak DPS: %s", self:FormatNumber(displayData.peakDPS or 0))
        uiState.peakDPSText:SetText(peakText)
    end
    
    -- Update total damage
    if uiState.totalDamageText then
        local totalText = string.format("Total Damage: %s", self:FormatNumber(displayData.totalDamage or 0))
        uiState.totalDamageText:SetText(totalText)
    end
    
    -- Update activity
    if uiState.activityText then
        local activityLevel = displayData.activityLevel or 0
        local activityText = "Activity: "
        
        if activityLevel > 0.8 then
            activityText = activityText .. "High"
            uiState.activityText:SetTextColor(1.0, 0.4, 0.4) -- Red
        elseif activityLevel > 0.5 then
            activityText = activityText .. "Medium"
            uiState.activityText:SetTextColor(1.0, 0.8, 0.0) -- Yellow
        elseif activityLevel > 0.1 then
            activityText = activityText .. "Low"
            uiState.activityText:SetTextColor(0.4, 1.0, 0.4) -- Green
        else
            activityText = activityText .. "Idle"
            uiState.activityText:SetTextColor(0.6, 0.6, 0.6) -- Gray
        end
        
        local activityPercent = math.floor(activityLevel * 100)
        activityText = activityText .. string.format(" (%d%%)", activityPercent)
        uiState.activityText:SetText(activityText)
    end
    
    -- Update stats/debug info
    if uiState.statsText then
        local eventStats = ""
        local entityStats = ""
        
        -- Get event processor stats
        if addon.EventProcessor then
            local stats = addon.EventProcessor:GetStats()
            eventStats = string.format("Events: %d", stats.processedEvents)
        end
        
        -- Get entity tracker stats
        if addon.EntityTracker then
            local stats = addon.EntityTracker:GetStats()
            entityStats = string.format("Entities: %d", stats.tracking.activePets)
        end
        
        local statsText = eventStats
        if entityStats ~= "" then
            statsText = statsText .. " | " .. entityStats
        end
        
        uiState.statsText:SetText(statsText)
    end
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
    
    uiState.mainFrame:Show()
    uiState.isVisible = true
    
    self:StartUpdates()
    self:UpdateDisplay() -- Immediate update
    
    print("[STORMY] Damage meter shown")
end

-- Hide the damage meter
function DamageMeter:Hide()
    if uiState.mainFrame then
        uiState.mainFrame:Hide()
    end
    
    uiState.isVisible = false
    self:StopUpdates()
    
    print("[STORMY] Damage meter hidden")
end

-- Toggle visibility
function DamageMeter:Toggle()
    if uiState.isVisible then
        self:Hide()
    else
        self:Show()
    end
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
-- UTILITY FUNCTIONS
-- =============================================================================

-- Format numbers for display
function DamageMeter:FormatNumber(num)
    if not num or num == 0 then
        return "0"
    end
    
    if num >= 1000000000 then
        return string.format("%.1fB", num / 1000000000)
    elseif num >= 1000000 then
        return string.format("%.1fM", num / 1000000)
    elseif num >= 1000 then
        return string.format("%.1fK", num / 1000)
    else
        return tostring(math.floor(num))
    end
end

-- =============================================================================
-- DEBUGGING
-- =============================================================================

-- Debug UI state
function DamageMeter:Debug()
    print("=== DamageMeter Debug ===")
    print(string.format("Visible: %s", tostring(uiState.isVisible)))
    print(string.format("Frame exists: %s", tostring(uiState.mainFrame ~= nil)))
    print(string.format("Update timer: %s", tostring(uiState.updateTimer ~= nil)))
    print(string.format("Last update: %.1fs ago", GetTime() - uiState.lastUpdate))
    
    if uiState.mainFrame then
        local position = self:GetPosition()
        if position then
            print(string.format("Position: %s %d,%d", position.point, position.x, position.y))
        end
    end
end

-- Force immediate update
function DamageMeter:ForceUpdate()
    uiState.lastUpdate = 0 -- Reset throttle
    self:UpdateDisplay()
    print("[STORMY] Display force updated")
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
    
    print("[STORMY] DamageMeter UI initialized")
end

-- Module ready
DamageMeter.isReady = true