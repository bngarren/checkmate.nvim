---@alias basic_log fun(...: any)
---@alias fmt_log fun(format_string: string, ...)
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

M.levels = vim.log.levels

local level_map = {
  trace = M.levels.TRACE,
  debug = M.levels.DEBUG,
  info = M.levels.INFO,
  warn = M.levels.WARN,
  error = M.levels.ERROR,
  off = M.levels.OFF,
}

local DEFAULT_NAME = "checkmate.log"
local DEFAULT_MAX_FILE_SIZE_KB = 5 * 1024
local log_file = nil
local log_file_path = nil

local function safe_tostring(value)
  if type(value) == "string" then
    return value
  end

  local ok, result = pcall(tostring, value)
  return ok and result or ("<" .. type(value) .. ">")
end

local function ensure_default_log_dir()
  local log_dir = vim.fs.joinpath(vim.fn.stdpath("log"))
  pcall(vim.fn.mkdir, log_dir, "p")
  return log_dir
end

local function get_log_file_path(customPath)
  local function get_default_path()
    return vim.fs.joinpath(ensure_default_log_dir(), DEFAULT_NAME)
  end

  if not customPath or type(customPath) ~= "string" or customPath == "" then
    return get_default_path()
  end

  local looks_like_dir = customPath:match("[/\\]$")
  local expanded = vim.fs.normalize(customPath)

  if expanded == "" then
    vim.notify("Checkmate: Invalid log path: " .. customPath, vim.log.levels.WARN)
    return get_default_path()
  end

  local absolute = vim.fn.fnamemodify(expanded, ":p")
  local stat = vim.uv.fs_stat(absolute)

  if stat and stat.type == "directory" then
    absolute = vim.fs.joinpath(absolute, DEFAULT_NAME)
  elseif not stat then
    if looks_like_dir or not absolute:match("%.%w+$") then
      pcall(vim.fn.mkdir, absolute, "p")
      absolute = vim.fs.joinpath(absolute, DEFAULT_NAME)
    else
      local parent = vim.fs.dirname(absolute)
      if parent and parent ~= "" then
        pcall(vim.fn.mkdir, parent, "p")
      end
    end
  else
    local parent = vim.fs.dirname(absolute)
    if parent and parent ~= "" then
      pcall(vim.fn.mkdir, parent, "p")
    end
  end

  local parent_dir = vim.fs.dirname(absolute)
  if parent_dir and not vim.uv.fs_access(parent_dir, "W") then
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
      x = safe_tostring(round(x, 0.01))
    elseif type(x) == "table" then
      local ok, inspected = pcall(vim.inspect, x)
      x = ok and inspected or safe_tostring(x)
    else
      x = safe_tostring(x)
    end

    t[#t + 1] = x
  end
  return table.concat(t, " ")
end

local function format_message(format_str, ...)
  local fmt = safe_tostring(format_str)
  local ok, result = pcall(string.format, fmt, ...)

  if ok then
    return result
  end

  local suffix = make_string(...)
  return suffix ~= "" and (fmt .. " " .. suffix) or fmt
end

local function format_log(level_name, msg, source_info)
  local parts = {
    os.date("%Y-%m-%d %H:%M:%S"),
    string.format("[%s]", level_name),
  }

  if source_info then
    table.insert(parts, string.format("[%s:%d]", source_info.path, source_info.line))
  end

  table.insert(parts, safe_tostring(msg))
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

local function get_log_options()
  local ok, config = pcall(require, "checkmate.config")
  if not ok or type(config) ~= "table" or type(config.options) ~= "table" or type(config.options.log) ~= "table" then
    return {}
  end
  return config.options.log
end

local function normalize_level(level)
  if type(level) == "string" then
    return level_map[level:lower()] or M.levels.INFO
  end
  if type(level) == "number" then
    return level
  end
  return M.levels.INFO
end

local function get_max_file_size_bytes(max_file_size)
  local kb = tonumber(max_file_size) or DEFAULT_MAX_FILE_SIZE_KB
  if kb <= 0 then
    kb = DEFAULT_MAX_FILE_SIZE_KB
  end
  return kb * 1024
end

local function close_log_file()
  if log_file then
    pcall(function()
      log_file:close()
    end)
    log_file = nil
  end
end

local function write_log_line(line)
  if not log_file then
    return
  end

  local ok = pcall(function()
    log_file:write(line .. "\n")
    log_file:flush()
  end)

  if not ok then
    close_log_file()
  end
end

local function log_at_level(level, level_name, message_maker, ...)
  local options = get_log_options()
  local current_level = normalize_level(options.level)

  -- skip if current level is higher than this message's level
  if level < current_level then
    return
  end

  local ok, msg = pcall(message_maker, ...)
  if not ok then
    msg = "[log] failed to create log message: " .. safe_tostring(msg)
  end

  -- get source info if configured
  local source_info = nil
  if false then
    source_info = get_source_info(4)
  end

  local formatted = format_log(level_name, msg, source_info)

  if options.use_file and log_file then
    write_log_line(formatted)
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
      return log_at_level(level, level_name, format_message, fmt, ...)
    end

    -- Lazy logging: M.lazy_debug(function() return expensive_calculation() end)
    M["lazy_" .. name] = function(fn)
      return log_at_level(level, level_name, function(f)
        if not vim.is_callable(f) then
          return "[log] lazy logger expected function, got " .. type(f)
        end

        local ok, result = pcall(f)
        if not ok then
          return "[log] lazy logger failed: " .. safe_tostring(result)
        end
        return make_string(result)
      end, fn)
    end
  end
end

function M.setup()
  local options = get_log_options()

  if options.use_file then
    close_log_file()

    log_file_path = get_log_file_path(options.file_path)

    local append_mode = true
    local file_size = get_file_size(log_file_path)
    local max_file_size = get_max_file_size_bytes(options.max_file_size)
    if file_size > max_file_size then
      append_mode = false
    end

    local ok, file = pcall(io.open, log_file_path, append_mode and "a" or "w")

    if ok and file then
      log_file = file
      local info = {
        path = log_file_path,
        max_file_size = tostring(max_file_size / (1024 ^ 2)) .. " mb",
      }
      write_log_line(format_log("INFO", "[log] Checkmate logger initialized:\n" .. vim.inspect(info), nil))
    else
      vim.notify("Checkmate: Failed to open log file: " .. safe_tostring(log_file_path), vim.log.levels.ERROR)
    end
  end
end

function M.shutdown()
  close_log_file()
end

function M.get_log_path()
  return log_file_path
end

---@param opts? {scratch?: "floating" | "split"}
function M.open(opts)
  opts = type(opts) == "table" and opts or {}

  if opts.scratch then
    local scratch =
      require("checkmate.ui.scratch").open({ floating = opts.scratch == "floating", ft = "checkmate_log" })

    if log_file_path and vim.fn.filereadable(log_file_path) == 1 then
      local ok, lines = pcall(vim.fn.readfile, log_file_path)
      scratch:set(ok and lines or { "Log file not found or not readable: " .. log_file_path })
    else
      scratch:set({ "Log file not found or not readable: " .. (log_file_path or "no path set") })
    end
  else
    if not log_file_path then
      vim.notify("Checkmate: Log file path is not set", vim.log.levels.WARN)
      return
    end
    ---@diagnostic disable-next-line: param-type-mismatch
    pcall(vim.cmd, "tabnew " .. vim.fn.fnameescape(log_file_path))
  end
end

function M.clear()
  local options = get_log_options()

  if options.use_file then
    close_log_file()
    log_file_path = log_file_path or get_log_file_path(options.file_path)

    local ok, file = pcall(io.open, log_file_path, "w")
    if ok and file then
      log_file = file
      M.info("Log file cleared")
    end
  end
end

function M.log_error(err, context)
  if err then
    M.fmt_error("%s: %s", context or "Error", err)
    return true
  end
  return false
end

-- exposed for testing
M._get_log_file_path = get_log_file_path

create_logger_methods()

return M
