# Rolling Window Plot Feature Plan

## Overview
Add a real-time scrolling plot window that visualizes DPS/HPS metrics over time, with data points moving from right to left.

## Architecture

### 1. Core Components

#### PlotWindow.lua (Base Class)
```lua
-- Base class for plot visualization
addon.PlotWindow = {
    -- Configuration
    width = 400,
    height = 200,
    backgroundColor = {0.1, 0.1, 0.1, 0.9},
    gridColor = {0.3, 0.3, 0.3, 0.5},
    
    -- Data management
    maxDataPoints = 120,  -- 2 minutes at 1 update/sec
    dataBuffer = {},      -- Circular buffer
    
    -- Performance
    updateRate = 0.25,    -- 4 FPS update rate
    texturePool = {}      -- Reuse textures
}
```

#### MetricsPlot.lua (DPS/HPS Implementation)
```lua
-- Extends PlotWindow for metrics plotting
addon.MetricsPlot = {
    -- Plot both DPS and HPS
    metrics = {
        dps = { color = {1, 0.2, 0.2, 1}, data = {} },
        hps = { color = {0.2, 1, 0.2, 1}, data = {} }
    },
    
    -- Y-axis auto-scaling
    autoScale = true,
    maxValue = 100000,
    
    -- Time window options
    timeWindows = { 30, 60, 120 },
    currentWindow = 60
}
```

### 2. Data Flow

1. **Event Bus Integration**
   - Subscribe to "METRIC_UPDATE" events
   - Receive DPS/HPS updates from accumulators
   - Timestamp each data point

2. **Circular Buffer Management**
   ```lua
   function MetricsPlot:AddDataPoint(metric, value)
       local point = {
           timestamp = GetTime(),
           value = value
       }
       
       -- Circular buffer logic
       local buffer = self.metrics[metric].data
       buffer[self.writeIndex] = point
       self.writeIndex = (self.writeIndex % self.maxDataPoints) + 1
   end
   ```

3. **Rendering Pipeline**
   - Update only on timer (not every frame)
   - Calculate visible data range
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

2. **EventBus Subscription**
   ```lua
   addon.EventBus:Subscribe("METRIC_UPDATE", function(data)
       if data.metric == "DPS" then
           metricsPlot:AddDataPoint("dps", data.value)
       elseif data.metric == "HPS" then
           metricsPlot:AddDataPoint("hps", data.value)
       end
   end)
   ```

3. **Slash Commands**
   - `/stormy plot` - Toggle plot window
   - `/stormy plot 30` - Set 30s window
   - `/stormy plot pause` - Pause updates

### 6. Implementation Steps

1. **Phase 1: Base Infrastructure**
   - Create PlotWindow base class
   - Implement texture pooling
   - Add basic frame and drawing

2. **Phase 2: Data Management**
   - Implement circular buffer
   - Add EventBus integration
   - Handle data point storage

3. **Phase 3: Rendering**
   - Draw grid and axes
   - Implement line drawing
   - Add auto-scaling

4. **Phase 4: Polish**
   - Add interactive controls
   - Implement smooth scrolling
   - Add visual effects

### 7. Performance Targets

- Memory: < 500KB for 2 minutes of data
- CPU: < 1% usage during normal operation
- Update rate: 4 FPS (configurable)
- Latency: < 250ms from event to visual update

### 8. Future Enhancements

- Multiple plot types (stacked, percentage)
- Damage type breakdown
- Spell-specific tracking
- Export data to CSV
- Comparison mode (multiple attempts)