-- MetricsPlot.lua
-- Real-time scrolling plot for DPS/HPS metrics
-- Queries existing accumulator data for visualization

local addonName, addon = ...

-- =============================================================================
-- METRICS PLOT MODULE
-- =============================================================================

addon.MetricsPlot = {}
local MetricsPlot = addon.MetricsPlot

-- Plot configuration
local PLOT_CONFIG = {
    -- Window dimensions
    width = 400,
    height = 250,
    
    -- Colors
    backgroundColor = {0.1, 0.1, 0.1, 0.9},
    gridColor = {0.3, 0.3, 0.3, 0.5},
    dpsColor = {1, 0.2, 0.2, 1},    -- Red for DPS
    hpsColor = {0.2, 1, 0.2, 1},    -- Green for HPS
    
    -- Performance settings
    updateRate = 0.25,      -- 4 FPS update rate
    sampleRate = 1,         -- Sample every 1 second
    maxTextures = 200,      -- Texture pool size
    
    -- Plot settings
    timeWindow = 60,        -- Show last 60 seconds
    gridLines = 5,          -- Number of horizontal grid lines
    timeMarks = 6,          -- Number of time axis marks
    
    -- Auto-scaling
    autoScale = true,
    minScale = 1000,        -- Minimum Y-axis scale
    scaleMargin = 0.1       -- 10% margin above max value
}

-- =============================================================================
-- METRICS PLOT CLASS
-- =============================================================================

function MetricsPlot:New()
    local instance = {
        -- Configuration
        config = PLOT_CONFIG,
        
        -- State
        isVisible = false,
        isPaused = false,
        
        -- Data
        dpsPoints = {},
        hpsPoints = {},
        maxValue = PLOT_CONFIG.minScale,
        
        -- UI components
        frame = nil,
        plotFrame = nil,
        
        -- Texture management
        texturePool = {},
        usedTextures = {},
        
        -- Timing
        lastUpdate = 0,
        updateTimer = nil
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
-- DATA SAMPLING
-- =============================================================================

-- Sample accumulator data over time window
function MetricsPlot:SampleAccumulatorData(rollingData, startTime, endTime, windowSize)
    if not rollingData then
        return {}
    end
    
    local points = {}
    local currentTime = startTime
    
    while currentTime <= endTime do
        local windowStart = currentTime - windowSize
        local windowEnd = currentTime
        local sum = 0
        
        -- Sum values in this sample's window
        for timestamp, value in pairs(rollingData) do
            if type(timestamp) == "number" and timestamp >= windowStart and timestamp <= windowEnd then
                sum = sum + value
            end
        end
        
        -- Calculate rate (per second)
        local rate = windowSize > 0 and (sum / windowSize) or 0
        
        table.insert(points, {
            time = currentTime,
            value = rate
        })
        
        currentTime = currentTime + self.config.sampleRate
    end
    
    return points
end

-- Update plot data by sampling accumulators
function MetricsPlot:UpdateData()
    if not addon.TimingManager then
        return
    end
    
    local now = addon.TimingManager:GetCurrentRelativeTime()
    local startTime = now - self.config.timeWindow
    
    -- Sample DPS data
    if addon.DamageAccumulator and addon.DamageAccumulator.rollingData then
        self.dpsPoints = self:SampleAccumulatorData(
            addon.DamageAccumulator.rollingData.values,
            startTime, now, 5  -- 5-second rolling window for DPS
        )
    end
    
    -- Sample HPS data
    if addon.HealingAccumulator and addon.HealingAccumulator.rollingData then
        self.hpsPoints = self:SampleAccumulatorData(
            addon.HealingAccumulator.rollingData.values,
            startTime, now, 5  -- 5-second rolling window for HPS
        )
    end
    
    -- Update auto-scaling
    if self.config.autoScale then
        self:UpdateScale()
    end
end

-- Update Y-axis scaling based on current data
function MetricsPlot:UpdateScale()
    local maxValue = self.config.minScale
    
    -- Find maximum value in current data
    for _, point in ipairs(self.dpsPoints) do
        maxValue = math.max(maxValue, point.value)
    end
    
    for _, point in ipairs(self.hpsPoints) do
        maxValue = math.max(maxValue, point.value)
    end
    
    -- Add margin and round up to nice numbers
    maxValue = maxValue * (1 + self.config.scaleMargin)
    
    -- Round to nice scale values
    if maxValue > 100000 then
        maxValue = math.ceil(maxValue / 10000) * 10000
    elseif maxValue > 10000 then
        maxValue = math.ceil(maxValue / 1000) * 1000
    else
        maxValue = math.ceil(maxValue / 100) * 100
    end
    
    self.maxValue = maxValue
end

-- =============================================================================
-- TEXTURE MANAGEMENT
-- =============================================================================

-- Get texture from pool or create new one
function MetricsPlot:GetTexture()
    local texture = table.remove(self.texturePool)
    if not texture then
        texture = self.plotFrame:CreateTexture(nil, "ARTWORK")
    end
    
    table.insert(self.usedTextures, texture)
    return texture
end

-- Return all used textures to pool
function MetricsPlot:ReturnTextures()
    for _, texture in ipairs(self.usedTextures) do
        texture:Hide()
        table.insert(self.texturePool, texture)
    end
    self.usedTextures = {}
end

-- =============================================================================
-- RENDERING
-- =============================================================================

-- Convert data coordinates to screen coordinates
function MetricsPlot:DataToScreen(time, value)
    local plotWidth = self.config.width - 60  -- Leave space for Y-axis labels
    local plotHeight = self.config.height - 40  -- Leave space for X-axis labels
    
    -- Time to X coordinate (right to left scrolling)
    local now = addon.TimingManager:GetCurrentRelativeTime()
    local timeRange = self.config.timeWindow
    local normalizedTime = (time - (now - timeRange)) / timeRange
    local x = 50 + (normalizedTime * plotWidth)  -- 50px left margin
    
    -- Value to Y coordinate
    local normalizedValue = value / self.maxValue
    local y = 30 + (normalizedValue * plotHeight)  -- 30px bottom margin
    
    return x, y
end

-- Draw grid lines
function MetricsPlot:DrawGrid()
    local plotWidth = self.config.width - 60
    local plotHeight = self.config.height - 40
    
    -- Horizontal grid lines
    for i = 0, self.config.gridLines do
        local y = 30 + (i / self.config.gridLines) * plotHeight
        local texture = self:GetTexture()
        texture:SetTexture(self.config.gridColor[1], self.config.gridColor[2], self.config.gridColor[3], self.config.gridColor[4])
        texture:SetPoint("TOPLEFT", self.plotFrame, "BOTTOMLEFT", 50, y)
        texture:SetSize(plotWidth, 1)
        texture:Show()
    end
    
    -- Vertical grid lines (time marks)
    for i = 0, self.config.timeMarks do
        local x = 50 + (i / self.config.timeMarks) * plotWidth
        local texture = self:GetTexture()
        texture:SetTexture(self.config.gridColor[1], self.config.gridColor[2], self.config.gridColor[3], self.config.gridColor[4])
        texture:SetPoint("TOPLEFT", self.plotFrame, "BOTTOMLEFT", x, 30)
        texture:SetSize(1, plotHeight)
        texture:Show()
    end
end

-- Draw plot line from data points
function MetricsPlot:DrawLine(points, color)
    if #points < 2 then
        return
    end
    
    for i = 1, #points - 1 do
        local point1 = points[i]
        local point2 = points[i + 1]
        
        local x1, y1 = self:DataToScreen(point1.time, point1.value)
        local x2, y2 = self:DataToScreen(point2.time, point2.value)
        
        -- Calculate line segment
        local dx = x2 - x1
        local dy = y2 - y1
        local length = math.sqrt(dx * dx + dy * dy)
        local angle = math.atan2(dy, dx)
        
        if length > 0 then
            local texture = self:GetTexture()
            texture:SetTexture(color[1], color[2], color[3], color[4])
            texture:SetPoint("TOPLEFT", self.plotFrame, "BOTTOMLEFT", x1, y1)
            texture:SetSize(length, 2)  -- 2px line width
            
            -- Rotate texture for angled lines (if supported)
            -- Note: Texture rotation requires additional implementation
            
            texture:Show()
        end
    end
end

-- Main render function
function MetricsPlot:Render()
    if not self.isVisible or self.isPaused then
        return
    end
    
    -- Clear previous textures
    self:ReturnTextures()
    
    -- Draw grid
    self:DrawGrid()
    
    -- Draw DPS line
    if #self.dpsPoints > 1 then
        self:DrawLine(self.dpsPoints, self.config.dpsColor)
    end
    
    -- Draw HPS line
    if #self.hpsPoints > 1 then
        self:DrawLine(self.hpsPoints, self.config.hpsColor)
    end
end

-- =============================================================================
-- UPDATE LOOP
-- =============================================================================

-- Main update function called by timer
function MetricsPlot:OnUpdate()
    local now = GetTime()
    
    -- Throttle updates
    if now - self.lastUpdate < self.config.updateRate then
        return
    end
    
    self.lastUpdate = now
    
    -- Update data and render
    self:UpdateData()
    self:Render()
end

-- Start update timer
function MetricsPlot:StartUpdates()
    if self.updateTimer then
        self.updateTimer:Cancel()
    end
    
    self.updateTimer = C_Timer.NewTicker(self.config.updateRate, function()
        self:OnUpdate()
    end)
end

-- Stop update timer
function MetricsPlot:StopUpdates()
    if self.updateTimer then
        self.updateTimer:Cancel()
        self.updateTimer = nil
    end
end

-- =============================================================================
-- UI MANAGEMENT
-- =============================================================================

-- Create the plot window
function MetricsPlot:CreateWindow()
    if self.frame then
        return
    end
    
    -- Main frame
    self.frame = CreateFrame("Frame", "StormyMetricsPlot", UIParent)
    self.frame:SetSize(self.config.width, self.config.height)
    self.frame:SetPoint("CENTER", UIParent, "CENTER", 200, 0)  -- Offset from center
    
    -- Background
    local bg = self.frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(self.config.backgroundColor[1], self.config.backgroundColor[2], self.config.backgroundColor[3], self.config.backgroundColor[4])
    
    -- Plot area frame
    self.plotFrame = CreateFrame("Frame", nil, self.frame)
    self.plotFrame:SetAllPoints()
    
    -- Make draggable
    self.frame:SetMovable(true)
    self.frame:EnableMouse(true)
    self.frame:RegisterForDrag("LeftButton")
    self.frame:SetScript("OnDragStart", function() self.frame:StartMoving() end)
    self.frame:SetScript("OnDragStop", function() self.frame:StopMovingOrSizing() end)
    
    -- Title
    local title = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", self.frame, "TOP", 0, -5)
    title:SetText("DPS/HPS Plot")
    
    self.frame:Hide()
end

-- Show the plot window
function MetricsPlot:Show()
    if not self.frame then
        self:CreateWindow()
    end
    
    self.frame:Show()
    self.isVisible = true
    self:StartUpdates()
end

-- Hide the plot window
function MetricsPlot:Hide()
    if self.frame then
        self.frame:Hide()
    end
    
    self.isVisible = false
    self:StopUpdates()
end

-- Toggle visibility
function MetricsPlot:Toggle()
    if self.isVisible then
        self:Hide()
    else
        self:Show()
    end
end

-- Check if visible
function MetricsPlot:IsVisible()
    return self.isVisible
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the metrics plot
function MetricsPlot:Initialize()
    -- Create window but don't show it
    self:CreateWindow()
    
    -- MetricsPlot initialized
end

-- Module ready
MetricsPlot.isReady = true

return MetricsPlot