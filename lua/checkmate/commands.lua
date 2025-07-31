local log = require("checkmate.log")

local Commands = {}

---@class checkmate.CommandDefinition
---@field desc string description shown in help
---@field nargs string as in nvim_create_user_command
---@field handler fun(opts: { fargs: string[], bang: boolean, line: string }): nil callback invoked when this command runs
---@field complete? string[]|fun(arglead: string, cmdline: string, cursorpos: integer): string[] either a static list of completions or a function completer
---@field subcommands? table<string, checkmate.CommandDefinition>

---@type checkmate.CommandDefinition[]
local top_commands = {
  enable = {
    desc = "Activate Checkmate",
    nargs = "0",
    handler = function()
      require("checkmate").enable()
    end,
  },
  disable = {
    desc = "Deactivate Checkmate",
    nargs = "0",
    handler = function()
      require("checkmate").disable()
    end,
  },
  toggle = {
    desc = "Toggle todo item under cursor or selection",
    nargs = "?",
    handler = function(data)
      local fargs = data.fargs
      require("checkmate").toggle(fargs and fargs[2] or nil)
    end,
    complete = function()
      return require("checkmate.config").get_todo_states()
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

  cycle_next = {
    desc = "Cycle todo state forward",
    nargs = "0",
    handler = function()
      require("checkmate").cycle()
    end,
  },

  cycle_previous = {
    desc = "Cycle todo state backward",
    nargs = "0",
    handler = function()
      require("checkmate").cycle({ backward = true })
    end,
  },

  create = {
    desc = "Create a new todo item",
    nargs = "?",
    handler = function(data)
      local fargs = data.fargs
      require("checkmate").create({ state = fargs and fargs[2] or nil })
    end,
    complete = function()
      return require("checkmate.config").get_todo_states()
    end,
  },

  create_child = {
    desc = "Create a new todo item nested under current line",
    nargs = "?",
    handler = function(data)
      local fargs = data.fargs
      require("checkmate").create_child({ state = fargs and fargs[2] or nil })
    end,
    complete = function()
      return require("checkmate.config").get_todo_states()
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
      jump_next = {
        desc = "Move cursor to next metadata tag for todo under the cursor",
        nargs = "0",
        handler = function()
          require("checkmate").jump_next_metadata()
        end,
      },
      jump_previous = {
        desc = "Move cursor to previous metadata tag for todo under the cursor",
        nargs = "0",
        handler = function()
          require("checkmate").jump_previous_metadata()
        end,
      },
    },
  },

  debug = {
    desc = "Debug helpers",
    subcommands = {
      menu = {
        desc = "Open debug menu (requires 'nvzone/menu')",
        nargs = "0",
        handler = function()
          require("checkmate.debug.debug_menu").open()
        end,
      },
      log = {
        desc = "Open debug log",
        nargs = "0",
        handler = function()
          require("checkmate").debug.log()
        end,
      },
      clear_log = {
        desc = "Clear debug log",
        nargs = "0",
        handler = function()
          require("checkmate").debug.clear_log()
        end,
      },
      here = {
        desc = "Inspect todo at cursor",
        nargs = "0",
        handler = function()
          require("checkmate").debug.at_cursor()
        end,
      },
      print_map = {
        desc = "Print todo map",
        nargs = "0",
        handler = function()
          require("checkmate").debug.print_todo_map()
        end,
      },
      print_config = {
        desc = "Print config",
        nargs = "0",
        handler = function()
          require("checkmate").debug.print_config()
        end,
      },
      hl = {
        desc = "Highlight subcommands",
        subcommands = {
          todo = {
            desc = "Add a temporary highlight to various Todo ranges",
            nargs = "+", -- kind [persistent|timeout]
            handler = function(opts)
              local kind = opts.fargs[2]
              local parser = require("checkmate.parser")
              local row, col = unpack(vim.api.nvim_win_get_cursor(0))
              local todo = parser.get_todo_item_at_position(0, row - 1, col)
              if not todo then
                return
              end

              -- this arg can be a boolean string or parsed to a numeric timeout in ms
              local arg3 = opts.fargs[3]
              local persistent, timeout
              if arg3 == "true" or arg3 == "false" then
                persistent = (arg3 == "true")
              elseif tonumber(arg3) then
                timeout = tonumber(arg3)
                persistent = false
              else
                persistent = false
              end

              if not persistent and not timeout then
                timeout = 10000 -- default timeout
              end

              if kind == "metadata" then
                for _, entry in ipairs(todo.metadata.entries) do
                  require("checkmate").debug.highlight(entry.range, {
                    timeout = timeout,
                    persistent = persistent,
                  })
                end
              else
                local range = ({
                  fir = todo.first_inline_range,
                  inline = todo.first_inline_range,
                  ts = todo.ts_range,
                  semantic = todo.range,
                })[kind] or todo.range

                require("checkmate").debug.highlight(range, {
                  timeout = timeout,
                  persistent = persistent,
                })
              end
            end,
            complete = { "fir", "inline", "ts", "semantic", "metadata" },
          },

          clear = {
            desc = "Clear a debug highlight under the cursor",
            nargs = "0",
            handler = function()
              require("checkmate").debug.clear_highlight()
            end,
          },

          clear_all = {
            desc = "Clear all debug highlights",
            nargs = "0",
            handler = function()
              require("checkmate").debug.clear_all_highlights()
              vim.notify("Checkmate: cleared all debug highlights", vim.log.levels.INFO)
            end,
          },

          list = {
            desc = "List active debug highlights",
            nargs = "0",
            handler = function()
              local items = require("checkmate").debug.list_highlights()
              for _, h in ipairs(items) do
                print(string.format("buf=%d  id=%d", h.bufnr, h.id))
              end
            end,
          },
        },
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

function Commands.dispatch(opts)
  local args = opts.fargs
  local entry = { subcommands = top_commands }
  local depth = 0

  while entry.subcommands do
    depth = depth + 1
    local name = args[depth]
    if not name or not entry.subcommands[name] then
      local path = table.concat(vim.list_slice(args, 1, depth - 1), " ")
      vim.notify(
        ("Usage: Checkmate %s <%s>"):format(path, table.concat(vim.tbl_keys(entry.subcommands), "|")),
        vim.log.levels.INFO
      )
      log.fmt_warn("[commands] `%s %s` is not a valid Checkmate command", opts.name, opts.args)
      return
    end
    entry = entry.subcommands[name]
  end

  -- entry has no more subcommands ⇒ call its handler
  local handler_args = vim.list_slice(args, depth)
  return entry.handler({ fargs = handler_args, bang = opts.bang, line = opts.line })
end

local function complete_fn(arglead, cmdline, cursorpos)
  local parts = vim.split(cmdline, "%s+")
  table.remove(parts, 1) -- drop "Checkmate"

  local entry = { subcommands = top_commands }
  for i, part in ipairs(parts) do
    if i == #parts then
      -- at the slot we’re completing
      if entry.subcommands then
        -- suggest subcommand names
        return vim.tbl_filter(function(k)
          return vim.startswith(k, arglead)
        end, vim.tbl_keys(entry.subcommands))
      elseif entry.complete then
        -- suggest via `.complete`
        local c = entry.complete
        local candidates = type(c) == "function" and c(arglead, cmdline, cursorpos) or c
        ---@cast candidates table
        return vim.tbl_filter(function(k)
          return vim.startswith(k, arglead)
        end, candidates or {})
      end
      return {}
    end

    if entry.subcommands and entry.subcommands[part] then
      entry = entry.subcommands[part]
    else
      return {}
    end
  end

  return {}
end

-- called from init.lua when setting up a buffer
function Commands.setup(bufnr)
  vim.api.nvim_buf_create_user_command(bufnr, "Checkmate", function(opts)
    Commands.dispatch(opts)
  end, {
    nargs = "*",
    complete = complete_fn,
    desc = "Checkmate: main command",
  })
end

function Commands.dispose(bufnr)
  pcall(vim.api.nvim_buf_del_user_command, bufnr, "Checkmate")
end

return Commands
