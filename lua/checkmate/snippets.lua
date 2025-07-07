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

  local parser = require("checkmate.parser")
  local ph = require("checkmate.parser.helpers")

  opts = opts or {}
  local ctx = opts.ls_context or {}
  local snip_opts = opts.ls_opts or {}

  local context = vim.tbl_extend("force", {
    trig = trigger,
    wordTrig = true,
    priority = 1000,
  }, ctx)
  if opts.desc and not (context.desc or context.dscr) then
    context.desc = opts.desc
  end

  -- 1) compute the todo-prefix (indent + list-marker + unchecked + prefix)
  local todo_prefix = ls.f(function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]

    if parser.is_todo_item(line) or ph.match_markdown_checkbox(line) then
      return ""
    end

    -- figure out indent
    local indent = 0
    local prev = math.max(row - 1, 0)
    local prev_item = parser.get_todo_item_at_position(bufnr, prev, 0)
    if prev_item then
      indent = math.max(0, prev_item.range.start.col - col)
    end

    -- detect existing list marker
    local list_item = require("checkmate.parser.helpers").match_list_item(line)
    local node_opts = { indent = indent }
    if list_item and list_item.marker then
      node_opts.with_list_marker = false
    end

    -- make_todo_node must return a plain string
    return make_todo_node(node_opts)
  end, {})

  -- 2) the description insert
  local desc_node = ls.i(1, opts.desc or "")

  -- 3) metadata blob as one function_node
  local meta_mod = require("checkmate.metadata")
  local meta_blob = ls.f(function(_, snip)
    local parts = {}
    for tag, value in pairs(opts.metadata or {}) do
      local meta = meta_mod.get_meta_props(tag)
      local val = ""
      if type(value) == "boolean" and value then
        val = meta and meta.get_value and meta.get_value() or ""
      elseif type(value) == "string" then
        val = value
      elseif type(value) == "number" then
        val = tostring(value)
      elseif type(value) == "function" then
        val = tostring(value(snip.captures) or "")
      end
      table.insert(parts, " @" .. tag .. "(" .. val .. ")")
    end
    return table.concat(parts)
  end, {})

  -- build snippet with fmt + dedent
  local fmt = require("luasnip.extras.fmt").fmt
  return ls.s(
    context,
    fmt([[{}{}{}]], {
      todo_prefix,
      desc_node,
      meta_blob,
    }, {
      dedent = true,
    }),
    snip_opts
  )
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
