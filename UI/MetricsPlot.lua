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
        maxDPSValue = PLOT_CONFIG.minScale,
        maxHPSValue = PLOT_CONFIG.minScale,
        
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

-- Sample accumulator data over time window using the same method as MeterAccumulator
function MetricsPlot:SampleAccumulatorData(rollingData, startTime, endTime, windowSize)
    if not rollingData then
        return {}
    end
    
    local points = {}
    local currentTime = startTime
    
    while currentTime <= endTime do
        -- Use the same calculation method as MeterAccumulator:GetWindowTotals
        local cutoffTime = currentTime - windowSize
        local sum = 0
        local pointCount = 0
        
        -- Sum values in window using the same logic as the accumulator
        for timestamp, value in pairs(rollingData) do
            if type(timestamp) == "number" and timestamp >= cutoffTime then
                sum = sum + value
                pointCount = pointCount + 1
            end
        end
        
        -- Calculate rate (per second) - same as accumulator's metricPS calculation
        local rate = windowSize > 0 and (sum / windowSize) or 0
        
        -- Debug: Log sampling details for first few points (disabled to reduce spam)
        -- if #points < 5 and pointCount > 0 then
        --     print(string.format("Sample at %.1f: window [%.1f-%.1f], %d points, sum=%.0f, rate=%.0f", 
        --           currentTime, cutoffTime, currentTime, pointCount, sum, rate))
        -- end
        
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
        
        -- Debug: Check if we have DPS data (disabled to reduce spam)
        -- if #self.dpsPoints > 0 then
        --     local maxDPS = 0
        --     for _, point in ipairs(self.dpsPoints) do
        --         maxDPS = math.max(maxDPS, point.value)
        --     end
        --     print(string.format("DPS Points: %d, Max: %.0f", #self.dpsPoints, maxDPS))
        -- end
    else
        self.dpsPoints = {}
    end
    
    -- Sample HPS data
    if addon.HealingAccumulator and addon.HealingAccumulator.rollingData then
        self.hpsPoints = self:SampleAccumulatorData(
            addon.HealingAccumulator.rollingData.values,
            startTime, now, 5  -- 5-second rolling window for HPS
        )
        
        -- Debug: Check if we have HPS data (disabled to reduce spam)
        -- if #self.hpsPoints > 0 then
        --     local maxHPS = 0
        --     for _, point in ipairs(self.hpsPoints) do
        --         maxHPS = math.max(maxHPS, point.value)
        --     end
        --     print(string.format("HPS Points: %d, Max: %.0f", #self.hpsPoints, maxHPS))
        -- end
    else
        self.hpsPoints = {}
    end
    
    -- Update auto-scaling
    if self.config.autoScale then
        self:UpdateScale()
    end
end

-- Update Y-axis scaling based on current data - separate scales for DPS and HPS
function MetricsPlot:UpdateScale()
    -- Calculate DPS scale
    local maxDPS = self.config.minScale
    for _, point in ipairs(self.dpsPoints) do
        maxDPS = math.max(maxDPS, point.value)
    end
    maxDPS = maxDPS * (1 + self.config.scaleMargin)
    self.maxDPSValue = self:RoundToNiceScale(maxDPS)
    
    -- Calculate HPS scale
    local maxHPS = self.config.minScale
    for _, point in ipairs(self.hpsPoints) do
        maxHPS = math.max(maxHPS, point.value)
    end
    maxHPS = maxHPS * (1 + self.config.scaleMargin)
    self.maxHPSValue = self:RoundToNiceScale(maxHPS)
end

-- Round to nice scale values
function MetricsPlot:RoundToNiceScale(value)
    if value > 100000 then
        return math.ceil(value / 10000) * 10000
    elseif value > 10000 then
        return math.ceil(value / 1000) * 1000
    else
        return math.ceil(value / 100) * 100
    end
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
function MetricsPlot:DataToScreen(time, value, maxValue)
    local plotWidth = self.config.width - 80  -- Leave space for Y-axis labels on both sides
    local plotHeight = self.config.height - 40  -- Leave space for X-axis labels
    
    -- Time to X coordinate (right to left scrolling)
    local now = addon.TimingManager:GetCurrentRelativeTime()
    local timeRange = self.config.timeWindow
    local normalizedTime = (time - (now - timeRange)) / timeRange
    local x = 60 + (normalizedTime * plotWidth)  -- 60px left margin for HPS labels
    
    -- Value to Y coordinate using the provided max value
    local normalizedValue = maxValue > 0 and (value / maxValue) or 0
    local y = 30 + (normalizedValue * plotHeight)  -- 30px bottom margin
    
    return x, y
end

-- Draw grid lines and dual-axis labels
function MetricsPlot:DrawGrid()
    local plotWidth = self.config.width - 80  -- Space for labels on both sides
    local plotHeight = self.config.height - 40
    
    -- Horizontal grid lines
    for i = 0, self.config.gridLines do
        local y = 30 + (i / self.config.gridLines) * plotHeight
        
        -- Grid line
        local texture = self:GetTexture()
        texture:SetTexture(self.config.gridColor[1], self.config.gridColor[2], self.config.gridColor[3], self.config.gridColor[4])
        texture:SetPoint("BOTTOMLEFT", self.plotFrame, "BOTTOMLEFT", 60, y)  -- 60px left margin
        texture:SetSize(plotWidth, 1)
        texture:Show()
    end
    
    -- HPS Y-axis labels (left side, green)
    if not self.hpsLabels then
        self.hpsLabels = {}
    end
    
    for i = 0, self.config.gridLines do
        local y = 30 + (i / self.config.gridLines) * plotHeight
        
        if not self.hpsLabels[i] then
            self.hpsLabels[i] = self.plotFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        end
        
        local labelValue = (i / self.config.gridLines) * self.maxHPSValue
        local labelText = self:FormatNumber(labelValue)
        self.hpsLabels[i]:SetText(labelText)
        self.hpsLabels[i]:SetPoint("RIGHT", self.plotFrame, "BOTTOMLEFT", 55, y)  -- Left side
        self.hpsLabels[i]:SetTextColor(self.config.hpsColor[1], self.config.hpsColor[2], self.config.hpsColor[3], 1)  -- Green
    end
    
    -- DPS Y-axis labels (right side, red)
    if not self.dpsLabels then
        self.dpsLabels = {}
    end
    
    for i = 0, self.config.gridLines do
        local y = 30 + (i / self.config.gridLines) * plotHeight
        
        if not self.dpsLabels[i] then
            self.dpsLabels[i] = self.plotFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        end
        
        local labelValue = (i / self.config.gridLines) * self.maxDPSValue
        local labelText = self:FormatNumber(labelValue)
        self.dpsLabels[i]:SetText(labelText)
        self.dpsLabels[i]:SetPoint("LEFT", self.plotFrame, "BOTTOMLEFT", 60 + plotWidth + 5, y)  -- Right side
        self.dpsLabels[i]:SetTextColor(self.config.dpsColor[1], self.config.dpsColor[2], self.config.dpsColor[3], 1)  -- Red
    end
    
    -- Vertical grid lines (time marks)
    for i = 0, self.config.timeMarks do
        local x = 60 + (i / self.config.timeMarks) * plotWidth
        local texture = self:GetTexture()
        texture:SetTexture(self.config.gridColor[1], self.config.gridColor[2], self.config.gridColor[3], self.config.gridColor[4])
        texture:SetPoint("BOTTOMLEFT", self.plotFrame, "BOTTOMLEFT", x, 30)
        texture:SetSize(1, plotHeight)
        texture:Show()
        
        -- Time axis label
        if not self.timeLabels then
            self.timeLabels = {}
        end
        
        if not self.timeLabels[i] then
            self.timeLabels[i] = self.plotFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        end
        
        local timeOffset = -(self.config.timeWindow * (self.config.timeMarks - i) / self.config.timeMarks)
        local labelText = string.format("%ds", timeOffset)
        self.timeLabels[i]:SetText(labelText)
        self.timeLabels[i]:SetPoint("TOP", self.plotFrame, "BOTTOMLEFT", x, 25)
        self.timeLabels[i]:SetTextColor(0.8, 0.8, 0.8, 1)
    end
end

-- Format numbers for display
function MetricsPlot:FormatNumber(num)
    if num >= 1000000 then
        return string.format("%.1fM", num / 1000000)
    elseif num >= 1000 then
        return string.format("%.0fK", num / 1000)
    else
        return string.format("%.0f", num)
    end
end

-- Draw plot line from data points using simple point-to-point lines
function MetricsPlot:DrawLine(points, color, maxValue)
    if #points < 2 then
        return
    end
    
    for i = 1, #points - 1 do
        local point1 = points[i]
        local point2 = points[i + 1]
        
        local x1, y1 = self:DataToScreen(point1.time, point1.value, maxValue)
        local x2, y2 = self:DataToScreen(point2.time, point2.value, maxValue)
        
        -- Draw simple horizontal/vertical line segments instead of angled lines
        -- This is more reliable than texture rotation
        
        -- Draw horizontal segment
        if x2 > x1 then
            local texture = self:GetTexture()
            texture:SetTexture(color[1], color[2], color[3], color[4])
            texture:SetPoint("BOTTOMLEFT", self.plotFrame, "BOTTOMLEFT", x1, y1)
            texture:SetSize(x2 - x1, 2)  -- Horizontal line
            texture:Show()
        end
        
        -- Draw vertical segment if there's a height difference
        if math.abs(y2 - y1) > 2 then
            local minY = math.min(y1, y2)
            local maxY = math.max(y1, y2)
            local texture = self:GetTexture()
            texture:SetTexture(color[1], color[2], color[3], color[4])
            texture:SetPoint("BOTTOMLEFT", self.plotFrame, "BOTTOMLEFT", x2, minY)
            texture:SetSize(2, maxY - minY)  -- Vertical line
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
    
    -- Draw DPS line (red, using DPS scale)
    if #self.dpsPoints > 1 then
        self:DrawLine(self.dpsPoints, self.config.dpsColor, self.maxDPSValue)
        -- Debug: Add a marker to show DPS line is being drawn
        local lastPoint = self.dpsPoints[#self.dpsPoints]
        local x, y = self:DataToScreen(lastPoint.time, lastPoint.value, self.maxDPSValue)
        local marker = self:GetTexture()
        marker:SetTexture(1, 1, 1, 1)  -- White marker
        marker:SetPoint("BOTTOMLEFT", self.plotFrame, "BOTTOMLEFT", x-2, y-2)
        marker:SetSize(5, 5)
        marker:Show()
    elseif #self.dpsPoints == 1 then
        -- Draw single point as a dot
        local point = self.dpsPoints[1]
        local x, y = self:DataToScreen(point.time, point.value, self.maxDPSValue)
        local texture = self:GetTexture()
        texture:SetTexture(self.config.dpsColor[1], self.config.dpsColor[2], self.config.dpsColor[3], self.config.dpsColor[4])
        texture:SetPoint("BOTTOMLEFT", self.plotFrame, "BOTTOMLEFT", x-1, y-1)
        texture:SetSize(5, 5)  -- Larger dot for visibility
        texture:Show()
    end
    
    -- Draw HPS line (green, using HPS scale)
    if #self.hpsPoints > 1 then
        self:DrawLine(self.hpsPoints, self.config.hpsColor, self.maxHPSValue)
    elseif #self.hpsPoints == 1 then
        -- Draw single point as a dot
        local point = self.hpsPoints[1]
        local x, y = self:DataToScreen(point.time, point.value, self.maxHPSValue)
        local texture = self:GetTexture()
        texture:SetTexture(self.config.hpsColor[1], self.config.hpsColor[2], self.config.hpsColor[3], self.config.hpsColor[4])
        texture:SetPoint("BOTTOMLEFT", self.plotFrame, "BOTTOMLEFT", x-1, y-1)
        texture:SetSize(5, 5)  -- Larger dot for visibility
        texture:Show()
    end
end

-- Debug method to print current state
function MetricsPlot:Debug()
    print("=== MetricsPlot Debug ===")
    print(string.format("Visible: %s, Paused: %s", tostring(self.isVisible), tostring(self.isPaused)))
    print(string.format("Max DPS Value: %.0f, Max HPS Value: %.0f", self.maxDPSValue, self.maxHPSValue))
    print(string.format("DPS Points: %d, HPS Points: %d", #self.dpsPoints, #self.hpsPoints))
    
    if addon.TimingManager then
        local now = addon.TimingManager:GetCurrentRelativeTime()
        print(string.format("Current Time: %.1f", now))
    end
    
    -- Check DPS data in detail
    if addon.DamageAccumulator then
        print("DamageAccumulator found:")
        if addon.DamageAccumulator.rollingData then
            local count = 0
            local totalDamage = 0
            for timestamp, value in pairs(addon.DamageAccumulator.rollingData.values) do
                count = count + 1
                totalDamage = totalDamage + value
            end
            print(string.format("  DPS Rolling Data Points: %d, Total Damage: %.0f", count, totalDamage))
            
            -- Show current DPS calculation
            local currentDPS = addon.DamageAccumulator:GetCurrentDPS()
            print(string.format("  Current DPS: %.0f", currentDPS))
        else
            print("  No rollingData found")
        end
    else
        print("DamageAccumulator not found")
    end
    
    -- Check HPS data in detail  
    if addon.HealingAccumulator then
        print("HealingAccumulator found:")
        if addon.HealingAccumulator.rollingData then
            local count = 0
            local totalHealing = 0
            for timestamp, value in pairs(addon.HealingAccumulator.rollingData.values) do
                count = count + 1
                totalHealing = totalHealing + value
            end
            print(string.format("  HPS Rolling Data Points: %d, Total Healing: %.0f", count, totalHealing))
            
            -- Show current HPS calculation if available
            if addon.HealingAccumulator.GetCurrentHPS then
                local currentHPS = addon.HealingAccumulator:GetCurrentHPS()
                print(string.format("  Current HPS: %.0f", currentHPS))
            end
        else
            print("  No rollingData found")
        end
    else
        print("HealingAccumulator not found")
    end
    
    -- Print sample of DPS points for debugging
    if #self.dpsPoints > 0 then
        print("Sample DPS Points:")
        for i = 1, math.min(5, #self.dpsPoints) do
            local point = self.dpsPoints[i]
            print(string.format("  Time: %.1f, Value: %.0f", point.time, point.value))
        end
    end
    
    -- Print sample of HPS points for debugging
    if #self.hpsPoints > 0 then
        print("Sample HPS Points:")
        for i = 1, math.min(5, #self.hpsPoints) do
            local point = self.hpsPoints[i]
            print(string.format("  Time: %.1f, Value: %.0f", point.time, point.value))
        end
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