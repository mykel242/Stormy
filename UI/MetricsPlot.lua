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

-- Scaling constants
local SCALE_UP_THRESHOLD = 1.3      -- Scale up when value exceeds current scale by 30%
local SCALE_DOWN_THRESHOLD = 0.5    -- Scale down when value is less than 50% of current scale
local TRANSITION_DURATION = 0.5     -- Animation duration for outlier transitions
local OUTLIER_CLEANUP_TIME = 5.0    -- Clean up old transitions after 5 seconds

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
    scaleMargin = 0.1,      -- 10% margin above scale value
    
    -- Outlier handling
    usePercentileScaling = true,    -- Use percentile-based scaling instead of max
    scalePercentile = 0.95,         -- Use 95th percentile for scaling (ignores top 5% outliers)
    outlierThreshold = 2.0,         -- Values >2x the scale are considered outliers
    showOutlierIndicators = true,   -- Show visual indicators for outlier bars
    
    -- Data requirements
    minDataForPercentile = 10,      -- Minimum data points before using percentile scaling
    warmupPeriod = 5                -- Seconds before percentile scaling kicks in
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
        
        -- Track outlier transitions
        outlierTransitions = {},  -- Track which bars are transitioning to/from outlier state
        previousOutliers = {},     -- Track previous frame's outliers for transition detection
        
        -- Single source of truth for plot state
        plotState = {
            isPaused = false,           -- SINGLE pause state flag
            selectedBar = nil,          -- currently selected bar timestamp
            hoveredBar = nil,           -- currently hovered bar timestamp
            snapshot = {                -- frozen data when paused (nil when live)
                timestamp = nil,        -- when snapshot was taken
                dpsPoints = {},
                hpsPoints = {},
                maxDPS = 0,
                maxHPS = 0,
                isValid = false         -- marked invalid instead of garbage collected
            }
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
    
    -- Always use current time for live data collection
    local now = addon.TimingManager:GetCurrentRelativeTime()
    local startTime = now - self.config.timeWindow
    
    -- Sample data based on plot type
    if self.plotType == "DPS" then
        if addon.DamageAccumulator and addon.DamageAccumulator.rollingData then
            local rawData = addon.DamageAccumulator:GetTimeSeriesData(startTime, now, 1)
            -- Convert raw totals to rates (damage per second)
            self.dpsPoints = {}
            for _, point in ipairs(rawData) do
                table.insert(self.dpsPoints, {
                    time = point.time,
                    value = point.value  -- For 1-second buckets, total = rate
                })
            end
            -- Enhance with critical hit data
            self:EnhancePointsWithCritData(self.dpsPoints, addon.DamageAccumulator)
            if #self.dpsPoints > 0 then
                print(string.format("[STORMY] DPS Plot: Got %d data points, max value: %.0f", #self.dpsPoints, self:GetMaxValue(self.dpsPoints)))
            end
        else
            self.dpsPoints = {}
        end
        self.hpsPoints = {}  -- Empty for DPS plot
    else
        -- HPS plot
        if addon.HealingAccumulator and addon.HealingAccumulator.rollingData then
            local rawData = addon.HealingAccumulator:GetTimeSeriesData(startTime, now, 1)
            -- Convert raw totals to rates (healing per second)
            self.hpsPoints = {}
            for _, point in ipairs(rawData) do
                table.insert(self.hpsPoints, {
                    time = point.time,
                    value = point.value  -- For 1-second buckets, total = rate
                })
            end
            -- Enhance with critical hit data
            self:EnhancePointsWithCritData(self.hpsPoints, addon.HealingAccumulator)
            if #self.hpsPoints > 0 then
                print(string.format("[STORMY] HPS Plot: Got %d data points, max value: %.0f", #self.hpsPoints, self:GetMaxValue(self.hpsPoints)))
            end
        else
            self.hpsPoints = {}
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

-- Enhance data points with critical hit information
function MetricsPlot:EnhancePointsWithCritData(points, accumulator)
    if not accumulator or not accumulator.rollingData or not accumulator.rollingData.secondSummaries then
        return
    end
    
    for _, point in ipairs(points) do
        local flooredTime = math.floor(point.time)
        local summary = accumulator.rollingData.secondSummaries[flooredTime]
        
        if summary and summary.totalDamage > 0 then
            -- Calculate critical hit rate (damage from crits / total damage)
            point.critRate = summary.critDamage / summary.totalDamage
            point.critDamage = summary.critDamage
            point.totalHits = summary.eventCount
            point.totalCrits = summary.critCount
        else
            point.critRate = 0
            point.critDamage = 0
            point.totalHits = 0
            point.totalCrits = 0
        end
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

-- Collect values from plot data
function MetricsPlot:CollectPlotValues()
    local dpsValues = {}
    local hpsValues = {}
    
    -- Collect all values from current data
    for _, point in ipairs(self.dpsPoints) do
        if point.value > 0 then
            table.insert(dpsValues, point.value)
        end
    end
    
    for _, point in ipairs(self.hpsPoints) do
        if point.value > 0 then
            table.insert(hpsValues, point.value)
        end
    end
    
    return dpsValues, hpsValues
end

-- Get maximum value from a points array (helper for debugging)
function MetricsPlot:GetMaxValue(points)
    local maxVal = 0
    for _, point in ipairs(points) do
        if point.value > maxVal then
            maxVal = point.value
        end
    end
    return maxVal
end

-- Determine if percentile scaling should be used
function MetricsPlot:ShouldUsePercentileScaling(dpsCount, hpsCount, uptime)
    if not self.config.usePercentileScaling then
        return false
    end
    
    local hasEnoughData = (self.plotType == "DPS" and dpsCount >= self.config.minDataForPercentile) or
                         (self.plotType == "HPS" and hpsCount >= self.config.minDataForPercentile)
    local hasWarmedUp = uptime >= self.config.warmupPeriod
    
    return hasEnoughData and hasWarmedUp
end

-- Calculate target scales based on data
function MetricsPlot:CalculateTargetScales(usePercentile, dpsValues, hpsValues)
    local targetMaxDPS, targetMaxHPS
    
    if usePercentile then
        -- Calculate percentile values
        local percentileDPS = self:CalculatePercentile(dpsValues, self.config.scalePercentile)
        local percentileHPS = self:CalculatePercentile(hpsValues, self.config.scalePercentile)
        
        -- Ensure minimum meaningful scale
        percentileDPS = math.max(percentileDPS, self.config.minScale)
        percentileHPS = math.max(percentileHPS, self.config.minScale)
        
        -- Add margin and round to nice numbers
        targetMaxDPS = self:RoundToNiceScale(percentileDPS * (1 + self.config.scaleMargin))
        targetMaxHPS = self:RoundToNiceScale(percentileHPS * (1 + self.config.scaleMargin))
    else
        -- Traditional max-value scaling (fallback)
        local currentMaxDPS = self.config.minScale
        local currentMaxHPS = self.config.minScale
        
        for _, value in ipairs(dpsValues) do
            currentMaxDPS = math.max(currentMaxDPS, value)
        end
        
        for _, value in ipairs(hpsValues) do
            currentMaxHPS = math.max(currentMaxHPS, value)
        end
        
        targetMaxDPS = self:RoundToNiceScale(currentMaxDPS * (1 + self.config.scaleMargin))
        targetMaxHPS = self:RoundToNiceScale(currentMaxHPS * (1 + self.config.scaleMargin))
    end
    
    return targetMaxDPS, targetMaxHPS
end

-- Apply hysteresis to scale changes
function MetricsPlot:ApplyScaleHysteresis(targetMaxDPS, targetMaxHPS)
    -- Initialize if not set
    if not self.maxDPS then self.maxDPS = targetMaxDPS end
    if not self.maxHPS then self.maxHPS = targetMaxHPS end
    
    -- Stable scaling with hysteresis using constants
    if targetMaxDPS > self.maxDPS * SCALE_UP_THRESHOLD then
        self.maxDPS = targetMaxDPS
    elseif targetMaxDPS < self.maxDPS * SCALE_DOWN_THRESHOLD then
        self.maxDPS = targetMaxDPS
    end
    
    if targetMaxHPS > self.maxHPS * SCALE_UP_THRESHOLD then
        self.maxHPS = targetMaxHPS
    elseif targetMaxHPS < self.maxHPS * SCALE_DOWN_THRESHOLD then
        self.maxHPS = targetMaxHPS
    end
    
    -- Ensure minimum scale
    self.maxDPS = math.max(self.maxDPS, self.config.minScale)
    self.maxHPS = math.max(self.maxHPS, self.config.minScale)
end

-- Update Y-axis scaling with outlier-resistant percentile-based scaling
function MetricsPlot:UpdateScale()
    local now = GetTime()
    
    -- Only update scale periodically to prevent bouncing
    if now - self.lastScaleUpdate < self.scaleUpdateInterval then
        return
    end
    
    self.lastScaleUpdate = now
    
    -- Collect values once
    local dpsValues, hpsValues = self:CollectPlotValues()
    
    -- Determine if we should use percentile scaling
    local uptime = now - addon.startTime
    local usePercentile = self:ShouldUsePercentileScaling(#dpsValues, #hpsValues, uptime)
    
    -- Calculate target scales
    local targetMaxDPS, targetMaxHPS = self:CalculateTargetScales(usePercentile, dpsValues, hpsValues)
    
    -- Apply hysteresis to prevent scale bouncing
    self:ApplyScaleHysteresis(targetMaxDPS, targetMaxHPS)
end

-- Calculate percentile value from a list of numbers
function MetricsPlot:CalculatePercentile(values, percentile)
    if #values == 0 then
        return 0
    end
    
    -- Create a copy and sort
    local sortedValues = {}
    for i, v in ipairs(values) do
        if v > 0 then  -- Only include positive values
            table.insert(sortedValues, v)
        end
    end
    
    -- Handle edge cases
    if #sortedValues == 0 then
        return 0
    end
    
    if #sortedValues == 1 then
        return sortedValues[1]
    end
    
    table.sort(sortedValues)
    
    -- Calculate percentile index (safe with 2+ values)
    local index = percentile * (#sortedValues - 1) + 1
    local lower = math.floor(index)
    local upper = math.ceil(index)
    
    -- Bounds checking
    lower = math.max(1, math.min(lower, #sortedValues))
    upper = math.max(1, math.min(upper, #sortedValues))
    
    -- Interpolate if needed
    if lower == upper then
        return sortedValues[lower]
    else
        local weight = index - lower
        return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
    end
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
    local plotHeight = self.config.height - 25  -- Account for title bar (15px) + margins (10px)
    
    -- Simple logic: if paused, use snapshot time reference; if live, use current time
    local now
    if self.plotState.isPaused and self.plotState.snapshot.isValid then
        -- PAUSED: Use frozen snapshot timestamp directly - no animation
        now = self.plotState.snapshot.timestamp
        
        -- Using frozen timestamp for paused state
    else
        -- LIVE: Use current time - bars animate from right to left
        now = addon.TimingManager:GetCurrentRelativeTime()
        
        -- Using current timestamp for live state
    end
    
    -- Convert time to X coordinate
    local timeRange = self.config.timeWindow
    local normalizedTime = (time - (now - timeRange)) / timeRange
    local x = 50 + (normalizedTime * plotWidth)
    
    -- Convert value to Y coordinate using appropriate scale for this plot type
    local maxValue
    if self.plotState.isPaused and self.plotState.snapshot.isValid then
        -- Use the appropriate scale for this plot type
        if self.plotType == "DPS" then
            maxValue = self.plotState.snapshot.maxDPS or self.config.minScale
        else
            maxValue = self.plotState.snapshot.maxHPS or self.config.minScale
        end
    else
        -- Use the appropriate scale for this plot type
        if self.plotType == "DPS" then
            maxValue = self.maxDPS or self.config.minScale
        else
            maxValue = self.maxHPS or self.config.minScale
        end
    end
    
    local normalizedValue = maxValue > 0 and (value / maxValue) or 0
    local y = 5 + (normalizedValue * (plotHeight - 5)) + (baselineOffset or 0)
    
    return x, y
end

-- Draw grid lines and Y-axis with shared scale
function MetricsPlot:DrawGrid()
    local plotWidth = self.config.width - 60
    local plotHeight = self.config.height - 25  -- Account for title bar (15px) + margins (10px)
    
    -- Use appropriate scale for this plot type
    local maxValue
    if self.plotState.isPaused and self.plotState.snapshot.isValid then
        if self.plotType == "DPS" then
            maxValue = self.plotState.snapshot.maxDPS or self.config.minScale
        else
            maxValue = self.plotState.snapshot.maxHPS or self.config.minScale
        end
    else
        if self.plotType == "DPS" then
            maxValue = self.maxDPS or self.config.minScale
        else
            maxValue = self.maxHPS or self.config.minScale
        end
    end
    
    -- Horizontal grid lines (subtle)
    for i = 0, self.config.gridLines do
        local y = 5 + (i / self.config.gridLines) * (plotHeight - 5)  -- Adjust for margins
        
        local texture = self:GetTexture()
        texture:SetVertexColor(0.3, 0.3, 0.3, 0.3)  -- Subtle grid lines
        texture:SetPoint("BOTTOMLEFT", self.plotFrame, "BOTTOMLEFT", 50, y)
        texture:SetSize(plotWidth, 1)
        texture:Show()
    end
    
    -- Show scale label above the highest bar
    if not self.maxLabel then
        self.maxLabel = self.plotFrame:CreateFontString(nil, "OVERLAY")
        self.maxLabel:SetFont(FONT_PATH, 14, "OUTLINE")
        self.maxLabel:SetTextColor(0.9, 0.9, 0.9, 1)
    end
    
    local labelText = self:FormatNumberHumanized(maxValue)
    self.maxLabel:SetText(labelText)
    
    -- Position above the highest bar instead of left margin
    self:PositionValueLabelAboveHighestBar(maxValue)
    
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

-- Position scale label in a consistent location
function MetricsPlot:PositionValueLabelAboveHighestBar(maxValue)
    -- Simply position the scale label in the top-right corner of the plot
    -- This is cleaner and more consistent than trying to position above bars
    local plotWidth = self.config.width - 60
    local plotHeight = self.config.height - 25
    
    -- Check if we have any data to display
    local hasData = false
    if self.plotState.isPaused and self.plotState.snapshot.isValid then
        if self.plotType == "DPS" then
            hasData = self.plotState.snapshot.dpsPoints and #self.plotState.snapshot.dpsPoints > 0
        else
            hasData = self.plotState.snapshot.hpsPoints and #self.plotState.snapshot.hpsPoints > 0
        end
    else
        if self.plotType == "DPS" then
            hasData = self.dpsPoints and #self.dpsPoints > 0
        else
            hasData = self.hpsPoints and #self.hpsPoints > 0
        end
    end
    
    if hasData and maxValue > 0 then
        -- Position in top-right corner, slightly inset
        local x = 50 + plotWidth - 40
        local y = plotHeight - 10
        
        self.maxLabel:ClearAllPoints()
        self.maxLabel:SetPoint("CENTER", self.plotFrame, "BOTTOMLEFT", x, y)
        self.maxLabel:Show()
    else
        -- Hide label when no data
        self.maxLabel:Hide()
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

-- Check if a value is an outlier
function MetricsPlot:IsOutlier(value, scaleValue)
    -- Only consider values that significantly exceed the scale as outliers
    -- Default threshold is 1.0 (values that exceed the scale itself)
    return self.config.showOutlierIndicators and 
           value > scaleValue  -- Simplified: outliers are values that exceed the scale
end

-- Draw bars for each data point instead of continuous lines
function MetricsPlot:DrawBars(points, color, baselineOffset)
    if #points == 0 then
        return
    end
    
    local plotWidth = self.config.width - 60
    local plotHeight = self.config.height - 25  -- Account for title bar (15px) + margins (10px)
    local barWidth = plotWidth / self.config.timeWindow  -- Width per second
    
    -- Track current outliers for transition detection
    local currentOutliers = {}
    
    -- Get the selected plot type once for all bars (for performance and consistency)
    local selectedPlotType = addon.PlotStateManager:GetSelectedPlotType()
    
    -- Use appropriate scale for this plot type
    local maxValue
    if self.plotState.isPaused and self.plotState.snapshot.isValid then
        if self.plotType == "DPS" then
            maxValue = self.plotState.snapshot.maxDPS or self.config.minScale
        else
            maxValue = self.plotState.snapshot.maxHPS or self.config.minScale
        end
    else
        if self.plotType == "DPS" then
            maxValue = self.maxDPS or self.config.minScale
        else
            maxValue = self.maxHPS or self.config.minScale
        end
    end
    
    for i, point in ipairs(points) do
        if point.value > 0 then  -- Only draw bars for non-zero values
            -- Check if this value is an outlier
            local isOutlier = self:IsOutlier(point.value, maxValue)
            local timeKey = math.floor(point.time)
            
            -- Track outlier state
            if isOutlier then
                currentOutliers[timeKey] = true
            end
            
            -- Check for transitions
            local isNewOutlier = isOutlier and not self.previousOutliers[timeKey]
            local wasOutlier = not isOutlier and self.previousOutliers[timeKey]
            
            -- Update transition tracking
            if isNewOutlier then
                self.outlierTransitions[timeKey] = {
                    type = "becoming_outlier",
                    startTime = GetTime(),
                    duration = TRANSITION_DURATION
                }
            elseif wasOutlier then
                self.outlierTransitions[timeKey] = {
                    type = "becoming_normal",
                    startTime = GetTime(),
                    duration = TRANSITION_DURATION
                }
            end
            
            local x, yTop = self:DataToScreen(point.time, point.value, baselineOffset)
            local _, yBottom = self:DataToScreen(point.time, 0, baselineOffset)
            
            -- For outliers, cap the visual height but show indicator
            local actualYTop = yTop
            local maxY = plotHeight - 5 + baselineOffset  -- Account for top margin
            
            if isOutlier then
                -- Cap outlier bars to the plot area but track actual value
                yTop = maxY
            else
                -- Clip regular bars that exceed the plot area
                yTop = math.min(yTop, maxY)
            end
            
            -- Check if this bar is selected for dimming
            -- Only highlight bars in the plot type that initiated the selection
            local isSelected = self.plotState.selectedBar and 
                             math.floor(point.time) == self.plotState.selectedBar and
                             selectedPlotType == self.plotType
            
            -- Check if this bar is hovered for highlighting (exact match only)
            local isHovered = false
            if self.plotState.hoveredBar then
                local pointTime = math.floor(point.time)
                local hoveredTime = self.plotState.hoveredBar
                -- Exact match for precise highlighting
                isHovered = (pointTime == hoveredTime)
            end
            
            -- Determine bar color based on state
            local barColor = {color[1], color[2], color[3], color[4]}
            local transitionAlpha = 1.0
            local pulseEffect = 0
            
            -- Override color for outliers
            if isOutlier then
                -- Use outlier colors for the entire bar
                if self.plotType == "DPS" then
                    barColor = {1, 1, 0, 1}  -- Yellow for DPS outliers
                else
                    barColor = {0, 1, 1, 1}  -- Cyan for HPS outliers
                end
                
                -- Apply transition effects for new outliers
                local transition = self.outlierTransitions[timeKey]
                if transition and transition.type == "becoming_outlier" then
                    local elapsed = GetTime() - transition.startTime
                    local progress = math.min(elapsed / transition.duration, 1)
                    transitionAlpha = progress  -- Fade in
                    
                    -- Add pulse effect for new outliers
                    if progress < 1 then
                        pulseEffect = math.sin(progress * math.pi * 4) * 0.2  -- Pulse 2 times
                    end
                end
                
                -- Apply transition alpha to outlier color
                barColor[4] = transitionAlpha + pulseEffect
            end
            
            -- Apply hover highlighting (takes precedence over other effects)
            if isHovered then
                -- Use tracking colors for hover highlight
                if self.plotType == "DPS" then
                    barColor = {255/255, 192/255, 46/255, 1}  -- Orange for DPS hover
                else
                    barColor = {40/255, 190/255, 250/255, 1}  -- Light blue for HPS hover
                end
            elseif self.plotState.selectedBar and selectedPlotType ~= self.plotType then
                -- Dim all bars in non-selected plot types
                barColor[1] = barColor[1] * 0.5
                barColor[2] = barColor[2] * 0.5
                barColor[3] = barColor[3] * 0.5
            elseif not isSelected and self.plotState.selectedBar and selectedPlotType == self.plotType then
                -- Dim unselected bars in the selected plot type
                barColor[1] = barColor[1] * 0.5
                barColor[2] = barColor[2] * 0.5
                barColor[3] = barColor[3] * 0.5
            end
            
            -- Remove special 10-second boundary coloring since we use those colors for hover now
            
            -- Check for glow effect (30% crit damage threshold)
            local shouldGlow, glowIntensity = self:CalculateGlowEffect(point, maxValue)
            
            if shouldGlow then
                -- Draw glow layer behind the bar
                local glowTexture = self:GetTexture()
                glowTexture:SetVertexColor(barColor[1] * 1.5, barColor[2] * 1.5, barColor[3] * 1.5, glowIntensity)
                glowTexture:SetPoint("BOTTOMLEFT", self.plotFrame, "BOTTOMLEFT", 
                                   x - barWidth * 0.6, yBottom - 2)
                glowTexture:SetSize(barWidth * 1.2, (yTop - yBottom) + 4)
                glowTexture:Show()
            end
            
            -- Draw main vertical bar
            local texture = self:GetTexture()
            texture:SetVertexColor(barColor[1], barColor[2], barColor[3], barColor[4])
            texture:SetPoint("BOTTOMLEFT", self.plotFrame, "BOTTOMLEFT", x - barWidth/2, yBottom)
            texture:SetSize(math.max(1, barWidth * 0.8), yTop - yBottom)  -- 80% width with gaps
            texture:Show()
        end
    end
    
    -- Update previous outliers for next frame's transition detection
    self.previousOutliers = currentOutliers
    
    -- Clean up old transition entries to prevent memory leak
    local now = GetTime()
    for timeKey, transition in pairs(self.outlierTransitions) do
        local elapsed = now - transition.startTime
        if elapsed > OUTLIER_CLEANUP_TIME then
            self.outlierTransitions[timeKey] = nil
        end
    end
end

-- Calculate glow effect based on crit rate and magnitude
function MetricsPlot:CalculateGlowEffect(point, maxValue)
    local CRIT_THRESHOLD = 0.3  -- 30% threshold
    
    -- Check if we have crit data and it exceeds threshold
    if not point.critRate or point.critRate <= CRIT_THRESHOLD then
        return false, 0
    end
    
    -- Scale by how much above threshold and magnitude
    local critFactor = (point.critRate - CRIT_THRESHOLD) / (1.0 - CRIT_THRESHOLD)  -- Normalize 30%-100% to 0-1
    local magnitudeFactor = point.value / maxValue
    
    -- Maximum alpha of 0.4, scaled by both factors
    local glowIntensity = critFactor * magnitudeFactor * 0.4
    
    return true, glowIntensity
end

-- Main render function
function MetricsPlot:Render()
    if not self.isVisible then
        return
    end
    
    -- Render with current plot state
    
    
    -- Clear previous textures
    self:ReturnTextures()
    
    -- Draw grid
    self:DrawGrid()
    
    -- Simple render logic: paused = snapshot data, live = current data
    local dpsData, hpsData
    if self.plotState.isPaused and self.plotState.snapshot.isValid then
        -- PAUSED: Render static snapshot - no animation
        dpsData = self.plotState.snapshot.dpsPoints
        hpsData = self.plotState.snapshot.hpsPoints
        
        -- Using snapshot data for paused rendering
    else
        -- LIVE: Render current data - bars animate
        dpsData = self.dpsPoints
        hpsData = self.hpsPoints
        
        -- Using live data for active rendering
    end
    
    if self.plotType == "DPS" and #dpsData > 0 then
        local redColor = {1, 0, 0, 1}
        self:DrawBars(dpsData, redColor, 5)
    elseif self.plotType == "HPS" and #hpsData > 0 then
        local greenColor = {0.2, 1, 0.2, 1}
        self:DrawBars(hpsData, greenColor, 5)
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
-- SNAPSHOT MANAGEMENT
-- =============================================================================

-- Create snapshot of current data for paused viewing
function MetricsPlot:CreateSnapshot()
    local snapshot = self.plotState.snapshot
    
    -- Capture timestamp when snapshot was taken (use TimingManager's relative time)
    snapshot.timestamp = addon.TimingManager:GetCurrentRelativeTime()
    
    -- Capture snapshot at current time
    
    -- Deep copy current data points
    snapshot.dpsPoints = {}
    for i, point in ipairs(self.dpsPoints) do
        snapshot.dpsPoints[i] = {
            time = point.time,
            value = point.value,
            critRate = point.critRate or 0,
            critDamage = point.critDamage or 0,
            totalHits = point.totalHits or 0,
            totalCrits = point.totalCrits or 0
        }
    end
    
    snapshot.hpsPoints = {}
    for i, point in ipairs(self.hpsPoints) do
        snapshot.hpsPoints[i] = {
            time = point.time,
            value = point.value,
            critRate = point.critRate or 0,
            critDamage = point.critDamage or 0,
            totalHits = point.totalHits or 0,
            totalCrits = point.totalCrits or 0
        }
    end
    
    -- Capture current scale values
    snapshot.maxDPS = self.maxDPS
    snapshot.maxHPS = self.maxHPS
    
    -- Mark snapshot as valid
    snapshot.isValid = true
    
    -- Snapshot created successfully
end

-- Invalidate snapshot (mark as invalid to avoid garbage collection)
function MetricsPlot:InvalidateSnapshot()
    self.plotState.snapshot.isValid = false
    self.plotState.snapshot.timestamp = nil
    -- Don't clear arrays to avoid garbage collection - just mark invalid
    
    -- Snapshot invalidated
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
    
    -- Always update live data (even when paused - we continue collecting)
    self:UpdateData()
    
    -- Only render automatically when not paused
    -- In paused mode, rendering is triggered by mouse events to preserve hover highlighting
    if not self.plotState.isPaused then
        self:Render()
    end
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
    
    -- Create title bar for dragging (small area at top)
    local titleBar = CreateFrame("Frame", nil, self.frame)
    titleBar:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", 0, 0)
    titleBar:SetHeight(15)  -- Small 15px title bar
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() self.frame:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() self.frame:StopMovingOrSizing() end)
    
    -- Visual indicator for title bar (subtle)
    local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBg:SetAllPoints()
    titleBg:SetColorTexture(0.2, 0.2, 0.2, 0.5)  -- Darker background
    
    -- Title text - moved to top left corner
    local titleText = titleBar:CreateFontString(nil, "OVERLAY")
    titleText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    titleText:SetPoint("LEFT", titleBar, "LEFT", 5, 0)  -- Left-aligned with small margin
    titleText:SetTextColor(0.7, 0.7, 0.7, 1)
    titleText:SetText(self.plotType or "PLOT")
    
    -- Plot area frame (positioned below title bar)
    self.plotFrame = CreateFrame("Frame", nil, self.frame)
    self.plotFrame:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    self.plotFrame:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", 0, 0)
    
    -- Create tooltip
    self:CreateTooltip()
    
    -- Detail window is now shared via EventDetailWindow component
    -- Pause overlay creation disabled for cleaner UI
    
    -- Make main frame movable (dragging handled by title bar)
    self.frame:SetMovable(true)
    
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
        -- Create plot window on first show
        self:CreateWindow()
    end
    
    -- Show the plot window
    self.frame:Show()
    self.isVisible = true
    
    -- Register with PlotStateManager for synchronized pause
    addon.PlotStateManager:RegisterPlot(self, self.plotType)
    
    self:StartUpdates()
    
    -- Force initial render to ensure plot appears active
    self:Render()
    
    -- Plot window now visible
end

-- Hide the plot window
function MetricsPlot:Hide()
    if self.frame then
        self.frame:Hide()
    end
    
    self.isVisible = false
    
    -- Unregister from PlotStateManager
    addon.PlotStateManager:UnregisterPlot(self.plotType)
    
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

-- Detail window functionality is now handled by the shared EventDetailWindow component

-- Create pause overlay
function MetricsPlot:CreatePauseOverlay()
    -- Pause overlay creation disabled for cleaner UI
    -- No overlay, text, or resume button created
end

-- Convert screen coordinates to data time
function MetricsPlot:ScreenToDataTime(screenX)
    local plotWidth = self.config.width - 60
    local relativeX = screenX - 50  -- Account for left margin
    
    -- Convert to time - use same logic as DataToScreen for consistency
    local now
    if self.plotState.isPaused and self.plotState.snapshot.isValid then
        -- PAUSED: Use frozen snapshot timestamp directly - matches DataToScreen
        now = self.plotState.snapshot.timestamp
    else
        -- LIVE: Use current time - matches DataToScreen
        now = addon.TimingManager and addon.TimingManager:GetCurrentRelativeTime() or GetTime()
    end
    
    local timeRange = self.config.timeWindow
    local normalizedX = relativeX / plotWidth
    local time = (now - timeRange) + (normalizedX * timeRange)
    
    return time
end

-- Find the bar data for a given timestamp
function MetricsPlot:FindBarAtTime(timestamp)
    local flooredTime = math.floor(timestamp)
    
    -- Search in the appropriate points array - use snapshot if paused and valid
    local points
    if self.plotState.isPaused and self.plotState.snapshot.isValid then
        points = self.plotType == "DPS" and self.plotState.snapshot.dpsPoints or self.plotState.snapshot.hpsPoints
    else
        points = self.plotType == "DPS" and self.dpsPoints or self.hpsPoints
    end
    
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
    local plotHeight = self.config.height - 25  -- Account for title bar (15px) + margins (10px)
    
    if relativeX < 50 or relativeX > (50 + plotWidth) or relativeY < 5 or relativeY > (plotHeight - 5) then
        -- Click outside plot area - resume if paused
        if self.plotState.isPaused then
            self:Resume()
        end
        return
    end
    
    -- Find clicked bar
    local timestamp = self:ScreenToDataTime(relativeX)
    local bar = self:FindBarAtTime(timestamp)
    
    if bar then
        if self.plotState.isPaused then
            -- Already paused - change selection across all plots
            addon.PlotStateManager:ChangeSelection(math.floor(timestamp), self.plotType)
        else
            -- Not paused - pause and select
            self:Pause(math.floor(timestamp))
        end
        -- Show detailed breakdown
        self:ShowDetailFrame(math.floor(timestamp), frameX, frameY)
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
    
    -- In paused mode, be less aggressive about clearing hover state
    if not self.plotState.isPaused then
        self.plotState.hoveredBar = nil
        -- Trigger render to remove hover highlighting
        self:Render()
    end
    -- In paused mode, keep hover state but just hide tooltip
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
    if flooredTime ~= self.plotState.hoveredBar then
        self.plotState.hoveredBar = flooredTime
        
        local bar = self:FindBarAtTime(timestamp)
        if bar then
            self:ShowBarTooltip(bar)
        else
            self:OnPlotLeave()
        end
        
        -- Trigger immediate render to show hover highlighting
        self:Render()
    end
end

-- Show tooltip for a bar
function MetricsPlot:ShowBarTooltip(bar)
    if not self.tooltip or not bar then return end
    
    -- Position tooltip to the right of the chart to avoid overlap
    self.tooltip:SetOwner(self.plotFrame, "ANCHOR_RIGHT")
    self.tooltip:ClearLines()
    
    local now = addon.TimingManager and addon.TimingManager:GetCurrentRelativeTime() or GetTime()
    local timeAgo = math.floor(now - bar.time)
    
    self.tooltip:AddLine(string.format("%d seconds ago", timeAgo))
    self.tooltip:AddLine(string.format("%s: %s", self.plotType, 
                        self:FormatNumberHumanized(bar.value)), 1, 1, 1)
    
    -- Check if this is an outlier and show additional info
    local maxValue = self.plotType == "DPS" and (self.maxDPS or self.config.minScale) or (self.maxHPS or self.config.minScale)
    if self:IsOutlier(bar.value, maxValue) then
        local overScale = bar.value / maxValue
        self.tooltip:AddLine(string.format("OUTLIER: %.1fx above scale", overScale), 
                           1, 1, 0, 1)  -- Yellow text for outliers
        self.tooltip:AddLine("(Visual height capped)", 0.8, 0.8, 0.6, 1)
    end
    
    -- Add crit info if available
    if bar.critRate and bar.critRate > 0 then
        self.tooltip:AddLine(string.format("%.0f%% from crits", bar.critRate * 100), 
                           0.8, 0.8, 0.8)
    end
    
    self.tooltip:Show()
end

-- Pause the plot at a specific timestamp
function MetricsPlot:Pause(timestamp)
    -- Use PlotStateManager to pause all plots synchronously
    addon.PlotStateManager:PauseAll(timestamp, self.plotType)
    
    -- Plot paused
end

-- Resume live mode
function MetricsPlot:Resume()
    -- Use PlotStateManager to resume all plots synchronously
    addon.PlotStateManager:ResumeAll(self.plotType)
    
    -- Plot resumed
end

-- Pause overlay functions removed - cleaner UI per user request

-- Show detail popup frame
function MetricsPlot:ShowDetailFrame(timestamp, x, y)
    -- Use PlotStateManager to show the shared detail window
    addon.PlotStateManager:ShowDetailWindow(self.plotType, timestamp, self.plotFrame)
end

-- Hide detail popup frame
function MetricsPlot:HideDetailFrame()
    -- Use PlotStateManager to hide the shared detail window
    addon.PlotStateManager:HideDetailWindow()
end

-- Get detailed data for a timestamp from the accumulator
function MetricsPlot:GetSecondDetails(timestamp)
    local accumulator = nil
    
    -- Get the appropriate accumulator
    if self.plotType == "DPS" and addon.DamageAccumulator then
        accumulator = addon.DamageAccumulator
    elseif self.plotType == "HPS" and addon.HealingAccumulator then
        accumulator = addon.HealingAccumulator
    end
    
    if accumulator and accumulator.GetSecondDetails then
        return accumulator:GetSecondDetails(timestamp)
    end
    
    return nil, nil
end

-- Detail content population is now handled by the shared EventDetailWindow component
-- --[[
-- function MetricsPlot:PopulateDetailContent(timestamp, summary, events)
--     if not self.detailContent then return end]]--
--     
--     -- Clear existing content properly
--     for i, child in ipairs({self.detailContent:GetChildren()}) do
--         child:Hide()
--         child:ClearAllPoints()
--         if child.SetParent then
--             child:SetParent(nil)
--         end
--     end
--     
--     -- Also clear any existing FontStrings created by CreateDetailLine
--     if self.detailContent.createdLines then
--         for _, line in ipairs(self.detailContent.createdLines) do
--             line:Hide()
--             line:ClearAllPoints()
--             if line.SetParent then
--                 line:SetParent(nil)
--             end
--         end
--     end
--     self.detailContent.createdLines = {}
--     
--     local yOffset = -10
--     local lineHeight = 16
--     
--     -- Title with timestamp
--     local now = addon.TimingManager and addon.TimingManager:GetCurrentRelativeTime() or GetTime()
--     local timeAgo = math.floor(now - timestamp)
--     
--     local headerText = string.format("%d seconds ago", timeAgo)
--     local header = self:CreateDetailLine(headerText, 12, {1, 1, 0.5, 1})
--     header:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 0, yOffset)
--     yOffset = yOffset - lineHeight
--     
--     -- Summary stats
--     local totalText = string.format("Total: %s (%d hits, %d crits)", 
--         self:FormatNumberHumanized(summary.totalDamage), 
--         summary.eventCount, 
--         summary.critCount)
--     local total = self:CreateDetailLine(totalText, 11, {1, 1, 1, 1})
--     total:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 0, yOffset)
--     yOffset = yOffset - lineHeight
--     
--     -- Crit percentage
--     if summary.critCount > 0 then
--         local critPercent = (summary.critCount / summary.eventCount) * 100
--         local critDamagePercent = (summary.critDamage / summary.totalDamage) * 100
--         local critText = string.format("Crits: %.0f%% of hits, %.0f%% of damage", 
--             critPercent, critDamagePercent)
--         local crit = self:CreateDetailLine(critText, 10, {0.8, 0.8, 0.8, 1})
--         crit:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 0, yOffset)
--         yOffset = yOffset - lineHeight
--     end
--     
--     -- Separator
--     yOffset = yOffset - 5
--     
--     -- Spell breakdown header
--     local spellHeader = self:CreateDetailLine("Spell Breakdown:", 11, {1, 1, 0.5, 1})
--     spellHeader:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 0, yOffset)
--     yOffset = yOffset - lineHeight
--     
--     -- Sort spells by damage
--     local spells = {}
--     for spellId, data in pairs(summary.spells) do
--         table.insert(spells, {id = spellId, data = data})
--     end
--     table.sort(spells, function(a, b) return a.data.total > b.data.total end)
--     
--     -- Debug: Log spell count
--     print(string.format("[STORMY DEBUG] Found %d spells in summary for timestamp %d", #spells, timestamp))
--     
--     -- Show top 8 spells
--     for i = 1, math.min(8, #spells) do
--         local spell = spells[i]
--         local name = addon.SpellCache:GetSpellName(spell.id)
--         local percent = (spell.data.total / summary.totalDamage) * 100
--         local critRate = spell.data.crits > 0 and (spell.data.crits / spell.data.count) * 100 or 0
--         
--         -- Debug: Log spell details
--         print(string.format("[STORMY DEBUG] Spell %d: ID=%s, Name=%s, Total=%d", i, tostring(spell.id), tostring(name), spell.data.total))
--         
--         local spellText = string.format("%s: %s (%.0f%%) - %d hits", 
--             name, 
--             self:FormatNumberHumanized(spell.data.total),
--             percent,
--             spell.data.count)
--         
--         if critRate > 0 then
--             spellText = spellText .. string.format(", %.0f%% crit", critRate)
--         end
--         
--         local color = i <= 3 and {1, 1, 1, 1} or {0.8, 0.8, 0.8, 1}
--         local line = self:CreateDetailLine(spellText, 10, color)
--         line:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 10, yOffset)
--         yOffset = yOffset - lineHeight
--     end
--     
--     -- Entity breakdown if events are available
--     if events and #events > 0 then
--         yOffset = yOffset - 5
--         
--         local entityHeader = self:CreateDetailLine("Entity Breakdown:", 11, {1, 1, 0.5, 1})
--         entityHeader:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 0, yOffset)
--         yOffset = yOffset - lineHeight
--         
--         local entities = self:GroupEventsByEntity(events)
--         local entityList = {}
--         for name, data in pairs(entities) do
--             table.insert(entityList, {name = name, data = data})
--         end
--         table.sort(entityList, function(a, b) return a.data.total > b.data.total end)
--         
--         for i, entity in ipairs(entityList) do
--             local percent = (entity.data.total / summary.totalDamage) * 100
--             local entityText = string.format("%s: %s (%.0f%%)", 
--                 entity.name, 
--                 self:FormatNumberHumanized(entity.data.total),
--                 percent)
--             
--             local color = {0.7, 0.9, 0.7, 1}  -- Light green for entities
--             local line = self:CreateDetailLine(entityText, 10, color)
--             line:SetPoint("TOPLEFT", self.detailContent, "TOPLEFT", 10, yOffset)
--             yOffset = yOffset - lineHeight
--         end
--     end
--     
--     -- Update content height for scrolling
--     self.detailContent:SetHeight(math.abs(yOffset) + 20)
-- end
-- 
-- -- Create a text line for the detail frame
-- function MetricsPlot:CreateDetailLine(text, fontSize, color)
--     local line = self.detailContent:CreateFontString(nil, "OVERLAY")
--     line:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
--     line:SetText(text)
--     line:SetTextColor(color[1], color[2], color[3], color[4])
--     line:SetJustifyH("LEFT")
--     line:SetWordWrap(true)
--     line:SetWidth(240)  -- Account for scrollbar
--     
--     -- Track created lines for cleanup
--     if not self.detailContent.createdLines then
--         self.detailContent.createdLines = {}
--     end
--     table.insert(self.detailContent.createdLines, line)
--     
--     return line
-- end
-- 
-- -- Helper function to count table entries
-- function MetricsPlot:CountTableEntries(t)
--     local count = 0
--     for _ in pairs(t) do
--         count = count + 1
--     end
--     return count
-- end

-- -- Group events by entity (player vs pets)
-- function MetricsPlot:GroupEventsByEntity(events)
--     local entities = {}
--     
--     for _, event in ipairs(events) do
--         local entityName = "Player"
--         if event.sourceType == 1 and event.sourceName ~= "" then
--             entityName = event.sourceName  -- Pet name
--         elseif event.sourceType == 2 and event.sourceName ~= "" then
--             entityName = event.sourceName .. " (Guardian)"
--         end
--         
--         if not entities[entityName] then
--             entities[entityName] = {
--                 total = 0,
--                 count = 0,
--                 crits = 0
--             }
--         end
--         
--         local entity = entities[entityName]
--         entity.total = entity.total + event.amount
--         entity.count = entity.count + 1
--         if event.isCrit then
--             entity.crits = entity.crits + 1
--         end
--     end
--     
--     return entities
-- end

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