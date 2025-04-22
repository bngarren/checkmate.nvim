-- Config
---@class checkmate.Config.mod
local M = {}

local util = require("checkmate.util")

-- Namespace for plugin-related state
M.ns = vim.api.nvim_create_namespace("checkmate")

--- Checkmate configuration
---@class checkmate.Config
---@field enabled boolean Whether the plugin is enabled
---@field notify boolean Whether to show notifications
---@field log checkmate.LogSettings Logging settings
---@field keys ( table<string, checkmate.Action>| false ) Keymappings (false to disable)
---@field todo_markers checkmate.TodoMarkers Characters for todo markers (checked and unchecked)
---@field default_list_marker "-" | "*" | "+" Default list item marker to be used when creating new Todo items
---@field style checkmate.StyleSettings Highlight settings
---@field enter_insert_after_new boolean Enter insert mode after `:CheckmateCreate`
--- Depth within a todo item's hierachy from which actions (e.g. toggle) will act on the parent todo item
--- Examples:
--- 0 = toggle only triggered when cursor/selection includes same line as the todo item/marker
--- 1 = toggle triggered when cursor/selection includes any direct child of todo item
--- 2 = toggle triggered when cursor/selection includes any 2nd level children of todo item
---@field todo_action_depth integer
---@field metadata checkmate.Metadata

---@alias checkmate.Action "toggle" | "check" | "uncheck" | "create"

---@class checkmate.LogSettings
--- Any messages above this level will be logged
---@field level (
---    | "trace"
---    | "debug"
---    | "info"
---    | "warn"
---    | "error"
---    | "fatal"
---    | vim.log.levels.DEBUG
---    | vim.log.levels.ERROR
---    | vim.log.levels.INFO
---    | vim.log.levels.TRACE
---    | vim.log.levels.WARN)?
--- Should print log output to a file
--- Open with `:Checkmate debug_file`
---@field use_file boolean
--- The default path on-disk where log files will be written to.
--- Defaults to `~/.local/share/nvim/checkmate/current.log` (Unix) or `C:\Users\USERNAME\AppData\Local\nvim-data\checkmate\current.log` (Windows)
---@field file_path string?
--- Should print log output to a scratch buffer
--- Open with `require("checkmate").debug_log()`
---@field use_buffer boolean

---@class checkmate.TodoMarkers
---@field unchecked string Character used for unchecked items
---@field checked string Character used for checked items

---@class checkmate.StyleSettings Customize the style of markers and content
---@field list_marker_unordered vim.api.keyset.highlight Highlight settings for unordered list markers (-,+,*)
---@field list_marker_ordered vim.api.keyset.highlight Highlight settings for ordered (numerical) list markers (1.,2.)
---@field unchecked_marker vim.api.keyset.highlight Highlight settings for unchecked markers
---Highlight settings for main content of unchecked todo items
---This is typically the first line/paragraph
---@field unchecked_main_content vim.api.keyset.highlight
---Highlight settings for additional content of unchecked todo items
---This is the content below the first line/paragraph
---@field unchecked_additional_content vim.api.keyset.highlight
---@field checked_marker vim.api.keyset.highlight Highlight settings for checked markers
---Highlight settings for main content of checked todo items
---This is typically the first line/paragraph
---@field checked_main_content vim.api.keyset.highlight
---Highlight settings for additional content of checked todo items
---This is the content below the first line/paragraph
---@field checked_additional_content vim.api.keyset.highlight

---@class checkmate.MetadataProps
---Additional string values that can be used interchangably with the canonical tag name.
---E.g. @started could have aliases of `{"initiated", "began"}` so that @initiated and @began could
---also be used and have the same styling/functionality
---@field aliases string[]?
---Highlight settings or function that returns highlight settings based on the metadata's current value
---@field style vim.api.keyset.highlight|fun(value:string):vim.api.keyset.highlight
---Function that returns the default value for this metadata tag
---@field get_value fun():string

---A table of canonical metadata tag names and associated properties that define the look and function of the tag
---@alias checkmate.Metadata table<string, checkmate.MetadataProps>

---@type checkmate.Config
local _DEFAULTS = {
  enabled = true,
  notify = true,
  log = {
    level = "info",
    use_file = false,
    use_buffer = true,
  },
  -- Default keymappings
  keys = {
    ["<leader>Tt"] = "toggle", -- Toggle todo item
    ["<leader>Td"] = "check", -- Set todo item as checked (done)
    ["<leader>Tu"] = "uncheck", -- Set todo item as unchecked (not done)
    ["<leader>Tn"] = "create", -- Create todo item
  },
  default_list_marker = "-",
  todo_markers = {
    unchecked = "□",
    checked = "✔",
  },
  style = {
    -- List markers, such as "-" and "1."
    list_marker_unordered = {
      fg = util.blend(
        util.color("Normal", "fg", "#bbbbbb"), -- Fallback to light gray
        util.color("Normal", "bg", "#222222"), -- Fallback to dark gray
        0.2
      ),
    },
    list_marker_ordered = {
      fg = util.blend(
        util.color("Normal", "fg", "#bbbbbb"), -- Fallback to light gray
        util.color("Normal", "bg", "#222222"), -- Fallback to dark gray
        0.5
      ),
    },

    -- Unchecked todo items
    unchecked_marker = { fg = "#ff9500", bold = true }, -- The marker itself
    unchecked_main_content = { fg = "#ffffff" }, -- Style settings for main content: typically the first line/paragraph
    unchecked_additional_content = { fg = "#dddddd" }, -- Settings for additional content

    -- Checked todo items
    checked_marker = { fg = "#00cc66", bold = true }, -- The marker itself
    checked_main_content = { fg = "#aaaaaa", strikethrough = true }, -- Style settings for main content: typically the first line/paragraph
    checked_additional_content = { fg = "#aaaaaa" }, -- Settings for additional content
  },
  enter_insert_after_new = true, -- Should enter INSERT mode after :CheckmateCreate (new todo)
  todo_action_depth = 1, --  Depth within a todo item's hierachy from which actions (e.g. toggle) will act on the parent todo item

  metadata = {
    started = {
      aliases = { "init" },
      style = { fg = "#9fd6d5" },
      get_value = function()
        return tostring(os.date("%Y-%m-%d"))
      end,
    },
    done = {
      aliases = { "completed", "finished" },
      style = { fg = "#96de7a" },
      get_value = function()
        return tostring(os.date("%Y-%m-%d"))
      end,
    },
    priority = {
      style = function(value)
        -- Return different styles based on priority value
        if value:match("[Hh]igh") then
          return { fg = "#ff5555", bold = true }
        elseif value:match("[Mm]edium") then
          return { fg = "#ffb86c" }
        else -- low or default
          return { fg = "#8be9fd" }
        end
      end,
      get_value = function()
        return "medium" -- Default priority
      end,
    },
  },
}

-- Mark as not loaded initially
vim.g.loaded_checkmate = false

-- Combine all defaults
local defaults = vim.tbl_deep_extend("force", _DEFAULTS, {})

-- Runtime state
M._running = false

-- The active configuration
---@type checkmate.Config
---@diagnostic disable-next-line: missing-fields
M.options = {}

local function validate_type(value, expected_type, path, allow_nil)
  if value == nil then
    return allow_nil
  end

  if type(value) ~= expected_type then
    error(string.format("%s must be a %s", path, expected_type))
  end

  return true
end

-- Validate user provided options
local function validate_options(opts)
  if opts == nil then
    return true
  end

  if type(opts) ~= "table" then
    error("Options must be a table")
  end

  -- Validate basic options
  validate_type(opts.enabled, "boolean", "enabled", true)
  validate_type(opts.notify, "boolean", "notify", true)
  validate_type(opts.enter_insert_after_new, "boolean", "enter_insert_after_new", true)

  -- Validate log settings
  if opts.log ~= nil then
    validate_type(opts.log, "table", "log", false)

    if opts.log.level ~= nil then
      if type(opts.log.level) ~= "string" and type(opts.log.level) ~= "number" then
        error("log.level must be a string or number")
      end
    end

    validate_type(opts.log.use_buffer, "boolean", "log.use_buffer", true)
    validate_type(opts.log.use_file, "boolean", "log.use_file", true)
    validate_type(opts.log.file_path, "string", "log.file_path", true)
  end

  -- Validate keys
  if opts.keys ~= nil and opts.keys ~= false then
    validate_type(opts.keys, "table", "keys", false)
  end

  -- Validate todo_markers
  if opts.todo_markers ~= nil then
    validate_type(opts.todo_markers, "table", "todo_markers", false)
    validate_type(opts.todo_markers.checked, "string", "todo_markers.checked", true)
    validate_type(opts.todo_markers.unchecked, "string", "todo_markers.unchecked", true)
  end

  -- Validate default_list_marker
  if opts.default_list_marker ~= nil then
    validate_type(opts.default_list_marker, "string", "default_list_marker", false)

    if not (opts.default_list_marker == "-" or opts.default_list_marker == "*" or opts.default_list_marker == "+") then
      error("default_list_marker must be one of: '-', '*', '+'")
    end
  end

  -- Validate style
  if opts.style ~= nil then
    validate_type(opts.style, "table", "style", false)

    local style_fields = {
      "list_marker_unordered",
      "list_marker_ordered",
      "unchecked",
      "unchecked_main_content",
      "unchecked_child_content",
      "checked",
      "checked_main_content",
      "checked_child_content",
    }

    for _, field in ipairs(style_fields) do
      validate_type(opts.style[field], "table", "style." .. field, true)
    end
  end

  -- Validate todo_action_depth
  if opts.todo_action_depth ~= nil then
    validate_type(opts.todo_action_depth, "number", "todo_action_depth", false)

    if math.floor(opts.todo_action_depth) ~= opts.todo_action_depth or opts.todo_action_depth < 0 then
      error("todo_action_depth must be a non-negative integer")
    end
  end

  return true
end

-- Initialize plugin if needed
function M.initialize_if_needed()
  if vim.g.loaded_checkmate then
    return
  end

  -- Merge defaults with any global user configuration
  M.options = vim.tbl_deep_extend("force", defaults, vim.g.checkmate_config or {})

  -- Mark as loaded
  vim.g.loaded_checkmate = true

  -- Auto-start if enabled
  if M.options.enabled then
    M.start()
  end
end

--- Setup function
---@param opts? checkmate.Config
function M.setup(opts)
  -- If already running, stop first to clean up
  if M._running then
    M.stop()
  end

  opts = opts or {}
  local success, result = pcall(validate_options, opts)
  if not success then
    vim.notify("Checkmate.nvim failed to validate options: " .. result, vim.log.levels.ERROR)
    return M.options
  end

  -- Initialize if this is the first call
  if not vim.g.loaded_checkmate then
    M.initialize_if_needed()
  end

  -- Update configuration with provided options
  M.options = vim.tbl_deep_extend("force", M.options, opts)

  M.start()

  return M.options
end

function M.is_loaded()
  return vim.g.loaded_checkmate
end
function M.is_running()
  return M._running
end

function M.start()
  if M._running then
    return
  end
  M._running = true

  local augroup = vim.api.nvim_create_augroup("checkmate", { clear = true })

  M._active_buffers = {}

  -- If buffer is .todo file, ensure it is treated as Markdown filetype and then
  -- setup the API with this buffer
  vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    group = augroup,
    pattern = "*.todo",
    callback = function()
      local buf = vim.api.nvim_get_current_buf()

      if vim.bo[buf].filetype ~= "markdown" then
        vim.bo[buf].filetype = "markdown"
      end

      -- Setup API only once per buffer
      -- lazy loading the api module
      if not M._active_buffers[buf] then
        local success = require("checkmate.api").setup(buf)
        if success then
          M._active_buffers[buf] = true
          vim.b[buf].checkmate_api_setup_complete = true
        end
      end
      -- API setup will run some buffer modifications, e.g. converting from pure markdown to our replacements for todo items
      -- We don't want this to be seen as "modified" upon initial load of the buffer
      vim.cmd("set nomodified")
    end,
  })

  -- Cleanup when buffer is deleted
  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    callback = function(args)
      local buf = args.buf
      if M._active_buffers[buf] then
        M._active_buffers[buf] = nil
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      M.stop()
    end,
  })
end

function M.stop()
  if not M._running then
    return
  end
  M._running = false

  -- Cleanup buffer state
  for buf, _ in pairs(M._active_buffers or {}) do
    pcall(function()
      vim.b[buf].checkmate_api_setup_complete = nil
    end)
  end
  M._active_buffers = {}

  require("checkmate.log").shutdown()
  vim.api.nvim_del_augroup_by_name("checkmate")
end

-- Initialize on module load
M.initialize_if_needed()

return M
