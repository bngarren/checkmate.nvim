local M = {}

local config = require("checkmate.config")
local meta_module = require("checkmate.metadata")
local util = require("checkmate.util")
local fmt = require("luasnip.extras.fmt").fmt

---Base options passed to the checkmate.snippets API functions
---@class checkmate.SnippetOpts
---@field trigger string the trigger of the snippet
---@field desc? string Description for the snippet
---@field ls_context? table LuaSnip snippet context (e.g. priority, hidden, snippetType, wordTrig, etc.)
---@field ls_opts? table LuaSnip 'opts'

---@class checkmate.TodoSnippetOpts : checkmate.SnippetOpts
---@field text? string Default string to add (before any metadata)
---@field metadata? table<string, MetadataSnippetType> Metadata to include

---@class checkmate.MetadataSnippetOpts : checkmate.SnippetOpts
---@field tag string Metadata tag name
---@field value? string Metadata value to insert. If nil, will use the metadata's `get_value` function
---@field auto_select? boolean Selects the metadata's value on insert. Otherwise, moves cursor to the end. Default: false.

---@alias MetadataSnippetType
---| boolean Place a text node with the metadata's get_value()
---| string Place a text node with this string as the node text
---| number Place an insert node at this position
---| function(captures: any): string Place a text node based on the return of this function

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

---@param opts {indent?: integer, list_marker?: string}
local function make_todo_string(opts)
  opts = opts or {}
  local list_marker = opts.list_marker or config.options.default_list_marker
  local unchecked = config.options.todo_markers.unchecked
  local indent = string.rep(" ", opts.indent or 0)
  return indent .. list_marker .. " " .. unchecked .. " "
end

local function make_error_snippet(trigger, msg)
  return ls.s(trigger, {
    ls.t("ERROR: " .. msg),
  })
end

-------- PUBLIC API ---------

---Create a `checkmate.nvim` todo snippet
---
---# Basic usage
---```lua
---local cms = require("checkmate.snippets")
---require("luasnip").add_snippets("markdown", {
---  cms.todo({
---    trigger = ".bug",
---    text = "New BUG",
---    metadata = {
---      bug = true, -- use the metadata's `get_value`
---      priority = true,
---    },
---    ls_context = {
---      snippetType = "autosnippet",
---    },
---  })
---})
---```
--- - `opts.desc` can also be used to set the default text as well as the snippet description
---
---# Advanced usage
---```lua
---local cms = require("checkmate.snippets")
---require("luasnip").add_snippets("markdown", {
---  cms.todo({
---    trigger = "%.i(%d+)",
---    desc = "New ISSUE",
---    metadata = {
---      issue = function(captures)
---        local issue_num = captures[1] or ""
---        return "#" .. issue_num
---      end
---    },
---    ls_context = {
---      snippetType = "snippet",
---      regTrig = true -- important! (parse trigger as pattern)
---    },
---  })
---})
---```
---
---@param opts checkmate.TodoSnippetOpts
---@return LuaSnip.Addable? snippet LuaSnip snippet
function M.todo(opts)
  if not has_luasnip() then
    return
  end
  local parser = require("checkmate.parser")
  local ph = require("checkmate.parser.helpers")

  opts = opts or {}
  local trigger = opts.trigger
  local text = opts.text
  local usr_ls_ctx = opts.ls_context or {}
  local usr_ls_opts = opts.ls_opts or {}

  local context = vim.tbl_extend("force", {
    trig = trigger,
    wordTrig = true,
    priority = 1000,
  }, usr_ls_ctx)
  if opts.desc and not (context.desc or context.dscr) then
    context.desc = opts.desc
  end

  -- todo-prefix (indent + list-marker + todo-marker)
  local todo_prefix = ls.f(function()
    local bufnr = vim.api.nvim_get_current_buf()
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]

    if parser.is_todo_item(line) or ph.match_markdown_checkbox(line) then
      return ""
    end

    -- we auto-indent at least up to the previous todo line's indentation, if exists
    local indent = 0
    local prev = math.max(row - 1, 0)
    local prev_item = parser.get_todo_item_at_position(bufnr, prev, 0)
    if prev_item then
      indent = math.max(0, prev_item.range.start.col - col)
    end

    local list_item = require("checkmate.parser.helpers").match_list_item(line)
    local node_opts = { indent = indent }
    if list_item and list_item.marker then
      node_opts.with_list_marker = false
    end

    return make_todo_string(node_opts)
  end, {})

  -- the value to insert
  local default_value_node = ls.c(1, {
    ls.i(nil, text or opts.desc or ""),
    ls.i(nil, ""),
  })

  local meta_blob = ""
  if not util.tbl_isempty_or_nil(opts.metadata) then
    local sorted = {}
    for tag, value in pairs(opts.metadata) do
      table.insert(sorted, { name = tag, props = meta_module.get_meta_props(tag), snip_type = value })
    end
    -- sort by increasing sort_order
    table.sort(sorted, function(a, b)
      return a.props.sort_order < b.props.sort_order
    end)

    meta_blob = ls.f(function(_, snip)
      local parts = {}
      for _, m in ipairs(sorted) do
        ---@type checkmate.MetadataProps
        local meta = m.props
        local tag = m.name
        local value = m.snip_type
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
  end

  return ls.s(
    context,
    fmt([[{}{}{}]], {
      todo_prefix,
      default_value_node,
      meta_blob,
    }, {
      dedent = true,
    }),
    usr_ls_opts
  )
end

---Create a snippet that adds metadata `@tag(value)` to existing `checkmate.nvim` todo
---
---It will attempt to use the metadata's `get_value` function, if defined in the config opts
---
---# Example
---```lua
---local cms = require("checkmate.snippets")
---require("luasnip").add_snippets("markdown", {
---  cms.add_metadata({ trigger = "@s", tag = "started", desc = "@started" })
---})
---```
---
---@param opts checkmate.MetadataSnippetOpts
---@return LuaSnip.Addable? snippet LuaSnip snippet
function M.metadata(opts)
  if not has_luasnip() then
    return
  end

  opts = opts or {}
  local meta_name = opts.tag
  local meta_value = opts.value
  local trigger = opts.trigger
  local auto_select = opts.auto_select == true -- default false
  local usr_ls_ctx = opts.ls_context or {}
  local usr_ls_opts = opts.ls_opts or {}

  if not meta_name then
    return make_error_snippet(trigger, string.format("missing tag name"))
  end

  local meta_props = meta_module.get_meta_props(meta_name)

  local context = vim.tbl_extend("force", {
    trig = trigger,
    priority = 1000,
  }, usr_ls_ctx)

  if opts.desc and not (context.desc or context.dscr) then
    context.desc = opts.desc
  end

  local default_value = ""
  if meta_value ~= nil then
    default_value = tostring(meta_value)
  elseif meta_props and meta_props.get_value then
    local success, value = pcall(meta_props.get_value)
    if success then
      default_value = tostring(value or "")
    end
  end

  local nodes = {
    ls.t("@" .. meta_name .. "("),
    ls.c(1, {
      auto_select and ls.i(nil, default_value) or ls.sn(nil, {
        ls.t(default_value),
        ls.i(nil, ""),
      }),
      ls.i(nil, ""),
    }),
    ls.t(")"),
  }

  local snippet = ls.s(context, nodes, usr_ls_opts)

  return snippet
end

return M
