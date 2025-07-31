-- EventDetailWindow.lua
-- Shared event detail popup window for DPS/HPS plots

local addonName, addon = ...

-- =============================================================================
-- EVENT DETAIL WINDOW MODULE
-- =============================================================================

addon.EventDetailWindow = {}
local EventDetailWindow = addon.EventDetailWindow

-- Configuration
local WINDOW_CONFIG = {
    width = 320,
    height = 200,
    titleHeight = 20,
    padding = 10,
    lineHeight = 16,
    backgroundColor = {0, 0, 0, 0.9},
    borderColor = {0.3, 0.3, 0.3, 1},
    titleColor = {1, 1, 0.5, 1},
    textColor = {1, 1, 1, 1},
    spellTextColor = {0.8, 0.8, 0.8, 1}
}

-- Singleton instance
local instance = nil

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

function EventDetailWindow:GetInstance()
    if not instance then
        instance = self:Create()
    end
    return instance
end

function EventDetailWindow:Create()
    local window = {
        frame = nil,
        titleText = nil,
        closeButton = nil,
        content = nil,
        contentLines = {},
        isVisible = false,
        currentPlotType = nil
    }
    
    -- Copy methods to instance
    for k, v in pairs(self) do
        if type(v) == "function" and k ~= "Create" and k ~= "GetInstance" then
            window[k] = v
        end
    end
    
    -- Create the frame
    window:CreateFrame()
    
    return window
end

-- =============================================================================
-- FRAME CREATION
-- =============================================================================

function EventDetailWindow:CreateFrame()
    -- Main frame
    self.frame = CreateFrame("Frame", "StormyEventDetailWindow", UIParent, "BackdropTemplate")
    self.frame:SetSize(WINDOW_CONFIG.width, WINDOW_CONFIG.height)
    self.frame:SetFrameStrata("DIALOG")
    self.frame:SetClampedToScreen(true)
    self.frame:EnableMouse(true)
    self.frame:SetMovable(true)
    
    -- Backdrop
    self.frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets = {left = 4, right = 4, top = 4, bottom = 4}
    })
    self.frame:SetBackdropColor(unpack(WINDOW_CONFIG.backgroundColor))
    self.frame:SetBackdropBorderColor(unpack(WINDOW_CONFIG.borderColor))
    
    -- Title bar
    local titleBar = CreateFrame("Frame", nil, self.frame)
    titleBar:SetPoint("TOPLEFT", 4, -4)
    titleBar:SetPoint("TOPRIGHT", -4, -4)
    titleBar:SetHeight(WINDOW_CONFIG.titleHeight)
    titleBar:EnableMouse(true)
    
    -- Make window draggable by title bar
    titleBar:SetScript("OnMouseDown", function(frame, button)
        if button == "LeftButton" then
            self.frame:StartMoving()
        end
    end)
    titleBar:SetScript("OnMouseUp", function()
        self.frame:StopMovingOrSizing()
    end)
    
    -- Title text
    self.titleText = titleBar:CreateFontString(nil, "OVERLAY")
    self.titleText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    self.titleText:SetPoint("LEFT", titleBar, "LEFT", 5, 0)
    self.titleText:SetText("Event Details")
    self.titleText:SetTextColor(unpack(WINDOW_CONFIG.titleColor))
    
    -- Close button
    self.closeButton = CreateFrame("Button", nil, titleBar)
    self.closeButton:SetSize(16, 16)
    self.closeButton:SetPoint("RIGHT", titleBar, "RIGHT", -5, 0)
    self.closeButton:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    self.closeButton:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    self.closeButton:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
    self.closeButton:SetScript("OnClick", function()
        self:Hide()
    end)
    
    -- Content area
    self.content = CreateFrame("Frame", nil, self.frame)
    self.content:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 5, -5)
    self.content:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -5, 5)
    
    -- Initially hidden
    self.frame:Hide()
end

-- =============================================================================
-- CONTENT POPULATION
-- =============================================================================

function EventDetailWindow:Show(plotType, timestamp, summary, events, plotFrame)
    self.currentPlotType = plotType
    
    -- Position relative to plot frame
    self:PositionRelativeToPlot(plotFrame)
    
    -- Clear existing content
    self:ClearContent()
    
    -- Populate new content
    self:PopulateContent(timestamp, summary, events)
    
    -- Show the window
    self.frame:Show()
    self.isVisible = true
end

function EventDetailWindow:Hide()
    self.frame:Hide()
    self.isVisible = false
    self.currentPlotType = nil
end

function EventDetailWindow:PositionRelativeToPlot(plotFrame)
    if not plotFrame then return end
    
    -- Clear existing positioning
    self.frame:ClearAllPoints()
    
    -- Position above the plot, centered horizontally
    local plotLeft = plotFrame:GetLeft() or 0
    local plotTop = plotFrame:GetTop() or 0
    local plotWidth = plotFrame:GetWidth() or 380
    
    -- Center above the plot with vertical margin
    local windowWidth = WINDOW_CONFIG.width
    local left = plotLeft + (plotWidth - windowWidth) / 2
    local top = plotTop + 20  -- 20px above the plot
    
    -- Ensure it stays on screen
    left = math.max(20, math.min(left, UIParent:GetWidth() - windowWidth - 20))
    top = math.min(top, UIParent:GetHeight() - WINDOW_CONFIG.height)
    
    self.frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, top)
end

function EventDetailWindow:ClearContent()
    -- Hide all existing lines
    for _, line in ipairs(self.contentLines) do
        line:Hide()
    end
end

function EventDetailWindow:CreateContentLine()
    local line = self.content:CreateFontString(nil, "OVERLAY")
    line:SetFont("Fonts\\FRIZQT__.TTF", 12)
    line:SetJustifyH("LEFT")
    line:SetTextColor(unpack(WINDOW_CONFIG.textColor))
    table.insert(self.contentLines, line)
    return line
end

function EventDetailWindow:GetOrCreateLine(index)
    if self.contentLines[index] then
        return self.contentLines[index]
    end
    return self:CreateContentLine()
end

function EventDetailWindow:PopulateContent(timestamp, summary, events)
    local lineIndex = 1
    local yOffset = -5
    
    -- Time ago
    local now = addon.TimingManager and addon.TimingManager:GetCurrentRelativeTime() or GetTime()
    local timeAgo = math.floor(now - timestamp)
    local line = self:GetOrCreateLine(lineIndex)
    line:SetText(string.format("%d seconds ago", timeAgo))
    line:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, yOffset)
    line:Show()
    lineIndex = lineIndex + 1
    yOffset = yOffset - WINDOW_CONFIG.lineHeight - 5
    
    -- Total damage/healing
    if summary and summary.totalDamage > 0 then
        line = self:GetOrCreateLine(lineIndex)
        line:SetText(string.format("Total: %s (%d hits, %d crits)", 
            self:FormatNumberHumanized(summary.totalDamage),
            summary.eventCount or 0,
            summary.critCount or 0))
        line:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, yOffset)
        line:Show()
        lineIndex = lineIndex + 1
        yOffset = yOffset - WINDOW_CONFIG.lineHeight
        
        -- Crit percentage
        if summary.critCount and summary.critCount > 0 then
            local critPct = (summary.critCount / summary.eventCount) * 100
            local critDmgPct = (summary.critDamage / summary.totalDamage) * 100
            line = self:GetOrCreateLine(lineIndex)
            line:SetText(string.format("Crits: %.0f%% of hits, %.0f%% of damage", critPct, critDmgPct))
            line:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, yOffset)
            line:Show()
            lineIndex = lineIndex + 1
            yOffset = yOffset - WINDOW_CONFIG.lineHeight - 5
        end
    end
    
    -- Spell breakdown header
    line = self:GetOrCreateLine(lineIndex)
    line:SetText("Spell Breakdown:")
    line:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, yOffset)
    line:Show()
    lineIndex = lineIndex + 1
    yOffset = yOffset - WINDOW_CONFIG.lineHeight
    
    -- Spell details
    if summary and summary.spells then
        local sortedSpells = self:SortSpellsByDamage(summary.spells, summary.totalDamage)
        
        for i, spellData in ipairs(sortedSpells) do
            if i > 5 then break end  -- Show top 5 spells
            
            line = self:GetOrCreateLine(lineIndex)
            line:SetText(spellData.text)
            line:SetTextColor(unpack(WINDOW_CONFIG.spellTextColor))
            line:SetPoint("TOPLEFT", self.content, "TOPLEFT", 20, yOffset)
            line:Show()
            lineIndex = lineIndex + 1
            yOffset = yOffset - WINDOW_CONFIG.lineHeight
        end
    end
    
    -- Adjust frame height based on content
    local contentHeight = math.abs(yOffset) + 10
    local totalHeight = WINDOW_CONFIG.titleHeight + contentHeight + 20
    self.frame:SetHeight(totalHeight)
end

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================

function EventDetailWindow:FormatNumberHumanized(value)
    if value >= 1e9 then
        return string.format("%.2fB", value / 1e9)
    elseif value >= 1e6 then
        return string.format("%.1fM", value / 1e6)
    elseif value >= 1e3 then
        return string.format("%.0fK", value / 1e3)
    else
        return string.format("%d", value)
    end
end

function EventDetailWindow:SortSpellsByDamage(spells, totalDamage)
    local sorted = {}
    
    for spellId, spellInfo in pairs(spells) do
        local name = addon.SpellCache:GetSpellName(spellId) or "Unknown"
        local damage = spellInfo.damage or 0
        local hits = spellInfo.count or 0
        local crits = spellInfo.crits or 0
        local pct = totalDamage > 0 and (damage / totalDamage * 100) or 0
        
        local text = string.format("%s: %s (%.0f%%) ~ %d hits", 
            name, 
            self:FormatNumberHumanized(damage), 
            pct, 
            hits)
        
        if crits > 0 then
            local critPct = (crits / hits) * 100
            text = text .. string.format(", %.0f%% crit", critPct)
        end
        
        table.insert(sorted, {
            damage = damage,
            text = text
        })
    end
    
    -- Sort by damage descending
    table.sort(sorted, function(a, b) return a.damage > b.damage end)
    
    return sorted
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

function EventDetailWindow:IsVisible()
    return self.isVisible
end

function EventDetailWindow:GetCurrentPlotType()
    return self.currentPlotType
end