local commands = {}

---@class checkmate.CommandDefinition
---@field desc string description shown in help
---@field nargs string as in nvim_create_user_command
---@field handler fun(opts: { fargs: string[], bang: boolean, line: string }): nil callback invoked when this command runs
---@field complete? string[]|fun(arglead: string, cmdline: string, cursorpos: integer): string[] either a static list of completions or a function completer
---@field subcommands? table<string, checkmate.CommandDefinition>

---@type checkmate.CommandDefinition[]
local top_commands = {
  toggle = {
    desc = "Toggle todo item under cursor or selection",
    nargs = "?",
    handler = function(opts)
      -- opts.fargs[2] may be "checked" or "unchecked"
      require("checkmate").toggle(opts.fargs[2])
    end,
    complete = { "checked", "unchecked" },
  },

  create = {
    desc = "Create a new todo item",
    nargs = "0",
    handler = function()
      require("checkmate").create()
    end,
  },

  check = {
    desc = "Mark todo item as checked",
    nargs = "0",
    handler = function()
      require("checkmate").check()
    end,
  },

  uncheck = {
    desc = "Mark todo item as unchecked",
    nargs = "0",
    handler = function()
      require("checkmate").uncheck()
    end,
  },

  lint = {
    desc = "Lint this buffer for Checkmate formatting issues",
    nargs = "0",
    handler = function()
      require("checkmate").lint()
    end,
  },

  archive = {
    desc = "Archive checked todo items",
    nargs = "0",
    handler = function()
      require("checkmate").archive()
    end,
  },

  remove_all_metadata = {
    desc = "Remove all metadata from todo under cursor/selection",
    nargs = "0",
    handler = function()
      require("checkmate").remove_all_metadata()
    end,
  },

  metadata = {
    desc = "Metadata operations",
    subcommands = {
      add = {
        desc = "Add metadata tag: @<name>(value)",
        nargs = "+", -- at least name, maybe value
        handler = function(opts)
          local name = opts.fargs[2]
          local value = opts.fargs[3]
          require("checkmate").add_metadata(name, value)
        end,
        complete = function()
          return vim.tbl_keys(require("checkmate.config").options.metadata)
        end,
      },

      remove = {
        desc = "Remove a metadata tag",
        nargs = "1",
        handler = function(opts)
          require("checkmate").remove_metadata(opts.fargs[2])
        end,
        complete = function()
          return vim.tbl_keys(require("checkmate.config").options.metadata)
        end,
      },

      toggle = {
        desc = "Toggle a metadata tag on/off",
        nargs = "+",
        handler = function(opts)
          require("checkmate").toggle_metadata(opts.fargs[2], opts.fargs[3])
        end,
        complete = function()
          return vim.tbl_keys(require("checkmate.config").options.metadata)
        end,
      },
      select_value = {
        desc = "Select a value from completion options for the metadata tag under the cursor",
        nargs = "0",
        handler = function()
          require("checkmate").select_metadata_value()
        end,
      },
    },
  },

  debug = {
    desc = "Debug helpers",
    subcommands = {
      log = {
        desc = "Open debug log",
        nargs = "0",
        handler = function()
          require("checkmate").debug_log()
        end,
      },
      clear = {
        desc = "Clear debug log",
        nargs = "0",
        handler = function()
          require("checkmate").debug_clear()
        end,
      },
      at = {
        desc = "Inspect todo at cursor",
        nargs = "0",
        handler = function()
          require("checkmate").debug_at_cursor()
        end,
      },
      print_map = {
        desc = "Print todo map",
        nargs = "0",
        handler = function()
          require("checkmate").debug_print_todo_map()
        end,
      },
      profiler_on = {
        desc = "Start profiler",
        nargs = "0",
        handler = function()
          require("checkmate.profiler").start_session()
        end,
      },
      profiler_off = {
        desc = "Stop profiler",
        nargs = "0",
        handler = function()
          require("checkmate.profiler").stop_session()
        end,
      },
      report = {
        desc = "Show profiler report",
        nargs = "0",
        handler = function()
          require("checkmate.profiler").show_report()
        end,
      },
    },
  },
}

function commands.dispatch(opts)
  local args = opts.fargs
  local first = args[1]
  if not first or not top_commands[first] then
    return vim.notify("Checkmate: Unknown subcommand: " .. (first or "<none>"), vim.log.levels.WARN)
  end

  local entry = top_commands[first]

  if entry.subcommands then
    -- nested dispatch
    local second = args[2]
    if not second or not entry.subcommands[second] then
      return vim.notify(
        ("Usage: Checkmate %s <%s>"):format(first, table.concat(vim.tbl_keys(entry.subcommands), "|")),
        vim.log.levels.INFO
      )
    end
    local sub = entry.subcommands[second]
    -- pass only arguments after the nested key
    local nested_opts = {
      fargs = vim.list_slice(args, 2),
      bang = opts.bang,
    }
    return sub.handler(nested_opts)
  else
    -- direct dispatch
    return entry.handler(opts)
  end
end

local function complete_fn(arglead, cmdline, cursorpos)
  -- split "Checkmate metadata add foo" ⇒ { "Checkmate", "metadata", "add", "foo" }
  local parts = vim.split(cmdline, "%s+")
  -- drop "Checkmate"
  table.remove(parts, 1)

  -- top level commands
  if #parts <= 1 then
    return vim.tbl_filter(function(k)
      return vim.startswith(k, arglead)
    end, vim.tbl_keys(top_commands))
  end

  -- top level SUB command
  local first = parts[1]
  local entry = top_commands[first]
  if not entry or not entry.subcommands then
    return {}
  end

  -- SUB commands for the sub command
  if #parts == 2 then
    return vim.tbl_filter(function(k)
      return vim.startswith(k, arglead)
    end, vim.tbl_keys(entry.subcommands))
  end

  -- use the entry's own 'complete' function
  local nested = entry.subcommands[parts[2]]
  if nested and nested.complete then
    local candidates
    if type(nested.complete) == "function" then
      candidates = nested.complete(arglead, cmdline, cursorpos)
      ---@cast candidates string[]
    else
      candidates = nested.complete
      ---@cast candidates string[]
    end
    return vim.tbl_filter(function(k)
      return vim.startswith(k, arglead)
    end, candidates or {})
  end

  return {}
end

-- called from init.lua when setting up a buffer
function commands.setup(bufnr)
  vim.api.nvim_buf_create_user_command(bufnr, "Checkmate", function(opts)
    commands.dispatch(opts)
  end, {
    nargs = "*",
    complete = complete_fn,
    desc = "Checkmate: main command",
  })
end

function commands.dispose(bufnr)
  pcall(vim.api.nvim_buf_del_user_command, bufnr, "Checkmate")
end

return commands
