-- A structured logging module for Checkmate

local M = {}

-- Log levels
M.levels = {
  TRACE = 0,
  DEBUG = 1,
  INFO = 2,
  WARN = 3,
  ERROR = 4,
  OFF = 5,
}

-- Maps string level names to numeric values
local level_map = {
  trace = M.levels.TRACE,
  debug = M.levels.DEBUG,
  info = M.levels.INFO,
  warn = M.levels.WARN,
  error = M.levels.ERROR,
  off = M.levels.OFF,
}

local log_file = nil

local function ensure_default_log_dir()
  local log_dir = vim.fs.joinpath(vim.fn.stdpath("data"))
  vim.fn.mkdir(log_dir, "p") -- 'p' ensures parent dirs are created if needed
  return log_dir
end

local function get_log_file_path(customPath)
  if customPath and type(customPath) == "string" then
    -- expand ~ and env vars (like $HOME)
    local expanded = vim.fn.expand(customPath)
    -- turn relative paths into absolute paths
    return vim.fn.fnamemodify(expanded, ":p")
  end
  local log_dir = ensure_default_log_dir()
  -- return a OS system path to "~/.local/share/nvim/checkmate.log"
  return vim.fs.joinpath(log_dir, "checkmate.log")
end

local function round(x, increment)
  if x == 0 then
    return x
  end
  increment = increment or 1
  x = x / increment
  return (x > 0 and math.floor(x + 0.5) or math.ceil(x - 0.5)) * increment
end

local function make_string(...)
  local t = {}
  for i = 1, select("#", ...) do
    local x = select(i, ...)

    if type(x) == "number" then
      x = tostring(round(x, 5))
    elseif type(x) == "table" then
      x = vim.inspect(x)
    else
      x = tostring(x)
    end

    t[#t + 1] = x
  end
  return table.concat(t, " ")
end

local function format_log(level_name, msg, source_info)
  local parts = {
    os.date("%Y-%m-%d %H:%M:%S"),
    string.format("[%s]", level_name),
  }

  if source_info then
    table.insert(parts, string.format("[%s:%d]", source_info.path, source_info.line))
  end

  table.insert(parts, msg)
  return table.concat(parts, " ")
end

-- Get source information (expensive, only when needed)
local function get_source_info(level)
  local info = debug.getinfo(level or 3, "Sl")
  if info then
    return {
      path = info.source:sub(2), -- remove @ prefix
      line = info.currentline,
    }
  end
  return nil
end

local function log_at_level(level, level_name, message_maker, ...)
  local config = require("checkmate.config")
  local options = config.options.log
  local current_level = level_map[options.level] or M.levels.INFO

  -- skip if current level is higher than this message's level
  if level < current_level then
    return
  end

  local msg = message_maker(...)

  -- get source info if configured
  local source_info = nil
  if false then
    source_info = get_source_info(4)
  end

  local formatted = format_log(level_name, msg, source_info)

  if options.use_file and log_file then
    log_file:write(formatted .. "\n")
    log_file:flush()
  end
end

-- create logging methods for each level
local function create_logger_methods()
  local level_names = { "trace", "debug", "info", "warn", "error" }

  for _, name in ipairs(level_names) do
    local level = M.levels[name:upper()]
    local level_name = name:upper()

    -- Basic logging: M.debug("message", "multiple", "args")
    M[name] = function(...)
      return log_at_level(level, level_name, make_string, ...)
    end

    -- Formatted logging: M.fmt_debug("Hello %s", "world")
    M["fmt_" .. name] = function(fmt, ...)
      return log_at_level(level, level_name, function(format_str, ...)
        local args = { ... }
        local inspected = {}
        for _, v in ipairs(args) do
          table.insert(inspected, type(v) == "table" and vim.inspect(v) or tostring(v))
        end
        return string.format(format_str, unpack(inspected))
      end, fmt, ...)
    end

    -- Lazy logging: M.lazy_debug(function() return expensive_calculation() end)
    M["lazy_" .. name] = function(fn)
      return log_at_level(level, level_name, function(f)
        return tostring(f())
      end, fn)
    end
  end
end

function M.setup()
  local config = require("checkmate.config")
  local options = config.options.log

  if options.use_file then
    local log_file_path = get_log_file_path(options.file_path)
    local ok, file = pcall(io.open, log_file_path, "a")

    if ok and file then
      log_file = file
      local msg = "Checkmate logger initialized: " .. log_file_path
      local formatted = format_log("INFO", msg, nil)
      log_file:write(formatted .. "\n")
      log_file:flush()
    else
      vim.notify("Checkmate: Failed to open log file: " .. log_file_path, vim.log.levels.ERROR)
    end
  end
end

function M.shutdown()
  if log_file then
    log_file:close()
    log_file = nil
  end
end

create_logger_methods()

return M
