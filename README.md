<div align="center">

<img width="400" alt="Checkmate logo" src="./assets/logo.png">

### Get stuff done

[![Lua](https://img.shields.io/badge/Lua-blue.svg?style=for-the-badge&logo=lua)](http://www.lua.org)
[![Neovim](https://img.shields.io/badge/Neovim%200.10+-green.svg?style=for-the-badge&logo=neovim&color=%2343743f)](https://neovim.io)
![GitHub Release](https://img.shields.io/github/v/release/bngarren/checkmate.nvim?style=for-the-badge&logoSize=200&color=%23f3d38a&labelColor=%23061914)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/bngarren/checkmate.nvim/lint-test.yml?branch=main&style=for-the-badge&label=CI&labelColor=%23061914&color=%2343743f)


</div><br/>

A Markdown-based todo list plugin for Neovim with a nice UI and full customization options.

### Features
- Saves files in plain Markdown format (compatible with other apps)
- Customizable markers and colors
- Visual mode support for toggling multiple items at once
- Metadata e.g. `@tag(value)` annotations with extensive customization
  - e.g. @started, @done, @priority, @your-custom-tag
- Todo completion counts
- Smart toggling behavior
- Archive completed todos

<br/>

<img width="700" alt="Checkmate example 1" src="./assets/todos-example-1.png">
<img width="700" alt="Checkmate example 2" src="./assets/todos-example-2.png">


https://github.com/user-attachments/assets/d9b58e2c-24e2-4fd8-8d7f-557877a20218


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
  version = "~0.8.0" -- pins to minor 0.8.x
}
```

# ☑️ Usage

### 1. Open or Create a Todo File

Checkmate automatically activates when you open a Markdown file that matches your configured patterns.

**Default patterns:**
- `todo` or `TODO` (exact filename)
- `todo.md` or `TODO.md`
- Files with `.todo` extension (e.g., `project.todo`, `work.todo.md`)

<br>

> [!NOTE]
> Checkmate only activates for files with the "markdown" filetype. Files without extensions need their filetype set to markdown (`:set filetype=markdown`)

<br>

> [!TIP]
> You can customize which files activate Checkmate using the `files` configuration option:
> ```lua
> files = { "tasks", "*.plan", "project/**/todo.md" }
> ```
> Patterns support full Unix-style globs including `*`, `**`, `?`, `[abc]`, and `{foo,bar}`

### 2. Create Todo Items

- Use the **mapped key** (_recommended_, default: `<leader>Tn`) or the `:CheckmateCreate` command
- Or manually using Markdown syntax:

```md
- [ ] Unchecked todo
- [x] Checked todo
```

(These will automatically convert when you leave insert mode!)

### 3. Manage Your Tasks

- Toggle items with `:CheckmateToggle` (default: `<leader>Tt`)
- Check items with `:CheckmateCheck` (default: `<leader>Tc`)
- Uncheck items with `:CheckmateUncheck` (default: `<leader>Tu`)
- Select multiple items in visual mode and use the same commands
- Archive completed todos with `:CheckmateArchive` (default: `<leader>Ta`)

Enhance your todos with custom [metadata](#metadata) with quick keymaps!

> [!NOTE]
> The Checkmate buffer is saved as regular Markdown!

# ☑️ Commands
> [!WARNING]
> The top-level commands such as `:CheckmateToggle`, `:CheckmateArchive`, etc. have been deprecated and will be removed in upcoming release. Use the subcommands or public API below.

#### User commands
`:Checkmate [subcommand]`

| subcommand | Description |
|------------|-------------|
| `archive` | Archive all checked todo items in the buffer. See api `archive()` |
| `check` | Mark the todo item under the cursor as checked. See api `check()`|
| `create` | Create a new todo item at the current line or line below if a todo already exists. In visual mode, convert each line to a todo item. See api `create()`|
| `lint` | Lint this buffer for Checkmate formatting issues. See api `lint()` |
| `metadata add` | Add a metadata tag to the todo under the cursor or within the selection. Usage: `:Checkmate metadata add <key> [value]`. See api `add_metadata(key, value)` |
| `metadata remove` | Remove a specific metadata tag from the todo under the cursor or within the selection. Usage: `:Checkmate metadata remove <key>`. See api `remove_metadata(key)` |
| `metadata toggle` | Toggle a metadata tag on/off for the todo under the cursor or within the selection. Usage: `:Checkmate metadata toggle <key> [value]`. See api `toggle_metadata(key, value)` |
| `remove_all_metadata` | Remove *all* metadata tags from the todo under the cursor or within the selection. See api `remove_all_metadata()` |
| `toggle` | Toggle the todo item under the cursor (normal mode) or all todo items within the selection (visual mode). See api `toggle()` |
| `uncheck` | Mark the todo item under the cursor as unchecked. See api `uncheck()` |

<br>
<details>
<summary>Legacy commands (deprecated)</summary>

CheckmateToggle
: Toggle the todo item under the cursor (normal mode) or all todo items within the selection (visual mode)

CheckmateCreate
: Convert the current line to a todo item

CheckmateCheck
: Mark todo item as checked (done/completed) in normal or visual mode

CheckmateUncheck
: Mark todo item as unchecked in normal or visual mode

CheckmateRemoveAllMetadata
: Removes all metadata from todo item under the cursor (normal mode) or all todo items within the selection (visual mode)

CheckmateArchive
: Reorganize checked/completed todo items to the bottom section

CheckmateLint
: Perform limited linting of Checkmate buffer to warn about syntax issues that could cause unexpected plugin behavior

</details>
<br>

# ☑️ Config

<details>
<summary>Config definitions/annotations</summary>

```lua
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
---@field archive checkmate.ArchiveSettings? -- Settings for the archived todos section
---
---Config for the linter
---@field linter checkmate.LinterConfig?
---
---Turn off treesitter highlights (on by default)
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
```

</details>

### Defaults
```lua
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
    newest_first = true
  },
  linter = {
    enabled = true,
  },
}
```

Note: `checkmate.StyleSettings` uses highlight definition maps to define the colors/style, refer to `:h nvim_set_hl()`

## Styling
As of version 0.6, default styles are calculated based on the current _colorscheme_. This attempts to provide reasonable out-of-the-box defaults based on colorscheme-defined hl groups and contrast ratios.

Individual styles can still be overriden using the same `config.style` table and passing a 'highlight definition map' according to `:h nvim_set_hl()` and `vim.api.keyset.highlight`.

### Example: Change the checked marker to a bold green
```lua
opts = {
    style = {
        checked_marker = { fg = "#7bff4f", bold = true}
    }
}
```

> [!WARNING]
> Multi-character todo markers are not currently supported but _may_ work. For consistent behavior, recommend using a single character.

## Metadata

Metadata tags allow you to add custom `@tag(value)` annotations to todo items.

<img alt="Metadata Example" src="./assets/metadata-example.png" /><br/>

- Default tags:
  - `@started` - default value is the current date/time
  - `@done` - default value is the current date/time
  - `@priority` - "low" | "medium" (default) | "high"

#### @priority example

```lua
priority = {
  -- Dynamic styling based on the tag's current value
  style = function(value)
    local value = value:lower()
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
  get_value = function() return "medium" end,  -- Default value
  key = "<leader>Tp",                          -- Keymap to toggle
  sort_order = 10,                             -- Order when multiple tags exist (lower comes first)
  jump_to_on_insert = "value",                 -- Move the cursor after insertion
  select_on_insert = true                      -- Select the 'value' (visual mode) on insert
},
```

#### @done example

```lua
done = {
  aliases = { "completed", "finished" },
  style = { fg = "#96de7a" },
  get_value = function()
    return tostring(os.date("%m/%d/%y %H:%M"))
  end,
  key = "<leader>Td",
  -- Changes todo state when tag is added
  on_add = function(todo_item)
    require("checkmate").set_todo_item(todo_item, "checked")
  end,
  -- Changes todo state when tag is removed
  on_remove = function(todo_item)
    require("checkmate").set_todo_item(todo_item, "unchecked")
  end,
  sort_order = 30,
},
```

## Todo count indicator

<table>
  <tr>
    <td align="center">
      <img
        src="./assets/count-indicator-eol.png"
        alt="Todo count indicator using 'eol' position"
        height="75"
      /><br/>
      <sub>Todo count indicator using <code>eol</code> position</sub>
    </td>
    <td align="center">
      <img
        src="./assets/count-indicator-inline.png"
        alt="Todo count indicator using 'inline' position"
        height="75"
      /><br/>
      <sub>Todo count indicator using <code>inline</code> position</sub>
    </td>
  </tr>
</table>

#### Change the default display by passing a custom formatter

```lua
-- Custom formatter that returns the % completed
todo_count_formatter = function(completed, total)
  return string.format("%.0f%%", completed / total * 100)
end,
```

<img
        src="./assets/count-indicator-custom-formatter.png"
        alt="Todo count indicator using a custom formatter function"
        height="75"
      /><br/>
<sub>Todo count indicator using <code>todo_count_formatter</code> function</sub>

#### Count all nested todo items
If you want the todo count of a parent todo item to include _all_ nested todo items, set the recursive option.

```lua
todo_count_recursive = true,
```
<img
        src="./assets/count-indicator-recursive.png"
        alt="Todo count indicator using recursive option"
        height="90"
      /><br/>
<sub>Todo count indicator using <code>recursive</code> option. The children of 'Sub-task 3' are included in the overall count of 'Big important task'.</sub> 

# Smart Toggle

Smart toggle provides intelligent parent-child todo state propagation. When you toggle a todo item, it can automatically update related todos based on your configuration.

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

# Archiving
Allows you to easily reorganize the buffer by moving all checked/completed todo items to a Markdown section beneath all other content. The unchecked todos are reorganized up top and spacing is adjusted.

See `CheckmateArchive` command or `require("checkmate").archive()`

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


# Linting
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

# Roadmap

Planned features:

- [x] **Metadata support** - mappings for quick addition of metadata/tags such as @start, @done, @due, @priority, etc. with custom highlighting. _Added v0.2.0_

- [x] **Sub-task counter** - add a completed/total count (e.g. 1/4) to parent todo items. _Added v0.3.0_

- [x] **Archiving** - manually or automatically move completed items to the bottom of the document. _Added v0.7.0_ (experimental)

- [x] Smart toggling - toggle all children checked if a parent todo is checked. Toggle a parent checked if the last unchecked child is checked. _Added v0.7.0_ 

- [ ] Sorting API - user can register custom sorting functions and keymap them so that sibling todo items can be reordered quickly. e.g. `function(todo_a, todo_b)` should return an integer, and where todo_a/todo_b is a table containing data such as checked state and metadata tag/values

- [ ] Distinguish todo siblings - highlighting feature that applies slightly different colors to siblings to better differentiate them

# Contributing

If you have feature suggestions or ideas, please feel free to open an issue on GitHub!

# Credits

- Inspired by the [Todo+](https://github.com/fabiospampinato/vscode-todo-plus) VS Code extension (credit to @[fabiospampinato](https://github.com/fabiospampinato))
