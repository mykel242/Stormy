-- MySimpleLogWindow.lua
-- Simple, user-friendly log window with selectable text and copy/paste support
-- Replaces the complex ring buffer approach with a straightforward scrolling text area

local addonName, addon = ...

-- =============================================================================
-- MY SIMPLE LOG WINDOW MODULE
-- =============================================================================

local MySimpleLogWindow = {}
addon.MySimpleLogWindow = MySimpleLogWindow

-- =============================================================================
-- CONSTANTS AND CONFIGURATION
-- =============================================================================

local WINDOW_WIDTH = 800
local WINDOW_HEIGHT = 600
local MAX_LOG_LINES = 2000  -- Keep last 2000 lines for performance
local LOG_FONT_SIZE = 12

-- =============================================================================
-- STATE TRACKING
-- =============================================================================

local logWindow = nil
local logFrame = nil
local logEditBox = nil
local isVisible = false
local logLines = {}
local lineCount = 0

-- =============================================================================
-- CORE FUNCTIONALITY
-- =============================================================================

function MySimpleLogWindow:Initialize()
    -- Subscribe to log events
    if addon.LogEventQueue then
        addon.LogEventQueue:Subscribe("LOG", function(message)
            self:AddLogLine(message.data.formattedMessage)
        end, "SimpleLogWindow")
        addon:Debug("MySimpleLogWindow: Subscribed to LOG events from LogEventQueue")
    else
        addon:Warn("MySimpleLogWindow: LogEventQueue not available for subscription")
    end
end

function MySimpleLogWindow:AddLogLine(line)
    if not line then return end
    
    -- Add to our line buffer
    lineCount = lineCount + 1
    logLines[lineCount] = line
    
    -- Trim old lines if we exceed the limit
    if lineCount > MAX_LOG_LINES then
        -- Remove the oldest 200 lines when we hit the limit
        local removeCount = 200
        for i = 1, lineCount - removeCount do
            logLines[i] = logLines[i + removeCount]
        end
        lineCount = lineCount - removeCount
        
        -- Clear the nil entries
        for i = lineCount + 1, lineCount + removeCount do
            logLines[i] = nil
        end
    end
    
    -- Update the display if window is visible and properly initialized
    if isVisible and logEditBox and logWindow then
        self:RefreshDisplay()
    end
end

function MySimpleLogWindow:RefreshDisplay()
    if not logEditBox or not logWindow then return end
    
    -- Combine all log lines into a single string
    local logText = table.concat(logLines, "\n", 1, lineCount)
    
    -- Set the text
    logEditBox:SetText(logText)
    
    -- Auto-scroll to bottom if enabled
    if logWindow.autoScroll and logWindow.autoScroll() then
        logEditBox:SetCursorPosition(string.len(logText))
    end
    
    -- No need to manually set height - let the scroll frame handle it
end

-- =============================================================================
-- WINDOW CREATION
-- =============================================================================

function MySimpleLogWindow:CreateWindow()
    if logWindow then return end
    
    -- Create main window frame
    logWindow = CreateFrame("Frame", addonName .. "SimpleLogWindow", UIParent, BackdropTemplateMixin and "BackdropTemplate")
    logWindow:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    logWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    logWindow:SetMovable(true)
    logWindow:EnableMouse(true)
    logWindow:RegisterForDrag("LeftButton")
    logWindow:SetScript("OnDragStart", logWindow.StartMoving)
    logWindow:SetScript("OnDragStop", logWindow.StopMovingOrSizing)
    logWindow:Hide()
    
    -- Set backdrop for window appearance
    logWindow:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 }
    })
    logWindow:SetBackdropColor(0, 0, 0, 0.9)
    
    -- Create title bar
    local titleBar = logWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    titleBar:SetPoint("TOP", logWindow, "TOP", 0, -15)
    titleBar:SetText("MyUI2 Log Viewer")
    
    -- Create scrollable edit box for log content
    local scrollFrame = CreateFrame("ScrollFrame", nil, logWindow, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", logWindow, "TOPLEFT", 15, -45)
    scrollFrame:SetPoint("BOTTOMRIGHT", logWindow, "BOTTOMRIGHT", -35, 45)
    
    -- Create the actual edit box
    logEditBox = CreateFrame("EditBox", nil, scrollFrame)
    logEditBox:SetMultiLine(true)
    logEditBox:SetAutoFocus(false)
    logEditBox:SetFontObject("ChatFontNormal")
    logEditBox:SetWidth(WINDOW_WIDTH - 50)
    logEditBox:SetScript("OnEscapePressed", function() logEditBox:ClearFocus() end)
    
    -- Make text selectable for copy/paste
    logEditBox:EnableMouse(true)
    logEditBox:SetScript("OnEditFocusGained", function() end) -- Allow text selection
    logEditBox:SetScript("OnEditFocusLost", function() end)
    
    -- Set up scroll frame
    scrollFrame:SetScrollChild(logEditBox)
    
    -- Create control buttons
    self:CreateControlButtons()
    
    -- Store references
    logFrame = scrollFrame
    
    addon:Debug("MySimpleLogWindow: Window created")
end

function MySimpleLogWindow:CreateControlButtons()
    -- Close button
    local closeButton = CreateFrame("Button", nil, logWindow, "GameMenuButtonTemplate")
    closeButton:SetSize(80, 25)
    closeButton:SetPoint("BOTTOMRIGHT", logWindow, "BOTTOMRIGHT", -15, 15)
    closeButton:SetText("Close")
    closeButton:SetScript("OnClick", function()
        self:Hide()
    end)
    
    -- Clear button
    local clearButton = CreateFrame("Button", nil, logWindow, "GameMenuButtonTemplate")
    clearButton:SetSize(80, 25)
    clearButton:SetPoint("RIGHT", closeButton, "LEFT", -10, 0)
    clearButton:SetText("Clear")
    clearButton:SetScript("OnClick", function()
        self:ClearLog()
    end)
    
    -- Copy All button (sets focus to edit box for easy Ctrl+A, Ctrl+C)
    local copyButton = CreateFrame("Button", nil, logWindow, "GameMenuButtonTemplate")
    copyButton:SetSize(80, 25)
    copyButton:SetPoint("RIGHT", clearButton, "LEFT", -10, 0)
    copyButton:SetText("Select All")
    copyButton:SetScript("OnClick", function()
        logEditBox:SetFocus()
        logEditBox:HighlightText()
    end)
    
    -- Auto-scroll toggle
    local autoScrollButton = CreateFrame("Button", nil, logWindow, "GameMenuButtonTemplate")
    autoScrollButton:SetSize(100, 25)
    autoScrollButton:SetPoint("RIGHT", copyButton, "LEFT", -10, 0)
    autoScrollButton:SetText("Auto-scroll: ON")
    
    local autoScroll = true
    autoScrollButton:SetScript("OnClick", function()
        autoScroll = not autoScroll
        autoScrollButton:SetText("Auto-scroll: " .. (autoScroll and "ON" or "OFF"))
    end)
    
    -- Store auto-scroll state
    logWindow.autoScroll = function() return autoScroll end
end

-- =============================================================================
-- PUBLIC INTERFACE
-- =============================================================================

function MySimpleLogWindow:Show()
    if not logWindow then
        self:CreateWindow()
    end
    
    logWindow:Show()
    isVisible = true
    
    -- Load recent log messages if the window is empty
    if lineCount == 0 then
        self:LoadRecentLogMessages()
    end
    
    -- Refresh display with current log content
    self:RefreshDisplay()
    
    addon:Debug("MySimpleLogWindow: Window shown")
end

function MySimpleLogWindow:Hide()
    if logWindow then
        logWindow:Hide()
    end
    isVisible = false
    addon:Debug("MySimpleLogWindow: Window hidden")
end

function MySimpleLogWindow:Toggle()
    if isVisible then
        self:Hide()
    else
        self:Show()
    end
end

function MySimpleLogWindow:IsVisible()
    return isVisible and logWindow and logWindow:IsVisible()
end

function MySimpleLogWindow:ClearLog()
    logLines = {}
    lineCount = 0
    
    if logEditBox then
        logEditBox:SetText("")
    end
    
    addon:Info("Log cleared (%d lines removed)", lineCount)
end

-- Load recent log messages from MyLogger when window first opens
function MySimpleLogWindow:LoadRecentLogMessages()
    if addon.MyLogger and addon.MyLogger.GetRecentMessages then
        local recentMessages = addon.MyLogger:GetRecentMessages(100) -- Get last 100 messages
        for _, messageData in ipairs(recentMessages) do
            if messageData.formattedMessage then
                self:AddLogLine(messageData.formattedMessage)
            end
        end
        addon:Debug("MySimpleLogWindow: Loaded %d recent log messages", #recentMessages)
    else
        -- Add a welcome message if no recent messages available
        self:AddLogLine("[08:00:00] [INFO] [myui2] MyUI2 Simple Log Window - Ready for copy/paste")
        addon:Debug("MySimpleLogWindow: No recent messages available, added welcome message")
    end
end

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================

function MySimpleLogWindow:GetLogLineCount()
    return lineCount
end

function MySimpleLogWindow:GetLogText()
    return table.concat(logLines, "\n", 1, lineCount)
end

-- Export log to a table for external use
function MySimpleLogWindow:ExportLog()
    local export = {}
    for i = 1, lineCount do
        export[i] = logLines[i]
    end
    return export
end

return MySimpleLogWindow