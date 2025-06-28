-- VirtualScrollMixin.lua
-- Reusable virtual scrolling system for performance optimization

local addonName, addon = ...

-- ============================================================================
-- VIRTUAL SCROLL MIXIN
-- ============================================================================

local VirtualScrollMixin = {}
addon.VirtualScrollMixin = VirtualScrollMixin

-- Default configuration
local DEFAULT_CONFIG = {
    LINES_PER_CHUNK = 1000,       -- Lines loaded per chunk
    BUFFER_CHUNKS = 1,            -- Buffer chunks above/below visible area  
    MIN_LINES_FOR_VIRTUAL = 2000, -- Only virtualize if more than this many lines
    TIMER_INTERVAL = 1.0,         -- Scroll monitoring interval (1000ms for better performance)
    SCROLL_THRESHOLD = 10,        -- Minimum scroll change to trigger updates
    LINE_HEIGHT = 12,             -- Approximate line height for calculations
}

-- ============================================================================
-- MIXIN FUNCTIONS
-- ============================================================================

-- Create a new instance of the virtual scroll mixin
function VirtualScrollMixin:new()
    local instance = {}
    setmetatable(instance, { __index = VirtualScrollMixin })
    return instance
end

-- Initialize virtual scrolling for a frame
-- frame: The container frame
-- scrollFrame: The ScrollFrame
-- editBox: The EditBox/FontString that displays content  
-- config: Optional config overrides
function VirtualScrollMixin:Initialize(frame, scrollFrame, editBox, config)
    if not frame or not scrollFrame or not editBox then
        local errorMsg = string.format("VirtualScrollMixin requires frame, scrollFrame, and editBox. Got: frame=%s, scrollFrame=%s, editBox=%s",
            tostring(frame), tostring(scrollFrame), tostring(editBox))
        error(errorMsg)
    end
    
    -- Store references
    self.parentFrame = frame
    self.scrollFrame = scrollFrame
    self.editBox = editBox
    self.config = config and self:MergeConfig(DEFAULT_CONFIG, config) or DEFAULT_CONFIG
    
    -- Initialize state
    self.state = {
        isActive = false,
        totalLines = 0,
        totalChunks = 0,
        loadedChunks = {},
        headerLines = {},
        footerLines = {},
        timer = nil,
        lastScrollOffset = 0,
        cachedContent = nil,
        contentLines = nil,
        headerLineCount = 0,
        lastUpdateTime = 0
    }
    
    -- Set up scroll monitoring
    self:SetupScrollMonitoring()
    
    -- Initialization complete (removed debug spam)
end

-- Merge configuration tables
function VirtualScrollMixin:MergeConfig(default, override)
    local merged = {}
    for k, v in pairs(default) do
        merged[k] = v
    end
    for k, v in pairs(override) do
        merged[k] = v
    end
    return merged
end

-- Set up scroll position monitoring
function VirtualScrollMixin:SetupScrollMonitoring()
    local lastActivityTime = 0
    local function checkScrollPosition()
        if self.parentFrame and self.parentFrame:IsShown() and self.state.isActive then
            local currentOffset = self.scrollFrame:GetVerticalScroll()
            if math.abs(currentOffset - self.state.lastScrollOffset) > self.config.SCROLL_THRESHOLD then
                self.state.lastScrollOffset = currentOffset
                self:OnScrollChanged(currentOffset)
                lastActivityTime = GetTime()
            else
                -- Stop timer if no activity for 3 seconds
                if GetTime() - lastActivityTime > 3 then
                    if self.state.timer then
                        self.state.timer:Cancel()
                        self.state.timer = nil
                    end
                end
            end
        end
    end
    
    -- Start monitoring when frame is shown
    self.parentFrame:HookScript("OnShow", function()
        if self.state.timer then
            self.state.timer:Cancel()
        end
        if self.state.isActive then
            lastActivityTime = GetTime()
            self.state.timer = C_Timer.NewTicker(self.config.TIMER_INTERVAL, checkScrollPosition)
        end
    end)
    
    -- Stop monitoring when hidden
    self.parentFrame:HookScript("OnHide", function()
        if self.state.timer then
            self.state.timer:Cancel()
            self.state.timer = nil
        end
    end)
    
    -- Restart timer on user interaction
    if self.scrollFrame then
        self.scrollFrame:HookScript("OnMouseWheel", function()
            lastActivityTime = GetTime()
            if self.state.isActive and not self.state.timer then
                self.state.timer = C_Timer.NewTicker(self.config.TIMER_INTERVAL, checkScrollPosition)
            end
        end)
    end
end

-- Activate virtual scrolling with content
-- contentLines: Array of strings to display
-- headerLines: Optional array of header lines (always visible)
-- footerLines: Optional array of footer lines (always visible)
function VirtualScrollMixin:SetContent(contentLines, headerLines, footerLines)
    if not contentLines or #contentLines == 0 then
        self:Deactivate()
        return
    end
    
    local totalContentLines = #contentLines
    
    -- Check if virtual scrolling is needed
    if totalContentLines < self.config.MIN_LINES_FOR_VIRTUAL then
        self:DisplayTraditional(contentLines, headerLines, footerLines)
        return
    end
    
    -- Activate virtual scrolling
    self.state.isActive = true
    self.state.totalLines = totalContentLines
    self.state.totalChunks = math.ceil(totalContentLines / self.config.LINES_PER_CHUNK)
    self.state.loadedChunks = {} -- Clear loaded chunks to force reload with new content
    self.state.headerLines = headerLines or {}
    self.state.footerLines = footerLines or {}
    self.state.cachedContent = nil -- Invalidate cache to force regeneration
    
    -- Create full structure with placeholders
    self:CreateVirtualStructure(contentLines)
    
    -- Load initial chunks
    self:EnsureChunkLoaded(1)
    
    -- Start scroll monitoring if frame is visible
    if self.parentFrame:IsShown() then
        if self.state.timer then
            self.state.timer:Cancel()
        end
        self.state.timer = C_Timer.NewTicker(self.config.TIMER_INTERVAL, function()
            if self.parentFrame and self.parentFrame:IsShown() and self.state.isActive then
                local currentOffset = self.scrollFrame:GetVerticalScroll()
                if math.abs(currentOffset - self.state.lastScrollOffset) > self.config.SCROLL_THRESHOLD then
                    self.state.lastScrollOffset = currentOffset
                    self:OnScrollChanged(currentOffset)
                end
            end
        end)
    end
    
    -- Note: Avoid debug logging here to prevent infinite loops with MyLogger
end

-- Create virtual structure metadata only
function VirtualScrollMixin:CreateVirtualStructure(contentLines)
    -- Prevent infinite recursion from debug logging during same frame
    local currentTime = GetTime()
    if self.state.lastUpdateTime and (currentTime - self.state.lastUpdateTime) < 0.1 then
        return
    end
    self.state.lastUpdateTime = currentTime
    
    self.state.contentLines = contentLines
    self.state.headerLineCount = #self.state.headerLines
    
    -- Calculate estimated height without creating full structure
    local totalLines = #self.state.headerLines + #contentLines + #self.state.footerLines
    self.editBox:SetHeight(totalLines * self.config.LINE_HEIGHT)
    
    -- Set initial display - just headers and summary
    self.state.cachedContent = nil
    self:UpdateDisplay()
end

-- Display content traditionally (no virtual scrolling)
function VirtualScrollMixin:DisplayTraditional(contentLines, headerLines, footerLines)
    self:Deactivate()
    
    local allLines = {}
    
    -- Add header
    if headerLines then
        for _, line in ipairs(headerLines) do
            table.insert(allLines, line)
        end
    end
    
    -- Add content
    for _, line in ipairs(contentLines) do
        table.insert(allLines, line)
    end
    
    -- Add footer
    if footerLines then
        for _, line in ipairs(footerLines) do
            table.insert(allLines, line)
        end
    end
    
    local fullContent = table.concat(allLines, "\n")
    self.editBox:SetText(fullContent)
    self.editBox:SetHeight(#allLines * self.config.LINE_HEIGHT)
    
    -- Removed: This was causing logging recursion in MyLoggerWindow
end

-- Handle scroll position changes
function VirtualScrollMixin:OnScrollChanged(offset)
    if not self.state.isActive then
        return
    end
    
    local scrollHeight = self.scrollFrame:GetVerticalScrollRange()
    local scrollPercent = scrollHeight > 0 and (offset / scrollHeight) or 0
    
    local targetChunk = math.floor(scrollPercent * self.state.totalChunks) + 1
    targetChunk = math.max(1, math.min(targetChunk, self.state.totalChunks))
    
    self:EnsureChunkLoaded(targetChunk)
end

-- Ensure a chunk and its buffer are loaded
function VirtualScrollMixin:EnsureChunkLoaded(chunkIndex)
    if not self.state.isActive then
        return
    end
    
    local bufferSize = self.config.BUFFER_CHUNKS
    local startChunk = math.max(1, chunkIndex - bufferSize)
    local endChunk = math.min(self.state.totalChunks, chunkIndex + bufferSize)
    
    local needsUpdate = false
    
    -- Load missing chunks in range
    for i = startChunk, endChunk do
        if not self.state.loadedChunks[i] then
            self:LoadChunk(i)
            needsUpdate = true
        end
    end
    
    -- Invalidate cache when chunks change
    if needsUpdate then
        self.state.cachedContent = nil
    end
    
    -- Unload chunks outside range to save memory
    for loadedChunk, _ in pairs(self.state.loadedChunks) do
        if loadedChunk < startChunk or loadedChunk > endChunk then
            self:UnloadChunk(loadedChunk)
            self.state.loadedChunks[loadedChunk] = nil
            needsUpdate = true
        end
    end
    
    if needsUpdate then
        self:UpdateDisplay()
        -- Force garbage collection after chunk changes
        collectgarbage("collect")
    end
end

-- Load a specific chunk
function VirtualScrollMixin:LoadChunk(chunkIndex)
    if not self.state.isActive or not self.state.contentLines then
        return
    end
    
    local startIdx = (chunkIndex - 1) * self.config.LINES_PER_CHUNK + 1
    local endIdx = math.min(startIdx + self.config.LINES_PER_CHUNK - 1, #self.state.contentLines)
    
    local chunkLines = {}
    for i = startIdx, endIdx do
        table.insert(chunkLines, self.state.contentLines[i])
    end
    
    self.state.loadedChunks[chunkIndex] = chunkLines
    
    -- Invalidate cache when content changes
    self.state.cachedContent = nil
end

-- Unload a specific chunk  
function VirtualScrollMixin:UnloadChunk(chunkIndex)
    -- Chunk data is freed by removing from loadedChunks table
    -- No fullStructure to update since we generate content dynamically
end

-- Update the display with current loaded content  
function VirtualScrollMixin:UpdateDisplay()
    if not self.state.isActive then
        return
    end
    
    -- Generate content if not cached
    if not self.state.cachedContent then
        self.state.cachedContent = self:GenerateVisibleContent()
        self.editBox:SetText(self.state.cachedContent)
    end
end

-- Generate only visible content instead of full structure
function VirtualScrollMixin:GenerateVisibleContent()
    local content = {}
    
    -- Add headers
    for _, line in ipairs(self.state.headerLines) do
        table.insert(content, line)
    end
    
    -- Add only loaded chunks, placeholders for unloaded
    for chunkIndex = 1, self.state.totalChunks do
        if self.state.loadedChunks[chunkIndex] then
            -- Add loaded chunk content
            for _, line in ipairs(self.state.loadedChunks[chunkIndex]) do
                table.insert(content, line)
            end
        else
            -- Add single placeholder for entire unloaded chunk
            table.insert(content, string.format("[Chunk %d not loaded - scroll to load]", chunkIndex))
        end
    end
    
    -- Add footers
    for _, line in ipairs(self.state.footerLines) do
        table.insert(content, line)
    end
    
    return table.concat(content, "\n")
end

-- Deactivate virtual scrolling
function VirtualScrollMixin:Deactivate()
    self.state.isActive = false
    
    if self.state.timer then
        self.state.timer:Cancel()
        self.state.timer = nil
    end
    
    -- Clear state
    self.state.loadedChunks = {}
    self.state.totalChunks = 0
    self.state.totalLines = 0
    self.state.contentLines = nil
    self.state.cachedContent = nil
end

-- Get status information
function VirtualScrollMixin:GetStatus()
    return {
        isActive = self.state.isActive,
        totalLines = self.state.totalLines,
        totalChunks = self.state.totalChunks,
        loadedChunks = self:GetLoadedChunkCount(),
        hasTimer = self.state.timer ~= nil
    }
end

-- Get number of loaded chunks
function VirtualScrollMixin:GetLoadedChunkCount()
    local count = 0
    for _ in pairs(self.state.loadedChunks) do
        count = count + 1
    end
    return count
end

return VirtualScrollMixin