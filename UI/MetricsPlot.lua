-- MetricsPlot.lua
-- Real-time scrolling plot for DPS/HPS metrics
-- Queries existing accumulator data for visualization

local addonName, addon = ...

-- =============================================================================
-- METRICS PLOT MODULE
-- =============================================================================

addon.MetricsPlot = {}
local MetricsPlot = addon.MetricsPlot

-- Font configuration
local FONT_PATH = "Interface\\AddOns\\Stormy\\assets\\SCP-SB.ttf"
local FONT_SIZE_LABELS = 12

-- Plot configuration
local PLOT_CONFIG = {
    -- Window dimensions
    width = 380,  -- Same width as meters
    height = 90,   -- 50% shorter than before
    
    -- Colors
    backgroundColor = {0, 0, 0, 0.5},
    gridColor = {0.3, 0.3, 0.3, 0.5},
    dpsColor = {1, 0, 0, 1},    -- Pure red for DPS
    hpsColor = {0.2, 1, 0.2, 1},    -- Green for HPS
    
    -- Performance settings
    updateRate = 0.25,      -- 4 FPS update rate
    sampleRate = 1,         -- Sample every 1 second
    maxTextures = 200,      -- Texture pool size
    
    -- Plot settings
    timeWindow = 60,        -- Show last 60 seconds
    gridLines = 3,          -- Number of horizontal grid lines (4 labels including 0)
    timeMarks = 2,          -- Number of time axis marks (3 labels: 0s, -30s, -60s)
    
    -- Auto-scaling
    autoScale = true,
    minScale = 1000,        -- Minimum Y-axis scale
    scaleMargin = 0.1       -- 10% margin above max value
}

-- =============================================================================
-- METRICS PLOT CLASS
-- =============================================================================

function MetricsPlot:New(plotType)
    local instance = {
        -- Configuration
        config = PLOT_CONFIG,
        plotType = plotType or "DPS",  -- "DPS" or "HPS"
        
        -- State
        isVisible = false,
        isPaused = false,
        
        -- Plot interaction state
        plotState = {
            mode = "LIVE",             -- LIVE, PAUSED
            pausedAt = nil,            -- timestamp when paused
            selectedTimestamp = nil,   -- currently selected second
            hoveredTimestamp = nil,    -- currently hovered second
        },
        
        -- Data
        dpsPoints = {},
        hpsPoints = {},
        maxDPS = PLOT_CONFIG.minScale,
        maxHPS = PLOT_CONFIG.minScale,
        
        -- Scale stability
        lastScaleUpdate = 0,
        scaleUpdateInterval = 1.0,  -- Only update scale once per second
        
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
            if type(timestamp) == "number" and timestamp >= cutoffTime and timestamp <= currentTime then
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
    
    -- Sample data based on plot type
    if self.plotType == "DPS" then
        if addon.DamageAccumulator and addon.DamageAccumulator.rollingData then
            self.dpsPoints = addon.DamageAccumulator:GetTimeSeriesData(startTime, now, 1)
        else
            self.dpsPoints = {}
            print("DamageAccumulator not available or no rolling data")
        end
        self.hpsPoints = {}  -- Empty for DPS plot
    else
        -- HPS plot
        if addon.HealingAccumulator and addon.HealingAccumulator.rollingData then
            self.hpsPoints = addon.HealingAccumulator:GetTimeSeriesData(startTime, now, 1)
        else
            self.hpsPoints = {}
            print("HealingAccumulator not available or no rolling data")
        end
        self.dpsPoints = {}  -- Empty for HPS plot
    end
    
    -- Ensure both lines have baseline data for visibility
    self:EnsureBaselineData(startTime, now)
    
    -- Update auto-scaling
    if self.config.autoScale then
        self:UpdateScale()
    end
end

-- Ensure both DPS and HPS have baseline data points for visibility
function MetricsPlot:EnsureBaselineData(startTime, endTime)
    -- If DPS has no data, create baseline zero points
    if #self.dpsPoints == 0 then
        self.dpsPoints = {}
        local currentTime = startTime
        while currentTime <= endTime do
            table.insert(self.dpsPoints, {
                time = currentTime,
                value = 0
            })
            currentTime = currentTime + self.config.sampleRate
        end
    end
    
    -- If HPS has no data, create baseline zero points
    if #self.hpsPoints == 0 then
        self.hpsPoints = {}
        local currentTime = startTime
        while currentTime <= endTime do
            table.insert(self.hpsPoints, {
                time = currentTime,
                value = 0
            })
            currentTime = currentTime + self.config.sampleRate
        end
    end
end

-- Update Y-axis scaling with stability to prevent bouncing
function MetricsPlot:UpdateScale()
    local now = GetTime()
    
    -- Only update scale periodically to prevent bouncing
    if now - self.lastScaleUpdate < self.scaleUpdateInterval then
        return
    end
    
    self.lastScaleUpdate = now
    
    -- Calculate current max values across a longer period for stability
    local currentMaxDPS = self.config.minScale
    local currentMaxHPS = self.config.minScale
    
    -- Find maximum DPS value in current data
    for _, point in ipairs(self.dpsPoints) do
        currentMaxDPS = math.max(currentMaxDPS, point.value)
    end
    
    -- Find maximum HPS value in current data
    for _, point in ipairs(self.hpsPoints) do
        currentMaxHPS = math.max(currentMaxHPS, point.value)
    end
    
    -- Add margin and round up to nice numbers
    currentMaxDPS = currentMaxDPS * (1 + self.config.scaleMargin)
    currentMaxHPS = currentMaxHPS * (1 + self.config.scaleMargin)
    
    local targetMaxDPS = self:RoundToNiceScale(currentMaxDPS)
    local targetMaxHPS = self:RoundToNiceScale(currentMaxHPS)
    
    -- Initialize if not set
    if not self.maxDPS then self.maxDPS = targetMaxDPS end
    if not self.maxHPS then self.maxHPS = targetMaxHPS end
    
    -- Very stable scaling: only change when there's a big difference
    if targetMaxDPS > self.maxDPS * 1.5 then
        -- Scale up only if new peak is 50% higher
        self.maxDPS = targetMaxDPS
        -- Scaling up
    elseif targetMaxDPS < self.maxDPS * 0.3 then
        -- Scale down only if current max is less than 30% of current scale
        self.maxDPS = targetMaxDPS
        -- Scaling down
    end
    
    if targetMaxHPS > self.maxHPS * 1.5 then
        self.maxHPS = targetMaxHPS
    elseif targetMaxHPS < self.maxHPS * 0.3 then
        self.maxHPS = targetMaxHPS
    end
    
    -- Ensure minimum scale
    self.maxDPS = math.max(self.maxDPS, self.config.minScale)
    self.maxHPS = math.max(self.maxHPS, self.config.minScale)
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

-- Create new texture each time (no pooling to avoid flicker)
function MetricsPlot:GetTexture()
    local texture = self.plotFrame:CreateTexture(nil, "ARTWORK")
    -- Set a solid color texture file
    texture:SetTexture("Interface\\Buttons\\WHITE8X8")
    
    table.insert(self.usedTextures, texture)
    return texture
end

-- Destroy used textures instead of pooling to avoid flicker
function MetricsPlot:ReturnTextures()
    for _, texture in ipairs(self.usedTextures) do
        texture:Hide()
        -- Don't pool, just let it be garbage collected
    end
    self.usedTextures = {}
end

-- =============================================================================
-- RENDERING
-- =============================================================================

-- Convert data coordinates to screen coordinates for overlapping plot with shared scale
function MetricsPlot:DataToScreen(time, value, baselineOffset)
    local plotWidth = self.config.width - 60
    local plotHeight = self.config.height - 10  -- Reduced margin (5px bottom + 5px top)
    
    -- Time to X coordinate (right to left scrolling)
    local now = addon.TimingManager:GetCurrentRelativeTime()
    local timeRange = self.config.timeWindow
    local normalizedTime = (time - (now - timeRange)) / timeRange
    local x = 50 + (normalizedTime * plotWidth)
    
    -- Value to Y coordinate using shared max value
    local maxValue = math.max(self.maxDPS or 0, self.maxHPS or 0, self.config.minScale)
    local normalizedValue = maxValue > 0 and (value / maxValue) or 0
    local y = 5 + (normalizedValue * (plotHeight - 5)) + (baselineOffset or 0)  -- Adjust for margins
    
    return x, y
end

-- Draw grid lines and Y-axis with shared scale
function MetricsPlot:DrawGrid()
    local plotWidth = self.config.width - 60
    local plotHeight = self.config.height - 10  -- Reduced margin
    
    -- Calculate shared max value
    local maxValue = math.max(self.maxDPS or 0, self.maxHPS or 0, self.config.minScale)
    
    -- Horizontal grid lines (subtle)
    for i = 0, self.config.gridLines do
        local y = 5 + (i / self.config.gridLines) * (plotHeight - 5)  -- Adjust for margins
        
        local texture = self:GetTexture()
        texture:SetVertexColor(0.3, 0.3, 0.3, 0.3)  -- Subtle grid lines
        texture:SetPoint("BOTTOMLEFT", self.plotFrame, "BOTTOMLEFT", 50, y)
        texture:SetSize(plotWidth, 1)
        texture:Show()
    end
    
    -- Only show top scale label (maximum value)
    if not self.maxLabel then
        self.maxLabel = self.plotFrame:CreateFontString(nil, "OVERLAY")
        self.maxLabel:SetFont(FONT_PATH, 14, "OUTLINE")
        self.maxLabel:SetTextColor(0.9, 0.9, 0.9, 1)
    end
    
    local labelText = self:FormatNumberHumanized(maxValue)
    self.maxLabel:SetText(labelText)
    self.maxLabel:SetPoint("RIGHT", self.plotFrame, "TOPLEFT", 45, -5)
    
    -- Hide old Y-axis labels if they exist
    if self.yLabels then
        for i, label in pairs(self.yLabels) do
            label:Hide()
        end
    end
    
    -- Vertical grid lines (time marks)
    for i = 0, self.config.timeMarks do
        local x = 50 + (i / self.config.timeMarks) * plotWidth
        
        local texture = self:GetTexture()
        texture:SetVertexColor(0.3, 0.3, 0.3, 0.3)  -- Subtle grid lines
        texture:SetPoint("BOTTOMLEFT", self.plotFrame, "BOTTOMLEFT", x, 5)
        texture:SetSize(1, plotHeight)
        texture:Show()
    end
end


-- Format numbers for display (legacy function)
function MetricsPlot:FormatNumber(num)
    if num >= 1000000 then
        return string.format("%.1fM", num / 1000000)
    elseif num >= 1000 then
        return string.format("%.0fK", num / 1000)
    else
        return string.format("%.0f", num)
    end
end

-- Humanized number formatting for scale display
function MetricsPlot:FormatNumberHumanized(num)
    if num >= 1000000000 then
        return string.format("%.2fB", num / 1000000000)
    elseif num >= 1000000 then
        return string.format("%.1fM", num / 1000000)
    elseif num >= 10000 then
        return string.format("%.0fK", num / 1000)
    elseif num >= 1000 then
        return string.format("%.1fK", num / 1000)
    else
        return string.format("%.0f", num)
    end
end

-- Draw bars for each data point instead of continuous lines
function MetricsPlot:DrawBars(points, color, baselineOffset)
    if #points == 0 then
        return
    end
    
    local plotWidth = self.config.width - 60
    local plotHeight = self.config.height - 10  -- Reduced margin
    local barWidth = plotWidth / self.config.timeWindow  -- Width per second
    
    for i, point in ipairs(points) do
        if point.value > 0 then  -- Only draw bars for non-zero values
            local x, yTop = self:DataToScreen(point.time, point.value, baselineOffset)
            local _, yBottom = self:DataToScreen(point.time, 0, baselineOffset)
            
            -- Clip bars that exceed the plot area
            local maxY = plotHeight - 5 + baselineOffset  -- Account for top margin
            yTop = math.min(yTop, maxY)
            
            -- Special tracking bar: use distinct colors for 10-second boundaries
            local barColor = color
            if math.floor(point.time) % 10 == 0 then
                -- Use specific tracking colors based on plot type
                if self.plotType == "DPS" then
                    barColor = {255/255, 192/255, 46/255, 1}  -- Orange for DPS
                else
                    barColor = {40/255, 190/255, 250/255, 1}  -- Light blue for HPS
                end
            end
            
            -- Draw vertical bar
            local texture = self:GetTexture()
            texture:SetVertexColor(barColor[1], barColor[2], barColor[3], barColor[4])
            texture:SetPoint("BOTTOMLEFT", self.plotFrame, "BOTTOMLEFT", x - barWidth/2, yBottom)
            texture:SetSize(math.max(1, barWidth * 0.8), yTop - yBottom)  -- 80% width with gaps
            texture:Show()
        end
    end
end

-- Main render function
function MetricsPlot:Render()
    if not self.isVisible or self.isPaused then
        print("Plot not rendering - visible:", self.isVisible, "paused:", self.isPaused)
        return
    end
    
    -- Remove debug spam
    
    -- Clear previous textures
    self:ReturnTextures()
    
    -- Draw grid
    self:DrawGrid()
    
    -- Skip HPS for now - focusing on DPS first
    
    -- Draw bars based on plot type
    if self.plotType == "DPS" and #self.dpsPoints > 0 then
        local redColor = {1, 0, 0, 1}
        self:DrawBars(self.dpsPoints, redColor, 5)
    elseif self.plotType == "HPS" and #self.hpsPoints > 0 then
        local greenColor = {0.2, 1, 0.2, 1}
        self:DrawBars(self.hpsPoints, greenColor, 5)
    end
end

-- Debug method to print current state
function MetricsPlot:Debug()
    print("=== MetricsPlot Debug ===")
    print(string.format("Visible: %s, Paused: %s", tostring(self.isVisible), tostring(self.isPaused)))
    print(string.format("Max DPS: %.0f, Max HPS: %.0f", self.maxDPS or 0, self.maxHPS or 0))
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
    local frameName = "StormyMetricsPlot" .. (self.plotType or "DPS")
    self.frame = CreateFrame("Frame", frameName, UIParent)
    self.frame:SetSize(self.config.width, self.config.height)
    
    -- Position based on plot type
    if self.plotType == "HPS" then
        self.frame:SetPoint("CENTER", UIParent, "CENTER", 200, -200)  -- Below DPS plot
    else
        self.frame:SetPoint("CENTER", UIParent, "CENTER", 200, 0)  -- Default position
    end
    
    -- Background
    local bg = self.frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(self.config.backgroundColor[1], self.config.backgroundColor[2], self.config.backgroundColor[3], self.config.backgroundColor[4])
    
    -- Plot area frame
    self.plotFrame = CreateFrame("Frame", nil, self.frame)
    self.plotFrame:SetAllPoints()
    
    -- Create tooltip
    self:CreateTooltip()
    
    -- Make main frame draggable
    self.frame:SetMovable(true)
    self.frame:EnableMouse(true)
    self.frame:RegisterForDrag("LeftButton")
    self.frame:SetScript("OnDragStart", function() self.frame:StartMoving() end)
    self.frame:SetScript("OnDragStop", function() self.frame:StopMovingOrSizing() end)
    
    -- Add mouse interaction to plot frame
    self.plotFrame:EnableMouse(true)
    self.plotFrame:SetScript("OnMouseDown", function(frame, button)
        if button == "LeftButton" then
            self:HandlePlotClick(GetCursorPosition())
        end
    end)
    self.plotFrame:SetScript("OnEnter", function(frame)
        self:OnPlotEnter()
    end)
    self.plotFrame:SetScript("OnLeave", function(frame)
        self:OnPlotLeave()
    end)
    self.plotFrame:SetScript("OnUpdate", function(frame)
        if self:ShouldTrackMouse() then
            self:OnPlotMouseMove()
        end
    end)
    
    -- Title removed for cleaner look
    
    self.frame:Hide()
end

-- Show the plot window
function MetricsPlot:Show()
    if not self.frame then
        print("Creating plot window")
        self:CreateWindow()
    end
    
    print("Showing plot window")
    self.frame:Show()
    self.isVisible = true
    self:StartUpdates()
    print("Plot window should now be visible, isVisible =", self.isVisible)
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
-- MOUSE INTERACTION AND TOOLTIPS
-- =============================================================================

-- Create tooltip frame
function MetricsPlot:CreateTooltip()
    if not self.tooltip then
        self.tooltip = CreateFrame("GameTooltip", "StormyPlotTooltip" .. self.plotType, self.frame, "GameTooltipTemplate")
        self.tooltip:SetFrameStrata("TOOLTIP")
    end
end

-- Convert screen coordinates to data time
function MetricsPlot:ScreenToDataTime(screenX)
    local plotWidth = self.config.width - 60
    local relativeX = screenX - 50  -- Account for left margin
    
    -- Convert to time
    local now = addon.TimingManager and addon.TimingManager:GetCurrentRelativeTime() or GetTime()
    local timeRange = self.config.timeWindow
    local normalizedX = relativeX / plotWidth
    local time = (now - timeRange) + (normalizedX * timeRange)
    
    return time
end

-- Find the bar data for a given timestamp
function MetricsPlot:FindBarAtTime(timestamp)
    local flooredTime = math.floor(timestamp)
    
    -- Search in the appropriate points array
    local points = self.plotType == "DPS" and self.dpsPoints or self.hpsPoints
    
    for _, point in ipairs(points) do
        if math.floor(point.time) == flooredTime then
            return point
        end
    end
    
    return nil
end

-- Handle plot click
function MetricsPlot:HandlePlotClick(cursorX, cursorY)
    -- Convert screen coordinates to frame-relative coordinates
    local scale = UIParent:GetEffectiveScale()
    local frameX = cursorX / scale
    local frameY = cursorY / scale
    
    -- Convert to frame-relative coordinates
    local left = self.plotFrame:GetLeft()
    local bottom = self.plotFrame:GetBottom()
    
    if not left or not bottom then return end
    
    local relativeX = frameX - left
    local relativeY = frameY - bottom
    
    -- Check if click is within plot area
    local plotWidth = self.config.width - 60
    local plotHeight = self.config.height - 10
    
    if relativeX < 50 or relativeX > (50 + plotWidth) or relativeY < 5 or relativeY > (plotHeight - 5) then
        -- Click outside plot area - resume if paused
        if self.plotState.mode == "PAUSED" then
            self:Resume()
        end
        return
    end
    
    -- Find clicked bar
    local timestamp = self:ScreenToDataTime(relativeX)
    local bar = self:FindBarAtTime(timestamp)
    
    if bar then
        -- Auto-pause and select
        self:Pause(math.floor(timestamp))
        -- Show detailed breakdown (will be implemented later)
        print(string.format("Clicked bar at %d seconds: %s", 
              math.floor(timestamp), self:FormatNumberHumanized(bar.value)))
    end
end

-- Check if we should track mouse movement
function MetricsPlot:ShouldTrackMouse()
    return self.plotFrame:IsMouseOver()
end

-- Handle mouse enter plot area
function MetricsPlot:OnPlotEnter()
    -- Start tracking mouse movement for tooltips
end

-- Handle mouse leave plot area  
function MetricsPlot:OnPlotLeave()
    -- Hide tooltip
    if self.tooltip then
        self.tooltip:Hide()
    end
    self.plotState.hoveredTimestamp = nil
end

-- Handle mouse movement over plot
function MetricsPlot:OnPlotMouseMove()
    local cursorX, cursorY = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    local frameX = cursorX / scale
    
    -- Convert to frame-relative coordinates
    local left = self.plotFrame:GetLeft()
    if not left then return end
    
    local relativeX = frameX - left
    
    -- Check if mouse is over plot area
    local plotWidth = self.config.width - 60
    if relativeX < 50 or relativeX > (50 + plotWidth) then
        self:OnPlotLeave()
        return
    end
    
    -- Find hovered bar
    local timestamp = self:ScreenToDataTime(relativeX)
    local flooredTime = math.floor(timestamp)
    
    -- Only update if we moved to a different second
    if flooredTime ~= self.plotState.hoveredTimestamp then
        self.plotState.hoveredTimestamp = flooredTime
        
        local bar = self:FindBarAtTime(timestamp)
        if bar then
            self:ShowBarTooltip(bar)
        else
            self:OnPlotLeave()
        end
    end
end

-- Show tooltip for a bar
function MetricsPlot:ShowBarTooltip(bar)
    if not self.tooltip or not bar then return end
    
    self.tooltip:SetOwner(self.plotFrame, "ANCHOR_CURSOR")
    self.tooltip:ClearLines()
    
    local now = addon.TimingManager and addon.TimingManager:GetCurrentRelativeTime() or GetTime()
    local timeAgo = math.floor(now - bar.time)
    
    self.tooltip:AddLine(string.format("%d seconds ago", timeAgo))
    self.tooltip:AddLine(string.format("%s: %s", self.plotType, 
                        self:FormatNumberHumanized(bar.value)), 1, 1, 1)
    
    -- Add crit info if available
    if bar.critRate and bar.critRate > 0 then
        self.tooltip:AddLine(string.format("%.0f%% from crits", bar.critRate * 100), 
                           0.8, 0.8, 0.8)
    end
    
    self.tooltip:Show()
end

-- Pause the plot at a specific timestamp
function MetricsPlot:Pause(timestamp)
    self.plotState.mode = "PAUSED"
    self.plotState.pausedAt = GetTime()
    self.plotState.selectedTimestamp = timestamp
    
    -- Show pause overlay (will be implemented later)
    print(string.format("Plot paused at timestamp %d", timestamp))
end

-- Resume live mode
function MetricsPlot:Resume()
    self.plotState.mode = "LIVE"
    self.plotState.pausedAt = nil
    self.plotState.selectedTimestamp = nil
    
    -- Hide pause overlay (will be implemented later)
    print("Plot resumed to live mode")
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