# Rolling Window Plot Feature Plan (Simplified)

## Overview
Add a real-time scrolling plot window that visualizes DPS/HPS metrics over time by querying existing accumulator data.

## Architecture

### 1. Core Components

#### MetricsPlot.lua (Standalone Plot Window)
```lua
-- Lightweight plot window that queries accumulators
addon.MetricsPlot = {
    -- Configuration
    width = 400,
    height = 200,
    backgroundColor = {0.1, 0.1, 0.1, 0.9},
    gridColor = {0.3, 0.3, 0.3, 0.5},
    
    -- Plot settings
    timeWindow = 60,      -- Show last 60 seconds
    sampleRate = 1,       -- Sample every 1 second
    updateRate = 0.25,    -- Refresh plot at 4 FPS
    
    -- Texture pooling for performance
    texturePool = {},
    maxTextures = 200,
    
    -- Y-axis auto-scaling
    autoScale = true,
    maxValue = 100000
}
```

### 2. Data Flow (Simplified)

1. **Direct Accumulator Queries**
   ```lua
   function MetricsPlot:UpdateData()
       -- Query accumulators directly
       local now = addon.TimingManager:GetCurrentRelativeTime()
       local startTime = now - self.timeWindow
       
       -- Get DPS data points from accumulator's rolling window
       self.dpsPoints = self:SampleAccumulatorData(
           addon.DamageAccumulator.rollingData.values,
           startTime, now, self.sampleRate
       )
       
       -- Get HPS data points
       self.hpsPoints = self:SampleAccumulatorData(
           addon.HealingAccumulator.rollingData.values,
           startTime, now, self.sampleRate
       )
   end
   ```

2. **Sampling Method**
   ```lua
   function MetricsPlot:SampleAccumulatorData(rollingData, startTime, endTime, sampleRate)
       local points = {}
       local currentTime = startTime
       
       while currentTime <= endTime do
           local windowEnd = currentTime
           local windowStart = currentTime - 5  -- 5s rolling window
           local sum = 0
           
           -- Sum values in this sample's window
           for timestamp, value in pairs(rollingData) do
               if timestamp >= windowStart and timestamp <= windowEnd then
                   sum = sum + value
               end
           end
           
           table.insert(points, {
               time = currentTime,
               value = sum / 5  -- DPS/HPS
           })
           
           currentTime = currentTime + sampleRate
       end
       
       return points
   end
   ```

3. **Rendering Pipeline**
   - Timer-based updates (not per frame)
   - Query accumulators on timer tick
   - Draw grid, axes, labels
   - Draw plot lines using texture pool

### 3. Performance Optimizations

1. **Texture Pooling**
   ```lua
   function PlotWindow:GetLineTexture()
       local texture = table.remove(self.texturePool)
       if not texture then
           texture = self.frame:CreateTexture(nil, "ARTWORK")
       end
       return texture
   end
   ```

2. **Batch Updates**
   - Collect multiple data points
   - Update plot on timer tick
   - Minimize texture operations

3. **Smart Scaling**
   - Only recalculate scale when max value changes significantly
   - Cache axis label positions
   - Pre-calculate pixel-per-value ratio

### 4. UI Features

1. **Interactive Elements**
   - Time window selector (30s/60s/120s)
   - Pause/resume button
   - Clear data button
   - Toggle DPS/HPS visibility

2. **Visual Design**
   - Dark background with grid
   - Colored lines for each metric
   - Current value display
   - Peak value markers
   - Time axis labels

3. **Layout**
   ```
   ┌─────────────────────────────────────┐
   │ DPS: 45.2k  HPS: 12.3k   [30s|60s|120s] │
   ├─────────────────────────────────────┤
   │ 100k ┤                              │
   │      │    ╱╲    ╱╲                  │
   │  50k ┤   ╱  ╲  ╱  ╲                 │
   │      │  ╱    ╲╱    ╲                │
   │   0k └──────────────────────────────┤
   │      Now                        -60s │
   └─────────────────────────────────────┘
   ```

### 5. Integration Points

1. **MeterManager Registration**
   ```lua
   addon.MeterManager:RegisterMeter("Plot", nil, addon.MetricsPlot)
   ```

2. **Direct Accumulator Access**
   ```lua
   -- No EventBus needed - just query accumulators directly
   local dpsData = addon.DamageAccumulator.rollingData.values
   local hpsData = addon.HealingAccumulator.rollingData.values
   ```

3. **Slash Commands**
   - `/stormy plot` - Toggle plot window
   - `/stormy plot 30` - Set 30s window
   - `/stormy plot pause` - Pause updates

### 6. Implementation Steps

1. **Phase 1: Basic Plot Window**
   - Create MetricsPlot window frame
   - Implement texture pooling
   - Add timer for periodic updates

2. **Phase 2: Data Sampling**
   - Query accumulator rolling data
   - Sample at fixed intervals
   - Handle missing/sparse data

3. **Phase 3: Rendering**
   - Draw grid and axes
   - Plot lines from sampled data
   - Add auto-scaling

4. **Phase 4: Polish**
   - Add interactive controls
   - Implement time window selection
   - Add visual effects

### 7. Performance Targets

- Memory: No additional data storage (uses existing accumulators)
- CPU: < 0.5% usage during normal operation
- Update rate: 4 FPS (configurable)
- Zero memory allocations in render loop

### 8. Future Enhancements

- Multiple plot types (stacked, percentage)
- Damage type breakdown
- Spell-specific tracking
- Export data to CSV
- Comparison mode (multiple attempts)