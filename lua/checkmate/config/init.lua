local defaults = require("checkmate.config.defaults")
local validate = require("checkmate.config.validate")

-- Config
---@class checkmate.Config.mod
local M = {}

-- Namespace for plugin-related state
M.ns = vim.api.nvim_create_namespace("checkmate")
M.ns_todos = vim.api.nvim_create_namespace("checkmate_todos")

M._state = {
  user_style = nil, -- Track user-provided style settings (to reapply after colorscheme changes)
}

-- The active configuration
---@type checkmate.Config
---@diagnostic disable-next-line: missing-fields
M.options = {}

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
---Define the keymap as a dict-style table or a sequence of { rhs, desc, { modes } }
---See `h: vim.set.keymap` for how 'rhs' is treated, including being able to pass a Lua function directly
---Default modes is {"n"}
---@alias checkmate.KeymapConfig {rhs: string|function, desc?: string, modes?: string[]} | table<integer, any>
---
---Keymappings (false to disable)
---
---Setting `keys` to false will not register any keymaps. Setting a specific key to false will not register that default mapping.
---Note: mappings for metadata are set separately in the `metadata` table
---@field keys ( table<string, checkmate.KeymapConfig|false>| false )
---
---Characters for todo markers (checked and unchecked)
---@deprecated use todo_states
---@field todo_markers? checkmate.TodoMarkers
---
---The states that a todo item may have
---Default: "unchecked" and "checked"
---Note that Gith[118;1:3uub-flavored Markdown specification only includes "checked" and "unchecked".
---
---If you add additional states here, they may not work in other Markdown apps without special configuration.
---@field todo_states table<string, checkmate.TodoStateDefinition>
---
---Default list item marker to be used when creating new Todo items
---@field default_list_marker "-" | "*" | "+"
---
---@field ui? checkmate.UISettings
---
---Highlight settings (merges with defaults, user config takes precedence)
---Default style will attempt to integrate with current colorscheme (experimental)
---May need to tweak some colors to your liking
---@field style checkmate.StyleSettings?
---
---Enter insert mode after `:Checkmate create`, require("checkmate").create()
---@field enter_insert_after_new boolean
---
---Smart toggle provides intelligent parent-child todo state propagation
---
---When you change a todo's state, it can automatically update related todos based on their
---hierarchical relationship. Only "checked" and "unchecked" states are propagated - custom
---states remain unchanged but influence the propagation logic based on their type.
---@field smart_toggle checkmate.SmartToggleSettings
---
---Enable/disable the todo count indicator (shows number of child todo items incomplete vs complete)
---@field show_todo_count boolean
---
---Options for todo count indicator position
---@alias checkmate.TodoCountPosition "eol" | "inline"
---
---Position to show the todo count indicator (if enabled)
--- `eol` = End of the todo item line
--- `inline` = After the todo marker, before the todo item text
---@field todo_count_position checkmate.TodoCountPosition
---
---Formatter function for displaying the todo count indicator
---@field todo_count_formatter fun(completed: integer, total: integer)?: string
---
---Whether to count child todo items recursively in the todo_count
---If true, all nested todo items will count towards the parent todo's count
---@field todo_count_recursive boolean
---
---Whether to register keymappings defined in each metadata definition. If set the false,
---metadata actions need to be called programatically or otherwise mapped manually
---@field use_metadata_keymaps boolean
---
---Custom @tag(value) fields that can be toggled on todo items
---To add custom metadata tag, add a new field to this table with the metadata properties
---
---Note: When setting metadata in config, entire metadata entries are replaced,
---not deep-merged. To modify only specific fields of default metadata,
---you will need to manually merge the default implementation.
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

---@class checkmate.LogSettings
--- Any messages above this level will be logged
---@field level ("trace" | "debug" | "info" | "warn" | "error" | "fatal" | vim.log.levels.DEBUG | vim.log.levels.ERROR | vim.log.levels.INFO | vim.log.levels.TRACE | vim.log.levels.WARN)?
---
--- Should print log output to a file
---@field use_file boolean
---
--- The default path on-disk where log files will be written to.
--- Defaults to `vim.fn.stdpath("log")`
---@field file_path string?

-----------------------------------------------------

---@alias checkmate.TodoStateType "incomplete" | "complete" | "inactive"

---@class checkmate.TodoStateDefinition
---
--- The text string used for a todo marker is expected to be 1 character length.
--- Multiple characters _may_ work but are not currently supported and could lead to unexpected results.
---@field marker string
---
--- Markdown checkbox representation (custom states only)
--- For custom states, this determines how the todo state is written in Markdown syntax.
--- Important:
---   - Must be unique among all todo states. If two states share the same Markdown representation, there will
---   be unpredictable behavior when parsing the Markdown into the Checkmate buffer
---   - Not guaranteed to work in other apps/plugins as custom `[.]`, `[/]`, etc. are not standard Github-flavored Markdown
---   - This field is ignored for default `checked` and `unchecked` states as these are always represented per Github-flavored
--- Markdown spec, e.g. `[ ]` and `[x]`
---@field markdown string | string[]
---
--- Defines how a custom todo state relates to an intended task (custom states only)
---
--- The helps the custom state integrate with plugin behaviors like `smart toggle` and `todo count indicator`.
---
--- Options:
--- - "incomplete" - active/ongoing task (like unchecked)
--- - "complete"   - finished task (like checked)
--- - "inactive"   - paused/deferred task (neither)
---
--- Defaults:
---  - the "checked" state is always "complete" and the "unchecked" state is always "incomplete"
---  - custom states without a defined `type` will default to "inactive"
---@field type? checkmate.TodoStateType
---
--- The order in which this state is cycled (lower = first)
---@field order? number

-----------------------------------------------------

--- DEPRECATED v0.10
---@deprecated use `todo_states`
---@class checkmate.TodoMarkers
---
---Character used for unchecked items
---@field unchecked string
---
---Character used for checked items
---@field checked string

-----------------------------------------------------

---@class checkmate.UISettings
---
---@alias checkmate.Picker "telescope" | "snacks" | "mini" | false | fun(items: string[], opts: {on_choice: function})
---Default behavior: attempt to use an installed plugin, if found
---If false, will default to vim.ui.select
---If a function is passed, will use this picker implementation
---@field picker? checkmate.Picker

-----------------------------------------------------

---@class checkmate.SmartToggleSettings
---
---Whether to enable smart toggle behavior
---
---What is 'smart toggle'?
--- - Attempts to propagate a change in state (i.e. checked ←→ unchecked) up and down the hierarchy in a sensible manner
--- - In this mode, changing the state of a todo maybe also affect nearby todos
---Default: true
---@field enabled boolean?
---
---Whether to use smart toggle behavior with `cycle` commands/API
---
---If enabled, this may inadvertently toggle nearby todos as you cycle through, depending on `smart_toggle` rules.
---If you would like to cascade/propagate when setting a custom state, use the `toggle(target_state)` api.
---
---Default: false (cycling through states won't trigger propagation)
---@field include_cycle boolean?
---
---How checking a parent affects its children
---  - "all_children": Check all descendants, including nested
---  - "direct_children": Only check immediate unchecked children (default)
---  - "none": Don't propagate down
---@field check_down "all_children"|"direct_children"|"none"?
---
---How unchecking a parent affects its children
---  - "all_children": Uncheck all descendants, including nested
---  - "direct_children": Only uncheck immediate checked children
---  - "none": Don't propagate down (default)
---@field uncheck_down "all_children"|"direct_children"|"none"?
---
---When a parent should become checked
---i.e, how a checked child affects its parent
---
---Note: Custom states with "complete" type count as done, "incomplete" as not done,
---and "inactive" states are ignored (as if they don't exist for completion purposes).
---
---  - "all_children": When ALL descendants are complete or inactive, including nested
---  - "direct_children": When all immediate children are complete/inactive (default)
---  - "none": Never auto-check parents
---@field check_up "all_children"|"direct_children"|"none"?
---
---When a parent should become unchecked
---i.e, how a unchecked child affects its parent
---  - "all_children": When ANY descendant is incomplete
---  - "direct_children": When any immediate child is incomplete (default)
---  - "none": Never auto-uncheck parents
---@field uncheck_up "all_children"|"direct_children"|"none"?

-----------------------------------------------------

--- Style

---@alias checkmate.HighlightGroup
---| "CheckmateListMarkerUnordered" -- unordered list markers (-,+,*)
---| "CheckmateListMarkerOrdered" -- ordered (numerical) list markers (1.,2.)
---| "CheckmateUncheckedMarker" -- unchecked markers (□)
---| "CheckmateUncheckedMainContent" -- main content of unchecked todo items (typically 1st paragraph)
---| "CheckmateUncheckedAdditionalContent" -- additional content of unchecked todo items (subsequent paragraphs or list items)
---| "CheckmateCheckedMarker" -- checked markers (✔)
---| "CheckmateCheckedMainContent" -- main content of checked todo items (typically 1st paragraph)
---| "CheckmateCheckedAdditionalContent" -- additional content of checked todo items (subsequent paragraphs or list items)
---| "CheckmateTodoCountIndicator" -- the todo count indicator (e.g. x/x)

---Customize the style of markers and content
---@alias checkmate.StyleSettings table<checkmate.HighlightGroup, vim.api.keyset.highlight>

-----------------------------------------------------

--- Metadata

---A table of canonical metadata tag names and associated properties that define the look and function of the tag
---
---A 'canonical' name is the main lookup name for a metadata tag; additional 'aliases' can be used that point to this name
---@alias checkmate.Metadata table<string, checkmate.MetadataProps>

---@class checkmate.MetadataProps
---
---Additional string values that can be used interchangably with the canonical tag name.
---E.g. @started could have aliases of `{"initiated", "began"}` so that @initiated and @began could
---also be used and have the same styling/functionality
---@field aliases? string[]
---
---@alias checkmate.StyleFn fun(context?: checkmate.MetadataContext):vim.api.keyset.highlight
---
---Highlight settings table, or a function that returns highlight settings (being passed metadata context)
---@field style? vim.api.keyset.highlight|checkmate.StyleFn
---
---@alias checkmate.GetValueFn fun(context?: checkmate.MetadataContext):string
---
---Function that returns the default value for this metadata tag
---i.e. what is used after insertion
---@field get_value? checkmate.GetValueFn
---
---@alias checkmate.ChoicesFn fun(context?: checkmate.MetadataContext, cb?: fun(items: string[])): string[]?
---
---Values that are populated during completion or select pickers
---Can be either:
--- - An array of items (string[])
--- - A function that returns items
---@field choices? string[]|checkmate.ChoicesFn
---
---Keymapping for toggling (adding/removing) this metadata tag
---Can also pass a tuple (key, desc) to include a description
---@field key? string|string[]
---
---Used for displaying metadata in a consistent order
---@field sort_order? integer
---
---Moves the cursor to the metadata after it is inserted
---  - "tag" - moves to the beginning of the tag
---  - "value" - moves to the beginning of the value
---  - false - disables jump (default)
---@field jump_to_on_insert? "tag" | "value" | false
---
---Selects metadata text in visual mode after metadata is inserted
---The `jump_to_on_insert` field must be set (not false)
---The selected text will be the tag or value, based on jump_to_on_insert setting
---Default (false) - off
---@field select_on_insert? boolean
---
---Callback to run when this metadata tag is added to a todo item
---E.g. can be used to change the todo item state
---@field on_add? fun(todo_item: checkmate.TodoItem)
---
---Callback to run when this metadata tag is removed from a todo item
---E.g. can be used to change the todo item state
---@field on_remove? fun(todo_item: checkmate.TodoItem)
---
---Callback to run when this metadata tag's value is changed (not on initial add or removal)
---Receives the todo item, old value, and new value
---@field on_change? fun(todo_item: checkmate.TodoItem, old_value: string, new_value: string)

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
---
---Whether to use verbose linter/diagnostic messages
---Default: false
---@field verbose boolean?

-----------------------------------------------------

--- Returns list of deprecation warnings
function M.get_deprecations(user_opts)
  if type(user_opts) ~= "table" then
    return {}
  end

  local res = {}

  local function add(msg)
    table.insert(res, msg)
  end

  ---@deprecated v0.10
  if user_opts.todo_markers then
    add("`config.todo_markers` is deprecated. Use `todo_states` instead.")
  end

  ---removed in v0.10
  ---@diagnostic disable-next-line: undefined-field
  if user_opts.todo_action_depth then
    add(
      "`config.todo_action_depth` has been removed (v0.10). Note, todos can now be interacted from any depth in their hierarchy"
    )
  end
  return res
end

---Handles merging of deprecated config opts into current config to maintain backwards compatibility
---@param current_opts checkmate.Config
---@param user_opts? checkmate.Config
local function merge_deprecated_opts(current_opts, user_opts)
  -----------------------
  --- todo_markers
  ---@deprecated v0.10

  user_opts = user_opts or {}

  -- if the user set todo_markers but did not explicitly override todo_states,
  -- build a new todo_states table from their markers, preserving the default order.
  if user_opts.todo_markers and not user_opts.todo_states then
    local default_states = require("checkmate.config").get_defaults().todo_states
    current_opts.todo_states = {
      ---@diagnostic disable-next-line: missing-fields
      unchecked = {
        marker = user_opts.todo_markers.unchecked,
        order = default_states.unchecked.order,
      },
      ---@diagnostic disable-next-line: missing-fields
      checked = {
        marker = user_opts.todo_markers.checked,
        order = default_states.checked.order,
      },
    }
  elseif user_opts.todo_markers and user_opts.todo_states then
    -- vim.notify("Checkmate: `todo_markers` ignored because `todo_states` is set", vim.log.levels.WARN)
  end

  ---@diagnostic disable-next-line: deprecated
  current_opts.todo_markers = {
    unchecked = current_opts.todo_states.unchecked.marker,
    checked = current_opts.todo_states.checked.marker,
  }
  -----------------------
end

---@param opts? checkmate.Config
---@return checkmate.Config config
function M.setup(opts)
  local success, result = pcall(function()
    -- start with static defaults
    local config = vim.deepcopy(defaults)

    -- then merge global config if present
    if type(vim.g.checkmate_config) == "table" then
      config = vim.tbl_deep_extend("force", config, vim.g.checkmate_config)
    end

    -- then merge user options after validating
    if type(opts) == "table" then
      local ok, err = validate.validate_options(opts)
      if not ok then
        error(err)
      end

      config = vim.tbl_deep_extend("force", config, opts)

      -- don't merge, just override full table for these
      if opts.metadata then
        for meta_name, meta_props in pairs(opts.metadata) do
          config.metadata[meta_name] = vim.deepcopy(meta_props)
        end
      end
    end

    -- maintain backwards compatibility
    merge_deprecated_opts(config, opts)

    -- OVERRIDES
    -- ensure that checked and unchecked todo states always have GFM representation
    -- ensure that type is never altered
    config.todo_states.checked.markdown = { "x", "X" }
    config.todo_states.checked.type = "complete"
    config.todo_states.unchecked.markdown = " "
    config.todo_states.unchecked.type = "incomplete"

    -- save user style for colorscheme updates
    M._state.user_style = config.style and vim.deepcopy(config.style) or {}

    -- make theme-aware style defaults
    local theme_style = require("checkmate.theme").generate_style_defaults()
    config.style = vim.tbl_deep_extend("keep", config.style or {}, theme_style)

    M.options = config

    return config
  end)

  if not success then
    vim.notify("Checkmate: Config error: " .. tostring(result), vim.log.levels.ERROR)
    return {}
  end
  ---@cast result checkmate.Config

  return result
end

function M.get_defaults()
  return vim.deepcopy(defaults)
end

function M.get_todo_state_type(state_name)
  local state_def = M.options.todo_states[state_name]
  return state_def and state_def.type or "inactive"
end

return M
