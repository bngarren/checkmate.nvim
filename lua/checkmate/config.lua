-- Config
---@class checkmate.Config.mod
local M = {}

-- Namespace for plugin-related state
M.ns = vim.api.nvim_create_namespace("checkmate")

-----------------------------------------------------
---Checkmate configuration
---@class checkmate.Config
---
---Whether the plugin is enabled
---@field enabled boolean
---
---Whether to show notifications
---@field notify boolean
---
--- Filenames or patterns to activate Checkmate on when the filetype is 'markdown'
--- - Patterns are CASE-SENSITIVE (e.g., "TODO" won't match "todo.md")
--- - Include variations like {"TODO", "todo"} for case-insensitive matching
--- - Patterns can include wildcards (*) for more flexible matching
--- - Patterns without extensions (e.g., "TODO") will match files both with and without Markdown extension (e.g., "TODO" and "TODO.md")
--- - Patterns with extensions (e.g., "TODO.md") will only match files with that exact extension
--- - Examples: {"todo.md", "TODO", "*.todo", "todos/*"}
---@field files string[]
---
---Logging settings
---@field log checkmate.LogSettings
---
---Keymappings (false to disable)
---Note: mappings for metadata are set separately in the `metadata` table
---@field keys ( table<string, checkmate.Action>| false )
---
---Characters for todo markers (checked and unchecked)
---@field todo_markers checkmate.TodoMarkers
---
---Default list item marker to be used when creating new Todo items
---@field default_list_marker "-" | "*" | "+"
---
---Highlight settings (override merge with defaults)
---Default style will attempt to integrate with current colorscheme (experimental)
---May need to tweak some colors to your liking
---@field style checkmate.StyleSettings?
---
--- Depth within a todo item's hierachy from which actions (e.g. toggle) will act on the parent todo item
--- Examples:
--- 0 = toggle only triggered when cursor/selection includes same line as the todo item/marker
--- 1 = toggle triggered when cursor/selection includes any direct child of todo item
--- 2 = toggle triggered when cursor/selection includes any 2nd level children of todo item
---@field todo_action_depth integer
---
---Enter insert mode after `:CheckmateCreate`, require("checkmate").create()
---@field enter_insert_after_new boolean
---
---Enable/disable the todo count indicator (shows number of sub-todo items completed)
---@field show_todo_count boolean
---
---Position to show the todo count indicator (if enabled)
--- `eol` = End of the todo item line
--- `inline` = After the todo marker, before the todo item text
---@field todo_count_position checkmate.TodoCountPosition
---
---Formatter function for displaying the todo count indicator
---@field todo_count_formatter fun(completed: integer, total: integer)?: string
---
---Whether to count sub-todo items recursively in the todo_count
---If true, all nested todo items will count towards the parent todo's count
---@field todo_count_recursive boolean
---
---Whether to register keymappings defined in each metadata definition. If set the false,
---metadata actions (insert/remove) would need to be called programatically or otherwise mapped manually
---@field use_metadata_keymaps boolean
---
---Custom @tag(value) fields that can be toggled on todo items
---To add custom metadata tag, simply add a field and props to this metadata table and it
---will be merged with defaults.
---@field metadata checkmate.Metadata
---
---Config for the linter
---@field linter checkmate.LinterConfig?

-----------------------------------------------------

---Actions that can be used for keymaps in the `keys` table of 'checkmate.Config'
---@alias checkmate.Action "toggle" | "check" | "uncheck" | "create" | "remove_all_metadata"

---Options for todo count indicator position
---@alias checkmate.TodoCountPosition "eol" | "inline"

-----------------------------------------------------

---@class checkmate.LogSettings
--- Any messages above this level will be logged
---@field level ("trace" | "debug" | "info" | "warn" | "error" | "fatal" | vim.log.levels.DEBUG | vim.log.levels.ERROR | vim.log.levels.INFO | vim.log.levels.TRACE | vim.log.levels.WARN)?
---
--- Should print log output to a file
--- Open with `:Checkmate debug_file`
---@field use_file boolean
---
--- The default path on-disk where log files will be written to.
--- Defaults to `~/.local/share/nvim/checkmate/current.log` (Unix) or `C:\Users\USERNAME\AppData\Local\nvim-data\checkmate\current.log` (Windows)
---@field file_path string?
---
--- Should print log output to a scratch buffer
--- Open with `require("checkmate").debug_log()`
---@field use_buffer boolean

-----------------------------------------------------

---@class checkmate.TodoMarkers
---Character used for unchecked items
---@field unchecked string
---
---Character used for checked items
---@field checked string

-----------------------------------------------------

---@alias checkmate.StyleKey
---| "list_marker_unordered"
---| "list_marker_ordered"
---| "unchecked_marker"
---| "unchecked_main_content"
---| "unchecked_additional_content"
---| "checked_marker"
---| "checked_main_content"
---| "checked_additional_content"
---| "todo_count_indicator"

---Customize the style of markers and content
---@class checkmate.StyleSettings : table<checkmate.StyleKey, vim.api.keyset.highlight>
---
---Highlight settings for unordered list markers (-,+,*)
---@field list_marker_unordered vim.api.keyset.highlight?
---
---Highlight settings for ordered (numerical) list markers (1.,2.)
---@field list_marker_ordered vim.api.keyset.highlight?
---
---Highlight settings for unchecked markers
---@field unchecked_marker vim.api.keyset.highlight?
---
---Highlight settings for main content of unchecked todo items
---This is typically the first line/paragraph
---@field unchecked_main_content vim.api.keyset.highlight?
---
---Highlight settings for additional content of unchecked todo items
---This is the content below the first line/paragraph
---@field unchecked_additional_content vim.api.keyset.highlight?
---
---Highlight settings for checked markers
---@field checked_marker vim.api.keyset.highlight?
---
---Highlight settings for main content of checked todo items
---This is typically the first line/paragraph
---@field checked_main_content vim.api.keyset.highlight?
---
---Highlight settings for additional content of checked todo items
---This is the content below the first line/paragraph
---@field checked_additional_content vim.api.keyset.highlight?
---
---Highlight settings for the todo count indicator (e.g. x/x)
---@field todo_count_indicator vim.api.keyset.highlight?

-----------------------------------------------------

---A table of canonical metadata tag names and associated properties that define the look and function of the tag
---@alias checkmate.Metadata table<string, checkmate.MetadataProps>

---@class checkmate.MetadataProps
---Additional string values that can be used interchangably with the canonical tag name.
---E.g. @started could have aliases of `{"initiated", "began"}` so that @initiated and @began could
---also be used and have the same styling/functionality
---@field aliases string[]?
---
---Highlight settings or function that returns highlight settings based on the metadata's current value
---@field style vim.api.keyset.highlight|fun(value:string):vim.api.keyset.highlight
---
---Function that returns the default value for this metadata tag
---@field get_value fun():string
---
---Keymapping for toggling this metadata tag
---@field key string?
---
---Used for displaying metadata in a consistent order
---@field sort_order integer?
---
---Moves the cursor to the metadata after it is inserted
---  - "tag" - moves to the beginning of the tag
---  - "value" - moves to the beginning of the value
---  - false - disables jump (default)
---@field jump_to_on_insert "tag" | "value" | false?
---
---Selects metadata text in visual mode after metadata is inserted
---The `jump_to_on_insert` field must be set (not false)
---The selected text will be the tag or value, based on jump_to_on_insert setting
---Default (false) - off
---@field select_on_insert boolean?
---
---Callback to run when this metadata tag is added to a todo item
---E.g. can be used to change the todo item state
---@field on_add fun(todo_item: checkmate.TodoItem)?
---
---Callback to run when this metadata tag is removed from a todo item
---E.g. can be used to change the todo item state
---@field on_remove fun(todo_item: checkmate.TodoItem)?

---@class checkmate.LinterConfig
---
---Whether to enable the linter (vim.diagnostics)
---Default: true
---@field enabled boolean
---
---Map of issues to diagnostic severity level
---@field severity table<string, vim.diagnostic.Severity>?
--- TODO: @field auto_fix boolean Auto fix on buffer write

-----------------------------------------------------

---@type checkmate.Config
local _DEFAULTS = {
  enabled = true,
  notify = true,
  files = { "todo", "TODO", "*.todo*" }, -- matches TODO, TODO.md, .todo.md
  log = {
    level = "info",
    use_file = false,
    use_buffer = false,
  },
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
  style = {},
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
      jump_to_on_insert = "value",
      select_on_insert = true,
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
  linter = {
    enabled = true,
  },
}

M._state = {
  initialized = false, -- Has setup() been called? Prevent duplicate initializations of config.
  running = false, -- Is the plugin currently active?
  active_buffers = {}, -- Track which buffers have been set up (i.e., have Checkmate functionality loaded)
  user_style = nil, -- Track user-provided style settings (to reapply after colorscheme changes)
}

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

  ---@cast opts checkmate.Config

  -- Validate basic options
  validate_type(opts.enabled, "boolean", "enabled", true)
  validate_type(opts.notify, "boolean", "notify", true)
  validate_type(opts.enter_insert_after_new, "boolean", "enter_insert_after_new", true)

  -- Validate files
  validate_type(opts.files, "table", "files", true)
  if opts.files and #opts.files > 0 then
    for i, pattern in ipairs(opts.files) do
      if type(pattern) ~= "string" then
        error("files[" .. i .. "] must be a string")
      end
    end
  end

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

    ---@type table<checkmate.StyleKey>
    local style_fields = {
      "list_marker_unordered",
      "list_marker_ordered",
      "unchecked_marker",
      "unchecked_main_content",
      "unchecked_additional_content",
      "checked_marker",
      "checked_main_content",
      "checked_additional_content",
      "todo_count_indicator",
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

--- Setup function
---@param opts? checkmate.Config
function M.setup(opts)
  -- Prevent double initialization but allow reconfiguration
  local is_reconfigure = M._state.initialized

  -- 1. Start with static defaults
  local config = vim.deepcopy(_DEFAULTS)

  -- 2. (optional) Merge in global checkmate config
  if type(vim.g.checkmate_config) == "table" then
    config = vim.tbl_deep_extend("force", config, vim.g.checkmate_config)
  end

  -- 3. Merge override user opts
  if type(opts) == "table" then
    assert(validate_options(opts))
    config = vim.tbl_deep_extend("force", config, opts)
  end

  -- capture the explicit user-provided style (for later colorscheme updates)
  M._state.user_style = config.style and vim.deepcopy(config.style) or {}

  -- 4. Finally, backfill any missing keys from theme defaults
  local colorscheme_aware_style = require("checkmate.theme").generate_style_defaults()
  config.style = vim.tbl_deep_extend("keep", config.style or {}, colorscheme_aware_style)

  -- Store the resulting configuration
  M.options = config

  M._state.initialized = true

  -- Handle reconfiguration: notify dependent modules
  if is_reconfigure then
    M.notify_config_changed()
  else
    -- Save the intial setup's user opts
    vim.g.checkmate_user_opts = opts or {}
  end

  return M.options
end

-- Notify modules when config has changed
function M.notify_config_changed()
  if not M._state.running then
    return
  end

  -- Update linter config if loaded
  if package.loaded["checkmate.linter"] and M.options.linter then
    require("checkmate.linter").setup(M.options.linter)
  end

  -- Refresh highlights
  if package.loaded["checkmate.highlights"] then
    require("checkmate.highlights").setup_highlights()

    -- Re-apply to all buffers
    for bufnr, _ in pairs(M._state.active_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        require("checkmate.highlights").apply_highlighting(bufnr, {
          debug_reason = "config update",
        })
      end
    end
  end

  -- Handle enable/disable state changes
  local checkmate = package.loaded["checkmate"]
  if checkmate then
    if M._state.running and not M.options.enabled then
      -- Schedule to avoid doing it during another operation
      vim.schedule(function()
        require("checkmate").stop()
      end)
    elseif not M._state.running and M.options.enabled then
      vim.schedule(function()
        require("checkmate").start()
      end)
    end
  end
end

function M.is_initialized()
  return M._state.initialized
end

function M.is_running()
  return M._state.running
end

-- Start the configuration system
function M.start()
  if M._state.running then
    return
  end

  -- Update running state
  M._state.running = true
  M._state.active_buffers = {}

  -- Log the startup if the logger is already initialized
  if package.loaded["checkmate.log"] then
    require("checkmate.log").debug("Config system started", { module = "config" })
  end
end

function M.stop()
  if not M.is_running() then
    return
  end

  -- Cleanup buffer state
  for bufnr, _ in pairs(M.get_active_buffers()) do
    pcall(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        -- Clear buffer highlights
        vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)

        -- Clear buffer-specific diagnostics
        if package.loaded["checkmate.linter"] then
          local linter = require("checkmate.linter")
          linter.disable(bufnr)
        end
        -- Clear highlights and caches
        if package.loaded["checkmate.highlights"] then
          require("checkmate.highlights").clear_line_cache(bufnr)
        end

        -- Reset buffer state
        vim.b[bufnr].checkmate_setup_complete = nil
      end
    end)
  end

  -- Reset active buffers tracking
  M._state.active_buffers = {}

  -- Log the shutdown if the logger is still available
  if package.loaded["checkmate.log"] then
    require("checkmate.log").debug("Config system stopped", { module = "config" })
  end
end

-- Register a buffer as active - called during API setup
---@param bufnr integer The buffer number to register
function M.register_buffer(bufnr)
  if not M._state.active_buffers then
    M._state.active_buffers = {}
  end
  M._state.active_buffers[bufnr] = true
end

-- Unregister a buffer (called when buffer is deleted)
---@param bufnr integer The buffer number to unregister
function M.unregister_buffer(bufnr)
  if M._state.active_buffers then
    M._state.active_buffers[bufnr] = nil
  end
  -- Buffer-local vars are automatically cleaned up when buffer is deleted
end

-- Get all currently active buffers
---@return table<integer, boolean> The active buffers table
function M.get_active_buffers()
  return M._state.active_buffers or {}
end

return M
