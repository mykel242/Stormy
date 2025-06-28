-- MyDPSMeterWindow.lua
-- Real-time DPS meter with decoupled message queue architecture
--
-- PERFORMANCE DESIGN:
-- - Ring buffer for recent combat events (30 second window)
-- - Rate-limited UI updates (max 4 FPS during combat)
-- - Lightweight FontString-based 20-segment display
-- - Memory-bounded calculations with automatic cleanup
-- - Combat-aware performance scaling

local addonName, addon = ...

-- =============================================================================
-- DPS METER WINDOW MODULE
-- =============================================================================

local MyDPSMeterWindow = {}
addon.MyDPSMeterWindow = MyDPSMeterWindow

-- =============================================================================
-- CONSTANTS AND CONFIGURATION
-- =============================================================================

local WINDOW_WIDTH = 300  -- Compact horizontal layout
local WINDOW_HEIGHT = 100 -- Height increased to accommodate pet damage line
local SEGMENT_HEIGHT = 16
local MAX_SEGMENTS = 20

-- Performance configuration for meter updates
local PERFORMANCE_CONFIG = {
    REFRESH_THROTTLE_MS = 250, -- 4 FPS max during combat
    COMBAT_THROTTLE_MS = 500,  -- 2 FPS during intensive combat
    RING_BUFFER_SIZE = 1000,   -- Combat events for calculations
    CALCULATION_WINDOW = 30,   -- Seconds of data for rolling calculations
    BUSY_THRESHOLD = 10,       -- Events per second to consider "busy"
}

-- Calculation methods
local CALCULATION_METHODS = {
    ROLLING = "rolling",
    FINAL = "final",
    HYBRID = "hybrid"
}

-- =============================================================================
-- UI ELEMENTS AND STATE
-- =============================================================================

local meterWindow = nil
local meterSegments = {}
local currentCalculationMethod = CALCULATION_METHODS.ROLLING
local isVisible = false

-- Ring buffer for combat events
local eventRingBuffer = {
    events = {},
    capacity = PERFORMANCE_CONFIG.RING_BUFFER_SIZE,
    writeIndex = 1,
    size = 0,
    totalWritten = 0
}

-- DPS meter state (HPS removed - focused on DPS only)
local meterState = {
    currentDPS = 0,
    peakDPS = 0,
    combatStartTime = 0,
    inCombat = false,
    totalDamage = 0,
    petDamage = 0,         -- Track pet damage separately
    currentPetDPS = 0,     -- Current pet DPS for display
    scale = 1800000,       -- Current scale value
    autoScale = 1800000,   -- Auto-calculated scale
    manualScale = 1800000, -- User-specified scale
    useAutoScale = true,   -- Toggle between auto/manual
    isPaused = false,
    lastUpdateTime = 0,
    refreshTimer = nil
}

-- Performance tracking
local performanceState = {
    isBusyPeriod = false,
    recentEventTimes = {},
    pendingCalculation = false,
    throttleMode = "normal" -- "normal", "combat", "intensive"
}

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

function MyDPSMeterWindow:Initialize()
    -- Set up message queue subscription for combat events
    -- Note: We delay subscriptions until after the window is created
    addon:Info("MyDPSMeterWindow: Initialize called - subscriptions will be set up after window creation")
end

function MyDPSMeterWindow:SetupSubscriptions()
    -- This is called after the window is created to ensure the message queue instance is ready
    addon:Debug("MyDPSMeterWindow:SetupSubscriptions - setting up message queue subscriptions")

    -- Debug: Check if CombatEventQueue exists
    if not addon.CombatEventQueue then
        addon:Warn("MyDPSMeterWindow: CombatEventQueue is nil!")
        return
    end

    if not addon.CombatEventQueue.Subscribe then
        addon:Warn("MyDPSMeterWindow: CombatEventQueue.Subscribe method not found!")
        return
    end

    addon:Debug("MyDPSMeterWindow: CombatEventQueue found, setting up subscriptions...")

    if addon.CombatEventQueue and addon.CombatEventQueue.Subscribe then
        -- Subscribe to combat state changes
        self.combatStateSubscriberId = addon.CombatEventQueue:Subscribe(
            "COMBAT_STATE_CHANGED",
            function(message)
                self:UpdateCombatState(message.data)
            end,
            "DPSMeterWindow_StateTracker"
        )

        -- Subscribe to damage events
        self.damageSubscriberId = addon.CombatEventQueue:Subscribe(
            "DAMAGE_EVENT",
            function(message)
                local eventData = message.data

                -- Validate event data to prevent integer overflow
                if not eventData or not eventData.amount then
                    addon:Trace("MyDPSMeterWindow: Invalid damage event data")
                    return
                end

                local amount = eventData.amount
                if type(amount) ~= "number" or amount < 0 or amount > 2147483647 then -- Max 32-bit int
                    addon:Warn("MyDPSMeterWindow: Invalid damage amount: %s (type: %s)", tostring(amount), type(amount))
                    return
                end


                addon:Trace("MyDPSMeterWindow: Received DAMAGE_EVENT, amount: %d", amount)
                self:ProcessCombatEvent({
                    type = "DAMAGE",
                    amount = amount,
                    timestamp = eventData.timestamp or GetTime(),
                    source = eventData.source,
                    target = eventData.target,
                    sourceFlags = eventData.sourceFlags,
                    spellId = eventData.spellId,
                    spellName = eventData.spellName
                })
            end,
            "DPSMeterWindow_DamageTracker"
        )

        -- DPS meter focuses only on damage events (no healing subscription)

        addon:Info("MyDPSMeterWindow: Combat event queue subscriptions established")
        addon:Debug("Subscriber IDs: State=%d, Damage=%d",
            self.combatStateSubscriberId, self.damageSubscriberId)
    else
        addon:Warn("MyDPSMeterWindow: CombatEventQueue not available - meter will not receive events")
        print("MyDPSMeterWindow: ERROR - No combat event queue available")
    end
end

-- =============================================================================
-- RING BUFFER FUNCTIONS
-- =============================================================================

-- Add combat event to ring buffer
local function AddEventToBuffer(eventData)
    eventRingBuffer.events[eventRingBuffer.writeIndex] = eventData
    eventRingBuffer.totalWritten = eventRingBuffer.totalWritten + 1

    if eventRingBuffer.size < eventRingBuffer.capacity then
        eventRingBuffer.size = eventRingBuffer.size + 1
    end

    eventRingBuffer.writeIndex = eventRingBuffer.writeIndex + 1
    if eventRingBuffer.writeIndex > eventRingBuffer.capacity then
        eventRingBuffer.writeIndex = 1
    end
end

-- Get events from last N seconds for calculations
local function GetRecentEvents(secondsBack)
    local cutoffTime = GetTime() - secondsBack
    local recentEvents = {}

    for i = 1, eventRingBuffer.size do
        local index = eventRingBuffer.writeIndex - i
        if index <= 0 then
            index = index + eventRingBuffer.capacity
        end

        local event = eventRingBuffer.events[index]
        if event and event.timestamp >= cutoffTime then
            table.insert(recentEvents, event)
        else
            break -- Events are ordered by time, so we can stop here
        end
    end

    return recentEvents
end

-- =============================================================================
-- PERFORMANCE OPTIMIZATION FUNCTIONS
-- =============================================================================

-- Check if we're in a busy combat period
local function IsBusyPeriod()
    local currentTime = GetTime()
    local recentCount = 0

    -- Count events in the last second
    for i = #performanceState.recentEventTimes, 1, -1 do
        local eventTime = performanceState.recentEventTimes[i]
        if currentTime - eventTime <= 1.0 then
            recentCount = recentCount + 1
        else
            -- Remove old entries
            table.remove(performanceState.recentEventTimes, i)
        end
    end

    return recentCount >= PERFORMANCE_CONFIG.BUSY_THRESHOLD
end

-- Update performance throttle mode based on combat intensity
local function UpdateThrottleMode()
    if not meterState.inCombat then
        performanceState.throttleMode = "normal"
    elseif IsBusyPeriod() then
        performanceState.throttleMode = "intensive"
    else
        performanceState.throttleMode = "combat"
    end
end

-- Get appropriate refresh interval based on current mode
local function GetRefreshInterval()
    if performanceState.throttleMode == "intensive" then
        return PERFORMANCE_CONFIG.COMBAT_THROTTLE_MS
    elseif performanceState.throttleMode == "combat" then
        return PERFORMANCE_CONFIG.REFRESH_THROTTLE_MS
    else
        return PERFORMANCE_CONFIG.REFRESH_THROTTLE_MS
    end
end

-- =============================================================================
-- CALCULATION ENGINE
-- =============================================================================

-- Process combat event for DPS/HPS calculation
function MyDPSMeterWindow:ProcessCombatEvent(eventData)
    -- Safety check to prevent infinite loops during startup
    if not meterWindow then
        addon:Debug("MyDPSMeterWindow: Ignoring event - window not created yet")
        return
    end

    if not eventData or meterState.isPaused then
        addon:Debug("MyDPSMeterWindow: Event rejected - eventData: %s, isPaused: %s",
            tostring(eventData ~= nil), tostring(meterState.isPaused))
        return
    end

    -- Enhanced pet-aware damage detection
    local playerGUID = UnitGUID("player")
    local playerName = UnitName("player")
    local isPlayerDamage = false
    local damageSource = "Unknown"
    local isPetDamage = false

    -- Check if this is player or pet damage
    if addon.MySimpleCombatDetector then
        local petName
        isPetDamage, petName = addon.MySimpleCombatDetector:IsPetDamage(
            eventData.source,
            eventData.spellId,
            eventData.spellName
        )

        if isPetDamage then
            isPlayerDamage = true
            damageSource = petName or "Pet"
            addon:Debug("MyDPSMeterWindow: Including pet damage from %s", damageSource)
        elseif eventData.source == playerGUID then
            isPlayerDamage = true
            damageSource = "Player"
        end
    else
        -- Fallback: just check player GUID
        isPlayerDamage = eventData.source == playerGUID
        damageSource = "Player"
    end

    if not isPlayerDamage then
        addon:Debug("MyDPSMeterWindow: FILTERED OUT - not from player or pets (source: %s)",
            tostring(eventData.source))
        return
    end


    addon:Debug("MyDPSMeterWindow: ACCEPTED damage - type=%s, amount=%s",
        eventData.type or "nil", tostring(eventData.amount))

    -- Track event timing for performance monitoring
    local currentTime = GetTime()
    table.insert(performanceState.recentEventTimes, currentTime)

    -- Add to ring buffer with pet information
    eventData.timestamp = currentTime
    eventData.isPetDamage = isPetDamage
    AddEventToBuffer(eventData)

    -- Process damage events only (HPS removed)
    if eventData.type == "DAMAGE" and eventData.amount then
        local damage = eventData.amount

        -- Sanity check for reasonable damage values (prevent overflow)
        if damage > 10000000 then -- 10M damage seems unreasonable for a single hit
            addon:Warn("MyDPSMeterWindow: Suspicious damage amount: %d, capping at 10M", damage)
            damage = 10000000
        end

        meterState.totalDamage = meterState.totalDamage + damage

        -- Track pet damage separately for display
        if isPetDamage then
            meterState.petDamage = meterState.petDamage + damage
            addon:Debug("MyDPSMeterWindow: Added pet damage %d, pet total now: %d", damage, meterState.petDamage)
        end

        addon:Debug("MyDPSMeterWindow: Added damage %d (from %s), total now: %d", damage, damageSource,
            meterState.totalDamage)
    else
        addon:Debug("MyDPSMeterWindow: Event not processed - type: %s, amount: %s",
            eventData.type or "nil", tostring(eventData.amount))
        return -- Don't schedule updates for non-damage events
    end

    -- Schedule rate-limited calculation update
    self:ScheduleCalculationUpdate()
end

-- Schedule a rate-limited meter calculation
function MyDPSMeterWindow:ScheduleCalculationUpdate()
    if performanceState.pendingCalculation then
        return -- Already scheduled
    end

    UpdateThrottleMode()
    local delay = GetRefreshInterval() / 1000

    performanceState.pendingCalculation = true
    meterState.refreshTimer = C_Timer.After(delay, function()
        performanceState.pendingCalculation = false
        meterState.refreshTimer = nil

        if meterWindow and meterWindow:IsVisible() and meterState.inCombat then
            MyDPSMeterWindow:CalculateAndUpdate()
        end
    end)
end

-- Calculate current DPS using selected method (HPS removed)
function MyDPSMeterWindow:CalculateAndUpdate()
    if not meterState.inCombat then
        return
    end

    local currentTime = GetTime()
    local combatElapsed = currentTime - meterState.combatStartTime

    if combatElapsed <= 0 then
        return
    end

    local newDPS = 0

    if currentCalculationMethod == CALCULATION_METHODS.ROLLING then
        -- Rolling average over last 5 seconds
        newDPS = self:CalculateRollingAverage(5)
    elseif currentCalculationMethod == CALCULATION_METHODS.FINAL then
        -- Total damage divided by elapsed time
        newDPS = meterState.totalDamage / combatElapsed
    elseif currentCalculationMethod == CALCULATION_METHODS.HYBRID then
        -- 70% rolling + 30% final
        local rollingDPS = self:CalculateRollingAverage(5)
        local finalDPS = meterState.totalDamage / combatElapsed

        newDPS = (rollingDPS * 0.7) + (finalDPS * 0.3)
    end

    -- Calculate pet DPS using total/duration (persistent for infrequent pet events)
    local newPetDPS = 0
    if combatElapsed > 0 then
        newPetDPS = meterState.petDamage / combatElapsed
    end

    -- Update meter state
    meterState.currentDPS = newDPS
    meterState.currentPetDPS = newPetDPS
    meterState.peakDPS = math.max(meterState.peakDPS, newDPS)
    meterState.lastUpdateTime = currentTime

    -- Update visual display
    self:UpdateMeterDisplay()
end

-- Calculate rolling average DPS (HPS removed)
function MyDPSMeterWindow:CalculateRollingAverage(windowSeconds, petOnly)
    local recentEvents = GetRecentEvents(windowSeconds)
    local totalDamage = 0

    for _, event in ipairs(recentEvents) do
        if event.type == "DAMAGE" and event.amount then
            -- If petOnly is true, only count pet damage; otherwise count all damage
            if not petOnly or event.isPetDamage then
                totalDamage = totalDamage + event.amount
            end
        end
    end

    local actualWindow = math.min(windowSeconds, GetTime() - meterState.combatStartTime)
    if actualWindow <= 0 then
        return 0
    end

    return totalDamage / actualWindow
end

-- =============================================================================
-- COMBAT STATE MANAGEMENT
-- =============================================================================

-- Handle combat state changes
function MyDPSMeterWindow:UpdateCombatState(stateData)
    addon:Debug("MyDPSMeterWindow:UpdateCombatState - inCombat: %s, meterState.inCombat: %s",
        tostring(stateData.inCombat), tostring(meterState.inCombat))

    if stateData.inCombat and not meterState.inCombat then
        -- Combat started
        addon:Debug("MyDPSMeterWindow: Starting combat")
        self:StartCombat()
    elseif not stateData.inCombat and meterState.inCombat then
        -- Combat ended
        addon:Debug("MyDPSMeterWindow: Ending combat")
        self:EndCombat()
    end
end

-- Start combat tracking
function MyDPSMeterWindow:StartCombat()
    meterState.inCombat = true
    meterState.combatStartTime = GetTime()
    meterState.totalDamage = 0
    meterState.petDamage = 0
    meterState.currentDPS = 0
    meterState.currentPetDPS = 0
    meterState.peakDPS = 0


    -- Clear ring buffer for new combat
    eventRingBuffer.size = 0
    eventRingBuffer.writeIndex = 1

    -- Reset performance state
    performanceState.recentEventTimes = {}
    performanceState.isBusyPeriod = false
    performanceState.throttleMode = "combat"

    if meterWindow and meterWindow:IsVisible() then
        self:UpdateMeterDisplay()
    end

    addon:Debug("Combat meter: Combat started")
end

-- End combat tracking
function MyDPSMeterWindow:EndCombat()
    meterState.inCombat = false


    -- Clean up refresh timer
    if meterState.refreshTimer then
        meterState.refreshTimer:Cancel()
        meterState.refreshTimer = nil
    end

    performanceState.pendingCalculation = false
    performanceState.throttleMode = "normal"

    -- Final calculation for end-of-combat display
    if meterState.combatStartTime > 0 then
        local combatDuration = meterState.lastUpdateTime - meterState.combatStartTime
        if combatDuration > 0 then
            local finalDPS = meterState.totalDamage / combatDuration

            meterState.currentDPS = finalDPS

            -- Delegate scaling to MyCombatMeterScaler
            if meterState.useAutoScale and addon.MyCombatMeterScaler then
                addon:Info("DPS meter: Combat ended - Peak: %.0f, Final: %.0f, Duration: %.1fs",
                    meterState.peakDPS, finalDPS, combatDuration)

                -- Let MyCombatMeterScaler handle all scaling logic
                -- Scale updates will come via UI event subscription
                addon.MyCombatMeterScaler:AutoUpdateAfterCombat({
                    duration = combatDuration,
                    peakDPS = meterState.peakDPS,
                    totalDamage = meterState.totalDamage
                })
            end

            -- Always update display after combat
            if meterWindow and meterWindow:IsVisible() then
                self:UpdateMeterDisplay()
            end

            addon:Debug("DPS meter: Combat ended - Final DPS: %.0f", finalDPS)
        end
    end
end

-- =============================================================================
-- SCALE UPDATE SUBSCRIPTION
-- =============================================================================

-- Subscribe to scale updates from the scaler
function MyDPSMeterWindow:SubscribeToScaleUpdates()
    if addon.UIEventQueue then
        addon.UIEventQueue:Subscribe("SCALE_UPDATE", function(message)
            addon:Info("MyDPSMeterWindow: Received SCALE_UPDATE event")
            if message.data then
                local dpsScale = message.data.dpsScale
                local hpsScale = message.data.hpsScale

                addon:Info("MyDPSMeterWindow: Scale event data - DPS: %.0f, HPS: %.0f", dpsScale or 0, hpsScale or 0)

                if dpsScale and dpsScale > 0 then
                    meterState.autoScale = dpsScale

                    if meterState.useAutoScale then
                        local oldScale = meterState.scale
                        meterState.scale = dpsScale
                        addon:Info("MyDPSMeterWindow: Scale updated via event from %.0f to %.0f", oldScale, dpsScale)

                        -- Update display if window is visible
                        if meterWindow and meterWindow:IsVisible() then
                            self:UpdateMeterDisplay()
                            addon:Info("MyDPSMeterWindow: Display updated")
                        else
                            addon:Info("MyDPSMeterWindow: Window not visible, display not updated")
                        end
                    else
                        addon:Info("MyDPSMeterWindow: Auto-scale disabled, ignoring scale update")
                    end
                else
                    addon:Info("MyDPSMeterWindow: Invalid scale value received")
                end
            else
                addon:Info("MyDPSMeterWindow: Scale event missing data")
            end
        end, "DPSMeterWindow")

        addon:Debug("MyDPSMeterWindow: Subscribed to SCALE_UPDATE events")
    else
        addon:Debug("MyDPSMeterWindow: UIEventQueue not available for scale subscription")
    end
end

-- =============================================================================
-- WINDOW CREATION AND MANAGEMENT
-- =============================================================================

function MyDPSMeterWindow:CreateWindow()
    if meterWindow then return end

    addon:Debug("Starting DPS meter window creation...")

    -- Subscribe to scale updates from the scaler
    self:SubscribeToScaleUpdates()

    -- Request initial scale from scaler (delayed to ensure scaler is fully initialized)
    C_Timer.After(0.5, function()
        if addon.MyCombatMeterScaler then
            addon:Info("MyDPSMeterWindow: Requesting initial scale from scaler...")
            addon.MyCombatMeterScaler:RequestCurrentScale()
            addon:Info("MyDPSMeterWindow: Initial scale request completed")
        else
            addon:Warn("MyDPSMeterWindow: MyCombatMeterScaler not available for initial scale request")
        end
    end)

    -- Create custom frame without default WoW template
    meterWindow = CreateFrame("Frame", addonName .. "DPSMeterWindow", UIParent,
        BackdropTemplateMixin and "BackdropTemplate")
    addon:Debug("Base frame created")

    meterWindow:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    meterWindow:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    meterWindow:SetMovable(true)
    meterWindow:EnableMouse(true)
    meterWindow:RegisterForDrag("LeftButton")
    meterWindow:SetScript("OnDragStart", meterWindow.StartMoving)
    meterWindow:SetScript("OnDragStop", meterWindow.StopMovingOrSizing)
    meterWindow:Hide()

    -- Create a solid black background texture
    local bg = meterWindow:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(meterWindow)
    bg:SetColorTexture(0, 0, 0, 0.85) -- Solid black, 85% opacity
    meterWindow.bg = bg

    -- Add subtle border frame
    meterWindow:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    meterWindow:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)

    -- Register with FocusManager
    if addon.FocusManager then
        addon.FocusManager:RegisterWindow(meterWindow, nil, "MEDIUM")
        addon:Debug("Registered with FocusManager")
    end

    -- Create minimal meter display (no control buttons for now)
    self:CreateMeterDisplay()
    -- self:CreateControlButtons() -- Disabled for minimal design

    addon:Debug("Combat meter window created successfully")
    return meterWindow
end

-- Create the meter display area
function MyDPSMeterWindow:CreateMeterDisplay()
    -- Create progress bar at top
    self:CreateProgressBar(meterWindow)

    -- Create info display directly on window (no inner frame needed)
    self:CreateInfoDisplay(meterWindow)

    -- Initial display update to show correct scale
    self:UpdateMeterDisplay()
end

-- Create horizontal progress bar
function MyDPSMeterWindow:CreateProgressBar(parent)
    local barHeight = 8
    local segmentCount = 25
    local barFrame = CreateFrame("Frame", nil, parent)
    barFrame:SetHeight(barHeight)
    barFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -5)
    barFrame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -5, -5)

    -- Store segments for updating
    meterWindow.progressSegments = {}

    local segmentWidth = (WINDOW_WIDTH - 10) / segmentCount
    for i = 1, segmentCount do
        local segment = barFrame:CreateTexture(nil, "ARTWORK")
        segment:SetHeight(barHeight)
        segment:SetWidth(segmentWidth - 2) -- 2px gap between segments
        segment:SetPoint("LEFT", barFrame, "LEFT", (i - 1) * segmentWidth + 1, 0)
        segment:SetTexture("Interface\\Buttons\\WHITE8X8")
        segment:SetVertexColor(0.2, 0.2, 0.2, 1) -- Dark gray when empty

        meterWindow.progressSegments[i] = segment
    end

    meterWindow.progressBar = barFrame
end

-- Create the 20-segment meter display
function MyDPSMeterWindow:CreateMeterSegments(parent)
    meterSegments = {}

    local segmentWidth = (WINDOW_WIDTH - 40) / 2 -- Two columns: DPS and HPS
    local startY = -20

    -- DPS column
    for i = 1, MAX_SEGMENTS do
        local segment = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        segment:SetSize(segmentWidth - 10, SEGMENT_HEIGHT)
        segment:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, startY - (i - 1) * SEGMENT_HEIGHT)
        segment:SetJustifyH("LEFT")
        segment:SetText("")               -- Start empty
        segment:SetTextColor(1, 0.8, 0.8) -- Light red for DPS

        meterSegments[i] = {
            dps = segment,
            level = i / MAX_SEGMENTS -- Normalized level (0-1)
        }
    end

    -- DPS-only meter (no HPS column)
end

-- Create minimal horizontal info display matching prototype
function MyDPSMeterWindow:CreateInfoDisplay(parent)
    -- Create custom font object for main DPS value
    local customFont = CreateFont("MyDPSMeterFont")
    customFont:SetFont("Interface\\AddOns\\myui2\\assets\\SCP-SB.ttf", 28, "OUTLINE")

    -- Main DPS value (large, custom font, left side)
    local dpsLabel = parent:CreateFontString(nil, "OVERLAY")
    dpsLabel:SetFontObject(customFont)
    dpsLabel:SetPoint("LEFT", parent, "LEFT", 10, 5)
    dpsLabel:SetTextColor(1, 1, 1) -- Pure white
    dpsLabel:SetText("0")

    -- "DPS" label (top right corner)
    local dpsText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dpsText:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -10, -15)
    dpsText:SetTextColor(1, 0.4, 0.4) -- Red
    dpsText:SetText("DPS")

    -- Pet DPS line (smaller, below main DPS)
    local petLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    petLabel:SetPoint("LEFT", parent, "LEFT", 10, -15)
    petLabel:SetTextColor(0.9, 0.9, 0.6) -- Light yellow for pet
    petLabel:SetText("0 Pet")

    -- Peak DPS (smaller, right side of main number)
    local peakDPSLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    peakDPSLabel:SetPoint("RIGHT", parent, "RIGHT", -10, 5)
    peakDPSLabel:SetTextColor(0.8, 0.8, 0.8)
    peakDPSLabel:SetText("peak")

    -- Scale info (clickable, bottom left)
    local scaleButton = CreateFrame("Button", nil, parent)
    scaleButton:SetSize(100, 20)
    scaleButton:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 10, 8)

    local scaleLabel = scaleButton:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    scaleLabel:SetAllPoints(scaleButton)
    scaleLabel:SetJustifyH("LEFT")
    scaleLabel:SetTextColor(0.4, 0.8, 0.8) -- Cyan
    -- Initial text will be updated by UpdateMeterDisplay
    scaleLabel:SetText("...")

    -- Toggle between auto/manual on click
    scaleButton:SetScript("OnClick", function()
        self:ToggleAutoScale()
    end)

    -- Hover effect
    scaleButton:SetScript("OnEnter", function()
        scaleLabel:SetTextColor(0.6, 1, 1)
    end)
    scaleButton:SetScript("OnLeave", function()
        scaleLabel:SetTextColor(0.4, 0.8, 0.8)
    end)

    -- Method label (clickable, bottom right)
    local methodButton = CreateFrame("Button", nil, parent)
    methodButton:SetSize(60, 20)
    methodButton:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -10, 8)

    local methodLabel = methodButton:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    methodLabel:SetAllPoints(methodButton)
    methodLabel:SetTextColor(0.7, 0.7, 0.7)
    methodLabel:SetText("Rolling")

    -- Method cycling on click
    methodButton:SetScript("OnClick", function()
        self:CycleMethod()
    end)

    -- Hover effect
    methodButton:SetScript("OnEnter", function()
        methodLabel:SetTextColor(1, 1, 1)
    end)
    methodButton:SetScript("OnLeave", function()
        if meterState.inCombat then
            methodLabel:SetTextColor(1, 0.6, 0.6)
        else
            methodLabel:SetTextColor(0.7, 0.7, 0.7)
        end
    end)

    -- Store references
    meterWindow.dpsLabel = dpsLabel
    meterWindow.dpsText = dpsText
    meterWindow.petLabel = petLabel
    meterWindow.peakDPSLabel = peakDPSLabel
    meterWindow.methodLabel = methodLabel
    meterWindow.methodButton = methodButton
    meterWindow.scaleLabel = scaleLabel
end

-- Create control buttons
function MyDPSMeterWindow:CreateControlButtons()
    local buttonFrame = CreateFrame("Frame", nil, meterWindow)
    buttonFrame:SetSize(WINDOW_WIDTH - 30, 30)
    buttonFrame:SetPoint("BOTTOM", meterWindow, "BOTTOM", 0, 10)

    -- Pause/Resume button
    local pauseButton = CreateFrame("Button", nil, buttonFrame, "GameMenuButtonTemplate")
    pauseButton:SetSize(60, 22)
    pauseButton:SetPoint("LEFT", buttonFrame, "LEFT", 10, 0)
    pauseButton:SetText("Pause")
    pauseButton:SetScript("OnClick", function()
        MyDPSMeterWindow:TogglePause()
    end)

    -- Reset button
    local resetButton = CreateFrame("Button", nil, buttonFrame, "GameMenuButtonTemplate")
    resetButton:SetSize(60, 22)
    resetButton:SetPoint("LEFT", pauseButton, "RIGHT", 5, 0)
    resetButton:SetText("Reset")
    resetButton:SetScript("OnClick", function()
        MyDPSMeterWindow:ResetMeter()
    end)

    -- Method dropdown
    local methodDropdown = CreateFrame("Frame", nil, buttonFrame, "UIDropDownMenuTemplate")
    methodDropdown:SetPoint("RIGHT", buttonFrame, "RIGHT", -10, 0)
    UIDropDownMenu_SetWidth(methodDropdown, 80)
    UIDropDownMenu_SetText(methodDropdown, "Rolling")

    UIDropDownMenu_Initialize(methodDropdown, function(self, level)
        local methods = {
            { id = CALCULATION_METHODS.ROLLING, name = "Rolling" },
            { id = CALCULATION_METHODS.FINAL,   name = "Final" },
            { id = CALCULATION_METHODS.HYBRID,  name = "Hybrid" }
        }

        for _, method in ipairs(methods) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = method.name
            info.value = method.id
            info.func = function()
                MyDPSMeterWindow:SetCalculationMethod(method.id)
                UIDropDownMenu_SetSelectedValue(methodDropdown, method.id)
                UIDropDownMenu_SetText(methodDropdown, method.name)
            end
            info.checked = (currentCalculationMethod == method.id)
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    -- Store references
    meterWindow.pauseButton = pauseButton
    meterWindow.resetButton = resetButton
    meterWindow.methodDropdown = methodDropdown
end

-- =============================================================================
-- VISUAL UPDATE FUNCTIONS
-- =============================================================================

-- Update the meter visual display
function MyDPSMeterWindow:UpdateMeterDisplay()
    if not meterWindow or not meterWindow:IsVisible() then
        return
    end

    -- Update DPS value (hide units when zero)
    if meterState.currentDPS < 1 then
        meterWindow.dpsLabel:SetText("0")
    elseif meterState.currentDPS < 1000 then
        meterWindow.dpsLabel:SetText(string.format("%.0f", meterState.currentDPS))
    elseif meterState.currentDPS < 1000000 then
        meterWindow.dpsLabel:SetText(string.format("%.1fK", meterState.currentDPS / 1000))
    else
        meterWindow.dpsLabel:SetText(string.format("%.1fM", meterState.currentDPS / 1000000))
    end

    -- Update pet DPS
    if meterState.currentPetDPS < 1 then
        meterWindow.petLabel:SetText("0 Pet")
    elseif meterState.currentPetDPS < 1000 then
        meterWindow.petLabel:SetText(string.format("%.0f Pet", meterState.currentPetDPS))
    elseif meterState.currentPetDPS < 1000000 then
        meterWindow.petLabel:SetText(string.format("%.1fK Pet", meterState.currentPetDPS / 1000))
    else
        meterWindow.petLabel:SetText(string.format("%.1fM Pet", meterState.currentPetDPS / 1000000))
    end

    -- Update peak
    if meterState.peakDPS < 1000 then
        meterWindow.peakDPSLabel:SetText(string.format("%.0f peak", meterState.peakDPS))
    elseif meterState.peakDPS < 1000000 then
        meterWindow.peakDPSLabel:SetText(string.format("%.0fK peak", meterState.peakDPS / 1000))
    else
        meterWindow.peakDPSLabel:SetText(string.format("%.1fM peak", meterState.peakDPS / 1000000))
    end

    -- Update scale with auto/manual indicator
    local scaleText = ""
    if meterState.scale < 1000000 then
        scaleText = string.format("%.0fK", meterState.scale / 1000)
    else
        scaleText = string.format("%.1fM", meterState.scale / 1000000)
    end

    if meterState.useAutoScale then
        meterWindow.scaleLabel:SetText(scaleText .. " (auto)")
    else
        meterWindow.scaleLabel:SetText(scaleText .. " (manual)")
    end

    -- Combat indicator: change method text color when in combat
    if meterState.inCombat then
        meterWindow.methodLabel:SetTextColor(1, 0.6, 0.6) -- Reddish when in combat
    else
        meterWindow.methodLabel:SetTextColor(1, 1, 0.6)   -- Yellow when out of combat
    end

    -- Update method display
    local methodNames = {
        [CALCULATION_METHODS.ROLLING] = "Rolling",
        [CALCULATION_METHODS.FINAL] = "Final",
        [CALCULATION_METHODS.HYBRID] = "Hybrid"
    }
    meterWindow.methodLabel:SetText(methodNames[currentCalculationMethod] or "Unknown")

    -- Update progress bar
    self:UpdateProgressBar()
end

-- Update the progress bar
function MyDPSMeterWindow:UpdateProgressBar()
    if not meterWindow.progressSegments then return end

    local fillRatio = 0
    if meterState.scale > 0 then
        fillRatio = math.min(1, meterState.currentDPS / meterState.scale)
    end

    local segmentCount = #meterWindow.progressSegments
    local filledSegments = math.floor(fillRatio * segmentCount)

    for i = 1, segmentCount do
        local segment = meterWindow.progressSegments[i]
        if i <= filledSegments then
            -- Color gradient: green -> yellow -> orange -> red
            local segmentRatio = i / segmentCount
            local r, g, b = 0, 1, 0 -- Start green

            if segmentRatio > 0.75 then
                -- Red zone
                r, g, b = 1, 0.2, 0.2
            elseif segmentRatio > 0.5 then
                -- Orange zone
                r, g, b = 1, 0.6, 0.2
            elseif segmentRatio > 0.25 then
                -- Yellow zone
                r, g, b = 1, 1, 0.2
            end

            segment:SetVertexColor(r, g, b, 1)
        else
            -- Empty segment
            segment:SetVertexColor(0.2, 0.2, 0.2, 1)
        end
    end
end

-- Cycle through calculation methods
function MyDPSMeterWindow:CycleMethod()
    if currentCalculationMethod == CALCULATION_METHODS.ROLLING then
        currentCalculationMethod = CALCULATION_METHODS.FINAL
    elseif currentCalculationMethod == CALCULATION_METHODS.FINAL then
        currentCalculationMethod = CALCULATION_METHODS.HYBRID
    else
        currentCalculationMethod = CALCULATION_METHODS.ROLLING
    end

    -- Recalculate with new method if we have combat data
    if meterState.totalDamage > 0 and meterState.combatStartTime > 0 then
        -- If in combat, trigger immediate recalculation
        if meterState.inCombat then
            self:CalculateAndUpdate()
        else
            -- Out of combat - recalculate based on final totals
            local combatDuration = meterState.lastUpdateTime - meterState.combatStartTime
            if combatDuration > 0 then
                if currentCalculationMethod == CALCULATION_METHODS.FINAL then
                    meterState.currentDPS = meterState.totalDamage / combatDuration
                elseif currentCalculationMethod == CALCULATION_METHODS.ROLLING then
                    -- Use the last calculated rolling value (can't recalculate without events)
                    -- This is already stored in currentDPS from combat
                elseif currentCalculationMethod == CALCULATION_METHODS.HYBRID then
                    -- Hybrid uses 70% rolling + 30% final
                    local finalDPS = meterState.totalDamage / combatDuration
                    -- We can't recalculate rolling out of combat, so approximate
                    meterState.currentDPS = meterState.currentDPS * 0.7 + finalDPS * 0.3
                end
            end
        end
    end

    -- Update display immediately
    if meterWindow and meterWindow:IsVisible() then
        self:UpdateMeterDisplay()
    end

    addon:Debug("DPS meter: Method cycled to %s", currentCalculationMethod)
end

-- =============================================================================
-- PUBLIC INTERFACE
-- =============================================================================

function MyDPSMeterWindow:Show()
    if not meterWindow then
        self:CreateWindow()
        -- Set up message queue subscriptions after window creation
        self:SetupSubscriptions()
    end

    meterWindow:Show()
    isVisible = true

    -- Start listening for combat events (this is now a no-op since we use message queue)
    self:RegisterForCombatEvents()

    -- Update smart scale from combat history when showing the window
    self:UpdateSmartScale()

    -- Initial display update
    self:UpdateMeterDisplay()

    addon:Debug("DPS meter window shown")
end

function MyDPSMeterWindow:Hide()
    if meterWindow then
        meterWindow:Hide()
    end

    isVisible = false

    -- Stop listening for combat events
    self:UnregisterFromCombatEvents()

    -- Clean up any pending timers
    if meterState.refreshTimer then
        meterState.refreshTimer:Cancel()
        meterState.refreshTimer = nil
    end

    addon:Debug("Combat meter window hidden")
end

function MyDPSMeterWindow:Toggle()
    if isVisible then
        self:Hide()
    else
        self:Show()
    end
end

function MyDPSMeterWindow:IsVisible()
    return isVisible and meterWindow and meterWindow:IsVisible()
end

-- =============================================================================
-- CONFIGURATION FUNCTIONS
-- =============================================================================

function MyDPSMeterWindow:SetCalculationMethod(method)
    if CALCULATION_METHODS[method:upper()] then
        currentCalculationMethod = CALCULATION_METHODS[method:upper()]
        addon:Debug("Combat meter: Calculation method set to %s", method)

        if meterWindow and meterWindow:IsVisible() then
            self:UpdateMeterDisplay()
        end

        return true
    end

    return false
end

function MyDPSMeterWindow:GetCalculationMethod()
    return currentCalculationMethod
end

function MyDPSMeterWindow:TogglePause()
    meterState.isPaused = not meterState.isPaused

    if meterWindow and meterWindow.pauseButton then
        meterWindow.pauseButton:SetText(meterState.isPaused and "Resume" or "Pause")
    end

    addon:Debug("Combat meter: %s", meterState.isPaused and "Paused" or "Resumed")
end

function MyDPSMeterWindow:ResetMeter()
    meterState.currentDPS = 0
    meterState.peakDPS = 0
    meterState.totalDamage = 0

    -- Clear ring buffer
    eventRingBuffer.size = 0
    eventRingBuffer.writeIndex = 1

    if meterWindow and meterWindow:IsVisible() then
        self:UpdateMeterDisplay()
    end

    addon:Debug("Combat meter: Reset")
end

function MyDPSMeterWindow:SetScale(newScale)
    -- Setting manual scale
    meterState.manualScale = math.max(100, newScale) -- Minimum scale of 100
    meterState.useAutoScale = false                  -- Switch to manual mode
    meterState.scale = meterState.manualScale

    if meterWindow and meterWindow:IsVisible() then
        self:UpdateMeterDisplay()
    end

    addon:Debug("DPS meter: Manual scale set to %.0f", meterState.scale)
end

-- Toggle between auto and manual scale
function MyDPSMeterWindow:ToggleAutoScale()
    meterState.useAutoScale = not meterState.useAutoScale

    if meterState.useAutoScale then
        meterState.scale = meterState.autoScale
        addon:Debug("DPS meter: Switched to auto scale (%.0f)", meterState.scale)
    else
        meterState.scale = meterState.manualScale
        addon:Debug("DPS meter: Switched to manual scale (%.0f)", meterState.scale)
    end

    if meterWindow and meterWindow:IsVisible() then
        self:UpdateMeterDisplay()
    end
end

function MyDPSMeterWindow:GetScale()
    return meterState.scale
end

-- Sync scale from MyCombatMeterScaler
function MyDPSMeterWindow:UpdateSmartScale()
    if not addon.MyCombatMeterScaler then
        addon:Warn("DPS meter: MyCombatMeterScaler not available for scale sync")
        return
    end

    -- Get current scale from the scaler (it handles all the analysis)
    local dpsScale, _ = addon.MyCombatMeterScaler:GetCurrentScales()

    if dpsScale and dpsScale > 0 then
        local oldScale = meterState.autoScale
        meterState.autoScale = dpsScale

        if meterState.useAutoScale then
            meterState.scale = dpsScale
        end

        addon:Debug("DPS meter: Scale synced from MyCombatMeterScaler - Old: %.0f, New: %.0f",
            oldScale, dpsScale)

        if meterWindow and meterWindow:IsVisible() then
            self:UpdateMeterDisplay()
        end
    else
        addon:Warn("DPS meter: MyCombatMeterScaler returned invalid scale: %.1f", dpsScale or 0)
    end
end

-- Set auto scaling mode
function MyDPSMeterWindow:SetAutoScale(enabled)
    meterState.useAutoScale = enabled

    if enabled then
        -- Switch to auto scale and sync from MyCombatMeterScaler
        self:UpdateSmartScale()
        addon:Info("DPS meter: Auto-scaling enabled (scale: %.0f)", meterState.autoScale)
    else
        -- Switch to manual scale
        meterState.scale = meterState.manualScale
        addon:Info("DPS meter: Auto-scaling disabled (manual scale: %.0f)", meterState.manualScale)
    end

    if meterWindow and meterWindow:IsVisible() then
        self:UpdateMeterDisplay()
    end
end

-- Set manual scale value
function MyDPSMeterWindow:SetManualScale(scale)
    -- Also set manual override in MyCombatMeterScaler
    if addon.MyCombatMeterScaler then
        addon.MyCombatMeterScaler:SetManualScale(scale, scale) -- Same scale for DPS and HPS
    end

    meterState.manualScale = scale
    meterState.useAutoScale = false
    meterState.scale = scale

    addon:Info("DPS meter: Manual scale set to %.0f (also set in MyCombatMeterScaler)", scale)

    if meterWindow and meterWindow:IsVisible() then
        self:UpdateMeterDisplay()
    end
end

-- =============================================================================
-- EVENT REGISTRATION
-- =============================================================================

function MyDPSMeterWindow:RegisterForCombatEvents()
    -- Event registration handled by SetupSubscriptions() during initialization
end

function MyDPSMeterWindow:UnregisterFromCombatEvents()
    -- Cleanup any pending timers
    if meterState.refreshTimer then
        meterState.refreshTimer:Cancel()
        meterState.refreshTimer = nil
    end
end

-- =============================================================================
-- DEBUG AND MONITORING
-- =============================================================================

function MyDPSMeterWindow:GetMeterStats()
    return {
        -- Current state
        inCombat = meterState.inCombat,
        isPaused = meterState.isPaused,
        currentDPS = meterState.currentDPS,
        currentHPS = meterState.currentHPS,
        peakDPS = meterState.peakDPS,
        peakHPS = meterState.peakHPS,

        -- Configuration
        calculationMethod = currentCalculationMethod,
        scale = meterState.scale,
        segmentCount = MAX_SEGMENTS,

        -- Performance
        throttleMode = performanceState.throttleMode,
        refreshInterval = GetRefreshInterval(),
        bufferSize = eventRingBuffer.size,
        bufferCapacity = eventRingBuffer.capacity,
        pendingCalculation = performanceState.pendingCalculation,

        -- Combat tracking
        combatDuration = meterState.inCombat and (GetTime() - meterState.combatStartTime) or 0,
        totalDamage = meterState.totalDamage,
        totalHealing = meterState.totalHealing,
    }
end

-- Get window position for saving
function MyDPSMeterWindow:GetPosition()
    if not meterWindow then return nil end

    local point, relativeTo, relativePoint, xOfs, yOfs = meterWindow:GetPoint()
    return {
        point = point,
        relativePoint = relativePoint,
        xOffset = xOfs,
        yOffset = yOfs
    }
end

-- Restore window position
function MyDPSMeterWindow:RestorePosition(position)
    if not meterWindow or not position then return end

    meterWindow:ClearAllPoints()
    meterWindow:SetPoint(
        position.point or "CENTER",
        UIParent,
        position.relativePoint or "CENTER",
        position.xOffset or 0,
        position.yOffset or 0
    )
end

return MyDPSMeterWindow
