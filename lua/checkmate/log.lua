-- A structured logging module for Checkmate

---@alias basic_log fun(args: any)
---@alias fmt_log fun(format_string: string, args: any)
---@alias lazy_log fun(lazy_fn: fun())

---@class checkmate.Log
---@field trace basic_log
---@field debug basic_log
---@field info basic_log
---@field warn basic_log
---@field error basic_log
---@field fmt_trace fmt_log
---@field fmt_debug fmt_log
---@field fmt_info fmt_log
---@field fmt_warn fmt_log
---@field fmt_error fmt_log
---@field lazy_trace lazy_log
---@field lazy_debug lazy_log
---@field lazy_info lazy_log
---@field lazy_warn lazy_log
---@field lazy_error lazy_log
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

local DEFAULT_NAME = "checkmate.log"
local log_file = nil
local log_file_path = nil

local function ensure_default_log_dir()
  local log_dir = vim.fs.joinpath(vim.fn.stdpath("log"))
  vim.fn.mkdir(log_dir, "p") -- 'p' ensures parent dirs are created if needed
  return log_dir
end

local function get_log_file_path(customPath)
  local function get_default_path()
    local log_dir = ensure_default_log_dir()
    return vim.fs.joinpath(log_dir, DEFAULT_NAME)
  end

  if not customPath or type(customPath) ~= "string" or customPath == "" then
    return get_default_path()
  end

  -- expand ~ and env vars (like $HOME)
  local expanded = vim.fn.expand(customPath)

  if expanded == "" then
    vim.notify("Checkmate: Invalid log path: " .. customPath, vim.log.levels.WARN)
    -- fallback to default
    local log_dir = ensure_default_log_dir()
    return vim.fs.joinpath(log_dir, DEFAULT_NAME)
  end

  local absolute = vim.fn.fnamemodify(expanded, ":p")

  local stat = vim.uv.fs_stat(absolute)
  if stat and stat.type == "directory" then
    -- existing directory
    absolute = vim.fs.joinpath(absolute, DEFAULT_NAME)
  elseif not stat then
    -- path doesn't exist yet
    if absolute:match("[/\\]$") or not absolute:match("%.%w+$") then
      -- ends with separator OR has no extension = directory
      vim.fn.mkdir(absolute, "p")
      absolute = vim.fs.joinpath(absolute, DEFAULT_NAME)
    else
      -- has extension = file
      local parent = vim.fs.dirname(absolute)
      if parent and parent ~= "" then
        vim.fn.mkdir(parent, "p")
      end
    end
  else
    -- file path (existing or not): ensure parent exists
    local parent = vim.fs.dirname(absolute)
    if parent and parent ~= "" then
      vim.fn.mkdir(parent, "p")
    end
  end

  -- verify parent directory is writable
  local parent_dir = vim.fs.dirname(absolute)
  if vim.uv.fs_access(parent_dir, "W") then
    vim.notify("Checkmate: Log directory not writable: " .. parent_dir, vim.log.levels.WARN)
    return get_default_path()
  end

  return absolute
end

local function get_file_size(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.size or 0
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
      x = tostring(round(x, 0.01))
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
        -- protect against format string errors
        local args = { ... }
        local ok, result = pcall(function()
          local inspected = {}
          for _, v in ipairs(args) do
            table.insert(inspected, type(v) == "table" and vim.inspect(v) or tostring(v))
          end
          return string.format(format_str, unpack(inspected))
        end)

        if not ok then
          -- basic concatenation if format fails
          return format_str .. " " .. make_string(...)
        end
        return result
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
    log_file_path = get_log_file_path(options.file_path)

    local append_mode = true
    local file_size = get_file_size(log_file_path)
    local default_max_file_size = 5 * 1024 -- 5120 kb
    local max_file_size = (config.options.log.max_file_size or default_max_file_size * 1024) -- convert to bytes
    if file_size > max_file_size then
      append_mode = false
      if log_file then
        log_file:close()
        log_file = nil
      end
    end

    local ok, file = pcall(io.open, log_file_path, append_mode and "a" or "w")

    if ok and file then
      log_file = file
      local info = {
        path = log_file_path,
        max_file_size = tostring(max_file_size / (1024 ^ 2)) .. " mb",
      }
      local msg = "Checkmate logger initialized:\n" .. vim.inspect(info)
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

function M.get_log_path()
  return log_file_path
end

---@param opts? {scratch?: "floating" | "split"}
function M.open(opts)
  opts = opts or {}

  if opts.scratch then
    local scratch =
      require("checkmate.ui.scratch").open({ floating = opts.scratch == "floating", ft = "checkmate_log" })

    if log_file_path and vim.fn.filereadable(log_file_path) == 1 then
      local lines = vim.fn.readfile(log_file_path)
      scratch:set(lines)
    else
      scratch:set({ "Log file not found or not readable: " .. (log_file_path or "no path set") })
    end
  else
    vim.cmd(string.format("tabnew %s", log_file_path))
  end
end

function M.clear()
  local config = require("checkmate.config")
  local options = config.options.log

  if options.use_file then
    if log_file then
      log_file:close()
    end

    local ok, file = pcall(io.open, log_file_path, "w")
    if ok and file then
      log_file = file
      M.info("Log file cleared")
    end
  end
end

function M.log_error(err, context)
  if err then
    M.error(string.format("%s: %s", context or "Error", tostring(err)))
    return true
  end
  return false
end

-- exposed for testing
M._get_log_file_path = get_log_file_path

create_logger_methods()

return M
