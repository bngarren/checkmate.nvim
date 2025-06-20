local M = {}

local config = require("checkmate.config")
local meta_module = require("checkmate.metadata")

local shown_missing_luasnip_warning = false
local ls
local has_luasnip = function()
  if not ls then
    local ok, res = pcall(require, "luasnip")
    if not ok then
      if not shown_missing_luasnip_warning then
        vim.notify("Checkmate: LuaSnip plugin required for 'checkmate.snippets'")
      end
      return false
    end
    ls = res
    ---@cast ls LuaSnip
  end
  return true
end

---@param opts {indent?: integer, list_marker?: string, prefix?: string}
local function make_todo_node(opts)
  opts = opts or {}
  local list_marker = opts.list_marker or config.options.default_list_marker
  local unchecked = config.options.todo_markers.unchecked
  local indent = string.rep(" ", opts.indent or 0)
  local prefix = opts.prefix and (opts.prefix .. " ") or ""
  return indent .. list_marker .. " " .. unchecked .. prefix .. " "
end

---@alias MetadataSnippetType
---| boolean Place a text node with the metadata's get_value()
---| string Place a text node with this string as the node text
---| number Place an insert node at this position
---| function(captures: any): string Place a text node based on the return of this function

---@class checkmate.SnippetOpts
---@field desc? string Description for the snippet
---@field metadata? table<string, MetadataSnippetType> Metadata to include
---@field indent? boolean|integer Automatically indent based on context or indent to a specific number of spaces
---@field ls_context? table LuaSnip snippet context (e.g. priority, hidden, snippetType, wordTrig, etc.)
---@field ls_opts? table LuaSnip 'opts'

---Create a basic todo snippet
---@param trigger string The snippet trigger
---@param opts? checkmate.SnippetOpts
---@return table? LuaSnip snippet
function M.todo(trigger, opts)
  if not has_luasnip() then
    return
  end

  opts = opts or {}
  local ls_opts = opts.ls_context or {}

  local util = require("checkmate.util")
  local parser = require("checkmate.parser")

  local list_marker_patterns = util.build_empty_list_patterns()

  local nodes = {
    ls.f(function()
      local bufnr = vim.api.nvim_get_current_buf()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local cursor_row = cursor[1] - 1 -- 0-indexed
      local line = vim.api.nvim_buf_get_lines(bufnr, cursor_row, cursor_row + 1, false)[1]

      local on_todo_item = parser.get_todo_item_state(line) ~= nil
      if not on_todo_item then
        local indent
        if opts.indent then
          if type(opts.indent) == "number" then
            -- user specified number of spaces
            indent = opts.indent
          else
            -- auto detect from previous todo
            local prev_row = math.max(cursor_row - 1, 0)
            local prev_todo_item = parser.get_todo_item_at_position(bufnr, prev_row, 0)
            if prev_todo_item then
              indent = prev_todo_item.range.start.col
            end
          end
        end
        ---@cast indent integer?

        -- does the line already already have a list marker
        local list_marker = util.match_first(list_marker_patterns, line)

        if list_marker ~= nil then
          local todo_line = make_todo_node({ indent = indent, with_list_marker = false })
          return todo_line
        else
          return make_todo_node({ indent = indent })
        end
      else
        return ""
      end
    end, {}),
    ls.i(1, opts.desc or ""),
  }

  if opts.metadata then
    for tag, value in pairs(opts.metadata) do
      local meta = meta_module.get_meta_props(tag)

      table.insert(nodes, ls.t(" "))
      table.insert(nodes, ls.t("@" .. tag .. "("))

      if type(value) == "boolean" and value then
        table.insert(
          nodes,
          ls.f(function()
            return meta and meta.get_value and meta.get_value() or ""
          end, {})
        )
      elseif type(value) == "string" then
        -- a text node
        table.insert(nodes, ls.t(value))
      elseif type(value) == "number" then
        -- an insert node
        table.insert(nodes, ls.i(value, ""))
      elseif type(value) == "function" then
        -- a text node generated from a function
        table.insert(
          nodes,
          ls.f(function(_, snip)
            local captures = snip.captures or {}
            return tostring(value(captures) or "")
          end, {})
        )
      end

      table.insert(nodes, ls.t(")"))
    end
  end

  local context = vim.tbl_extend("force", { trig = trigger, wordTrig = true, priority = 1000 }, ls_opts)
  if opts.desc and not context.desc and not context.dscr then
    context.desc = opts.desc
  end

  return ls.s(context, nodes, opts.ls_opts)
end

---Create snippet that adds metadata to existing todo
---@param trigger string The snippet trigger
---@param meta_name string The metadata tag name
---@param opts? checkmate.SnippetOpts
---@return table? snippet LuaSnip snippet
function M.add_metadata(trigger, meta_name, opts)
  if not has_luasnip() then
    return
  end

  opts = opts or {}
  local ls_opts = opts.ls_context or { wordTrig = false }

  local meta_props = meta_module.get_meta_props(meta_name)
  if not meta_props then
    vim.notify("Unknown metadata tag: " .. meta_name, vim.log.levels.WARN)
    return
  end

  local nodes = {
    ls.t("@" .. meta_name .. "("),
    ls.c(1, {
      ls.f(function()
        return meta_props.get_value and meta_props.get_value() or ""
      end, {}),
      ls.i(nil, ""),
    }),
    ls.t(")"),
  }

  local context = vim.tbl_extend("force", { trig = trigger, priority = 1000 }, ls_opts)
  if opts.desc and not context.desc and not context.dscr then
    context.desc = opts.desc
  end

  local snippet = ls.s(context, nodes, opts.ls_opts)

  return snippet
end

return M
