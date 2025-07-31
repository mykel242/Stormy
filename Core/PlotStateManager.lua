-- PlotStateManager.lua
-- Manages synchronized state between DPS and HPS plots

local addonName, addon = ...

-- =============================================================================
-- PLOT STATE MANAGER MODULE
-- =============================================================================

addon.PlotStateManager = {}
local PlotStateManager = addon.PlotStateManager

-- Shared state
local sharedState = {
    isPaused = false,
    pauseTimestamp = nil,
    selectedBar = nil,
    selectedPlotType = nil,  -- Track which plot type the selection came from
    registeredPlots = {}  -- Table of registered plot instances
}

-- Make registered plots accessible for positioning
PlotStateManager.registeredPlots = sharedState.registeredPlots

-- =============================================================================
-- STATE MANAGEMENT
-- =============================================================================

function PlotStateManager:RegisterPlot(plot, plotType)
    sharedState.registeredPlots[plotType] = plot
end

function PlotStateManager:UnregisterPlot(plotType)
    sharedState.registeredPlots[plotType] = nil
end

function PlotStateManager:IsPaused()
    return sharedState.isPaused
end

function PlotStateManager:GetPauseTimestamp()
    return sharedState.pauseTimestamp
end

function PlotStateManager:GetSelectedBar()
    return sharedState.selectedBar
end

function PlotStateManager:GetSelectedPlotType()
    return sharedState.selectedPlotType
end

-- =============================================================================
-- SYNCHRONIZED ACTIONS
-- =============================================================================

function PlotStateManager:PauseAll(timestamp, initiatingPlotType)
    -- Set shared pause state
    sharedState.isPaused = true
    sharedState.pauseTimestamp = addon.TimingManager:GetCurrentRelativeTime()
    sharedState.selectedBar = timestamp
    sharedState.selectedPlotType = initiatingPlotType
    
    -- Pause all registered plots
    for plotType, plot in pairs(sharedState.registeredPlots) do
        if plot and plot.Pause then
            -- Create snapshot for this plot
            plot:CreateSnapshot()
            plot.plotState.isPaused = true
            plot.plotState.selectedBar = timestamp
            
            -- Plot paused
        end
    end
    
    -- All plots paused
end

function PlotStateManager:ResumeAll(initiatingPlotType)
    -- Clear shared pause state
    sharedState.isPaused = false
    sharedState.pauseTimestamp = nil
    sharedState.selectedBar = nil
    sharedState.selectedPlotType = nil
    
    -- Resume all registered plots
    for plotType, plot in pairs(sharedState.registeredPlots) do
        if plot and plot.Resume then
            -- Clear pause state for this plot
            plot.plotState.isPaused = false
            plot.plotState.selectedBar = nil
            plot.plotState.hoveredBar = nil
            
            -- Invalidate snapshot
            if plot.InvalidateSnapshot then
                plot:InvalidateSnapshot()
            end
            
            -- Plot resumed
        end
    end
    
    -- Hide the shared detail window
    local detailWindow = addon.EventDetailWindow:GetInstance()
    if detailWindow and detailWindow:IsVisible() then
        detailWindow:Hide()
    end
    
    -- All plots resumed
end

-- =============================================================================
-- SELECTION MANAGEMENT
-- =============================================================================

function PlotStateManager:ChangeSelection(timestamp, initiatingPlotType)
    -- Update shared selection state
    sharedState.selectedBar = timestamp
    sharedState.selectedPlotType = initiatingPlotType
    
    -- Update selection for all registered plots
    for plotType, plot in pairs(sharedState.registeredPlots) do
        if plot then
            plot.plotState.selectedBar = timestamp
        end
    end
    
    -- Force render on all plots after state is updated (important for paused mode)
    for plotType, plot in pairs(sharedState.registeredPlots) do
        if plot and plot.Render then
            plot:Render()
        end
    end
end

-- =============================================================================
-- DETAIL WINDOW MANAGEMENT
-- =============================================================================

function PlotStateManager:ShowDetailWindow(plotType, timestamp, plotFrame)
    -- Get the shared detail window instance
    local detailWindow = addon.EventDetailWindow:GetInstance()
    
    -- Get the appropriate plot instance
    local plot = sharedState.registeredPlots[plotType]
    if not plot then
        print(string.format("[PlotStateManager] Plot type '%s' not registered", plotType))
        return
    end
    
    -- Get detail data from the plot
    local summary, events = plot:GetSecondDetails(timestamp)
    
    if summary then
        -- Show the detail window with data
        detailWindow:Show(plotType, timestamp, summary, events, plotFrame)
    else
        print(string.format("[PlotStateManager] No detail data found for timestamp %d", timestamp))
    end
end

function PlotStateManager:HideDetailWindow()
    local detailWindow = addon.EventDetailWindow:GetInstance()
    if detailWindow then
        detailWindow:Hide()
    end
end