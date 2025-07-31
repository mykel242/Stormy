# STORMY Performance Test Suite

Comprehensive performance testing for the STORMY addon to ensure optimal performance under various load conditions.

## Overview

The performance test suite evaluates:
- **Event Processing**: Burst and sustained combat event throughput
- **Memory Usage**: Memory leak detection and growth monitoring  
- **UI Performance**: Render performance and hover responsiveness
- **Stress Testing**: Mythic+ dungeon simulation with high event loads

## Usage

### Slash Commands

Run tests using the `/stormyperf` command:

```
/stormyperf all        # Run complete test suite (recommended)
/stormyperf burst      # Test event processing burst capacity
/stormyperf sustained  # Test sustained event processing
/stormyperf memory     # Monitor memory usage over time
/stormyperf ui         # Test UI render and hover performance
/stormyperf stress     # Run mythic+ stress test simulation
/stormyperf report     # Show results from last test run
/stormyperf help       # Show command help
```

### Test Duration

- **Full Suite**: ~6-7 minutes total
- **Individual Tests**: 30 seconds - 5 minutes each
- **Stress Test**: 5 minutes (simulates full mythic+ encounter)

## Test Details

### Event Processing Tests

**Burst Test**
- Processes 100 events as fast as possible
- Measures events/second throughput and memory usage
- **Target**: >1000 events/second, <1KB memory per event

**Sustained Test** 
- Processes 50 events/second for 30 seconds
- Measures processing latency and consistency
- **Target**: <1ms average processing time

### Memory Usage Test

- Monitors memory growth over 60 seconds
- Detects memory leaks and excessive allocation
- **Target**: <1KB/second leak rate

### UI Performance Tests

**Render Test**
- Times 100 consecutive render cycles
- **Target**: <5ms average render time (200+ FPS equivalent)

**Hover Test**
- Times 50 hover state changes with re-renders
- **Target**: <2ms hover response time

### Stress Test (Mythic+ Simulation)

- Simulates 5-minute mythic+ encounter
- 40 events/second baseline + 80 events/second bursts every 10s
- Tests sustained performance under realistic high-load conditions
- **Targets**: 
  - Memory growth <10MB
  - Processing time <1ms average
  - Throughput >95% of target rate

## Performance Targets

### Acceptable Performance
- Event processing: >500 events/second
- Memory leak: <2KB/second
- UI render: <10ms average
- Stress test: All targets within 150% of ideal

### Excellent Performance  
- Event processing: >1000 events/second
- Memory leak: <0.5KB/second
- UI render: <5ms average
- Stress test: All targets met

### Performance Issues
- Event processing: <200 events/second
- Memory leak: >5KB/second  
- UI render: >20ms average
- Stress test: Any target >200% of ideal

## Interpreting Results

Results are displayed in chat with summary statistics:

```
[PERF] Burst test completed: 1250 events/sec, 0.45 KB memory delta
[PERF] Sustained test completed: 1180 events, 49.2 avg events/sec
[PERF] Processing time: 0.654 ms avg, 2.134 ms max
[PERF] Memory test completed: 12.34 KB total growth, 0.206 KB/sec leak rate
[PERF] UI render test completed: 3.421 ms avg, 292.4 FPS equivalent
[PERF] Hover test completed: 1.234 ms avg hover response
[PERF] Stress test completed: 11,847 events in 300s (39.5 events/sec)
[PERF] Memory growth: 8,234.56 KB, Processing: 0.789 ms avg
[PERF] Tests passed: Memory=PASS, Speed=PASS, Throughput=PASS
```

## Troubleshooting

### Common Issues

**High Memory Usage**
- Check for table pool leaks in Core/TablePool.lua
- Review ring buffer sizing in Combat/MeterAccumulator.lua
- Ensure proper cleanup in UI components

**Slow Event Processing**
- Review event filtering in Combat/EventProcessor.lua
- Check circuit breaker settings in Core/Constants.lua
- Optimize hot paths in accumulator classes

**Poor UI Performance**
- Check texture pool efficiency in UI/MetricsPlot.lua
- Review render frequency and update throttling
- Optimize bar drawing and hover highlighting

### Running Tests in Development

For development debugging, you can access detailed results:

```lua
local results = addon.PerformanceTests:GetResults()
-- Examine detailed statistics and samples
```

## Integration

The performance test suite is automatically loaded with the addon and available via slash commands. Tests run independently and don't interfere with normal addon operation.

For continuous integration or automated testing, the results can be programmatically accessed and evaluated against performance thresholds.