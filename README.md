<div align="center">

<img width="350" alt="checkmate_logo" src="https://github.com/user-attachments/assets/01c8e335-b8a0-47d5-b480-8ad8957c7b5f" />


### Get stuff done

[![Lua](https://img.shields.io/badge/Lua-blue.svg?style=for-the-badge&logo=lua)](http://www.lua.org)
[![Neovim](https://img.shields.io/badge/Neovim%200.10+-green.svg?style=for-the-badge&logo=neovim&color=%2343743f)](https://neovim.io)
![GitHub Release](https://img.shields.io/github/v/release/bngarren/checkmate.nvim?style=for-the-badge&logoSize=200&color=%23f3d38a&labelColor=%23061914)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/bngarren/checkmate.nvim/lint-test.yml?branch=main&style=for-the-badge&label=CI&labelColor=%23061914&color=%2343743f)


</div><br/>

A Markdown-based todo/task plugin for Neovim.

### Features
- Saves files in plain Markdown format (compatible with other apps)
- Customizable markers and styling
- Visual mode support for toggling multiple items at once
- Metadata e.g. `@tag(value)` annotations with extensive customization
  - e.g. @started, @done, @priority, @your-custom-tag
- Todo completion counts/percentage
- Smart toggling behavior
- Archive completed todos
- Todo templates with LuaSnip snippet integration
- Custom todo states
  - More than just "checked" and "unchecked", e.g. "partial", "in-progress", "on-hold"
- 🆕 Automatic todo creation (list continuation in insert mode)

> [!NOTE]
> Check out the [Wiki](https://github.com/bngarren/checkmate.nvim/wiki) for additional documentation and recipes, including:
> - [Advanced metadata](https://github.com/bngarren/checkmate.nvim/wiki/Metadata)
> - [Snippets](https://github.com/bngarren/checkmate.nvim/wiki/Snippets)
> - How to setup a per-project, low-friction `checkmate.nvim` buffer with [snacks.nvim](https://github.com/bngarren/checkmate.nvim/wiki#snacksnvim)

<br/>

<img width="1200" height="204" alt="checkmate_example_simple" src="https://github.com/user-attachments/assets/6eecda10-109a-442f-b709-83ed35065bf9" />


<img width="1200" height="341" alt="checkmate_demo_complex" src="https://github.com/user-attachments/assets/8bbb9b20-23f7-4f82-b2b3-a8e8d2d9d4c5" />


https://github.com/user-attachments/assets/d9b58e2c-24e2-4fd8-8d7f-557877a20218

<!-- panvimdoc-ignore-start -->
## Table of Contents
- [Installation](#installation)
- [Requirements](#requirements)
- [Usage](#usage)
- [Commands](#commands)
- [Configuration](#config)
  - [Styling](#styling)
  - [Todo states](#todo-states)
  - [Todo counts](#todo-count-indicator)
  - [Smart toggle](#smart-toggle)
- [Metadata](#metadata)
- [Archiving](#archiving)
- [Integrations](#integrations)
- [Linting](#linting)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [Credits](#credits)

<!-- panvimdoc-ignore-end -->

<br>

<a id="installation"><a/>

# ☑️ Installation

## Requirements

- Neovim 0.10 or higher

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
    "bngarren/checkmate.nvim",
    ft = "markdown", -- Lazy loads for Markdown files matching patterns in 'files'
    opts = {
        -- your configuration here
        -- or leave empty to use defaults
    },

}
```

If you'd like _stable-ish_ version during pre-release, can add a minor version to the [lazy spec](https://lazy.folke.io/spec#spec-versioning):
```
{
  version = "~0.10.0" -- pins to minor 0.10.x
}
```
<a id="usage"><a/>

# ☑️ Usage

### 1. Open or Create a Todo File

Checkmate automatically activates when you open a Markdown file that matches your configured file name patterns.

**Default patterns:**
- `todo` or `TODO` (exact filename)
- `todo.md` or `TODO.md`
- Files with `.todo` extension (e.g., `project.todo`, `work.todo.md`)

<br>

> [!NOTE]
> Checkmate only activates for files with the "markdown" filetype. Files without extensions need their filetype set to markdown (`:set filetype=markdown`)

<br>

You can customize **which files activate Checkmate** using the `files` configuration option:
```lua
files = { "tasks", "*.plan", "project/**/todo.md" }
```
Patterns support full Unix-style globs including `*`, `**`, `?`, `[abc]`, and `{foo,bar}`

### 2. Create Todos

- Use the **mapped key** (_recommended_, default: `<leader>Tn`) or the `:Checkmate create` command
- Or manually using Markdown syntax:

```md
- [ ] Unchecked todo
- [x] Checked todo
```

(These will automatically convert when you leave insert mode!)

### 3. Manage Your Tasks

- Toggle items with `:Checkmate toggle` (default: `<leader>Tt`)
- Check items with `:Checkmate check` (default: `<leader>Tc`)
- Uncheck items with `:Checkmate uncheck` (default: `<leader>Tu`)
- Cycle to other [custom states](#todo-states) with `:Checkmate cycle_next` (default: `<leader>T=`) and `:Checkmate cycle_previous` (default `<leader>T-`)
- Select multiple items in visual mode and use the same commands
- Archive completed todos with `:Checkmate archive` (default: `<leader>Ta`)

Enhance your todos with custom [metadata](#metadata) with quick keymaps!

The Checkmate buffer is **saved as regular Markdown** which means it's compatible with any Markdown editor!

<a id="commands"><a/>

# ☑️ Commands

#### User commands
`:Checkmate [subcommand]`

| subcommand   | Description |
|--------------|-------------|
| `archive` | Archive all checked todo items in the buffer. See api `archive()` |
| `check` | Mark the todo item under the cursor as checked. See api `check()`|
| `create` | In normal mode, converts the current line into a todo (or if already a todo, creates a sibling below). In visual mode, converts each selected line into a todo. In insert mode, creates a new todo on the next line and keeps you in insert mode. For more advanced placement, indentation, and state options, see the `create(opts)` API. |
| `cycle_next` | Cycle a todo's state to the next available. See api `cycle()` |
| `cycle_previous` | Cycle a todo's state to the previous. See api `cycle()` |
| `lint` | Lint this buffer for Checkmate formatting issues. See api `lint()` |
| `metadata add` | Add a metadata tag to the todo under the cursor or within the selection. Usage: `:Checkmate metadata add <key> [value]`. See api `add_metadata(key, value)` |
| `metadata jump_next` | Move the cursor to the next metadata tag for the todo item under the cursor. See api `jump_next_metadata()` |
| `metadata jump_previous` | Move the cursor to the previous metadata tag for the todo item under the cursor. See api `jump_previous_metadata()` |
| `metadata remove` | Remove a specific metadata tag from the todo under the cursor or within the selection. Usage: `:Checkmate metadata remove <key>`. See api `remove_metadata(key)` |
| `metadata select_value` | Select a value from the 'choices' option for the metadata tag under the cursor. See api `select_metadata_value()` |
| `metadata toggle` | Toggle a metadata tag on/off for the todo under the cursor or within the selection. Usage: `:Checkmate metadata toggle <key> [value]`. See api `toggle_metadata(key, value)` |
| `remove` | Convert a todo line back to regular text. See api `remove(opts)`. By default, will preserve the list item marker and remove any metadata. This can be configured via `opts`.
| `remove_all_metadata` | Remove *all* metadata tags from the todo under the cursor or within the selection. See api `remove_all_metadata()` |
| `toggle` | Toggle the todo item under the cursor (normal mode) or all todo items within the selection (visual mode). See api `toggle()`. This command only toggles between `unchecked` and `checked`. To change to custom states, use the api `toggle(target_state)` or the `cycle_*` commands. |
| `uncheck` | Mark the todo item under the cursor as unchecked. See api `uncheck()` |

<br>

<a id="config"><a/>

# ☑️ Config

<details>
<summary>Config definitions/annotations</summary>

```lua
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
---Note that Github-flavored Markdown specification only includes "checked" and "unchecked".
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
---Default: true
---@field enter_insert_after_new boolean
---
---List continuation refers to the automatic creation of new todo lines when insert mode keymaps are fired, i.e., typically <CR>
---To offer optimal configurability and integration with other plugins, you can set the exact keymaps and their functions via the `keys` option. The list continuation functionality can also be toggled via the `enabled` option.
--- - When enabled and keymap calls `create()`, it will create a new todo line, using the origin/current row with reasonable defaults
--- - Works for both raw Markdown (e.g. `- [ ]`) and Unicode style (e.g. `- ☐`) todos.
---@field list_continuation checkmate.ListContinuationSettings
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
---@field todo_count_formatter? fun(completed: integer, total: integer): string
---
---Whether to count child todo items recursively in the todo_count
---If true, all nested todo items will count towards the parent todo's count
---@field todo_count_recursive boolean
---
---Whether to register keymappings defined in each metadata definition.
---When false, default metadata keymaps are not created; you can still call require('checkmate').toggle_metadata() or bind keys manually.
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
--- Default: true
---@field use_file boolean
---
--- The default path on-disk where log files will be written to.
--- Defaults to `vim.fn.stdpath("log") .. "checkmate.log"`
---@field file_path string?
---
--- Max file size (kilobytes)
--- When file size exceeds max, a new file will be overwritten
--- Default: 5120 kb (5 mb)
---@field max_file_size? number

-----------------------------------------------------

---The broad categories used internally that give semantic meaning to each todo state
---@alias checkmate.TodoStateType "incomplete" | "complete" | "inactive"

---@class checkmate.TodoStateDefinition
---
--- The glyph or text string used for a todo marker is expected to be 1 character length.
--- Multiple characters _may_ work but are not currently supported and could lead to unexpected results.
---@field marker string
---
--- Markdown checkbox representation (custom states only)
--- For custom states, this determines how the todo state is written to file in Markdown syntax.
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

---@class checkmate.ListContinuationSettings
---
--- Whether to enable list continuation behavior
---
--- Default: true
---@field enabled? boolean
---
--- Control behavior when cursor is mid-line (not at the end).
---
--- When `true` (default):
---   - Text after cursor moves to the new todo line
---   - Original line is truncated at cursor position
---   - Example: "- ☐ Buy |milk and eggs" → "- ☐ Buy" + "- ☐ milk and eggs"
---
--- When `false`:
---   - List continuation only works when cursor is at end of line
---
--- Default: true
---@field split_line? boolean
---
--- Define which keys trigger list continuation and their behavior.
---
--- Each key can map to either:
---   - A function that creates the new todo
---   - A table with `rhs` (function) and optional `desc` (description)
---
--- Default keys:
---   - `<CR>`: Create sibling todo (same indentation)
---   - `<S-CR>`: Create nested todo (indented as child)
---
--- **Important**: This field completely replaces the default keys (no merging).
--- To keep some defaults while adding custom keys, explicitly include them in your config.
---@field keys? table<string, {rhs: function, desc?: string}|function>
---
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
---@alias checkmate.ChoicesFn fun(context?: checkmate.MetadataContext, cb?: fun(items: string[])): string[]|nil
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
```

</details>

### Defaults
```lua
---@type checkmate.Config
return {
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
    level = "warn",
    use_file = true,
  },
  -- Default keymappings
  keys = {
    ["<leader>Tt"] = {
      rhs = "<cmd>Checkmate toggle<CR>",
      desc = "Toggle todo item",
      modes = { "n", "v" },
    },
    ["<leader>Tc"] = {
      rhs = "<cmd>Checkmate check<CR>",
      desc = "Set todo item as checked (done)",
      modes = { "n", "v" },
    },
    ["<leader>Tu"] = {
      rhs = "<cmd>Checkmate uncheck<CR>",
      desc = "Set todo item as unchecked (not done)",
      modes = { "n", "v" },
    },
    ["<leader>T="] = {
      rhs = "<cmd>Checkmate cycle_next<CR>",
      desc = "Cycle todo item(s) to the next state",
      modes = { "n", "v" },
    },
    ["<leader>T-"] = {
      rhs = "<cmd>Checkmate cycle_previous<CR>",
      desc = "Cycle todo item(s) to the previous state",
      modes = { "n", "v" },
    },
    ["<leader>Tn"] = {
      rhs = "<cmd>Checkmate create<CR>",
      desc = "Create todo item",
      modes = { "n", "v" },
    },
    ["<leader>Tr"] = {
      rhs = "<cmd>Checkmate remove<CR>",
      desc = "Remove todo marker (convert to text)",
      modes = { "n", "v" },
    },
    ["<leader>TR"] = {
      rhs = "<cmd>Checkmate remove_all_metadata<CR>",
      desc = "Remove all metadata from a todo item",
      modes = { "n", "v" },
    },
    ["<leader>Ta"] = {
      rhs = "<cmd>Checkmate archive<CR>",
      desc = "Archive checked/completed todo items (move to bottom section)",
      modes = { "n" },
    },
    ["<leader>Tv"] = {
      rhs = "<cmd>Checkmate metadata select_value<CR>",
      desc = "Update the value of a metadata tag under the cursor",
      modes = { "n" },
    },
    ["<leader>T]"] = {
      rhs = "<cmd>Checkmate metadata jump_next<CR>",
      desc = "Move cursor to next metadata tag",
      modes = { "n" },
    },
    ["<leader>T["] = {
      rhs = "<cmd>Checkmate metadata jump_previous<CR>",
      desc = "Move cursor to previous metadata tag",
      modes = { "n" },
    },
  },
  default_list_marker = "-",
  todo_states = {
    -- we don't need to set the `markdown` field for `unchecked` and `checked` as these can't be overriden
    ---@diagnostic disable-next-line: missing-fields
    unchecked = {
      marker = "□",
      order = 1,
    },
    ---@diagnostic disable-next-line: missing-fields
    checked = {
      marker = "✔",
      order = 2,
    },
  },
  style = {}, -- override defaults
  enter_insert_after_new = true, -- Should enter INSERT mode after `:Checkmate create` (new todo)
  list_continuation = {
    enabled = true,
    split_line = true,
    keys = {
      ["<CR>"] = function()
        require("checkmate").create({
          position = "below",
          indent = false,
        })
      end,
      ["<S-CR>"] = function()
        require("checkmate").create({
          position = "below",
          indent = true,
        })
      end,
    },
  },
  smart_toggle = {
    enabled = true,
    include_cycle = false,
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
      style = function(context)
        local value = context.value:lower()
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
      choices = function()
        return { "low", "medium", "high" }
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
```

> [!WARNING]
> Multi-character todo markers are not officially supported but _may_ work. For consistent behavior, recommend using a single character.

## Keymapping
Default keymaps can be disabled by setting `keys = false`.

Keymaps should be defined as a dict-like table or a sequence of `{rhs, desc?, modes?}`.

```lua
keys = {
  ["<leader>Ta"] = {
      rhs = "<cmd>Checkmate archive<CR>",
      desc = "Archive todos",
      modes = { "n" },
  },
}
```

or

```lua
keys = {
  ["<leader>Ta"] = {"<cmd>Checkmate archive<CR>", "Archive todos", {"n"} }
}
```

The `rhs` parameter follows `:h vim.keymap.set()` and can be a string or Lua function.

## Styling
Default styles are calculated based on the current _colorscheme_. This attempts to provide reasonable out-of-the-box defaults based on colorscheme-defined hl groups and contrast ratios.

Individual styles can still be overriden using the `style` option and passing a 'highlight definition map' according to `:h nvim_set_hl()` and `vim.api.keyset.highlight` for the desired highlight group (see below).

### Highlight groups
| hl_group | description |
|----------|-------------|
| CheckmateListMarkerUnordered | Unordered list markers, e.g. `-`,`*`, and `+`. (_Only those associated with a todo_) |
| CheckmateListMarkerOrdered | Ordered list markers, e.g. `1.`, `2)`. (_Only those associated with a todo_) |
| CheckmateUncheckedMarker | Unchecked todo marker, e.g. `□`. See `todo_states` `marker` option |
| CheckmateUncheckedMainContent | The main content of an unchecked todo (typically the first paragraph) |
| CheckmateUncheckedAdditionalContent | Additional content for an unchecked todo (subsequent paragraphs, list items, etc.) |
| CheckmateCheckedMarker | Checked todo marker, e.g. `✔`. See `todo_states` `marker` option |
| CheckmateCheckedMainContent | The main content of a checked todo (typically the first paragraph) |
| CheckmateCheckedAdditionalContent | Additional content for a checked todo (subsequent paragraphs, list items, etc.) |
| CheckmateTodoCountIndicator | The todo count indicator, e.g. `1/4`, shown on the todo line, if enabled. See `show_todo_count` option |

Metadata highlights are prefixed with `CheckmateMeta_` and keyed with the tag name and style.

#### Main content versus Additional content
Highlight groups with 'MainContent' refer to the todo item's first paragraph. 'AdditionalContent' refers to subsequent paragraphs, list items, etc.

<img width="800" alt="checkmate_main_vs_additional_hl_groups" src="https://github.com/user-attachments/assets/adbd0766-8f33-4c8f-be1f-3eafacd81dda" />


#### Example: Change the checked marker to a bold green
```lua
opts = {
    style = {
        CheckmateCheckedMarker = { fg = "#7bff4f", bold = true}
    }
}
```

#### Example: Style a custom todo state
[Custom todo states](#todo-states) will be styled following the same highlight group naming convention:
e.g. `Checkmate[State]Marker`
So, if you define a `partial` state:
```lua
todo_states = {
  partial = {
    -- ...
  }
}
```
You can then style it:
```lua
styles = {
  CheckmatePartialMarker = { fg = "#f0fc03" }
  CheckmatePartialMainContent = { fg = "#faffa1" }
}
```

> State names will be converted to CamelCase when used in highlight group names. E.g. `not_planned` = `NotPlanned`

## Todo states
Checkmate supports both standard GitHub-flavored Markdown states and custom states for more nuanced task management.

### Default states
The standard states are `checked` and `unchecked`, which are always saved to disk as `- [ ]` and `- [x]` per the Github-flavored Markdown spec. You can customize their visual appearance with the `todo_states` `marker` opt:
```lua
todo_states = {
  checked = {
    marker = "☒" -- how it appears in Neovim
  },
  unchecked = {
    marker = "☐" -- how it appears in Neovim
  }
}
```

### Custom states
Add custom states to track tasks more precisely. Each state needs:

- `marker`: How it appears in Neovim (must be unique)
- `markdown`: How it's saved to disk (must be unique)
<br><br>
_and optionally_:
- `type`: How it behaves in the task hierarchy

```lua
todo_states = {
  -- Built-in states (cannot change markdown or type)
  unchecked = { marker = "□" },
  checked = { marker = "✔" },
  
  -- Custom states
  in_progress = {
    marker = "◐",
    markdown = ".",     -- Saved as `- [.]`
    type = "incomplete", -- Counts as "not done"
    order = 50,
  },
  cancelled = {
    marker = "✗",
    markdown = "c",     -- Saved as `- [c]` 
    type = "complete",   -- Counts as "done"
    order = 2,
  },
  on_hold = {
    marker = "⏸",
    markdown = "/",     -- Saved as `- [/]`
    type = "inactive",   -- Ignored in counts
    order = 100,
  }
}
```

<img width="800" height="145" alt="checkmate_custom_states" src="https://github.com/user-attachments/assets/b8f89d00-4523-4106-8dbe-82059b1a1334" />

#### State types
States have three behavior types that affect smart toggle and todo counts:
| Type | Behavior | Example States |
|------|----------|----------------|
| `incomplete` | Counts as "not done" | **unchecked**, in_progress, pending, future |
| `complete` | Counts as "done" | **checked**, cancelled |
| `inactive` | Ignored in calculations | on_hold, not_planned |


> [!WARNING]
> Custom states like `- [.]` or `- [/]` are not standard Markdown and may not be recognized by other apps.

You can then cycle through a todo's states with `:Checkmate cycle_next` and `:Checkmate cycle_previous` or using the API, such as:
```lua
require("checkmate").cycle()        -- Next state
require("checkmate").cycle(true)    -- Previous state

-- or to toggle to a specific state
require("checkmate").toggle("on_hold")
```

## Todo count indicator
Shows completion progress for todos with subtasks. 

It displays the number of `checked / unchecked` todos in a hierarchy. It counts the standard "checked" and "unchecked" states, as well as custom states based on their `type` (incomplete, complete, or inactive).

<table>
  <tr>
    <td align="center">
      <img width="400" alt="checkmate_todo_indicator_eol" src="https://github.com/user-attachments/assets/1db966b3-3618-4aa4-915c-d3ea720c0a40" />
      <br/>
      <sub>Todo count indicator using <code>eol</code> position</sub>
    </td>
    <td align="center">
      <img width="400" alt="checkmate_todo_indicator_inline" src="https://github.com/user-attachments/assets/a75b63c5-6df5-4937-9c15-c9fa7170ce4a" />
      <br/>
      <sub>Todo count indicator using <code>inline</code> position</sub>
    </td>
  </tr>
</table>

### Change the default display by passing a custom formatter

#### Basic example
```lua
-- Custom formatter that returns the % completed
todo_count_formatter = function(completed, total)
  return string.format("[%.0f%%]", completed / total * 100)
end,
style = {
  CheckmateTodoCountIndicator = { fg = "#faef89" },
},
```
<img width="400" alt="checkmate_todo_count_percentage" src="https://github.com/user-attachments/assets/ebbf1de4-bde3-4001-beab-a96feecd5f80" />
<br/>
<sub>Todo count indicator using <code>todo_count_formatter</code> function</sub>
<br/>
<br/>

#### Progress bar example, see [Wiki](https://github.com/bngarren/checkmate.nvim/wiki/Styling#use-a-progress-bar-for-more-than-4-subtasks) for code.
<img width="400" alt="checkmate_progress_bar_example" src="https://github.com/user-attachments/assets/1aa6c88c-2b69-415f-9313-ff2df6888608" />
<br>


#### Count all nested todo items
If you want the todo count of a parent todo item to include _all_ nested todo items, set the `todo_count_recursive` option.

<table>
  <tr>
    <td align="center">
      <img width="400" alt="checkmate_todo_indicator_recursive_false" src="https://github.com/user-attachments/assets/82b8a025-e71c-487c-b42f-27a16f9bf810" />
      <br/>
      <sub><code>todo_count_recursive</code> false. Only direct children are counted.</sub>
    </td>
    <td align="center">
      <img width="400" alt="checkmate_todo_indicator_recursive_true" src="https://github.com/user-attachments/assets/8e2b47bd-db1a-452f-872e-90db17702193" />
      <br/>
      <sub><code>todo_count_recursive</code> true. All children are counted.</sub>
    </td>
  </tr>
</table>

## Smart Toggle

Intelligently propagates a todo's state change through its hierarchy. 

When you toggle a todo item, it can automatically update related todos based on your configuration.

> [!NOTE] 
> Smart toggle only propagates "unchecked" and "checked" states (the default/standard todo states). If [custom todo states](#todo-states) are used, they may influence parent completion but will not be changed themselves.

### How it works

Smart toggle operates in two phases:
1. **Downward propagation**: When toggling a parent, optionally propagate the state change to children
2. **Upward propagation**: When toggling a child, optionally update the parent based on children states

### Configuration

Smart toggle is enabled by default with sensible defaults. You can customize the behavior:

```lua
opts = {
  smart_toggle = {
    enabled = true,
    check_down = "direct",        -- How checking a parent affects children
    uncheck_down = "none",        -- How unchecking a parent affects children
    check_up = "direct_children", -- When to auto-check parents
    uncheck_up = "direct_children", -- When to auto-uncheck parents
  }
}
```
<a id="metadata"><a/>

# ☑️ Metadata

Metadata tags allow you to add custom `@tag(value)` annotations to todo items.

<img width="909" height="95" alt="checkmate_metadata_example" src="https://github.com/user-attachments/assets/69d95b07-f80a-4cd3-be40-856e627a8023" />


- Default tags:
  - `@started` - default value is the current date/time
  - `@done` - default value is the current date/time
  - `@priority` - "low" | "medium" (default) | "high"

The default tags are not deeply merged in order to avoid unexpected behavior. If you wish to modify a default metadata, you should copy the default implementation.

By configuring a metadata's `choices` option, you can populate your own lists of metadata values for powerful workflows, e.g. project file names, Git branches, PR's, issues, etc., team member names, external APIs, etc.

For in-depth guide and recipes for custom metadata, see the [Wiki](https://github.com/bngarren/checkmate.nvim/wiki/Todo-Metadata) page.

<a id="archiving"><a/>

# ☑️ Archiving
Allows you to easily reorganize the buffer by moving all checked/completed todo items to a Markdown section beneath all other content. The unchecked todos are reorganized up top and spacing is adjusted.

See `Checkmate archive` command or `require("checkmate").archive()`

> Current behavior (could be adjusted in the future): a checked todo item that is nested under an unchecked parent will not be archived. This prevents 'orphan' todos being separated from their parents. Similarly, a checked parent todo will carry all nested todos (checked and unchecked) when archived.

#### Heading
By default, a Markdown level 2 header (##) section named "**Archive**" is used. You can configure the archive section heading via `config.archive.heading`

The following will produce an archive section labeled:
```markdown
#### Completed
```

```lua
opts = {
  archive = {
    heading = {
      title = "Completed",
      level = 4
    }
  }
}
```

#### Spacing
The amount of blank lines between each archived todo item can be customized via `config.archive.parent_spacing`

E.g. `parent_spacing = 0`
```lua
## Archive

- ✔ Update the dependencies 
- ✔ Refactor the User api
- ✔ Add additional tests 
```

E.g. `parent_spacing = 1`
```lua
## Archive

- ✔ Update the dependencies 

- ✔ Refactor the User api

- ✔ Add additional tests 
```

<a id="integrations"><a/>

# ☑️ Integrations

Please see [Wiki](https://github.com/bngarren/checkmate.nvim/wiki) for additional details/recipes.

| Integration | Capable? |
|----------------|----------|
| [render-markdown](https://github.com/MeanderingProgrammer/render-markdown.nvim) | ✅ [wiki](https://github.com/bngarren/checkmate.nvim/wiki#render-markdownnvim)|
| [LuaSnip](https://github.com/L3MON4D3/LuaSnip) | ✅ [wiki](https://github.com/bngarren/checkmate.nvim/wiki/Snippets) |
| scratch buffer/floating window for quick todos, e.g. [snacks.nvim](https://github.com/folke/snacks.nvim/blob/main/docs/scratch.md) | ✅ [wiki](https://github.com/bngarren/checkmate.nvim/wiki#snacksnvim) |


<a id="linting"><a/>

# ☑️ Linting
Checkmate uses a _very_ limited custom linter in order require zero dependencies but attempt to warn the user of Markdown (CommonMark spec) formatting issues that could cause unexpected plugin behavior.

> The embedded linter is NOT a general-purpose Markdown linter and _may_ interfere with other linting tools. Though, in testing with conform.nvim and prettier, I have not found any issues.

#### Example

❌ misaligned list marker
```md
1. ☐ Parent todo item
  - ☐ Child todo item (indented only 2 spaces!)
```

✅ correctly aligned list marker
```md
1. ☐ Parent todo item
   - ☐ Child todo item (indented 3 spaces!)
```
The [CommonMark spec](https://spec.commonmark.org/current) requires that nested list markers begin at the col of the first non-whitespace content after the parent list marker (which will be a different col for bullet list vs ordered list markers)

If you feel comfortable with the nuances of Markdown list syntax, you can disable the linter (default is enabled) via config:
```lua
{
  linter = {
    enabled = false
  }
}
```

<a id="roadmap"><a/>

# ☑️ Roadmap

Planned features:

- [x] **Metadata support** - mappings for quick addition of metadata/tags such as @start, @done, @due, @priority, etc. with custom highlighting. _Added v0.2.0_

- [x] **Sub-task counter** - add a completed/total count (e.g. 1/4) to parent todo items. _Added v0.3.0_

- [x] **Archiving** - manually or automatically move completed items to the bottom of the document. _Added v0.7.0_ (experimental)

- [x] **Smart toggling** - toggle all children checked if a parent todo is checked. Toggle a parent checked if the last unchecked child is checked. _Added v0.7.0_ 

- [x] **Metadata upgrade** - callbacks, async support, jump to. _Added v0.9.0_

- [x] **Custom todo states** - support beyond binary "checked" and "unchecked", allowing for todos to be in custom states, e.g. pending, not-planned, on-hold, etc. _Added v0.10.0_

- [x] **List (todo) continuation** - automatically created new todo lines in insert mode, e.g. `<CR>` on a todo line will create a new todo below. _Added v0.11.0_

<a id="contributing"><a/>

# ☑️ Contributing

If you have feature suggestions or ideas, please feel free to open an issue on GitHub!

<a id="credits"><a/>

# ☑️ Credits

- Inspired by the [Todo+](https://github.com/fabiospampinato/vscode-todo-plus) VS Code extension (credit to @[fabiospampinato](https://github.com/fabiospampinato))
