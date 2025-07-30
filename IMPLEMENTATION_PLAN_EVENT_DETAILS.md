# Event Detail Breakdown Feature Implementation Plan

## Overview
This document outlines the implementation plan for adding event detail breakdown functionality to the STORMY addon's DPS/HPS plots. Users will be able to click on any bar in the plot to see a detailed breakdown of events that contributed to that second's value.

## Branch
- Working branch: `feature/ui-optimization-improvements`
- Created from: `main`

## Feature Requirements
1. Click on any bar in the DPS/HPS plot to see event details
2. Auto-pause when clicking, with visual overlay showing paused state
3. Continue collecting data while paused (ring buffer with 180s retention)
4. Show spell breakdown, entity breakdown (including pets), and summary stats
5. Visual feedback using HSL color system for selection and magnitude

## Implementation Components

### 1. Event Detail Storage System

#### 1.1 Data Structure (MeterAccumulator.lua)
```lua
rollingData = {
    -- Existing
    values = {},
    events = {},
    
    -- NEW: Ring buffer for detailed events
    detailBuffer = {
        buffer = {},      -- Pre-allocated array
        size = 9000,      -- Configurable based on content type
        head = 1,         -- Next write position
        tail = 1,         -- Oldest data position
        count = 0,        -- Current number of items
        timeIndex = {},   -- [flooredTimestamp] = {startIdx, endIdx}
    },
    
    -- Per-second summaries
    secondSummaries = {},  -- [timestamp] = summary table from pool
}
```

#### 1.2 Event Detail Structure
```lua
eventDetail = {
    timestamp = 0,      -- Precise timestamp
    amount = 0,
    spellId = 0,        -- Store ID only (not name)
    sourceGUID = "",    -- Source entity GUID
    sourceName = "",    -- Pet name for pet events
    sourceType = 0,     -- 0=player, 1=pet, 2=guardian
    isCrit = false,
}
```

### 2. Table Pool Extensions

#### 2.1 New Templates (TablePool.lua)
Add these templates to the TEMPLATES table:
```lua
eventDetail = {
    timestamp = 0,
    amount = 0,
    spellId = 0,
    sourceGUID = "",
    sourceName = "",
    sourceType = 0,
    isCrit = false,
},
secondSummary = {
    timestamp = 0,
    totalDamage = 0,
    eventCount = 0,
    critCount = 0,
    critDamage = 0,    -- NEW: Track total damage from crits
    spells = {},       -- Reused table, cleared on release
}
```

#### 2.2 Pool Configuration
Add new pool type with larger size:
```lua
POOL_CONFIG = {
    EVENT_POOL_SIZE = 50,
    CALC_POOL_SIZE = 20,
    UI_POOL_SIZE = 10,
    DETAIL_POOL_SIZE = 200,    -- NEW: For event details
    SUMMARY_POOL_SIZE = 60     -- NEW: For second summaries
}
```

### 3. Spell Cache System (New Module)

#### 3.1 Create Core/SpellCache.lua
```lua
-- Caches spell names with lazy loading
-- Handles spell rank grouping
-- Manages entity name caching
```

Key features:
- LRU cache with 500 spell limit
- Spell rank consolidation (remove "Rank X" suffixes)
- Pet/guardian name tracking
- O(1) lookup performance

### 4. Ring Buffer Implementation

#### 4.1 Configurable Sizing (Constants.lua)
```lua
Constants.DETAIL_BUFFER = {
    SIZES = {
        SOLO = 3000,      -- Solo content
        DUNGEON = 6000,   -- 5-man content
        RAID = 12000,     -- Raid content
        MYTHIC = 24000,   -- Mythic raid
        CUSTOM = 9000     -- User defined
    },
    AUTO_THRESHOLDS = {
        SOLO = 5,         -- events/sec
        DUNGEON = 15,
        RAID = 30,
    }
}
```

#### 4.2 Core Methods (MeterAccumulator.lua)
- `InitializeDetailBuffer()` - Pre-allocate all tables
- `AddDetailedEvent()` - Add event to ring buffer
- `GetSecondDetails()` - Retrieve events for a specific second
- `CleanupOldTimeIndex()` - Maintain time index

### 5. UI Components

#### 5.1 Click Detection (MetricsPlot.lua)
- Add mouse event handlers to plot frame
- Convert screen coordinates to data coordinates
- Identify clicked bar by timestamp

#### 5.2 Auto-Pause System
States:
- LIVE - Normal scrolling updates
- PAUSED - Frozen display, data collection continues
- REPLAY - Future enhancement

Visual feedback:
- Semi-transparent overlay (0.3 alpha black)
- "PAUSED - Data collection continues" text
- Resume button in top-right

#### 5.3 Detail Popup Window
Components:
- Floating frame positioned near clicked bar
- Header with timestamp and totals
- Spell breakdown (top 10 spells)
- Entity breakdown (player + each pet)
- Close button or click-away to dismiss

### 6. Visual Feedback System

#### 6.1 Simplified Color System
```lua
-- Base colors remain constant (red for DPS, green for HPS)
-- Selection state: Full color for selected, 50% dimmed for unselected
-- No brightness/lightness changes (bar height shows magnitude)
```

#### 6.2 Critical Hit Glow
- Threshold: 30% of damage from crits (fixed)
- Glow intensity: Scaled by (critRate * normalizedMagnitude)
- Visual: Soft glow behind bar, 40% alpha max
- Formula: `glowAlpha = (critRate - 0.3) * (value/maxValue) * 0.4`

#### 6.3 Implementation Code
```lua
function MetricsPlot:GetBarColor(point, isSelected)
    -- Use existing color constants
    local r, g, b = unpack(self.config.dpsColor)  -- or hpsColor
    
    -- Dim unselected bars when something is selected
    if not isSelected and self.plotState.selectedTimestamp then
        r, g, b = r * 0.5, g * 0.5, b * 0.5
    end
    
    return r, g, b, 1.0
end

function MetricsPlot:ShouldShowGlow(point)
    local CRIT_THRESHOLD = 0.3  -- 30% threshold
    local critRate = point.critDamage and (point.critDamage / point.value) or 0
    return critRate > CRIT_THRESHOLD, critRate
end

function MetricsPlot:CalculateGlowIntensity(critRate, value, maxValue)
    -- Only calculate for bars above threshold
    if critRate <= 0.3 then return 0 end
    
    -- Scale by how much above threshold and magnitude
    local critFactor = (critRate - 0.3) / 0.7  -- Normalize 30%-100% to 0-1
    local magnitudeFactor = value / maxValue
    
    -- Maximum alpha of 0.4, scaled by both factors
    return critFactor * magnitudeFactor * 0.4
end
```

#### 6.4 Detail View Colors
- Spell breakdown uses variations of main color
- Each spell gets slightly different brightness (0.8x to 1.2x)
- Maintains visual connection to main plot color

### 7. Modified Event Flow

#### 7.1 EventProcessor Changes
Current flow:
```
CombatLogEvent -> ProcessDamageEvent -> MeterManager -> Accumulator
```

New flow:
```
CombatLogEvent -> ProcessDamageEvent -> MeterManager -> Accumulator
                                                     -> AddDetailedEvent (NEW)
```

#### 7.2 Data Passed to Accumulator
Add to existing AddEvent call:
- spellId
- spellName (removed - lookup by ID instead)
- sourceGUID
- Entity type (player/pet/guardian)

### 8. Performance Considerations

#### 8.1 Memory Budget
- Ring buffer: 1-2.4MB depending on content type
- Spell cache: ~100KB
- Second summaries: ~50KB
- Total overhead: <3MB worst case

#### 8.2 CPU Budget
- Ring buffer write: O(1)
- Detail lookup: O(n) where n ≈ 50-100 events
- Render overhead: <5ms per frame
- Maintains 4 FPS update target

### 9. Implementation Order

1. **Phase 1: Core Data Structures**
   - [ ] Extend TablePool with new templates
   - [ ] Create SpellCache module
   - [ ] Add ring buffer to MeterAccumulator

2. **Phase 2: Event Collection**
   - [ ] Modify EventProcessor to pass spell/entity data
   - [ ] Implement AddDetailedEvent in accumulators
   - [ ] Add configurable buffer sizing

3. **Phase 3: UI Click Detection**
   - [ ] Add mouse handlers to MetricsPlot
   - [ ] Implement coordinate conversion
   - [ ] Create selection state management

4. **Phase 4: Detail Display**
   - [ ] Create detail popup frame
   - [ ] Implement data aggregation for display
   - [ ] Add spell rank grouping
   - [ ] Add pet entity grouping

5. **Phase 5: Visual Feedback**
   - [ ] Implement HSL color system
   - [ ] Add selection highlighting
   - [ ] Add crit glow effects
   - [ ] Create pause overlay

6. **Phase 6: Polish & Testing**
   - [ ] Performance profiling
   - [ ] Memory leak testing
   - [ ] Edge case handling
   - [ ] User settings integration

### 10. Testing Plan

#### 10.1 Unit Tests
- Ring buffer wraparound
- Spell cache LRU eviction
- Time index maintenance
- Pool allocation/release

#### 10.2 Integration Tests
- Click detection accuracy
- Pause/resume state transitions
- Data consistency during pause
- Memory growth over time

#### 10.3 Performance Tests
- Event rate stress test (100+ events/sec)
- Memory usage monitoring
- Frame rate impact measurement
- Cache hit rate analysis

### 11. Future Enhancements
- Export clicked data to CSV
- Multi-bar selection for comparison
- Replay mode with scrubbing
- Filtering by spell/entity
- Integration with main meter windows

## Notes
- Maintain zero-allocation philosophy where possible
- Ensure all new features respect the 4 FPS update rate
- Consider adding debug commands for testing
- Document any deviations from original design

## Status
- Created: 2025-01-30
- Last Updated: 2025-01-30
- Status: Planning Complete, Ready for Implementation