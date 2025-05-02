-- Config
---@class checkmate.Config.mod
local M = {}

local util = require("checkmate.util")

-- Namespace for plugin-related state
M.ns = vim.api.nvim_create_namespace("checkmate")

-----------------------------------------------------
--- Checkmate configuration
---@class checkmate.Config
---@field enabled boolean Whether the plugin is enabled
---@field notify boolean Whether to show notifications
---@field log checkmate.LogSettings Logging settings
---Keymappings (false to disable)
---Note: mappings for metadata are set separately in the `metadata` table
---@field keys ( table<string, checkmate.Action>| false )
---@field todo_markers checkmate.TodoMarkers Characters for todo markers (checked and unchecked)
---@field default_list_marker "-" | "*" | "+" Default list item marker to be used when creating new Todo items
---@field style checkmate.StyleSettings Highlight settings
--- Depth within a todo item's hierachy from which actions (e.g. toggle) will act on the parent todo item
--- Examples:
--- 0 = toggle only triggered when cursor/selection includes same line as the todo item/marker
--- 1 = toggle triggered when cursor/selection includes any direct child of todo item
--- 2 = toggle triggered when cursor/selection includes any 2nd level children of todo item
---@field todo_action_depth integer
---@field enter_insert_after_new boolean Enter insert mode after `:CheckmateCreate`
---Enable/disable the todo count indicator (shows number of sub-todo items completed)
---@field show_todo_count boolean
---Position to show the todo count indicator (if enabled)
---eol = End of the todo item line
---inline = After the todo marker, before the todo item text
---@field todo_count_position checkmate.TodoCountPosition
---Formatter function for displaying the todo count indicator
---@field todo_count_formatter? fun(completed: integer, total: integer): string
---Whether to count sub-todo items recursively in the todo_count
---If true, all nested todo items will count towards the parent todo's count
---@field todo_count_recursive boolean
---Whether to register keymappings defined in each metadata definition. If set the false,
---metadata actions (insert/remove) would need to be called programatically or otherwise mapped manually
---@field use_metadata_keymaps boolean
---Custom @tag(value) fields that can be toggled on todo items
---@field metadata checkmate.Metadata

---Actions that can be used for keymaps in the `keys` table of 'checkmate.Config'
---@alias checkmate.Action "toggle" | "check" | "uncheck" | "create" | "remove_all_metadata"

---Options for todo count indicator position
---@alias checkmate.TodoCountPosition "eol" | "inline"

-----------------------------------------------------
---@class checkmate.LogSettings
--- Any messages above this level will be logged
---@field level ("trace" | "debug" | "info" | "warn" | "error" | "fatal" | vim.log.levels.DEBUG | vim.log.levels.ERROR | vim.log.levels.INFO | vim.log.levels.TRACE | vim.log.levels.WARN)?
--- Should print log output to a file
--- Open with `:Checkmate debug_file`
---@field use_file boolean
--- The default path on-disk where log files will be written to.
--- Defaults to `~/.local/share/nvim/checkmate/current.log` (Unix) or `C:\Users\USERNAME\AppData\Local\nvim-data\checkmate\current.log` (Windows)
---@field file_path string?
--- Should print log output to a scratch buffer
--- Open with `require("checkmate").debug_log()`
---@field use_buffer boolean

-----------------------------------------------------
---@class checkmate.TodoMarkers
---@field unchecked string Character used for unchecked items
---@field checked string Character used for checked items

-----------------------------------------------------
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
---Highlight settings for the todo count indicator (e.g. x/x)
---@field todo_count_indicator vim.api.keyset.highlight

-----------------------------------------------------
---@class checkmate.MetadataProps
---Additional string values that can be used interchangably with the canonical tag name.
---E.g. @started could have aliases of `{"initiated", "began"}` so that @initiated and @began could
---also be used and have the same styling/functionality
---@field aliases string[]?
---Highlight settings or function that returns highlight settings based on the metadata's current value
---@field style vim.api.keyset.highlight|fun(value:string):vim.api.keyset.highlight
---Function that returns the default value for this metadata tag
---@field get_value fun():string
---Keymapping for toggling this metadata tag
---@field key string?
---Used for displaying metadata in a consistent order
---@field sort_order integer?
---Callback to run when this metadata tag is added to a todo item
---E.g. can be used to change the todo item state
---@field on_add fun(todo_item: checkmate.TodoItem)?
---Callback to run when this metadata tag is removed from a todo item
---E.g. can be used to change the todo item state
---@field on_remove fun(todo_item: checkmate.TodoItem)?

---A table of canonical metadata tag names and associated properties that define the look and function of the tag
---@alias checkmate.Metadata table<string, checkmate.MetadataProps>

-----------------------------------------------------
---@type checkmate.Config
local _DEFAULTS = {
  enabled = true,
  notify = true,
  -- Default keymappings
  keys = {
    ["<leader>Tt"] = "toggle", -- Toggle todo item
    ["<leader>Tc"] = "check", -- Set todo item as checked (done)
    ["<leader>Tu"] = "uncheck", -- Set todo item as unchecked (not done)
    ["<leader>Tn"] = "create", -- Create todo item
    ["<leader>TR"] = "remove_all_metadata", -- Remove all metadata from a todo item
  },
  default_list_marker = "-",
  todo_markers = {
    unchecked = "□",
    checked = "✔",
  },
  style = {
    -- List markers, such as "-" and "1."
    list_marker_unordered = {
      -- Can use util functions to get existing highlight colors and blend them together
      -- This is one way to integrate with an existing colorscheme
      fg = util.blend(util.get_hl_color("Normal", "fg", "#bbbbbb"), util.get_hl_color("Normal", "bg", "#222222"), 0.2),
    },
    list_marker_ordered = {
      fg = util.blend(util.get_hl_color("Normal", "fg", "#bbbbbb"), util.get_hl_color("Normal", "bg", "#222222"), 0.5),
    },

    -- Unchecked todo items
    unchecked_marker = { fg = "#ff9500", bold = true }, -- The marker itself
    unchecked_main_content = { fg = "#ffffff" }, -- Style settings for main content: typically the first line/paragraph
    unchecked_additional_content = { fg = "#dddddd" }, -- Settings for additional content

    -- Checked todo items
    checked_marker = { fg = "#00cc66", bold = true }, -- The marker itself
    checked_main_content = { fg = "#aaaaaa", strikethrough = true }, -- Style settings for main content: typically the first line/paragraph
    checked_additional_content = { fg = "#aaaaaa" }, -- Settings for additional content

    -- Todo count indicator
    todo_count_indicator = {
      fg = util.blend("#e3b3ff", util.get_hl_color("Normal", "bg", "'#222222"), 0.9),
      bg = util.blend("#ffffff", util.get_hl_color("Normal", "bg", "'#222222"), 0.02),
      italic = true,
    },
  },
  todo_action_depth = 1, --  Depth within a todo item's hierachy from which actions (e.g. toggle) will act on the parent todo item
  enter_insert_after_new = true, -- Should enter INSERT mode after :CheckmateCreate (new todo)
  show_todo_count = true,
  todo_count_position = "eol",
  todo_count_recursive = true,
  use_metadata_keymaps = true,
  metadata = {
    -- Example: A @priority tag that has dynamic color based on the priority value
    priority = {
      style = function(_value)
        local value = _value:lower()
        if value == "high" then
          return { fg = "#ff5555", bold = true }
        elseif value == "medium" then
          return { fg = "#ffb86c" }
        elseif value == "low" then
          return { fg = "#8be9fd" }
        else -- fallback
          return { fg = "#8be9fd" }
        end
      end,
      get_value = function()
        return "medium" -- Default priority
      end,
      key = "<leader>Tp",
      sort_order = 10,
    },
    -- Example: A @started tag that uses a default date/time string when added
    started = {
      aliases = { "init" },
      style = { fg = "#9fd6d5" },
      get_value = function()
        return tostring(os.date("%m/%d/%y %H:%M"))
      end,
      key = "<leader>Ts",
      sort_order = 20,
    },
    -- Example: A @done tag that also sets the todo item state when it is added and removed
    done = {
      aliases = { "completed", "finished" },
      style = { fg = "#96de7a" },
      get_value = function()
        return tostring(os.date("%m/%d/%y %H:%M"))
      end,
      key = "<leader>Td",
      on_add = function(todo_item)
        require("checkmate").set_todo_item(todo_item, "checked")
      end,
      on_remove = function(todo_item)
        require("checkmate").set_todo_item(todo_item, "unchecked")
      end,
      sort_order = 30,
    },
  },
  log = {
    level = "info",
    use_file = false,
    use_buffer = false,
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

  -- Validate use_metadata_keymaps
  if opts.use_metadata_keymaps ~= nil then
    validate_type(opts.use_metadata_keymaps, "boolean", "use_metadata_keymaps", false)
  end

  -- Validate metadata
  if opts.metadata ~= nil then
    if type(opts.metadata) ~= "table" then
      error("metadata must be a table")
    end

    for meta_name, meta_props in pairs(opts.metadata) do
      validate_type(meta_props, "table", "metadata." .. meta_name, false)

      -- validate 'style' (can be table or function)
      if meta_props.style ~= nil then
        local style_type = type(meta_props.style)
        if style_type ~= "table" and style_type ~= "function" then
          error("metadata." .. meta_name .. ".style must be a table or function")
        end
      end

      -- validate 'get_value'
      validate_type(meta_props.get_value, "function", "metadata." .. meta_name .. ".get_value", true)

      -- validate 'key'
      validate_type(meta_props.key, "string", "metadata." .. meta_name .. ".key", true)

      -- validate 'sort_order'
      validate_type(meta_props.sort_order, "integer", "metadata." .. meta_name .. ".sort_order", true)

      -- validate 'on_add'
      validate_type(meta_props.on_add, "function", "metadata." .. meta_name .. ".on_add", true)

      -- validate 'on_remove'
      validate_type(meta_props.on_remove, "function", "metadata." .. meta_name .. ".on_remove", true)

      -- Validate aliases must be a table of strings
      if meta_props.aliases ~= nil then
        if type(meta_props.aliases) ~= "table" then
          error("metadata." .. meta_name .. ".aliases must be a table")
        end

        for i, alias in ipairs(meta_props.aliases) do
          if type(alias) ~= "string" then
            error("metadata." .. meta_name .. ".aliases[" .. i .. "] must be a string")
          end
        end
      end
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
