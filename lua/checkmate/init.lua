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

  -- Initialize linter if enabled
  if true then
    require("checkmate.linter").setup({ enabled = true, auto_fix = false })
    log.debug("Linter initialized", { module = "setup" })
  end

  setup_formatters()
end

-- PUBLIC API --

---Toggle todo item state at cursor or in visual selection
---
---To set a specific todo item to a target state, use `set_todo_item`
---@param target_state? checkmate.TodoItemState Optional target state ("checked" or "unchecked")
function M.toggle(target_state)
  local api = require("checkmate.api")
  local is_visual = require("checkmate.util").is_visual_mode()

  return api.apply_todo_operation({
    operation = api.toggle_todo_item,
    is_visual = is_visual,
    action_name = "toggle",
    params = { target_state = target_state },
  })
end

---Sets a given todo item to a specific state
---@param todo_item checkmate.TodoItem
---@param target_state checkmate.TodoItemState
function M.set_todo_item(todo_item, target_state)
  local api = require("checkmate.api")
  return api.toggle_todo_item(todo_item, { target_state = target_state })
end

--- Set todo item to checked state
function M.check()
  M.toggle("checked")
end

--- Set todo item to unchecked state
function M.uncheck()
  M.toggle("unchecked")
end

--- Create a new todo item
function M.create()
  require("checkmate.api").create_todo()
end

--- Insert a metadata tag into a todo item at the cursor or per todo in the visual selection
---@param metadata_name string Name of the metadata tag (defined in the config)
---@param value string Value contained in the tag
function M.add_metadata(metadata_name, value)
  local config = require("checkmate.config")
  local util = require("checkmate.util")
  local api = require("checkmate.api")
  local meta_config = config.options.metadata[metadata_name]

  if not meta_config then
    util.notify("Unknown metadata tag: " .. metadata_name, vim.log.levels.WARN)
    return
  end

  local is_visual = util.is_visual_mode()

  api.apply_todo_operation({
    operation = api.apply_metadata,
    is_visual = is_visual,
    action_name = "add metadata",
    params = { meta_name = metadata_name, custom_value = value },
  })
end

--- Remove a metadata tag from a todo item at the cursor or per todo in the visual selection
---@param metadata_name string Name of the metadata tag (defined in the config)
function M.remove_metadata(metadata_name)
  local is_visual = require("checkmate.util").is_visual_mode()
  local api = require("checkmate.api")

  api.apply_todo_operation({
    operation = api.remove_metadata,
    is_visual = is_visual,
    action_name = "remove metadata",
    params = { meta_name = metadata_name },
  })
end

function M.remove_all_metadata()
  local is_visual = require("checkmate.util").is_visual_mode()
  local api = require("checkmate.api")

  api.apply_todo_operation({
    operation = api.remove_all_metadata,
    is_visual = is_visual,
    action_name = "remove all metadata",
  })
end

--- Toggle a metadata tag on/off at the cursor or for each todo in the visual selection
---@param meta_name string Name of the metadata tag (defined in the config)
---@param custom_value string Value contained in tag
function M.toggle_metadata(meta_name, custom_value)
  local is_visual = require("checkmate.util").is_visual_mode()
  local api = require("checkmate.api")

  return api.apply_todo_operation({
    operation = api.toggle_metadata,
    is_visual = is_visual,
    action_name = "toggle metadata",
    params = { meta_name = meta_name, custom_value = custom_value },
  })
end

--- Open debug log
function M.debug_log()
  require("checkmate.log").open()
end

--- Clear debug log
function M.debug_clear()
  require("checkmate.log").clear()
end

--- Inspect todo item at cursor
function M.debug_at_cursor()
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
    ("  List marker: [%s]"):format(util.get_ts_node_range_string(item.list_marker.node)),
    ("  Todo marker: [%d,%d] → %s"):format(
      item.todo_marker.position.row,
      item.todo_marker.position.col,
      item.todo_marker.text
    ),
    ("  Range: [%d,%d] → [%d,%d]"):format(
      item.range.start.row,
      item.range.start.col,
      item.range["end"].row,
      item.range["end"].col
    ),
    ("  Metadata: %s"):format(vim.inspect(item.metadata)),
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
function M.debug_print_todo_map()
  local parser = require("checkmate.parser")
  local todo_map = parser.discover_todos(vim.api.nvim_get_current_buf())
  local sorted_list = require("checkmate.util").get_sorted_todo_list(todo_map)
  vim.notify(vim.inspect(sorted_list), vim.log.levels.DEBUG)
end

return M
