<div align="center">

# checkmate.nvim

### A simple Todo plugin

[![Lua](https://img.shields.io/badge/Lua-blue.svg?style=for-the-badge&logo=lua)](http://www.lua.org)
[![Neovim](https://img.shields.io/badge/Neovim%200.10+-green.svg?style=for-the-badge&logo=neovim)](https://neovim.io)

<img alt="Checkmate Mate" height="220" src="./assets/checkmate-logo.png" />
</div><br/>

A markdown-based todo list manager for Neovim with a clean UI, multi-line support, and full customization options.

- Stores todos in plain Markdown format (compatible with other apps)
- Unicode symbol support for more beautiful todo items
- Customizable markers and colors
- Multi-line todo item support with hierarchical toggling
- Visual mode support for toggling multiple items at once
- Full keyboard shortcut customization

<br/>



https://github.com/user-attachments/assets/ac18f810-2bf7-40a7-96d7-9de492c75445





# ☑️ Installation

## Requirements
- Neovim 0.10 or higher

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
    "bngarren/checkmate.nvim",
    opts = {
        -- your configuration here
        -- or leave empty to use defaults
    },

}
```

# ☑️ Usage

#### 1. Open or Create a Todo File
- Create or open a file with the `.todo` extension
- The plugin automatically activates for `.todo` files, treating them as Markdown

> As of now, the plugin is only activated when a buffer with `.todo` extension is opened.

#### 2. Create Todo Items

- Use `:CheckmateCreate` command or the mapped key (default: `<leader>Tn`)
- Or manually using Markdown syntax:
```md
- [ ] Unchecked todo
- [x] Checked todo
```
(These will automatically convert when you leave insert mode!)

#### 3. Manage Your Tasks
- Toggle items with `:CheckmateToggle` (default: `<leader>Tt`)
- Check items with `:CheckmateCheck` (default: `<leader>Td`)
- Uncheck items with `:CheckmateUncheck` (default: `<leader>Tu`)
- Select multiple items in visual mode and use the same commands

# ☑️ Commands

:CheckmateToggle
: Toggle the todo item under the cursor (normal mode) or all todo items within the selection (visual mode)

:CheckmateCreate
: Convert the current line to a todo item

:CheckmateCheck
: Mark todo item as checked (done/completed)

:CheckmateUncheck
: Mark todo item as unchecked

# ☑️ Config

```lua
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
--- Open with `:Checkmate debug_log`
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
    list_marker_unordered = { fg = "#666666" },
    list_marker_ordered = { fg = "#333333" },

    -- Unchecked todo items
    unchecked_marker = { fg = "#ff9500", bold = true }, -- The marker itself
    unchecked_main_content = { fg = "#ffffff" }, -- Style settings for main content: typicallly the first line/paragraph
    unchecked_additional_content = { fg = "#dddddd" }, -- Settings for additional content

    -- Checked todo items
    checked_marker = { fg = "#00cc66", bold = true }, -- The marker itself
    checked_main_content = { fg = "#aaaaaa", strikethrough = true }, -- Style settings for main content: typicallly the first line/paragraph
    checked_additional_content = { fg = "#aaaaaa" }, -- Settings for additional content
  },
  enter_insert_after_new = true, -- Should enter INSERT mode after :CheckmateCreate (new todo)
  todo_action_depth = 1, --  Depth within a todo item's hierachy from which actions (e.g. toggle) will act on the parent todo item
}
```

Note: `checkmate.StyleSettings` uses highlight definition maps to define the colors/style, refer to `:h nvim_set_hl()`

# Roadmap
Planned features:
1. **Metadata support** - mappings for quick addition of metadata/tags such as @start, @done, @due, @priority, etc. with custom highlighting

2. **Archiving** - manually or automatically move completed items to the bottom of the document

# Contributing
If you have feature suggestions or ideas, please feel free to open an issue on GitHub!

# Credits
- Inspired by the [Todo+](https://github.com/fabiospampinato/vscode-todo-plus) VS Code extension (credit to @[fabiospampinato](https://github.com/fabiospampinato))

