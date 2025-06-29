# STORMY Development Roadmap

## Overview
This roadmap outlines the planned features and improvements for STORMY, a high-performance damage tracking addon for World of Warcraft. The roadmap is organized by release versions with estimated timelines.

## Current Status: v1.0.0 (Released)
✅ Core damage tracking functionality  
✅ Real-time DPS calculations with rolling windows  
✅ Pet and guardian detection  
✅ Circuit breaker protection  
✅ Basic damage meter UI  
✅ Slash commands for control  

## Version 1.1.0 - Foundation & Documentation (Q3 2025)
**Theme:** Making STORMY accessible and maintainable

### High Priority
- [ ] **Comprehensive README.md**
  - Installation instructions
  - Feature overview with screenshots
  - Basic usage guide
  - Troubleshooting section
  
- [ ] **GitHub Actions Workflow**
  - Automated testing pipeline
  - Release automation
  - Version tagging
  - Automatic changelog generation

### Medium Priority
- [ ] **Unit Test Framework**
  - Tests for TablePool memory management
  - EventBus message passing tests
  - RingBuffer boundary tests
  - Mock combat log events for testing

## Version 1.2.0 - Enhanced User Experience (Q4 2025)
**Theme:** Making STORMY more user-friendly

### High Priority
- [ ] **In-Game Configuration UI**
  - Settings panel integration
  - Visual customization options
  - Performance tuning sliders
  - Import/export settings

### Medium Priority
- [ ] **Damage Breakdown Features**
  - Damage by spell/ability
  - Damage type distribution (Physical/Magic)
  - Critical strike statistics
  - Hit/miss tracking

- [ ] **Enhanced UI Options**
  - Multiple display modes (bars/text/minimal)
  - Customizable colors and fonts
  - Window locking/unlocking
  - Transparency controls

## Version 1.3.0 - Advanced Features (Q1 2026)
**Theme:** Power user features and analysis tools

### Medium Priority
- [ ] **Combat Segments**
  - Automatic encounter detection
  - Per-pull statistics
  - Boss fight analysis
  - Trash vs boss damage separation

- [ ] **Data Export System**
  - CSV export for spreadsheets
  - JSON export for analysis tools
  - Combat log integration
  - Shareable damage reports

### Low Priority
- [ ] **Profile System**
  - Per-character settings
  - Per-spec configurations
  - Quick profile switching
  - Profile sharing via import/export

## Version 1.4.0 - Performance & Scaling (Q2 2026)
**Theme:** Optimization for all content types

### High Priority
- [ ] **Mythic+ Optimizations**
  - Dynamic scaling for high key levels
  - Pull detection and segmentation
  - Death tracking integration
  - Interrupt tracking

### Medium Priority
- [ ] **Raid Performance Mode**
  - Ultra-low overhead mode
  - Raid-wide performance metrics
  - Boss phase detection
  - Mechanic failure correlation

## Version 2.0.0 - Major Expansion (Q3 2026)
**Theme:** Expanding beyond damage tracking

### Future Considerations
- [ ] **Healing Tracking Module**
  - HPS calculations
  - Overhealing analysis
  - Absorption tracking

- [ ] **Tanking Metrics**
  - Damage taken analysis
  - Mitigation effectiveness
  - Threat tracking

- [ ] **API for Other Addons**
  - Public data access
  - Event hooks
  - Integration examples

## Development Principles

### Performance First
- Every feature must maintain the zero-allocation principle
- No feature should impact frame rate
- Circuit breaker protection for all new systems

### User Experience
- Features should be discoverable
- Defaults should work for 90% of users
- Advanced options available but not required

### Code Quality
- Comprehensive testing for new features
- Documentation for all public APIs
- Consistent code style and patterns

## Contributing
Want to help? Check out:
1. Open issues labeled "good first issue"
2. The developer documentation (coming in v1.1.0)
3. Join discussions in the issues section

## Version History
- **v1.0.0** (2025-06-28): Initial release with core functionality

---

*This roadmap is subject to change based on user feedback and technical constraints. Features may be moved between versions or modified as development progresses.*