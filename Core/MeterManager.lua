-- MeterManager.lua
-- Central coordination for multiple meter types
-- Manages meter registration, event routing, and configuration

local addonName, addon = ...

-- =============================================================================
-- METER MANAGER MODULE
-- =============================================================================

addon.MeterManager = {}
local MeterManager = addon.MeterManager

-- Registered meters and accumulators
local registeredMeters = {}
local registeredAccumulators = {}

-- Configuration
local config = {
    autoPositioning = true,
    positionOffset = 50, -- Pixels between meters
    basePosition = { point = "CENTER", x = 100, y = 0 }
}

-- =============================================================================
-- METER REGISTRATION
-- =============================================================================

-- Register a new meter type
function MeterManager:RegisterMeter(meterType, accumulator, window)
    if registeredMeters[meterType] then
        -- Meter type already registered
        return false
    end
    
    registeredMeters[meterType] = {
        type = meterType,
        accumulator = accumulator,
        window = window,
        enabled = true,
        visible = false
    }
    
    registeredAccumulators[meterType] = accumulator
    
    -- Meter type registered
    return true
end

-- Unregister a meter type
function MeterManager:UnregisterMeter(meterType)
    if not registeredMeters[meterType] then
        return false
    end
    
    -- Hide the meter if visible
    self:HideMeter(meterType)
    
    registeredMeters[meterType] = nil
    registeredAccumulators[meterType] = nil
    
    -- Meter type unregistered
    return true
end

-- Get registered meter info
function MeterManager:GetMeterInfo(meterType)
    return registeredMeters[meterType]
end

-- Get all registered meters
function MeterManager:GetAllMeters()
    local meters = {}
    for meterType, meterInfo in pairs(registeredMeters) do
        meters[meterType] = {
            type = meterInfo.type,
            enabled = meterInfo.enabled,
            visible = meterInfo.visible
        }
    end
    return meters
end

-- =============================================================================
-- EVENT ROUTING
-- =============================================================================

-- Route damage events to appropriate accumulators
function MeterManager:RouteDamageEvent(timestamp, sourceGUID, amount, isPlayer, isPet, isCritical,
                                      spellId, sourceName, sourceType)
    -- Create detailed event data
    local extraData = {
        spellId = spellId or 0,
        sourceName = sourceName or "",
        sourceType = sourceType or 0
    }
    
    -- Route to damage-based meters
    if registeredAccumulators.Damage then
        registeredAccumulators.Damage:AddEvent(timestamp, sourceGUID, amount, isPlayer, isPet, isCritical, extraData)
        
        -- Also add to detailed event tracking
        if registeredAccumulators.Damage.AddDetailedEvent then
            registeredAccumulators.Damage:AddDetailedEvent(timestamp, amount, spellId, sourceGUID, 
                                                          sourceName, sourceType, isCritical)
        end
    end
    
    -- Allow other meters to process damage events if needed
    for meterType, accumulator in pairs(registeredAccumulators) do
        if meterType ~= "Damage" and accumulator.OnDamageEvent then
            accumulator:OnDamageEvent(timestamp, sourceGUID, amount, isPlayer, isPet, isCritical, extraData)
            
            -- Also add detailed events to other accumulators if they support it
            if accumulator.AddDetailedEvent then
                accumulator:AddDetailedEvent(timestamp, amount, spellId, sourceGUID, 
                                           sourceName, sourceType, isCritical)
            end
        end
    end
end

-- Route healing events to appropriate accumulators
function MeterManager:RouteHealingEvent(timestamp, sourceGUID, amount, absorbAmount, isPlayer, isPet, isCritical, overhealing)
    -- Route to healing-based meters
    if registeredAccumulators.Healing then
        local extraData = {
            absorbAmount = absorbAmount or 0,
            overhealing = overhealing or 0
        }
        registeredAccumulators.Healing:AddEvent(timestamp, sourceGUID, amount, isPlayer, isPet, isCritical, extraData)
    end
    
    -- Allow other meters to process healing events if needed
    for meterType, accumulator in pairs(registeredAccumulators) do
        if meterType ~= "Healing" and accumulator.OnHealingEvent then
            accumulator:OnHealingEvent(timestamp, sourceGUID, amount, absorbAmount, isPlayer, isPet, isCritical, overhealing)
        end
    end
end


-- Route damage taken events to appropriate accumulators (future)
function MeterManager:RouteDamageTakenEvent(timestamp, sourceGUID, amount, isPlayer, isPet, isCritical)
    -- Route to damage taken meters when implemented
    if registeredAccumulators.DamageTaken then
        registeredAccumulators.DamageTaken:AddEvent(timestamp, sourceGUID, amount, isPlayer, isPet, isCritical)
    end
end

-- =============================================================================
-- METER CONTROL
-- =============================================================================

-- Show a specific meter
function MeterManager:ShowMeter(meterType)
    local meterInfo = registeredMeters[meterType]
    if not meterInfo then
        -- Unknown meter type
        return false
    end
    
    if not meterInfo.enabled then
        -- Meter type is disabled
        return false
    end
    
    if meterInfo.visible then
        -- Meter is already visible
        return true
    end
    
    -- Position the meter if auto-positioning is enabled
    if config.autoPositioning then
        self:PositionMeter(meterType)
    end
    
    -- Show the meter window
    if meterInfo.window and meterInfo.window.Show then
        meterInfo.window:Show()
        meterInfo.visible = true
        -- Meter shown
        return true
    end
    
    -- Failed to show meter - no window available
    return false
end

-- Hide a specific meter
function MeterManager:HideMeter(meterType)
    local meterInfo = registeredMeters[meterType]
    if not meterInfo then
        -- Unknown meter type
        return false
    end
    
    if not meterInfo.visible then
        -- Meter is already hidden
        return true
    end
    
    -- Hide the meter window
    if meterInfo.window and meterInfo.window.Hide then
        meterInfo.window:Hide()
        meterInfo.visible = false
        -- Meter hidden
        return true
    end
    
    return false
end

-- Toggle a specific meter
function MeterManager:ToggleMeter(meterType)
    local meterInfo = registeredMeters[meterType]
    if not meterInfo then
        -- Unknown meter type
        return false
    end
    
    if meterInfo.visible then
        return self:HideMeter(meterType)
    else
        return self:ShowMeter(meterType)
    end
end

-- Show all enabled meters
function MeterManager:ShowAllMeters()
    local shown = 0
    for meterType, meterInfo in pairs(registeredMeters) do
        if meterInfo.enabled and self:ShowMeter(meterType) then
            shown = shown + 1
        end
    end
    -- Showed meters
    return shown
end

-- Hide all meters
function MeterManager:HideAllMeters()
    local hidden = 0
    for meterType, meterInfo in pairs(registeredMeters) do
        if meterInfo.visible and self:HideMeter(meterType) then
            hidden = hidden + 1
        end
    end
    -- Hid meters
    return hidden
end

-- =============================================================================
-- METER POSITIONING
-- =============================================================================

-- Position a meter based on auto-positioning rules
function MeterManager:PositionMeter(meterType)
    local meterInfo = registeredMeters[meterType]
    if not meterInfo or not meterInfo.window then
        return
    end
    
    -- Count visible meters to determine position
    local visibleCount = 0
    for _, info in pairs(registeredMeters) do
        if info.visible then
            visibleCount = visibleCount + 1
        end
    end
    
    -- Calculate position based on meter order and count
    local xOffset = config.basePosition.x + (visibleCount * config.positionOffset)
    local yOffset = config.basePosition.y
    
    -- Set position if the window supports it
    if meterInfo.window.state and meterInfo.window.state.mainFrame then
        meterInfo.window.state.mainFrame:ClearAllPoints()
        meterInfo.window.state.mainFrame:SetPoint(
            config.basePosition.point,
            UIParent,
            config.basePosition.point,
            xOffset,
            yOffset
        )
    end
end

-- Set auto-positioning configuration
function MeterManager:SetAutoPositioning(enabled, offset, basePos)
    config.autoPositioning = enabled
    if offset then
        config.positionOffset = offset
    end
    if basePos then
        config.basePosition = basePos
    end
    
    -- Auto-positioning configuration updated
end

-- =============================================================================
-- METER CONFIGURATION
-- =============================================================================

-- Enable/disable a meter type
function MeterManager:SetMeterEnabled(meterType, enabled)
    local meterInfo = registeredMeters[meterType]
    if not meterInfo then
        -- Unknown meter type
        return false
    end
    
    meterInfo.enabled = enabled
    
    -- Hide if being disabled
    if not enabled and meterInfo.visible then
        self:HideMeter(meterType)
    end
    
    -- Meter enabled/disabled
    return true
end

-- Check if a meter is enabled
function MeterManager:IsMeterEnabled(meterType)
    local meterInfo = registeredMeters[meterType]
    return meterInfo and meterInfo.enabled or false
end

-- Check if a meter is visible
function MeterManager:IsMeterVisible(meterType)
    local meterInfo = registeredMeters[meterType]
    return meterInfo and meterInfo.visible or false
end

-- =============================================================================
-- RESET AND MAINTENANCE
-- =============================================================================

-- Reset all meter data
function MeterManager:ResetAllMeters()
    local resetCount = 0
    for meterType, accumulator in pairs(registeredAccumulators) do
        if accumulator.Reset then
            accumulator:Reset()
            resetCount = resetCount + 1
        end
    end
    
    -- Meters reset
    return resetCount
end

-- Perform maintenance on all meters
function MeterManager:PerformMaintenance()
    local maintenanceCount = 0
    for meterType, accumulator in pairs(registeredAccumulators) do
        if accumulator.Maintenance then
            accumulator:Maintenance()
            maintenanceCount = maintenanceCount + 1
        end
    end
    
    return maintenanceCount
end

-- =============================================================================
-- DEBUGGING AND STATUS
-- =============================================================================

-- Get status of all meters
function MeterManager:GetStatus()
    local status = {
        registeredCount = 0,
        enabledCount = 0,
        visibleCount = 0,
        meters = {}
    }
    
    for meterType, meterInfo in pairs(registeredMeters) do
        status.registeredCount = status.registeredCount + 1
        
        if meterInfo.enabled then
            status.enabledCount = status.enabledCount + 1
        end
        
        if meterInfo.visible then
            status.visibleCount = status.visibleCount + 1
        end
        
        status.meters[meterType] = {
            enabled = meterInfo.enabled,
            visible = meterInfo.visible,
            hasAccumulator = meterInfo.accumulator ~= nil,
            hasWindow = meterInfo.window ~= nil
        }
    end
    
    return status
end

-- Debug information
function MeterManager:Debug()
    local status = self:GetStatus()
    
    print("=== MeterManager Debug ===")
    print(string.format("Registered: %d, Enabled: %d, Visible: %d", 
          status.registeredCount, status.enabledCount, status.visibleCount))
    
    for meterType, meterStatus in pairs(status.meters) do
        print(string.format("  %s: %s%s%s%s", 
              meterType,
              meterStatus.enabled and "enabled" or "disabled",
              meterStatus.visible and ", visible" or ", hidden",
              meterStatus.hasAccumulator and ", accumulator" or ", no accumulator",
              meterStatus.hasWindow and ", window" or ", no window"))
    end
    
    print(string.format("Auto-positioning: %s (offset: %d)", 
          config.autoPositioning and "enabled" or "disabled",
          config.positionOffset))
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the meter manager
function MeterManager:Initialize()
    -- Set up periodic maintenance
    local maintenanceTimer = C_Timer.NewTicker(60, function()
        self:PerformMaintenance()
    end)
    
    self.maintenanceTimer = maintenanceTimer
    
    -- MeterManager initialized
end

-- Module ready
MeterManager.isReady = true

return MeterManager