-- main module entry point
-- should handle configuration/setup, define the public API

---@class Checkmate
local M = {}

---Configure formatters to play nicely with .todo files (which should be parsed as markdown)
local function setup_formatters()
  -- Setup formatters (currently only for conform.nvim) to use prettier's 'markdown' parser
  -- for the .todo extension
  local has_conform, conform = pcall(require, "conform")
  if has_conform then
    conform.formatters_by_ft.markdown = { "todo_prettier" }

    conform.formatters.todo_prettier = {
      command = "prettier",
      args = function(self, ctx)
        return { "--parser", "markdown" }
      end,
      stdin = true,
      condition = function(self, ctx)
        -- Only apply to files ending in `.todo`
        return ctx.filename and ctx.filename:match("%.todo$")
      end,
    }
  end
end

---@param opts checkmate.Config?
M.setup = function(opts)
  local config = require("checkmate.config")
  config.setup(opts)

  -- Initialize the logger
  local log = require("checkmate.log")
  log.setup()

  log.debug(config.options)

  -- Now setup parser after config is fully initialized
  if config.is_running() then
    require("checkmate.parser").setup()
    log.debug("Parser initialized", { module = "setup" })
  end

  setup_formatters()
end

-- PUBLIC API --

--- Toggle todo item state at cursor or in visual selection
---@param target_state? checkmate.TodoItemState Optional target state ("checked" or "unchecked")
M.toggle = function(target_state)
  local is_visual = require("checkmate.util").is_visual_mode()

  local api = require("checkmate.api")
  if is_visual then
    api.toggle_todo_visual(target_state)
  else
    api.toggle_todo_at_cursor(target_state)
  end
end

---Toggle todo item state
---@param todo_item any
M.toggle_todo = function(todo_item, target_state)
  local api = require("checkmate.api")
  local bufnr = vim.api.nvim_get_current_buf()
  api.handle_toggle(bufnr, nil, nil, { existing_todo_item = todo_item, target_state = target_state })
end

--- Set todo item to checked state
M.check = function()
  M.toggle("checked")
end

--- Set todo item to unchecked state
M.uncheck = function()
  M.toggle("unchecked")
end

--- Create a new todo item
M.create = function()
  require("checkmate.api").create_todo()
end

--- Insert a metadata tag into a todo item at the cursor
M.add_metadata = function(metadata_name, value)
  local config = require("checkmate.config")
  local util = require("checkmate.util")
  local api = require("checkmate.api")
  local meta_config = config.options.metadata[metadata_name]

  if not meta_config then
    util.notify("Unknown metadata tag: " .. metadata_name, vim.log.levels.WARN)
    return
  end

  api.apply_metadata(metadata_name, value)
end

--- Remove a metadata tag from a todo item at the cursor
M.remove_metadata = function(metadata_name)
  require("checkmate.api").remove_metadata(metadata_name)
end

--- Toggle a metadata tag on/off at the cursor
M.toggle_metadata = function(meta_name, custom_value)
  return require("checkmate.api").toggle_metadata(meta_name, custom_value)
end

--- Open debug log
M.debug_log = function()
  require("checkmate.log").open()
end

--- Clear debug log
M.debug_clear = function()
  require("checkmate.log").clear()
end

--- Inspect todo item at cursor
M.debug_at_cursor = function()
  local log = require("checkmate.log")
  local parser = require("checkmate.parser")
  local config = require("checkmate.config")
  local util = require("checkmate.util")

  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1 -- normalize

  local extmark_id = 9001 -- Arbitrary unique ID for debug highlight

  -- Clear the previous debug highlight (just that one)
  pcall(vim.api.nvim_buf_del_extmark, bufnr, config.ns, extmark_id)

  local item = parser.get_todo_item_at_position(bufnr, row, col, {
    search = { main_content = true },
  })

  if not item then
    util.notify("No todo item found at cursor", vim.log.levels.INFO)
    return
  end

  local msg = {
    ("Debug called at (0-index): %s:%s"):format(row, col),
    "Todo item at cursor:",
    ("  State: %s"):format(item.state),
    ("  Todo marker: %s"):format(item.todo_marker.text),
    ("  Range: [%d,%d] → [%d,%d]"):format(
      item.range.start.row,
      item.range.start.col,
      item.range["end"].row,
      item.range["end"].col
    ),
    ("Metadata: %s"):format(vim.inspect(item.metadata)),
  }

  -- Use native vim.notify here as we want to show this regardless of config.options.notify
  vim.notify(table.concat(msg, "\n"), vim.log.levels.DEBUG)

  -- Add debug highlight
  vim.api.nvim_set_hl(0, "CheckmateDebugHighlight", { bg = "#3b3b3b" })

  vim.api.nvim_buf_set_extmark(bufnr, config.ns, item.range.start.row, item.range.start.col, {
    id = extmark_id,
    end_row = item.range["end"].row,
    end_col = item.range["end"].col,
    hl_group = "CheckmateDebugHighlight",
    priority = 9999, -- Ensure it draws on top
  })

  -- Auto-remove highlight after 3 seconds
  vim.defer_fn(function()
    pcall(vim.api.nvim_buf_del_extmark, bufnr, config.ns, extmark_id)
  end, 3000)
end

--- Print todo map
M.debug_print_todo_map = function()
  local parser = require("checkmate.parser")
  local todo_map = parser.discover_todos(vim.api.nvim_get_current_buf())
  local sorted_list = require("checkmate.util").get_sorted_todo_list(todo_map)
  vim.notify(vim.inspect(sorted_list), vim.log.levels.DEBUG)
end

return M
