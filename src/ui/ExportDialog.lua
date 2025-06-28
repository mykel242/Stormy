-- ExportDialog.lua
-- Export functionality for external tools

local addonName, addon = ...

-- Export Dialog module
addon.ExportDialog = {}
local ExportDialog = addon.ExportDialog

-- State tracking
local isInitialized = false
local exportFrame = nil
local formatDropdown = nil
local optionsFrame = nil

-- Export formats
local EXPORT_FORMATS = {
    {
        id = "json",
        name = "JSON Format",
        description = "JavaScript Object Notation - compatible with most analysis tools",
        extension = "json"
    },
    {
        id = "csv",
        name = "CSV Format", 
        description = "Comma-Separated Values - compatible with Excel and spreadsheet tools",
        extension = "csv"
    },
    {
        id = "txt",
        name = "Text Format",
        description = "Human-readable text format for manual analysis",
        extension = "txt"
    },
    {
        id = "lua",
        name = "Lua Table",
        description = "Lua table format for addon developers",
        extension = "lua"
    }
}

-- Configuration
local CONFIG = {
    WINDOW_WIDTH = 450,
    WINDOW_HEIGHT = 350,
}

-- Initialize the export dialog
function ExportDialog:Initialize()
    if isInitialized then
        return
    end
    
    self:CreateExportDialog()
    isInitialized = true
    
    addon:Debug("ExportDialog initialized - ready for data export")
end

-- Create the export dialog window
function ExportDialog:CreateExportDialog()
    if exportFrame then
        return
    end
    
    -- Main frame using default WoW UI style
    local frame = CreateFrame("Frame", addonName .. "ExportDialog", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(CONFIG.WINDOW_WIDTH, CONFIG.WINDOW_HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER", 150, 50)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    
    -- Set title
    frame.TitleText:SetText("Export Combat Data")
    
    -- Close button behavior
    frame.CloseButton:SetScript("OnClick", function()
        self:Hide()
    end)
    
    -- === DATA SOURCE SELECTION ===
    local sourcePanel = CreateFrame("Frame", nil, frame)
    sourcePanel:SetSize(CONFIG.WINDOW_WIDTH - 30, 80)
    sourcePanel:SetPoint("TOP", frame, "TOP", 0, -35)
    
    local sourceTitle = sourcePanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    sourceTitle:SetPoint("TOPLEFT", sourcePanel, "TOPLEFT", 10, -5)
    sourceTitle:SetText("Data Source")
    
    -- Current combat radio button
    local currentCombatBtn = CreateFrame("CheckButton", nil, sourcePanel, "InterfaceOptionsCheckButtonTemplate")
    currentCombatBtn:SetPoint("TOPLEFT", sourcePanel, "TOPLEFT", 10, -25)
    currentCombatBtn.Text:SetText("Current Combat Session")
    currentCombatBtn:SetScript("OnClick", function()
        self:SetDataSource("current")
    end)
    
    -- All sessions radio button
    local allSessionsBtn = CreateFrame("CheckButton", nil, sourcePanel, "InterfaceOptionsCheckButtonTemplate")
    allSessionsBtn:SetPoint("TOPLEFT", currentCombatBtn, "BOTTOMLEFT", 0, -5)
    allSessionsBtn.Text:SetText("All Stored Sessions")
    allSessionsBtn:SetScript("OnClick", function()
        self:SetDataSource("all")
    end)
    
    -- Recent sessions radio button
    local recentSessionsBtn = CreateFrame("CheckButton", nil, sourcePanel, "InterfaceOptionsCheckButtonTemplate")
    recentSessionsBtn:SetPoint("TOPLEFT", allSessionsBtn, "BOTTOMLEFT", 0, -5)
    recentSessionsBtn.Text:SetText("Recent Sessions (Last 10)")
    recentSessionsBtn:SetScript("OnClick", function()
        self:SetDataSource("recent")
    end)
    
    -- Store radio button references
    frame.sourceButtons = {
        current = currentCombatBtn,
        all = allSessionsBtn,
        recent = recentSessionsBtn
    }
    
    -- Default to current combat
    currentCombatBtn:SetChecked(true)
    frame.selectedSource = "current"
    
    -- === FORMAT SELECTION ===
    local formatPanel = CreateFrame("Frame", nil, frame)
    formatPanel:SetSize(CONFIG.WINDOW_WIDTH - 30, 100)
    formatPanel:SetPoint("TOP", sourcePanel, "BOTTOM", 0, -10)
    
    local formatTitle = formatPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    formatTitle:SetPoint("TOPLEFT", formatPanel, "TOPLEFT", 10, -5)
    formatTitle:SetText("Export Format")
    
    -- Format dropdown
    local dropdown = CreateFrame("Frame", nil, formatPanel, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", formatPanel, "TOPLEFT", 0, -25)
    UIDropDownMenu_SetWidth(dropdown, 200)
    UIDropDownMenu_SetText(dropdown, EXPORT_FORMATS[1].name)
    
    UIDropDownMenu_Initialize(dropdown, function(self, level)
        for _, format in ipairs(EXPORT_FORMATS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = format.name
            info.value = format.id
            info.func = function()
                UIDropDownMenu_SetSelectedValue(dropdown, format.id)
                UIDropDownMenu_SetText(dropdown, format.name)
                ExportDialog:UpdateFormatDescription(format)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    
    -- Format description
    local formatDesc = formatPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    formatDesc:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 20, -10)
    formatDesc:SetWidth(CONFIG.WINDOW_WIDTH - 60)
    formatDesc:SetJustifyH("LEFT")
    formatDesc:SetText(EXPORT_FORMATS[1].description)
    frame.formatDescription = formatDesc
    
    formatDropdown = dropdown
    
    -- === EXPORT OPTIONS ===
    local optionsPanel = CreateFrame("Frame", nil, frame)
    optionsPanel:SetSize(CONFIG.WINDOW_WIDTH - 30, 60)
    optionsPanel:SetPoint("TOP", formatPanel, "BOTTOM", 0, -10)
    
    local optionsTitle = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    optionsTitle:SetPoint("TOPLEFT", optionsPanel, "TOPLEFT", 10, -5)
    optionsTitle:SetText("Options")
    
    -- Include metadata checkbox
    local metadataBtn = CreateFrame("CheckButton", nil, optionsPanel, "InterfaceOptionsCheckButtonTemplate")
    metadataBtn:SetPoint("TOPLEFT", optionsPanel, "TOPLEFT", 10, -25)
    metadataBtn.Text:SetText("Include Metadata (zone, group info, etc.)")
    metadataBtn:SetChecked(true)
    frame.includeMetadata = metadataBtn
    
    -- Compress output checkbox
    local compressBtn = CreateFrame("CheckButton", nil, optionsPanel, "InterfaceOptionsCheckButtonTemplate")
    compressBtn:SetPoint("TOPLEFT", metadataBtn, "BOTTOMLEFT", 0, -5)
    compressBtn.Text:SetText("Compress Output (remove whitespace)")
    compressBtn:SetChecked(false)
    frame.compressOutput = compressBtn
    
    optionsFrame = optionsPanel
    
    -- === ACTION BUTTONS ===
    local buttonPanel = CreateFrame("Frame", nil, frame)
    buttonPanel:SetSize(CONFIG.WINDOW_WIDTH - 30, 40)
    buttonPanel:SetPoint("BOTTOM", frame, "BOTTOM", 0, 15)
    
    -- Export button
    local exportBtn = CreateFrame("Button", nil, buttonPanel, "GameMenuButtonTemplate")
    exportBtn:SetSize(100, 25)
    exportBtn:SetPoint("RIGHT", buttonPanel, "RIGHT", -10, 0)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", function()
        self:PerformExport()
    end)
    
    -- Preview button
    local previewBtn = CreateFrame("Button", nil, buttonPanel, "GameMenuButtonTemplate")
    previewBtn:SetSize(100, 25)
    previewBtn:SetPoint("RIGHT", exportBtn, "LEFT", -10, 0)
    previewBtn:SetText("Preview")
    previewBtn:SetScript("OnClick", function()
        self:ShowPreview()
    end)
    
    -- Cancel button
    local cancelBtn = CreateFrame("Button", nil, buttonPanel, "GameMenuButtonTemplate")
    cancelBtn:SetSize(100, 25)
    cancelBtn:SetPoint("LEFT", buttonPanel, "LEFT", 10, 0)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function()
        self:Hide()
    end)
    
    exportFrame = frame
    
    addon:Debug("Export dialog window created")
end

-- Set data source selection
function ExportDialog:SetDataSource(source)
    if not exportFrame then
        return
    end
    
    -- Update radio buttons
    for key, button in pairs(exportFrame.sourceButtons) do
        button:SetChecked(key == source)
    end
    
    exportFrame.selectedSource = source
end

-- Update format description
function ExportDialog:UpdateFormatDescription(format)
    if exportFrame and exportFrame.formatDescription then
        exportFrame.formatDescription:SetText(format.description)
    end
end

-- Show the export dialog
function ExportDialog:Show()
    if not isInitialized then
        self:Initialize()
    end
    
    if exportFrame then
        exportFrame:Show()
        
        addon:Debug("Export dialog shown")
    end
end

-- Hide the export dialog
function ExportDialog:Hide()
    if exportFrame then
        exportFrame:Hide()
        
        addon:Debug("Export dialog hidden")
    end
end

-- Toggle visibility
function ExportDialog:Toggle()
    if exportFrame and exportFrame:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

-- Get selected export format
function ExportDialog:GetSelectedFormat()
    if formatDropdown then
        local selectedValue = UIDropDownMenu_GetSelectedValue(formatDropdown)
        for _, format in ipairs(EXPORT_FORMATS) do
            if format.id == selectedValue then
                return format
            end
        end
    end
    return EXPORT_FORMATS[1] -- Default to JSON
end

-- Get data to export based on source selection
function ExportDialog:GetExportData()
    if not exportFrame then
        return nil
    end
    
    local source = exportFrame.selectedSource
    local data = {}
    
    if source == "current" then
        -- Current combat session
        if addon.CombatEventLogger and addon.CombatEventLogger:IsTracking() then
            local events = addon.CombatEventLogger:GetCurrentEvents()
            local status = addon.CombatEventLogger:GetStatus()
            
            data = {
                type = "current_combat",
                combatId = status.currentCombatId,
                events = events,
                eventCount = #events,
                duration = status.combatDuration
            }
            
            if exportFrame.includeMetadata:GetChecked() and addon.MetadataCollector then
                data.metadata = addon.MetadataCollector:GetCurrentMetadata()
            end
        else
            data = {
                type = "current_combat",
                message = "No active combat session"
            }
        end
        
    elseif source == "all" then
        -- All stored sessions
        if addon.StorageManager then
            data = addon.StorageManager:ExportSessionsToTable()
            data.type = "all_sessions"
        else
            data = {
                type = "all_sessions",
                message = "StorageManager not available"
            }
        end
        
    elseif source == "recent" then
        -- Recent sessions
        if addon.StorageManager then
            local sessions = addon.StorageManager:GetRecentSessions(10)
            data = {
                type = "recent_sessions",
                sessions = sessions,
                sessionCount = #sessions
            }
            
            if exportFrame.includeMetadata:GetChecked() then
                data.exportMetadata = {
                    exportTime = GetServerTime(),
                    addonVersion = addon.VERSION
                }
            end
        else
            data = {
                type = "recent_sessions",
                message = "StorageManager not available"
            }
        end
    end
    
    return data
end

-- Format data according to selected format
function ExportDialog:FormatExportData(data, format)
    if format.id == "json" then
        return self:FormatAsJSON(data)
    elseif format.id == "csv" then
        return self:FormatAsCSV(data)
    elseif format.id == "txt" then
        return self:FormatAsText(data)
    elseif format.id == "lua" then
        return self:FormatAsLua(data)
    else
        return "Unknown format: " .. format.id
    end
end

-- Format as JSON (simplified implementation)
function ExportDialog:FormatAsJSON(data)
    -- Basic JSON-like formatting for WoW Lua
    local function serializeValue(value, indent)
        indent = indent or 0
        local spacing = string.rep("  ", indent)
        
        if type(value) == "table" then
            local result = "{\n"
            for k, v in pairs(value) do
                result = result .. spacing .. "  \"" .. tostring(k) .. "\": " .. serializeValue(v, indent + 1) .. ",\n"
            end
            result = result .. spacing .. "}"
            return result
        elseif type(value) == "string" then
            return "\"" .. value:gsub("\"", "\\\"") .. "\""
        elseif type(value) == "number" then
            return tostring(value)
        elseif type(value) == "boolean" then
            return value and "true" or "false"
        else
            return "\"" .. tostring(value) .. "\""
        end
    end
    
    return serializeValue(data)
end

-- Format as CSV (basic implementation)
function ExportDialog:FormatAsCSV(data)
    local lines = {"Event Type,Source,Destination,Timestamp,Args"}
    
    if data.events then
        for _, event in ipairs(data.events) do
            local line = string.format("%s,%s,%s,%.3f,%s",
                event.subevent or "",
                event.sourceName or "",
                event.destName or "",
                event.realTime or 0,
                event.args and table.concat(event.args, ";") or "")
            table.insert(lines, line)
        end
    end
    
    return table.concat(lines, "\n")
end

-- Format as readable text
function ExportDialog:FormatAsText(data)
    local lines = {"=== MyUI2 Combat Data Export ==="}
    table.insert(lines, "Export Time: " .. date("%Y-%m-%d %H:%M:%S"))
    table.insert(lines, "Data Type: " .. (data.type or "unknown"))
    table.insert(lines, "")
    
    if data.events then
        table.insert(lines, string.format("Combat Events (%d total):", #data.events))
        for i, event in ipairs(data.events) do
            local line = string.format("[%.3f] %s: %s -> %s",
                event.realTime or 0,
                event.subevent or "UNKNOWN",
                event.sourceName or "?",
                event.destName or "?")
            table.insert(lines, line)
        end
    end
    
    return table.concat(lines, "\n")
end

-- Format as Lua table
function ExportDialog:FormatAsLua(data)
    local function serializeLua(value, indent)
        indent = indent or 0
        local spacing = string.rep("  ", indent)
        
        if type(value) == "table" then
            local result = "{\n"
            for k, v in pairs(value) do
                local key = type(k) == "string" and "[\"" .. k .. "\"]" or "[" .. tostring(k) .. "]"
                result = result .. spacing .. "  " .. key .. " = " .. serializeLua(v, indent + 1) .. ",\n"
            end
            result = result .. spacing .. "}"
            return result
        elseif type(value) == "string" then
            return "\"" .. value:gsub("\"", "\\\"") .. "\""
        else
            return tostring(value)
        end
    end
    
    return "local exportedData = " .. serializeLua(data) .. "\nreturn exportedData"
end

-- Show preview of export data
function ExportDialog:ShowPreview()
    local data = self:GetExportData()
    local format = self:GetSelectedFormat()
    
    if not data then
        print("No data available for preview")
        return
    end
    
    local formatted = self:FormatExportData(data, format)
    local preview = string.sub(formatted, 1, 500) -- First 500 characters
    
    print("=== Export Preview (" .. format.name .. ") ===")
    print(preview)
    if string.len(formatted) > 500 then
        print("... (truncated, full export will contain " .. string.len(formatted) .. " characters)")
    end
end

-- Perform the actual export
function ExportDialog:PerformExport()
    local data = self:GetExportData()
    local format = self:GetSelectedFormat()
    
    if not data then
        print("No data available for export")
        return
    end
    
    local formatted = self:FormatExportData(data, format)
    
    -- For now, output to chat with instructions
    print("=== Combat Data Export Complete ===")
    print("Format: " .. format.name)
    print("Size: " .. string.len(formatted) .. " characters")
    print("")
    print("Copy the following data to a ." .. format.extension .. " file:")
    print("--- BEGIN EXPORT ---")
    print(formatted)
    print("--- END EXPORT ---")
    print("")
    print("Note: Advanced clipboard/file export coming in future updates!")
    
    self:Hide()
end

-- Public API
function ExportDialog:IsShown()
    return exportFrame and exportFrame:IsShown()
end

function ExportDialog:GetStatus()
    return {
        isInitialized = isInitialized,
        isShown = self:IsShown(),
        availableFormats = #EXPORT_FORMATS
    }
end