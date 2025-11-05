---@class checkmate.picker.TelescopeAdapter : checkmate.picker.Adapter
local M = {}

---@param ctx checkmate.picker.AdapterContext
function M.select(ctx)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local state = require("telescope.actions.state")

  local entries = {}
  for i = 1, #ctx.items do
    local it = ctx.items[i]
    entries[i] = { display = ctx.format_item(it), ordinal = it.text, value = it }
  end

  local opts = ctx.backend_opts or {}
  pickers
    .new(opts, {
      prompt_title = ctx.prompt or "Select",
      finder = finders.new_table({
        results = entries,
        entry_maker = function(e)
          return e
        end,
      }),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(_, map)
        local accept = function(bufnr)
          local entry = state.get_selected_entry()
          actions.close(bufnr)
          if entry and ctx.on_accept then
            ctx.on_accept(entry.value)
          end
        end
        map("i", "<CR>", accept)
        map("n", "<CR>", accept)
        return true
      end,
    })
    :find()
end

return M
