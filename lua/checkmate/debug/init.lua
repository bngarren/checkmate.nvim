---------- DEBUGGING API ----------------

local debug_hl = require("checkmate.debug.debug_highlights")

local M = {
  ---Add a new highlight
  ---@param range checkmate.Range
  ---@param opts? {timeout?: integer, permanent?: boolean}
  ---@return integer id extmark id
  highlight = function(range, opts)
    return debug_hl.add(range, opts)
  end,
  clear_all_highlights = function()
    debug_hl.clear_all()
  end,
  list_highlights = function()
    return debug_hl.list()
  end,
  ---@param opts? {type?: "floating" | "split"}
  log = function(opts)
    opts = opts or {}
    require("checkmate.log").open({ scratch = opts.type or "floating" })
  end,
  clear_log = function()
    require("checkmate.log").clear()
  end,
}

-- Clears a debug highlight under the cursor
function M.clear_highlight()
  local config = require("checkmate.config")
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, config.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })
  for _, m in ipairs(marks) do
    local id, _, start_col, details = m[1], m[2], m[3], m[4]
    local end_col = details and details.end_col or start_col
    if col - 1 >= start_col and col - 1 < end_col then
      debug_hl.clear(bufnr, id)
      vim.notify("Cleared debug highlight " .. id, vim.log.levels.INFO)
      return
    end
  end
  vim.notify("No debug highlight under cursor", vim.log.levels.WARN)
end

--- Inspect todo item at cursor
function M.at_cursor()
  local parser = require("checkmate.parser")
  local util = require("checkmate.util")

  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1

  local item = parser.get_todo_item_at_position(bufnr, row, col)

  if not item then
    util.notify("No todo item found at cursor", vim.log.levels.INFO)
    return
  end

  local msg = {
    ("Debug called at (0-index): %s:%s"):format(row, col),
    "Todo item at cursor:",
    ("  ID: %s"):format(item.id),
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

  vim.notify(table.concat(msg, "\n"), vim.log.levels.DEBUG)

  M.highlight(item.range)
end

--- Print todo map (in Snacks scratch buffer or vim.print)
function M.print_todo_map()
  local parser = require("checkmate.parser")
  local todo_map = parser.discover_todos(vim.api.nvim_get_current_buf())
  local sorted_list = require("checkmate.util").get_sorted_todo_list(todo_map)
  require("checkmate.util").scratch_buf_or_print(sorted_list, { name = "checkmate.nvim todo_map" })
end

-- Print current config (in Snacks scratch buffer or vim.print)
function M.print_config()
  local config = require("checkmate.config")
  require("checkmate.util").scratch_buf_or_print(config.options, { name = "checkmate.nvim config" })
end

function M.print_buf_local_vars(bufnr)
  require("checkmate.util").scratch_buf_or_print(
    vim.fn.getbufvar(bufnr or 0, ""),
    { name = "checkmate.nvim buffer vars" }
  )
end

function M.insert_todos(bufnr, opts)
  local config = require("checkmate.config")
  local lines = {}
  for i = 1, opts.count ~= nil and opts.count or 2000 do
    lines[#lines + 1] = ("- %s Item %d %s %s"):format(
      config.get_defaults().todo_states.unchecked.marker,
      i,
      "@priority(high)",
      "@started(today)"
    )
  end
  vim.api.nvim_buf_call(bufnr, function()
    vim.api.nvim_put(lines, "l", true, false)
  end)
end

return M
