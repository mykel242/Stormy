-- MyLogger.lua
-- Simplified logging system with in-memory buffer + SavedVariables persistence

local addonName, addon = ...

-- =============================================================================
-- LOGGER MODULE
-- =============================================================================

local MyLogger = {}
addon.MyLogger = MyLogger

-- =============================================================================
-- LOG LEVELS AND CONSTANTS
-- =============================================================================

-- Log levels (lower numbers = higher priority)
MyLogger.LOG_LEVELS = {
    OFF = 0,
    PANIC = 1,    -- Critical errors that should always show
    ERROR = 2,
    WARN = 3,
    INFO = 4,
    DEBUG = 5,
    TRACE = 6
}

-- Level names for display
MyLogger.LEVEL_NAMES = {
    [0] = "OFF",
    [1] = "PANIC",
    [2] = "ERROR",
    [3] = "WARN",
    [4] = "INFO",
    [5] = "DEBUG",
    [6] = "TRACE"
}

-- Level colors for console output
MyLogger.LEVEL_COLORS = {
    [0] = "|cFFFFFFFF", -- White
    [1] = "|cFFFF00FF", -- Magenta (PANIC - stands out)
    [2] = "|cFFFF0000", -- Red (ERROR)
    [3] = "|cFFFFFF00", -- Yellow (WARN)
    [4] = "|cFF00FF00", -- Green (INFO)
    [5] = "|cFF00FFFF", -- Cyan (DEBUG)
    [6] = "|cFF8080FF"  -- Light Blue (TRACE)
}

-- =============================================================================
-- CONFIGURATION
-- =============================================================================

local config = {
    currentLevel = MyLogger.LOG_LEVELS.OFF,
    includeTimestamp = true,
    includeLevel = true,
    savedVariables = nil -- Reference to addon's saved variables
}

-- =============================================================================
-- CORE LOGGING API
-- =============================================================================

-- Set the current log level
function MyLogger:SetLevel(level)
    if type(level) == "string" then
        -- Convert string to number
        for num, name in pairs(self.LEVEL_NAMES) do
            if name:upper() == level:upper() then
                level = num
                break
            end
        end
    end
    
    if type(level) == "number" and level >= 0 and level <= 6 then
        config.currentLevel = level
        return true
    else
        print(string.format("[%s] Invalid log level: %s", addonName, tostring(level)))
        return false
    end
end

-- Get current log level
function MyLogger:GetLevel()
    return config.currentLevel
end

-- Check if a level should be logged
function MyLogger:ShouldLog(level)
    return config.currentLevel >= level
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

-- Initialize the logger
function MyLogger:Initialize(options)
    options = options or {}
    
    -- Set log level
    local levelName = options.level or "OFF"
    config.currentLevel = self.LOG_LEVELS[levelName] or self.LOG_LEVELS.OFF
    
    -- Set other options
    config.includeTimestamp = options.includeTimestamp ~= false -- Default true
    config.includeLevel = options.includeLevel ~= false -- Default true
    config.savedVariables = options.savedVariables -- Reference for persistence
    
    -- Initialize logging storage
    self:InitializeStorage()
    
    -- Initialize log event queue if available
    if addon.LogEventQueue then
        self.logEventQueue = addon.LogEventQueue
        self:Debug("Logger connected to LogEventQueue")
    elseif addon.EventQueueFactory then
        -- Fallback: create our own if not already created
        self.logEventQueue = addon.EventQueueFactory:CreateLogEventQueue()
        addon.LogEventQueue = self.logEventQueue
        self:Debug("Logger created LogEventQueue")
    end
    
    -- Log initialization
    self:Info("Log level set to: %s (%d)", levelName, config.currentLevel)
end

-- Initialize logging storage
function MyLogger:InitializeStorage()
    -- Initialize in-memory buffer
    if not self.memoryLogs then
        self.memoryLogs = {}
    end
    
    -- Initialize SavedVariables logs if reference provided
    if config.savedVariables then
        if not config.savedVariables.logs then
            config.savedVariables.logs = {}
        end
    end
end

-- =============================================================================
-- MESSAGE STORAGE
-- =============================================================================

-- Store log message in both memory and SavedVariables
function MyLogger:StoreLogMessage(level, message)
    local timestamp = date("%H:%M:%S")
    local levelName = self.LEVEL_NAMES[level] or "UNKNOWN"
    local formattedMessage = string.format("[%s] [%s] %s", timestamp, levelName, message)
    
    -- Always store in memory buffer
    if not self.memoryLogs then
        self.memoryLogs = {}
    end
    table.insert(self.memoryLogs, formattedMessage)
    
    -- Keep only last 100 messages in memory
    if #self.memoryLogs > 100 then
        table.remove(self.memoryLogs, 1)
    end
    
    -- Store important logs (PANIC, ERROR, WARN) in SavedVariables
    if level <= self.LOG_LEVELS.WARN and config.savedVariables then
        local entry = {
            timestamp = time(),
            level = levelName,
            message = message,
            session = date("%Y-%m-%d %H:%M:%S")
        }
        table.insert(config.savedVariables.logs, entry)
        
        -- Keep only last 500 persistent logs
        if #config.savedVariables.logs > 500 then
            table.remove(config.savedVariables.logs, 1)
        end
    end
end

-- =============================================================================
-- MESSAGE FORMATTING AND OUTPUT
-- =============================================================================

-- Format a log message
function MyLogger:FormatMessage(level, message, ...)
    -- Ensure message is a string
    message = tostring(message)
    
    -- Format the message content if additional arguments provided
    if ... then
        -- Convert all arguments to strings to prevent function formatting errors
        local args = {...}
        for i = 1, #args do
            local arg = args[i]
            -- Limit string length to prevent hangs
            if type(arg) == "string" and #arg > 100 then
                args[i] = string.sub(arg, 1, 100) .. "..."
            else
                args[i] = tostring(arg)
            end
        end
        
        -- Safely format the message
        local success, formatted = pcall(string.format, message, unpack(args))
        if success then
            message = formatted
        else
            -- Fallback if formatting fails
            message = message .. " [formatting failed]"
        end
    end
    
    -- Limit final message length
    if #message > 500 then
        message = string.sub(message, 1, 500) .. "... [truncated]"
    end
    
    local parts = {}
    
    -- Add timestamp if enabled
    if config.includeTimestamp then
        table.insert(parts, date("%H:%M:%S"))
    end
    
    -- Add level if enabled
    if config.includeLevel then
        local levelName = self.LEVEL_NAMES[level] or "UNKNOWN"
        local colorCode = self.LEVEL_COLORS[level] or ""
        table.insert(parts, string.format("%s[%s]|r", colorCode, levelName))
    end
    
    -- Add addon name
    table.insert(parts, string.format("[%s]", addonName))
    
    -- Add the message
    table.insert(parts, message)
    
    return table.concat(parts, " ")
end

-- Core logging function
function MyLogger:Log(level, message, ...)
    -- Check if we should log this level
    if not self:ShouldLog(level) then return end
    
    -- Format the message
    local formattedMessage = self:FormatMessage(level, message, ...)
    
    -- Store the message
    self:StoreLogMessage(level, message)
    
    -- Push to log event queue if available
    if self.logEventQueue then
        self.logEventQueue:Push("LOG", {
            level = level,
            levelName = self.LEVEL_NAMES[level] or "UNKNOWN",
            message = message,
            formattedMessage = formattedMessage,
            args = {...},
            timestamp = GetTime()
        })
    end
    
    -- MyLogger never writes directly to UI - only to storage and queue
    -- UI components pull from queue when needed
end

-- =============================================================================
-- CONVENIENCE METHODS
-- =============================================================================

-- Log at PANIC level (critical errors that need immediate attention)
function MyLogger:Panic(message, ...)
    -- PANIC goes through normal queue/storage system
    -- UI components can subscribe to PANIC messages for immediate display
    self:Log(self.LOG_LEVELS.PANIC, message, ...)
end

-- Log at ERROR level
function MyLogger:Error(message, ...)
    self:Log(self.LOG_LEVELS.ERROR, message, ...)
end

-- Log at WARN level
function MyLogger:Warn(message, ...)
    self:Log(self.LOG_LEVELS.WARN, message, ...)
end

-- Log at INFO level
function MyLogger:Info(message, ...)
    self:Log(self.LOG_LEVELS.INFO, message, ...)
end

-- Log at DEBUG level
function MyLogger:Debug(message, ...)
    self:Log(self.LOG_LEVELS.DEBUG, message, ...)
end

-- Log at TRACE level
function MyLogger:Trace(message, ...)
    self:Log(self.LOG_LEVELS.TRACE, message, ...)
end

-- =============================================================================
-- EXPORT FUNCTIONS
-- =============================================================================

-- Get recent logs from memory buffer
function MyLogger:GetRecentLogs()
    return self.memoryLogs or {}
end

-- Get all persistent logs from SavedVariables
function MyLogger:GetPersistentLogs()
    if config.savedVariables and config.savedVariables.logs then
        return config.savedVariables.logs
    end
    return {}
end

-- Export recent logs to clipboard
function MyLogger:ExportRecentLogs()
    local logs = self:GetRecentLogs()
    if #logs == 0 then
        print("No recent logs available")
        return
    end
    
    local exportText = string.format("=== %d Recent MyUI2 Logs ===\n", #logs)
    for i, log in ipairs(logs) do
        exportText = exportText .. log .. "\n"
    end
    exportText = exportText .. "=== End Recent Logs ==="
    
    -- Copy to clipboard using WoW's API
    if C_System and C_System.SetClipboard then
        C_System.SetClipboard(exportText)
    else
        -- Fallback: show in a copy-friendly format
        print("=== COPY THIS TEXT ===")
        print(exportText)
        print("=== END COPY TEXT ===")
    end
    
    print(string.format("Recent logs (%d messages) copied to clipboard", #logs))
end

-- Export persistent logs to clipboard
function MyLogger:ExportPersistentLogs()
    local logs = self:GetPersistentLogs()
    if #logs == 0 then
        print("No persistent logs available")
        return
    end
    
    local exportText = string.format("=== %d Persistent MyUI2 Logs ===\n", #logs)
    for i, entry in ipairs(logs) do
        exportText = exportText .. string.format("[%s] [%s] %s\n", entry.session, entry.level, entry.message)
    end
    exportText = exportText .. "=== End Persistent Logs ==="
    
    -- Copy to clipboard using WoW's API
    if C_System and C_System.SetClipboard then
        C_System.SetClipboard(exportText)
    else
        -- Fallback: show in a copy-friendly format
        print("=== COPY THIS TEXT ===")
        print(exportText)
        print("=== END COPY TEXT ===")
    end
    
    print(string.format("Persistent logs (%d messages) copied to clipboard", #logs))
end

-- Print recent logs for copying (fallback)
function MyLogger:DumpRecentLogs()
    local logs = self:GetRecentLogs()
    if #logs == 0 then
        print("No recent logs available")
        return
    end
    
    print(string.format("=== %d Recent Logs ===", #logs))
    for i, log in ipairs(logs) do
        print(log)
    end
    print("=== End Recent Logs ===")
    print("Use /myui copylogs to copy to clipboard")
end

-- Print all persistent logs for copying (fallback)
function MyLogger:DumpPersistentLogs()
    local logs = self:GetPersistentLogs()
    if #logs == 0 then
        print("No persistent logs available")
        return
    end
    
    print(string.format("=== %d Persistent Logs ===", #logs))
    for i, entry in ipairs(logs) do
        print(string.format("[%s] [%s] %s", entry.session, entry.level, entry.message))
    end
    print("=== End Persistent Logs ===")
    print("Use /myui copyexportlogs to copy to clipboard")
end

-- =============================================================================
-- CONFIGURATION METHODS
-- =============================================================================

-- Enable/disable fallback to print
function MyLogger:SetFallbackToPrint(enabled)
    config.fallbackToPrint = enabled
end

-- Enable/disable timestamps
function MyLogger:SetIncludeTimestamp(enabled)
    config.includeTimestamp = enabled
end

-- Enable/disable level names
function MyLogger:SetIncludeLevel(enabled)
    config.includeLevel = enabled
end

-- Get current configuration
function MyLogger:GetConfig()
    return {
        level = config.currentLevel,
        levelName = self.LEVEL_NAMES[config.currentLevel],
        fallbackToPrint = config.fallbackToPrint,
        includeTimestamp = config.includeTimestamp,
        includeLevel = config.includeLevel,
        memoryLogCount = self.memoryLogs and #self.memoryLogs or 0,
        persistentLogCount = config.savedVariables and config.savedVariables.logs and #config.savedVariables.logs or 0
    }
end

-- Debug dump of current configuration
function MyLogger:DumpConfig()
    local cfg = self:GetConfig()
    self:Info("=== MyLogger Configuration ===")
    self:Info("Level: %s (%d)", cfg.levelName, cfg.level)
    self:Info("Fallback to Print: %s", tostring(cfg.fallbackToPrint))
    self:Info("Include Timestamp: %s", tostring(cfg.includeTimestamp))
    self:Info("Include Level: %s", tostring(cfg.includeLevel))
    self:Info("Memory Logs: %d", cfg.memoryLogCount)
    self:Info("Persistent Logs: %d", cfg.persistentLogCount)
    self:Info("==============================")
end

return MyLogger