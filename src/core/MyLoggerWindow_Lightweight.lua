-- MyLoggerWindow_Lightweight.lua
-- Ultra-lightweight logger window with ZERO performance impact
-- 
-- DESIGN PRINCIPLES:
-- - Ring buffer with fixed memory allocation
-- - No ScrollingMessageFrame, no persistence, no filters
-- - Simple FontString rendering of last N messages
-- - Aggressive throttling (max 2 FPS updates)
-- - Ephemeral messages only - nothing stored
-- - Absolutely minimal CPU/memory footprint

local addonName, addon = ...

local MyLoggerWindow = {}
addon.MyLoggerWindow = MyLoggerWindow

-- =============================================================================
-- CONSTANTS - TUNED FOR ZERO PERFORMANCE IMPACT
-- =============================================================================

local WINDOW_WIDTH = 600
local WINDOW_HEIGHT = 600
local MAX_VISIBLE_LINES = 30  -- FontStrings to create
local MAX_BUFFER_SIZE = 1000  -- Total messages in memory
local LINE_HEIGHT = 18
local UPDATE_INTERVAL = 0.5  -- Max 2 FPS updates
local FONT_SIZE = 12

-- Message type colors
local MESSAGE_COLORS = {
    PANIC = "|cFFFF0000",  -- Red
    ERROR = "|cFFFF6B6B",  -- Light Red
    WARN = "|cFFFFD93D",   -- Yellow
    INFO = "|cFFFFFFFF",   -- White
    DEBUG = "|cFF6BCB77",  -- Green
    TRACE = "|cFF9B9B9B",  -- Gray
}

-- =============================================================================
-- RING BUFFER - FIXED SIZE, NO ALLOCATIONS
-- =============================================================================

local ringBuffer = {
    messages = {},      -- Pre-allocated array
    writePos = 1,       -- Next write position
    count = 0,          -- Current message count
    scrollOffset = 0,   -- How many lines scrolled up from bottom
}

-- Pre-allocate the ring buffer for 1000 messages
for i = 1, MAX_BUFFER_SIZE do
    ringBuffer.messages[i] = {
        text = "",
        color = "",
        timestamp = "",
    }
end

-- =============================================================================
-- UI ELEMENTS
-- =============================================================================

local window = nil
local fontStrings = {}  -- Pre-allocated FontStrings
local content = nil     -- Content frame reference
local lastUpdateTime = 0
local isDirty = false   -- Needs UI refresh
local isVisible = false

-- =============================================================================
-- RING BUFFER OPERATIONS
-- =============================================================================

local function AddMessage(level, text)
    -- Get the message slot to write to
    local msg = ringBuffer.messages[ringBuffer.writePos]
    
    -- Update the message (reuse existing table)
    msg.text = text
    msg.color = MESSAGE_COLORS[level] or MESSAGE_COLORS.INFO
    msg.timestamp = date("%H:%M:%S")
    
    -- Advance write position
    ringBuffer.writePos = ringBuffer.writePos % MAX_BUFFER_SIZE + 1
    ringBuffer.count = math.min(ringBuffer.count + 1, MAX_BUFFER_SIZE)
    
    -- Auto-follow behavior: stay at bottom if following, maintain position if not
    if isAutoFollowing then
        -- Auto-follow mode: always stay at bottom
        ringBuffer.scrollOffset = 0
    else
        -- Manual mode: increment offset to maintain current view position
        if ringBuffer.scrollOffset > 0 then
            ringBuffer.scrollOffset = ringBuffer.scrollOffset + 1
        end
    end
    
    -- Mark for UI update
    isDirty = true
end

-- =============================================================================
-- DYNAMIC SIZING
-- =============================================================================

-- Calculate how many lines can fit in current window size
local function CalculateMaxVisibleLines()
    if not content then return MAX_VISIBLE_LINES end
    
    local _, contentHeight = content:GetSize()
    local maxLines = math.max(1, math.floor(contentHeight / LINE_HEIGHT))
    
    -- Ensure we have enough FontStrings created
    while #fontStrings < maxLines and #fontStrings < MAX_BUFFER_SIZE do
        local i = #fontStrings + 1
        local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetFont("Fonts\\FRIZQT__.TTF", FONT_SIZE, "OUTLINE")
        fs:SetJustifyH("LEFT")
        fs:SetPoint("TOPLEFT", 0, -(i - 1) * LINE_HEIGHT)
        fs:SetPoint("RIGHT", -5, 0)
        fs:SetHeight(LINE_HEIGHT)
        fs:Hide()
        fontStrings[i] = fs
    end
    
    return math.min(maxLines, MAX_BUFFER_SIZE, #fontStrings)
end

-- =============================================================================
-- UI UPDATE - HEAVILY THROTTLED
-- =============================================================================

local function UpdateDisplay()
    if not isVisible or not isDirty then return end
    
    local currentTime = GetTime()
    if currentTime - lastUpdateTime < UPDATE_INTERVAL then
        return -- Throttle updates
    end
    
    lastUpdateTime = currentTime
    isDirty = false
    
    -- Calculate which messages to show (from bottom up, accounting for scroll)
    local maxVisibleLines = CalculateMaxVisibleLines()
    local visibleCount = math.min(ringBuffer.count, maxVisibleLines)
    local newestIndex = ringBuffer.writePos - 1
    if newestIndex <= 0 then newestIndex = newestIndex + MAX_BUFFER_SIZE end
    
    -- Apply scroll offset (0 = show newest, higher = scroll up in history)
    local displayStartIndex = newestIndex - ringBuffer.scrollOffset
    
    -- Update FontStrings (up to current max visible lines)
    for i = 1, maxVisibleLines do
        local fontString = fontStrings[i]
        if i <= visibleCount and (i + ringBuffer.scrollOffset) <= ringBuffer.count then
            -- Calculate which message to show (counting backwards from newest)
            local messageIndex = displayStartIndex - (visibleCount - i)
            if messageIndex <= 0 then messageIndex = messageIndex + MAX_BUFFER_SIZE end
            if messageIndex > MAX_BUFFER_SIZE then messageIndex = messageIndex - MAX_BUFFER_SIZE end
            
            local msg = ringBuffer.messages[messageIndex]
            if msg and msg.text ~= "" then
                fontString:SetText(string.format("%s[%s] %s%s|r", 
                    msg.color, msg.timestamp, msg.color, msg.text))
                fontString:Show()
            else
                fontString:Hide()
            end
        else
            fontString:Hide()
        end
    end
    
    -- Hide any FontStrings beyond the calculated max visible lines (prevents overflow)
    for i = maxVisibleLines + 1, #fontStrings do
        fontStrings[i]:Hide()
    end
    
    -- Update scroll button visibility (only if buttons exist)
    if UpdateButtonVisibility then
        UpdateButtonVisibility()
    end
end

-- =============================================================================
-- SCROLL BUTTON VISIBILITY IMPLEMENTATION
-- =============================================================================

UpdateButtonVisibility = function()
    if not scrollUpButton or not scrollDownButton then return end
    
    local maxVisibleLines = CalculateMaxVisibleLines()
    local canScrollUp = ringBuffer.count > maxVisibleLines and ringBuffer.scrollOffset < (ringBuffer.count - maxVisibleLines)
    local canScrollDown = ringBuffer.scrollOffset > 0
    
    -- Show/hide and enable/disable scroll buttons based on available content
    if canScrollUp then
        scrollUpButton:Show()
        scrollUpButton:Enable()
    else
        scrollUpButton:Hide()
    end
    
    -- Auto-follow mode: hide down button when following (always at bottom)
    if isAutoFollowing or not canScrollDown then
        scrollDownButton:Hide()
    else
        scrollDownButton:Show()
        scrollDownButton:Enable()
    end
end

-- =============================================================================
-- SCROLL BUTTON VISIBILITY AND AUTO-FOLLOW
-- =============================================================================

local scrollUpButton, scrollDownButton = nil, nil
local autoFollowCheckbox = nil
local isAutoFollowing = true  -- Start with auto-follow enabled

-- Forward declaration
local UpdateButtonVisibility

-- =============================================================================
-- SIMPLE WINDOW CREATION - NO TEMPLATES
-- =============================================================================

local function CreateWindow()
    if window then return window end
    
    -- Main window frame - use modern mixins for backdrop and resizing
    window = CreateFrame("Frame", "MyUI2LoggerWindowLightweight", UIParent, "BackdropTemplate")
    window:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    window:SetPoint("CENTER")
    window:SetMovable(true)
    window:SetClampedToScreen(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    
    -- Add resize functionality (manual implementation - no mixin needed)
    window:SetResizable(true)
    -- Note: SetMinResize/SetMaxResize don't exist - we'll handle limits manually
    
    window:Hide()
    
    -- Simple backdrop (BackdropTemplate mixin provides SetBackdrop method)
    window:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    window:SetBackdropColor(0, 0, 0, 0.8)
    
    -- Title bar
    local titleBg = window:CreateTexture(nil, "BACKGROUND")
    titleBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleBg:SetPoint("TOP", 0, 12)
    titleBg:SetSize(256, 64)
    
    -- Title text
    local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -5)
    title:SetText("MyUI2 Debug Output (Lightweight)")
    
    -- Close button
    local closeButton = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -5, -5)
    closeButton:SetScript("OnClick", function() window:Hide() end)
    
    -- Resize handle (bottom-right corner)
    local resizeHandle = CreateFrame("Button", nil, window)
    resizeHandle:SetSize(16, 16)
    resizeHandle:SetPoint("BOTTOMRIGHT", -2, 2)
    resizeHandle:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeHandle:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeHandle:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeHandle:EnableMouse(true)
    resizeHandle:SetScript("OnMouseDown", function() window:StartSizing("BOTTOMRIGHT") end)
    resizeHandle:SetScript("OnMouseUp", function() 
        window:StopMovingOrSizing()
        
        -- Enforce size limits manually
        local width, height = window:GetSize()
        local newWidth = math.max(300, math.min(1200, width))   -- Min 300, Max 1200
        local newHeight = math.max(200, math.min(800, height))  -- Min 200, Max 800
        
        if newWidth ~= width or newHeight ~= height then
            window:SetSize(newWidth, newHeight)
        end
        
        -- Trigger display refresh to recalculate visible lines and update buttons
        isDirty = true
        UpdateDisplay() -- Force immediate update for resize
    end)
    
    -- Content area with better margins
    content = CreateFrame("Frame", nil, window)
    content:SetPoint("TOPLEFT", 25, -45)        -- More left/top margin
    content:SetPoint("BOTTOMRIGHT", -25, 45)    -- More right/bottom margin
    
    -- Pre-create FontStrings
    for i = 1, MAX_VISIBLE_LINES do
        local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetFont("Fonts\\FRIZQT__.TTF", FONT_SIZE, "OUTLINE")
        fs:SetJustifyH("LEFT")
        fs:SetPoint("TOPLEFT", 0, -(i - 1) * LINE_HEIGHT)
        fs:SetPoint("RIGHT", -5, 0)
        fs:SetHeight(LINE_HEIGHT)
        fs:Hide()
        fontStrings[i] = fs
    end
    
    -- Bottom bar frame
    local bottomBar = CreateFrame("Frame", nil, window)
    bottomBar:SetPoint("BOTTOMLEFT", 10, 10)
    bottomBar:SetPoint("BOTTOMRIGHT", -10, 10)
    bottomBar:SetHeight(25)
    
    -- Auto-follow checkbox
    autoFollowCheckbox = CreateFrame("CheckButton", nil, bottomBar, "UICheckButtonTemplate")
    autoFollowCheckbox:SetSize(20, 20)
    autoFollowCheckbox:SetPoint("LEFT", 5, 0)
    autoFollowCheckbox:SetChecked(isAutoFollowing)
    
    -- Auto-follow label
    local followLabel = bottomBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    followLabel:SetPoint("LEFT", autoFollowCheckbox, "RIGHT", 5, 0)
    followLabel:SetText("Auto-follow")
    followLabel:SetTextColor(0.8, 0.8, 0.8)
    
    -- Auto-follow checkbox behavior
    autoFollowCheckbox:SetScript("OnClick", function(self)
        isAutoFollowing = self:GetChecked()
        
        if isAutoFollowing then
            -- Jump to most recent messages and stay there
            ringBuffer.scrollOffset = 0
            isDirty = true
        end
        
        -- Update button visibility immediately (safe call)
        if UpdateButtonVisibility then
            UpdateButtonVisibility()
        end
    end)
    
    -- Scroll buttons (using text instead of unicode arrows for compatibility)
    scrollUpButton = CreateFrame("Button", nil, bottomBar, "UIPanelButtonTemplate")
    scrollUpButton:SetSize(50, 22)
    scrollUpButton:SetPoint("RIGHT", -80, 0)
    scrollUpButton:SetText("Up")
    scrollUpButton:SetScript("OnClick", function()
        -- Up = scroll towards older messages (increase offset)
        local maxVisibleLines = CalculateMaxVisibleLines()
        local maxOffset = math.max(0, ringBuffer.count - maxVisibleLines)
        ringBuffer.scrollOffset = math.min(maxOffset, ringBuffer.scrollOffset + 5)
        
        -- Disable auto-follow when user manually scrolls up
        if isAutoFollowing then
            isAutoFollowing = false
            autoFollowCheckbox:SetChecked(false)
        end
        
        isDirty = true
    end)
    
    scrollDownButton = CreateFrame("Button", nil, bottomBar, "UIPanelButtonTemplate")
    scrollDownButton:SetSize(60, 22)
    scrollDownButton:SetPoint("RIGHT", -135, 0)
    scrollDownButton:SetText("Down")
    scrollDownButton:SetScript("OnClick", function()
        -- Down = scroll towards newer messages (decrease offset, 0 = most recent)
        ringBuffer.scrollOffset = math.max(0, ringBuffer.scrollOffset - 5)
        
        -- If we've scrolled all the way to the bottom, re-enable auto-follow
        if ringBuffer.scrollOffset == 0 then
            isAutoFollowing = true
            autoFollowCheckbox:SetChecked(true)
        end
        
        isDirty = true
    end)
    
    -- Clear button
    local clearButton = CreateFrame("Button", nil, bottomBar, "UIPanelButtonTemplate")
    clearButton:SetSize(60, 22)
    clearButton:SetPoint("RIGHT", -5, 0)
    clearButton:SetText("Clear")
    clearButton:SetScript("OnClick", function()
        -- Reset ring buffer
        ringBuffer.writePos = 1
        ringBuffer.count = 0
        ringBuffer.scrollOffset = 0
        isDirty = true
        UpdateDisplay()
    end)
    
    -- OnUpdate handler for throttled updates
    window:SetScript("OnUpdate", UpdateDisplay)
    
    -- Track visibility
    window:SetScript("OnShow", function() isVisible = true end)
    window:SetScript("OnHide", function() isVisible = false end)
    
    -- Register with focus manager if available
    if addon.FocusManager then
        addon.FocusManager:RegisterWindow(window, "myui2LogWindow", "MEDIUM")
    end
    
    -- Initial button visibility update (now that UpdateButtonVisibility is defined)
    if UpdateButtonVisibility then
        UpdateButtonVisibility()
    end
    
    return window
end

-- =============================================================================
-- PUBLIC API - MINIMAL INTERFACE
-- =============================================================================

function MyLoggerWindow:Show()
    if not window then
        window = CreateWindow()
    end
    window:Show()
    isVisible = true
    isDirty = true
end

function MyLoggerWindow:Hide()
    if window then
        window:Hide()
    end
    isVisible = false
end

function MyLoggerWindow:Toggle()
    if window and window:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

function MyLoggerWindow:AddMessage(level, text)
    -- Strip any timestamp from the text (we add our own)
    text = text:gsub("^%[%d+:%d+:%d+%]%s*", "")
    text = text:gsub("^%[.-%]%s*", "")
    
    -- Truncate very long messages
    if #text > 100 then
        text = text:sub(1, 97) .. "..."
    end
    
    AddMessage(level, text)
end

-- Compatibility shims for existing API
function MyLoggerWindow:ClearAllLogs()
    if window then
        ringBuffer.writePos = 1
        ringBuffer.count = 0
        isDirty = true
    end
end

function MyLoggerWindow:GetBufferStats()
    return {
        size = ringBuffer.count,
        capacity = MAX_BUFFER_SIZE,
        displayBufferSize = math.min(ringBuffer.count, MAX_VISIBLE_LINES),
        scrollOffset = ringBuffer.scrollOffset,
        overflowCount = 0,  -- We don't track this anymore
        currentLag = 0,
        isLagged = false,
        laggedCount = 0,
        refreshRate = UPDATE_INTERVAL * 1000,
    }
end

-- Stub out methods we don't need anymore
function MyLoggerWindow:RefreshDisplay() isDirty = true end
function MyLoggerWindow:SetPaused() end
function MyLoggerWindow:SetResumed() end
function MyLoggerWindow:IsWindowShown() return window and window:IsShown() end

-- =============================================================================
-- QUEUE INTEGRATION
-- =============================================================================

local messageQueue = nil
local lastPullTime = 0

-- Pull functionality replaced by subscription-based approach

-- Initialize the lightweight logger window
function MyLoggerWindow:Initialize()
    -- Get the log message queue
    messageQueue = addon.LogEventQueue
    
    -- Subscribe to all log messages (replaces pull-based approach)
    if messageQueue then
        messageQueue:Subscribe("LOG", function(message)
            if message.data and message.data.levelName then
                -- Add all log messages to ring buffer
                AddMessage(message.data.levelName, message.data.formattedMessage or message.data.message or "")
                
                -- Mark for UI update (will refresh on next frame)
                if isVisible then
                    isDirty = true
                end
            end
        end, "LoggerWindowLightweight")
    end
    
    -- Schedule periodic pulls for other messages
    -- Timer no longer needed - using subscription-based updates
    -- C_Timer.NewTicker(UPDATE_INTERVAL, PullFromQueue)
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

addon:Debug("MyLoggerWindow (Lightweight) initialized - Zero performance impact mode")