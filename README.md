<div align="center">

<img width="350" alt="checkmate_logo" src="https://github.com/user-attachments/assets/01c8e335-b8a0-47d5-b480-8ad8957c7b5f" />

### Get stuff done

<p align="center">
<a href="#table-of-contents">Table of Contents</a>&nbsp;&bull;&nbsp;
<a href="https://github.com/bngarren/checkmate.nvim/wiki">Wiki</a>
</p>

</div><br/>

<i>A Markdown-based todo/task plugin for Neovim.</i>

# Features

- Create and toggle Markdown todos
- Customizable markers and styling
- Compatible with popular Neovim Markdown plugins (e.g., render-markdown, markview)
- Visual mode support for multiple todos
- Metadata e.g. `@tag(value)` annotations with extensive customization
  - e.g. @started, @done, @priority, @your-custom-tag
- Todo completion counts/percentage
- Smart toggling behavior
- Archive (reorganize) completed todos
- Todo templates with LuaSnip snippet integration
- Custom todo states
  - More than just "checked" and "unchecked", e.g. "partial", "in-progress", "on-hold"
- Automatic todo creation (list continuation in insert mode)

#### Check out the [wiki](https://github.com/bngarren/checkmate.nvim/wiki) for additional documentation and recipes, including:

> - [Advanced metadata](https://github.com/bngarren/checkmate.nvim/wiki/Metadata)
> - [Snippets](https://github.com/bngarren/checkmate.nvim/wiki/Snippets)
> - [How to setup a per-project, low-friction `checkmate.nvim` buffer with snacks.nvim](https://github.com/bngarren/checkmate.nvim/wiki#snacksnvim)

<br/>

<img width="1200" height="204" alt="checkmate_example_simple" src="https://github.com/user-attachments/assets/6eecda10-109a-442f-b709-83ed35065bf9" />

<img width="1200" height="341" alt="checkmate_demo_complex" src="https://github.com/user-attachments/assets/8bbb9b20-23f7-4f82-b2b3-a8e8d2d9d4c5" />

https://github.com/user-attachments/assets/d5fa2fc8-085a-4cee-9763-a392d543347e

<!-- panvimdoc-ignore-start -->

# Table of Contents

- [Installation](#installation)
- [Requirements](#requirements)
- [Usage](#usage)
- [Commands](#commands)
- [Configuration](#config)
  - [Keymaps](#keymapping)
  - [Styling](#styling)
  - [Todo states](#todo-states)
  - [Todo counts](#todo-count-indicator)
  - [Smart toggle](#smart-toggle)
  - [Pickers](#pickers)
- [Metadata](#metadata)
- [Archiving](#archiving)
- [Integrations](#integrations)
- [Linting](#linting)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [Credits](#credits)

<!-- panvimdoc-ignore-end -->

<a id="installation"><a/>

# Installation

## Requirements

- Neovim 0.10 or higher

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "bngarren/checkmate.nvim",
  ft = "markdown", -- Lazy loads for Markdown files matching patterns in 'files'
  opts = {
    -- files = { "*.md" }, -- any .md file (instead of defaults)
  },
}
```

If you'd like _stable-ish_ version during pre-release, can add a minor version to the [lazy spec](https://lazy.folke.io/spec#spec-versioning):

```
{
  version = "~0.12.0" -- pins to minor 0.12.x
}
```

<a id="usage"><a/>

# Usage

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
files = {
  "*.md",              -- Any markdown file (basename matching)
  "**/todo.md",        -- 'todo.md' anywhere in directory tree
  "project/todo.md",   -- Any path ending with 'project/todo.md'
  "/absolute/path.md", -- Exact absolute path match
}
```

Patterns support Unix-style globs including `*`, `**`, `?`, `[abc]`, and `{foo,bar}`

### 2. Create Todos

- Use the **mapped key** (default: `<leader>Tn`) or the `:Checkmate create` command
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
- [Archive](#archiving) completed todos with `:Checkmate archive` (default: `<leader>Ta`)

Enhance your todos with custom [metadata](#metadata) with quick keymaps!

Your buffer is **saved as regular Markdown** which means it's compatible with any Markdown editor!

<a id="commands"><a/>

# Commands

#### User commands

`:Checkmate [subcommand]`

| subcommand               | Description                                                                                                                                                                                                                                                                                                                                |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `archive`                | Archive all completed todo items in the buffer. This extracts them and moves them to a bottom section. See api `archive()` and [Archiving](#archiving) section.                                                                                                                                                                            |
| `check`                  | Mark the todo item under the cursor as checked. See api `check()`                                                                                                                                                                                                                                                                          |
| `create`                 | In normal mode, converts the current line into a todo (or if already a todo, creates a sibling below). In visual mode, converts each selected line into a todo. In insert mode, creates a new todo on the next line and keeps you in insert mode. For more advanced placement, indentation, and state options, see the `create(opts)` API. |
| `cycle_next`             | Cycle a todo's state to the next available. See api `cycle()`                                                                                                                                                                                                                                                                              |
| `cycle_previous`         | Cycle a todo's state to the previous. See api `cycle()`                                                                                                                                                                                                                                                                                    |
| `lint`                   | Lint this buffer for Checkmate formatting issues. Runs automatically on `InsertLeave` and `TextChanged`. See api `lint()` and[Linting](#linting) section.                                                                                                                                                                                  |
| `metadata add`           | Add a metadata tag to the todo under the cursor or within the selection. Usage: `:Checkmate metadata add <key> [value]`. See api `add_metadata(key, value)` and [Metadata](#metadata) section.                                                                                                                                             |
| `metadata jump_next`     | Move the cursor to the next metadata tag for the todo item under the cursor. See api `jump_next_metadata()`                                                                                                                                                                                                                                |
| `metadata jump_previous` | Move the cursor to the previous metadata tag for the todo item under the cursor. See api `jump_previous_metadata()`                                                                                                                                                                                                                        |
| `metadata remove`        | Remove a specific metadata tag from the todo under the cursor or within the selection. Usage: `:Checkmate metadata remove <key>`. See api `remove_metadata(key)`                                                                                                                                                                           |
| `metadata select_value`  | Select a value from the 'choices' option for the metadata tag under the cursor. See api `select_metadata_value()`                                                                                                                                                                                                                          |
| `metadata toggle`        | Toggle a metadata tag on/off for the todo under the cursor or within the selection. Usage: `:Checkmate metadata toggle <key> [value]`. See api `toggle_metadata(key, value)`                                                                                                                                                               |
| `remove`                 | Convert a todo line back to regular text. See api `remove(opts)`. By default, will preserve the list item marker and remove any metadata. This can be configured via `opts`.                                                                                                                                                               |
| `remove_all_metadata`    | Remove _all_ metadata tags from the todo under the cursor or within the selection. See api `remove_all_metadata()`                                                                                                                                                                                                                         |
| `toggle`                 | Toggle the todo item under the cursor (normal mode) or all todo items within the selection (visual mode). See api `toggle()`. Without a parameter, toggles between `unchecked` and `checked`. To change to custom states, use the api `toggle(target_state)` or the `cycle_*` commands.                                                    |
| `uncheck`                | Mark the todo item under the cursor as unchecked. See api `uncheck()`                                                                                                                                                                                                                                                                      |

<a id="config"><a/>

# Config

For config definitions/annotations, see [here](https://github.com/bngarren/checkmate.nvim/blob/main/lua/checkmate/config/init.lua#L34).

## Defaults

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
  ui = {},
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
      on_add = function(todo)
        require("checkmate").set_todo_state(todo, "checked")
      end,
      on_remove = function(todo)
        require("checkmate").set_todo_state(todo, "unchecked")
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

## Keymapping

[Default](#defaults) keymaps can be disabled by setting `keys = false`.

The `keys` table overrides the defaults (does not merge). If you want some custom and some defaults, you need to copy the defaults into your own `keys` table.

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

Checkmate highlighting can be completely disabled by setting `style` to _false_.

### Highlight groups

| hl_group                            | description                                                                                            |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------ |
| CheckmateListMarkerUnordered        | Unordered list markers, e.g. `-`,`*`, and `+`. (_Only those associated with a todo_)                   |
| CheckmateListMarkerOrdered          | Ordered list markers, e.g. `1.`, `2)`. (_Only those associated with a todo_)                           |
| CheckmateUncheckedMarker            | Unchecked todo marker, e.g. `□`. See `todo_states` `marker` option                                     |
| CheckmateUncheckedMainContent       | The main content of an unchecked todo (typically the first paragraph)                                  |
| CheckmateUncheckedAdditionalContent | Additional content for an unchecked todo (subsequent paragraphs, list items, etc.)                     |
| CheckmateCheckedMarker              | Checked todo marker, e.g. `✔`. See `todo_states` `marker` option                                      |
| CheckmateCheckedMainContent         | The main content of a checked todo (typically the first paragraph)                                     |
| CheckmateCheckedAdditionalContent   | Additional content for a checked todo (subsequent paragraphs, list items, etc.)                        |
| CheckmateTodoCountIndicator         | The todo count indicator, e.g. `1/4`, shown on the todo line, if enabled. See `show_todo_count` option |

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

States may be one of three types that give the state semantic and functional meaning:

| Type         | Behavior                | Example States                              |
| ------------ | ----------------------- | ------------------------------------------- |
| `incomplete` | Counts as "not done"    | **unchecked**, in_progress, pending, future |
| `complete`   | Counts as "done"        | **checked**, cancelled                      |
| `inactive`   | Ignored in calculations | on_hold, not_planned                        |

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

It displays the number of `complete / incomplete` todos in a hierarchy. It counts the standard "checked" and "unchecked" states, as well as custom states based on their `type` (incomplete or complete). The "inactive" type is not included.

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

## Pickers
Checkmate uses a picker for various API functions. To provide a reasonable, out-of-the-box experience, several popular external picker plugin backends are implemented:
- snacks.nvim
- mini.pick
- telescope.nvim

or, as a fallback native `vim.ui.select`

### Configuration
#### Global configuration
Set the default picker in the setup opts:
```lua
ui = {
  picker = "snacks" -- or "mini", "telescope", or "native"
}
```

#### Per-call configuration
Some API functions allow passing `picker_opts`:
```lua
require("checkmate").select_metadata_value({
  picker_opts = {
    picker = "snacks",  -- force snacks for this call
    snacks = {
      layout = { preset = "dropdown" }
    }
  }
})
```

#### Custom pickers
Some API functions support a `custom_picker` function that is intended to receive data related to that API and expects the `complete(value)` callback to finalize the Checkmate behavior.
```lua
require("checkmate").select_metadata_value({
  custom_picker = function(ctx, complete)
    require("snacks").picker.files({
      confirm = function(picker, item)
        if item then
          vim.schedule(function()
            complete(item.text)
          end)
        end
        picker:close()
      end,
    })
  end,
})
```

# Metadata

Metadata tags allow you to add custom `@tag(value)` annotations to todo items.

<img width="909" height="95" alt="checkmate_metadata_example" src="https://github.com/user-attachments/assets/69d95b07-f80a-4cd3-be40-856e627a8023" />

- Default tags:
  - `@started` - default value is the current date/time
  - `@done` - default value is the current date/time
  - `@priority` - "low" | "medium" (default) | "high"

The default tags are not deeply merged in order to avoid unexpected behavior. If you wish to modify a default metadata, you should copy the default implementation.

By configuring a metadata's `choices` option, you can populate your own lists of metadata values for powerful workflows, e.g. project file names, Git branches, PR's, issues, etc., team member names, external APIs, etc.

Alternatively, you can call `select_metadata_value()` and pass a custom picker function and use the selected item to update your metadata!

```lua
-- Update metadata under the cursor using a snacks.nvim picker
require("checkmate").select_metadata_value({
  custom_picker = function(ctx, complete)
    require("snacks").picker.files({
      confirm = function(picker, item)
        if item then
          vim.schedule(function()
            complete(item.text)
          end)
        end
        picker:close()
      end,
    })
  end,
})
```

For in-depth guide and recipes for custom metadata, see the [Wiki](https://github.com/bngarren/checkmate.nvim/wiki/Todo-Metadata) page.

<a id="archiving"><a/>

# Archiving

Allows you to easily reorganize the buffer by moving all **completed** todo items to a Markdown section beneath all other content. The remaining unchecked/incomplete todos are reorganized up top and spacing is adjusted.

Archiving collects all todos with the "completed" [state type](#state-types), which includes the default "checked" state, but possibly others based on custom todo states.

See `Checkmate archive` command or `require("checkmate").archive()`

> Current behavior (could be adjusted in the future): a completed todo item that is nested under an incomplete parent will not be archived. This prevents 'orphan' todos being separated from their parents. Similarly, a completed parent todo will carry all nested todos (completed and incomplete) when archived.

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

# Integrations

Please see [wiki](https://github.com/bngarren/checkmate.nvim/wiki) for additional details/recipes.

| Integration                                                                                                                        | Capable? |
| ---------------------------------------------------------------------------------------------------------------------------------- | -------- |
| [render-markdown](https://github.com/MeanderingProgrammer/render-markdown.nvim)                                                    | ✅       |
| [markview](https://github.com/OXY2DEV/markview.nvim)                                                                               | ✅       |
| [LuaSnip](https://github.com/L3MON4D3/LuaSnip)                                                                                     | ✅       |
| [scratch buffer/floating window for quick todos, e.g. snacks.nvim](https://github.com/folke/snacks.nvim/blob/main/docs/scratch.md) | ✅       |

<a id="linting"><a/>

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

<a id="roadmap"><a/>

# Roadmap

Planned features:

- [x] **Metadata support** - mappings for quick addition of metadata/tags such as @start, @done, @due, @priority, etc. with custom highlighting. _Added v0.2.0_

- [x] **Sub-task counter** - add a completed/total count (e.g. 1/4) to parent todo items. _Added v0.3.0_

- [x] **Archiving** - manually or automatically move completed items to the bottom of the document. _Added v0.7.0_

- [x] **Smart toggling** - toggle all children checked if a parent todo is checked. Toggle a parent checked if the last unchecked child is checked. _Added v0.7.0_

- [x] **Metadata upgrade** - callbacks, async support, jump to. _Added v0.9.0_

- [x] **Custom todo states** - support beyond binary "checked" and "unchecked", allowing for todos to be in custom states, e.g. pending, not-planned, on-hold, etc. _Added v0.10.0_

- [x] **List (todo) continuation** - automatically created new todo lines in insert mode, e.g. `<CR>` on a todo line will create a new todo below. _Added v0.11.0_
- [ ] **Better archive** - generalize the archive functionality to move todos to specific buffer locations (or even different buffers/files). Provide config opt and API to specify which todo state type to act on (i.e. completed, incompleted, inactive). Integrate with picker to choose a new Markdown heading location to move todos.

- [ ] **Improved todo search** - Expose a `find_todos` and `find_metadata` that return lists of todos, based on search criteria that can be used to populate qflists and pickers.

<a id="contributing"><a/>

# Contributing

If you have feature suggestions or ideas, please feel free to open an issue on GitHub!

<a id="credits"><a/>

# Credits

- Inspired by the [Todo+](https://github.com/fabiospampinato/vscode-todo-plus) VS Code extension (credit to @[fabiospampinato](https://github.com/fabiospampinato))
