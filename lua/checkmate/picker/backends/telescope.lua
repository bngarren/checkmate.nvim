-- telescope
-- NOTE: tested with v0.1.8

---@class checkmate.picker.TelescopeAdapter : checkmate.picker.Adapter
local M = {}

local api = vim.api
local picker_util = require("checkmate.picker.util")
local proxy = picker_util.proxy
local make_choose = picker_util.make_choose

local ns = api.nvim_create_namespace("checkmate_picker_telescope_todo")

local function load_telescope()
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  if not ok_pickers then
    error("telescope.nvim not available")
  end

  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local themes = require("telescope.themes")
  local previewers = require("telescope.previewers")

  return {
    pickers = pickers,
    finders = finders,
    conf = conf,
    actions = actions,
    action_state = action_state,
    themes = themes,
    previewers = previewers,
  }
end

local function make_theme_opts(tel, base, backend_opts)
  backend_opts = backend_opts or {}
  base = base or {}

  if tel.themes and tel.themes.get_dropdown then
    return tel.themes.get_dropdown(vim.tbl_extend("force", base, backend_opts))
  end

  return vim.tbl_extend("force", base, backend_opts)
end

---@param ctx checkmate.picker.AdapterContext
function M.pick(ctx)
  local tel = load_telescope()

  local items = ctx.items or {}

  local proxies, resolve = proxy.build(items, {
    format_item = ctx.format_item,
  })

  local choose = make_choose(ctx, resolve, {
    schedule = true,
  })

  local theme_opts = make_theme_opts(tel, {
    prompt_title = ctx.prompt or "Select an item",
    previewer = false,
  }, ctx.backend_opts)

  tel.pickers
    .new(theme_opts, {
      finder = tel.finders.new_table({
        results = proxies,
        -- see https://github.com/nvim-telescope/telescope.nvim/blob/master/lua/telescope/make_entry.lua
        entry_maker = function(p)
          local text = p.text or ""
          return {
            value = p,
            display = text,
            ordinal = text,
          }
        end,
      }),
      sorter = tel.conf.generic_sorter(theme_opts) or tel.conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        tel.actions.select_default:replace(function()
          local entry = tel.action_state.get_selected_entry()
          tel.actions.close(prompt_bufnr)

          if entry and entry.value then
            choose(entry.value, { prompt_bufnr = prompt_bufnr, entry = entry })
          end
        end)

        return true
      end,
    })
    :find()
end

---@param ctx checkmate.picker.AdapterContext
function M.pick_todo(ctx)
  local tel = load_telescope()

  local items = ctx.items or {}

  -- Proxies carry jump/preview metadata for each todo
  local proxies, resolve = proxy.build(items, {
    format_item = ctx.format_item,
    decorate = function(p, item)
      ---@type checkmate.Todo|any
      local todo = item.value
      if type(todo) == "table" and todo.bufnr and type(todo.row) == "number" then
        -- we need these to be available to telescope's entry maker
        p.bufnr = todo.bufnr
        p.lnum = todo.row + 1
        p.col = 0
      end
    end,
  })

  ---@type checkmate.picker.after_select
  local function after_select(_, proxy_item)
    local bufnr = proxy_item and proxy_item.bufnr
    local lnum = proxy_item and proxy_item.lnum
    local col = (proxy_item and proxy_item.col) or 0

    if not (bufnr and lnum) then
      return
    end

    vim.schedule(function()
      if not api.nvim_buf_is_valid(bufnr) then
        return
      end
      if not api.nvim_buf_is_loaded(bufnr) then
        pcall(vim.fn.bufload, bufnr)
      end
      pcall(api.nvim_set_current_buf, bufnr)
      pcall(api.nvim_win_set_cursor, 0, { lnum, col })
    end)
  end

  local previewer = false
  if tel.previewers then
    previewer = tel.previewers.new_buffer_previewer({
      define_preview = function(self, entry, status)
        if not (self and self.state and self.state.bufnr) then
          return
        end

        local p = entry and entry.value
        local src_bufnr = p and p.bufnr
        local lnum = (p and p.lnum) or 1
        local col = (p and p.col) or 0

        if not (src_bufnr and api.nvim_buf_is_valid(src_bufnr)) then
          return
        end

        local preview_bufnr = self.state.bufnr
        if not (preview_bufnr and api.nvim_buf_is_valid(preview_bufnr)) then
          return
        end

        local lines = api.nvim_buf_get_lines(src_bufnr, 0, -1, false)
        api.nvim_buf_set_lines(preview_bufnr, 0, -1, false, lines)

        -- mirror filetype from source buffer
        local ok_ft, ft = pcall(api.nvim_get_option_value, "filetype", { buf = src_bufnr })
        if ok_ft and ft and ft ~= "" then
          pcall(api.nvim_set_option_value, "filetype", ft, { buf = preview_bufnr })
        end

        api.nvim_buf_clear_namespace(preview_bufnr, ns, 0, -1)

        local hl_line = math.max(lnum - 1, 0)
        api.nvim_buf_set_extmark(preview_bufnr, ns, hl_line, col, {
          end_row = hl_line + 1,
          hl_group = "TelescopeSelection",
          hl_eol = true,
        })

        local winid = self.state.winid
        if not (winid and api.nvim_win_is_valid(winid)) then
          return
        end

        vim.schedule(function()
          if not (api.nvim_win_is_valid(winid) and api.nvim_buf_is_valid(preview_bufnr)) then
            return
          end

          api.nvim_win_call(winid, function()
            -- set cursor to lnum in the preview buffer's window
            pcall(api.nvim_win_set_cursor, winid, { lnum, col })
            ---@diagnostic disable-next-line: param-type-mismatch
            pcall(vim.cmd, "normal! zz")
          end)
        end)
      end,
    })
  end

  local choose = make_choose(ctx, resolve, {
    schedule = true,
    after_select = after_select,
  })

  local theme_opts = make_theme_opts(tel, {
    prompt_title = ctx.prompt or "Todos",
    previewer = previewer,
  }, ctx.backend_opts)

  tel.pickers
    .new(theme_opts, {
      finder = tel.finders.new_table({
        results = proxies,
        -- see https://github.com/nvim-telescope/telescope.nvim/blob/master/lua/telescope/make_entry.lua
        entry_maker = function(p)
          local text = p.text or ""
          return {
            value = p,
            display = text,
            ordinal = text,
          }
        end,
      }),
      sorter = tel.conf.generic_sorter(theme_opts) or tel.conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        tel.actions.select_default:replace(function()
          local entry = tel.action_state.get_selected_entry()
          tel.actions.close(prompt_bufnr)

          if entry and entry.value then
            choose(entry.value, { prompt_bufnr = prompt_bufnr, entry = entry })
          end
        end)

        return true
      end,
    })
    :find()
end

return M
