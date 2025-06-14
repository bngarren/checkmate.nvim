-- Config
---@class checkmate.Config.mod
local M = {}

-- Namespace for plugin-related state
M.ns = vim.api.nvim_create_namespace("checkmate")
M.ns_todos = vim.api.nvim_create_namespace("checkmate_todos")

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
---
--- Uses Unix-style glob patterns with the following rules:
--- - Patterns are CASE-SENSITIVE (e.g., "TODO" won't match "todo")
--- - Basename patterns (no slash): Match against filename only
---   - "TODO" matches any file named "TODO" regardless of path
---   - "*.md" matches any markdown file in any directory
---   - "*todo*" matches any file with "todo" in the name
--- - Path patterns (has slash):
---   - "docs/*.md" matches markdown files in any "docs" directory
---   - "/home/user/*.md" matches only in that specific directory (absolute)
---   - Both "docs/*.md" and "**/docs/*.md" behave the same (match at any depth)
--- - Glob syntax (refer to `h: vim.glob`):
---   - `*` matches any characters except /
---   - `**` matches any characters including / (recursive)
---   - `?` matches any single character
---   - `[abc]` matches any character in the set
---   - `{foo,bar}` matches either "foo" or "bar"
---
--- Examples:
--- - {"TODO", "todo"} - files named TODO (case variations)
--- - {"*.md"} - all markdown files
--- - {"*todo*", "*TODO*"} - files with "todo" in the name
--- - {"docs/*.md", "notes/*.md"} - markdown in specific directories
--- - {"project/**/todo.md"} - todo.md under any project directory
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
--- Depth within a todo item's hierarchy from which actions (e.g. toggle) will act on the parent todo item
--- Examples:
--- 0 = toggle only triggered when cursor/selection includes same line as the todo item/marker
--- 1 = toggle triggered when cursor/selection includes any direct child of todo item
--- 2 = toggle triggered when cursor/selection includes any 2nd level children of todo item
---@field todo_action_depth integer
---
---Enter insert mode after `:CheckmateCreate`, require("checkmate").create()
---@field enter_insert_after_new boolean
---
---Options for smart toggle behavior
---This allows an action on one todo item to recursively affect other todo items in the hierarchy in sensible manner
---The behavior is configurable with the following defaults:
--- - Toggling a todo item to checked will cause all direct children todos to become checked
--- - When all direct child todo items are checked, the parent todo will become checked
--- - Similarly, when a child todo is unchecked, it will ensure the parent todo also becomes unchecked if it was previously checked
--- - Unchecking a parent does not uncheck children by default. This can be changed.
---@field smart_toggle checkmate.SmartToggleSettings
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
---Settings for the archived todos section
---@field archive checkmate.ArchiveSettings?
---
---Config for the linter
---@field linter checkmate.LinterConfig?
---
---Turn off treesitter highlights (on by default)
---Buffer local
---See `:h treesitter-highlight`
---@field disable_ts_highlights? boolean

-----------------------------------------------------

---Actions that can be used for keymaps in the `keys` table of 'checkmate.Config'
---@alias checkmate.Action "toggle" | "check" | "uncheck" | "create" | "remove_all_metadata" | "archive"

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

--- The text string used for todo markers is expected to be 1 character length.
--- Multiple characters _may_ work but are not currently supported and could lead to unexpected results.
---@class checkmate.TodoMarkers
---Character used for unchecked items
---@field unchecked string
---
---Character used for checked items
---@field checked string

-----------------------------------------------------

---@class checkmate.SmartToggleSettings
---Whether to enable smart toggle behavior
---Default: true
---@field enabled boolean?
---
---How checking a parent affects its children
---  - "all_children": Check all descendants, including nested
---  - "direct_children": Only check direct children (default)
---  - "none": Don't propagate down
---@field check_down "all_children"|"direct_children"|"none"?
---
---How unchecking a parent affects its children
---  - "all_children": Uncheck all descendants, including nested
---  - "direct_children": Only uncheck direct children
---  - "none": Don't propagate down (default)
---@field uncheck_down "all_children"|"direct_children"|"none"?
---
---When a parent should become checked
---i.e, how a checked child affects its parent
---  - "all_children": When ALL descendants are checked, including nested
---  - "direct_children": When all direct children are checked (default)
---  - "none": Never auto-check parents
---@field check_up "all_children"|"direct_children"|"none"?
---
---When a parent should become unchecked
---i.e, how a unchecked child affects its parent
---  - "all_children": When ANY descendant is unchecked
---  - "direct_children": When any direct child is unchecked (default)
---  - "none": Never auto-uncheck parents
---@field uncheck_up "all_children"|"direct_children"|"none"?

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

-----------------------------------------------------

---@class checkmate.ArchiveSettings
---
---Defines the header section for the archived todos
---@field heading checkmate.ArchiveHeading
---
---Number of blank lines between archived todo items (root only)
---@field parent_spacing integer?
---
---How to arrange newly added archived todos
---If true, newly added todos will be added to the top of the archive section
---Default: true
---@field newest_first boolean?

---@class checkmate.ArchiveHeading
---
---Name for the archived todos section
---Default: "Archived"
---@field title string?
---
---The heading level (e.g. #, ##, ###, ####)
---Integers 1 to 6
---Default: 2 (##)
---@field level integer?

-----------------------------------------------------

---@class checkmate.LinterConfig
---
---Whether to enable the linter (vim.diagnostics)
---Default: true
---@field enabled boolean
---
---Map of issues to diagnostic severity level
---@field severity table<string, vim.diagnostic.Severity>?
--- TODO: @field auto_fix boolean Auto fix on buffer write
---
---Whether to use verbose linter/diagnostic messages
---Default: false
---@field verbose boolean?

-----------------------------------------------------

---@type checkmate.Config
local _DEFAULTS = {
  enabled = true,
  notify = true,
  -- Default file matching:
  --  - Any `todo` or `TODO` file, including with `.md` extension
  --  - Any `.todo` extension (can be ".todo" or ".todo.md")
  -- To activate Checkmate, the filename must match AND the filetype must be "markdown"
  files = {
    "todo",
    "TODO",
    "todo.md",
    "TODO.md",
    "*.todo",
    "*.todo.md",
  },
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
    ["<leader>Ta"] = "archive", -- Archive checked/completed todo items (move to bottom section)
  },
  default_list_marker = "-",
  todo_markers = {
    unchecked = "□",
    checked = "✔",
  },
  style = {},
  todo_action_depth = 1, --  Depth within a todo item's hierachy from which actions (e.g. toggle) will act on the parent todo item
  enter_insert_after_new = true, -- Should enter INSERT mode after :CheckmateCreate (new todo)
  smart_toggle = {
    enabled = true,
    check_down = "direct_children",
    uncheck_down = "none",
    check_up = "direct_children",
    uncheck_up = "direct_children",
  },
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
  archive = {
    heading = {
      title = "Archive",
      level = 2, -- e.g. ##
    },
    parent_spacing = 0, -- no extra lines between archived todos
    newest_first = true,
  },
  linter = {
    enabled = true,
  },
}

M._state = {
  user_style = nil, -- Track user-provided style settings (to reapply after colorscheme changes)
  active_buffers = {}, -- Track which buffers have checkmate active
}

-- The active configuration
---@type checkmate.Config
---@diagnostic disable-next-line: missing-fields
M.options = {}

local function validate_type(value, expected_type, path, allow_nil)
  if value == nil then
    if allow_nil ~= true then
      return false, string.format("%s is required", path)
    else
      return true
    end
  end

  if type(value) ~= expected_type then
    return false, string.format("%s must be a %s", path, expected_type)
  end

  return true
end

-- Validate user provided options
---@return boolean success
---@return string? err
function M.validate_options(opts)
  if opts == nil then
    return true, nil
  end

  if type(opts) ~= "table" then
    return false, "Options must be a table"
  end

  ---@cast opts checkmate.Config

  -- Basic options
  local validations = {
    { opts.enabled, "boolean", "enabled", true },
    { opts.notify, "boolean", "notify", true },
    { opts.enter_insert_after_new, "boolean", "enter_insert_after_new", true },
    { opts.files, "table", "files", true },
    { opts.show_todo_count, "boolean", "show_todo_count", true },
    { opts.todo_count_recursive, "boolean", "todo_count_recursive", true },
    { opts.use_metadata_keymaps, "boolean", "use_metadata_keymaps", true },
  }

  for _, v in ipairs(validations) do
    local ok, err = validate_type(v[1], v[2], v[3], v[4])
    if not ok then
      return false, err
    end
  end

  -- Validate files array
  if opts.files and #opts.files > 0 then
    for i, pattern in ipairs(opts.files) do
      if type(pattern) ~= "string" then
        return false, "files[" .. i .. "] must be a string"
      end
    end
  end

  -- Validate log settings
  if opts.log ~= nil then
    local ok, err = validate_type(opts.log, "table", "log", true)
    if not ok then
      return false, err
    end

    if opts.log.level ~= nil then
      if type(opts.log.level) ~= "string" and type(opts.log.level) ~= "number" then
        return false, "log.level must be a string or number"
      end
    end

    local log_validations = {
      { opts.log.use_buffer, "boolean", "log.use_buffer", true },
      { opts.log.use_file, "boolean", "log.use_file", true },
      { opts.log.file_path, "string", "log.file_path", true },
    }

    for _, v in ipairs(log_validations) do
      ok, err = validate_type(v[1], v[2], v[3], v[4])
      if not ok then
        return false, err
      end
    end
  end

  if opts.keys ~= nil and opts.keys ~= false then
    local ok, err = validate_type(opts.keys, "table", "keys", true)
    if not ok then
      return false, err
    end
  end

  -- Validate todo_markers
  if opts.todo_markers ~= nil then
    local ok, err = validate_type(opts.todo_markers, "table", "todo_markers", true)
    if not ok then
      return false, err
    end

    local marker_validations = {
      { opts.todo_markers.checked, "string", "todo_markers.checked", true },
      { opts.todo_markers.unchecked, "string", "todo_markers.unchecked", true },
    }

    for _, v in ipairs(marker_validations) do
      ok, err = validate_type(v[1], v[2], v[3], v[4])
      if not ok then
        return false, err
      end
    end

    -- Ensure the todo_markers are only 1 character length
    -- NOTE: Decided not to implement yet. Have added WARNING to config documentation
    --
    --[[ if opts.todo_markers.checked and vim.fn.strcharlen(opts.todo_markers.checked) ~= 1 then
      return false, "The 'checked' todo marker must be a single character"
    end
    if opts.todo_markers.unchecked and vim.fn.strcharlen(opts.todo_markers.unchecked) ~= 1 then
      return false, "The 'unchecked' todo marker must be a single character"
    end ]]
  end

  -- Validate default_list_marker
  if opts.default_list_marker ~= nil then
    local ok, err = validate_type(opts.default_list_marker, "string", "default_list_marker", true)
    if not ok then
      return false, err
    end

    local valid_markers = { ["-"] = true, ["*"] = true, ["+"] = true }
    if not valid_markers[opts.default_list_marker] then
      return false, "default_list_marker must be one of: '-', '*', '+'"
    end
  end

  -- Validate todo_count_position
  if opts.todo_count_position ~= nil then
    local ok, err = validate_type(opts.todo_count_position, "string", "todo_count_position", true)
    if not ok then
      return false, err
    end

    local valid_positions = { ["eol"] = true, ["inline"] = true }
    if not valid_positions[opts.todo_count_position] then
      return false, "todo_count_position must be one of: 'eol', 'inline'"
    end
  end

  -- Validate todo_count_formatter
  if opts.todo_count_formatter ~= nil then
    local ok, err = validate_type(opts.todo_count_formatter, "function", "todo_count_formatter", true)
    if not ok then
      return false, err
    end
  end

  -- Validate style
  if opts.style ~= nil then
    local ok, err = validate_type(opts.style, "table", "style", true)
    if not ok then
      return false, err
    end

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
      ok, err = validate_type(opts.style[field], "table", "style." .. field, true)
      if not ok then
        return false, err
      end
    end
  end

  -- Validate todo_action_depth
  if opts.todo_action_depth ~= nil then
    local ok, err = validate_type(opts.todo_action_depth, "number", "todo_action_depth", true)
    if not ok then
      return false, err
    end

    if math.floor(opts.todo_action_depth) ~= opts.todo_action_depth or opts.todo_action_depth < 0 then
      return false, "todo_action_depth must be a non-negative integer"
    end
  end

  -- Validate smart_toggle
  if opts.smart_toggle ~= nil then
    local ok, err = validate_type(opts.smart_toggle, "table", "smart_toggle", true)
    if not ok then
      return false, err
    end

    ok, err = validate_type(opts.smart_toggle.enabled, "boolean", "smart_toggle.enabled", true)
    if not ok then
      return false, err
    end

    -- Validate smart_toggle enum fields
    local toggle_options = { "all_children", "direct_children", "none" }
    local toggle_fields = {
      { opts.smart_toggle.check_down, "check_down" },
      { opts.smart_toggle.uncheck_down, "uncheck_down" },
      { opts.smart_toggle.check_up, "check_up" },
      { opts.smart_toggle.uncheck_up, "uncheck_up" },
    }

    for _, field in ipairs(toggle_fields) do
      if field[1] ~= nil then
        ok, err = validate_type(field[1], "string", "smart_toggle." .. field[2], true)
        if not ok then
          return false, err
        end

        local valid = false
        for _, opt in ipairs(toggle_options) do
          if field[1] == opt then
            valid = true
            break
          end
        end
        if not valid then
          return false, "smart_toggle." .. field[2] .. " must be one of: 'all_children', 'direct_children', 'none'"
        end
      end
    end
  end

  -- Validate archive
  if opts.archive ~= nil then
    local ok, err = validate_type(opts.archive, "table", "archive", true)
    if not ok then
      return false, err
    end

    ok, err = validate_type(opts.archive.parent_spacing, "number", "archive.parent_spacing", true)
    if not ok then
      return false, err
    end

    if opts.archive.heading ~= nil then
      ok, err = validate_type(opts.archive.heading, "table", "archive.heading", true)
      if not ok then
        return false, err
      end

      ok, err = validate_type(opts.archive.heading.title, "string", "archive.heading.title", true)
      if not ok then
        return false, err
      end

      if opts.archive.heading.level ~= nil then
        ok, err = validate_type(opts.archive.heading.level, "number", "archive.heading.level", true)
        if not ok then
          return false, err
        end

        if opts.archive.heading.level < 1 or opts.archive.heading.level > 6 then
          return false, "archive.heading.level must be between 1 and 6"
        end
      end
    end
  end

  -- Validate linter
  if opts.linter ~= nil then
    local ok, err = validate_type(opts.linter, "table", "linter", true)
    if not ok then
      return false, err
    end

    ok, err = validate_type(opts.linter.enabled, "boolean", "linter.enabled", true)
    if not ok then
      return false, err
    end

    ok, err = validate_type(opts.linter.severity, "table", "linter.severity", true)
    if not ok then
      return false, err
    end

    ok, err = validate_type(opts.linter.verbose, "boolean", "linter.verbose", true)
    if not ok then
      return false, err
    end
  end

  -- Validate metadata
  if opts.metadata ~= nil then
    if type(opts.metadata) ~= "table" then
      return false, "metadata must be a table"
    end

    for meta_name, meta_props in pairs(opts.metadata) do
      local ok, err = validate_type(meta_props, "table", "metadata." .. meta_name, true)
      if not ok then
        return false, err
      end

      -- validate 'style' (can be table or function)
      if meta_props.style ~= nil then
        local style_type = type(meta_props.style)
        if style_type ~= "table" and style_type ~= "function" then
          return false, "metadata." .. meta_name .. ".style must be a table or function"
        end
      end

      -- Validate metadata properties
      local meta_validations = {
        { meta_props.get_value, "function", "metadata." .. meta_name .. ".get_value", true },
        { meta_props.key, "string", "metadata." .. meta_name .. ".key", true },
        { meta_props.sort_order, "number", "metadata." .. meta_name .. ".sort_order", true },
        { meta_props.on_add, "function", "metadata." .. meta_name .. ".on_add", true },
        { meta_props.on_remove, "function", "metadata." .. meta_name .. ".on_remove", true },
        { meta_props.select_on_insert, "boolean", "metadata." .. meta_name .. ".select_on_insert", true },
      }

      for _, v in ipairs(meta_validations) do
        ok, err = validate_type(v[1], v[2], v[3], v[4])
        if not ok then
          return false, err
        end
      end

      -- Validate jump_to_on_insert
      if meta_props.jump_to_on_insert ~= nil and meta_props.jump_to_on_insert ~= false then
        ok, err =
          validate_type(meta_props.jump_to_on_insert, "string", "metadata." .. meta_name .. ".jump_to_on_insert", true)
        if not ok then
          return false, err
        end

        local valid_jumps = { ["tag"] = true, ["value"] = true }
        if not valid_jumps[meta_props.jump_to_on_insert] then
          return false, "metadata." .. meta_name .. ".jump_to_on_insert must be one of: 'tag', 'value', or false"
        end
      end

      -- Validate aliases
      if meta_props.aliases ~= nil then
        if type(meta_props.aliases) ~= "table" then
          return false, "metadata." .. meta_name .. ".aliases must be a table"
        end

        for i, alias in ipairs(meta_props.aliases) do
          if type(alias) ~= "string" then
            return false, "metadata." .. meta_name .. ".aliases[" .. i .. "] must be a string"
          end
        end
      end
    end
  end

  return true
end

--- Setup function
---@param opts? checkmate.Config
---@return checkmate.Config config
function M.setup(opts)
  local success, result = pcall(function()
    -- start with static defaults
    local config = vim.deepcopy(_DEFAULTS)

    -- then merge global config if present
    if type(vim.g.checkmate_config) == "table" then
      config = vim.tbl_deep_extend("force", config, vim.g.checkmate_config)
    end

    -- then merge user options after validating
    if type(opts) == "table" then
      assert(M.validate_options(opts))
      config = vim.tbl_deep_extend("force", config, opts)
    end

    -- save user style for colorscheme updates
    M._state.user_style = config.style and vim.deepcopy(config.style) or {}

    -- make theme-aware style defaults
    local theme_style = require("checkmate.theme").generate_style_defaults()
    config.style = vim.tbl_deep_extend("keep", config.style or {}, theme_style)

    M.options = config

    return config
  end)

  if not success then
    vim.notify("Checkmate: Config setup failed: " .. tostring(result), vim.log.levels.ERROR)
    return {}
  end

  return result
end

function M.get_defaults()
  return vim.deepcopy(_DEFAULTS)
end

return M
