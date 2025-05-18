--[[
-- Two critical CommonMark list
indentation rules (spec 0.31.2 §6):

1. **Indentation <= 3 spaces** – A child's marker may appear up to
   three spaces further to the right of its parent's *content* column.
2. **Nested items >= parent content column** – A child's marker must start
   at or to the right of its parent's content column.

It also warns when ordered & unordered markers are mixed at the same indent.
The algorithm is an *O(lines)* single pass with a tiny stack — perfect for
real‑time linting of large Markdown buffers.
--]]

local M = {}
local cfg = {} ---@type table<string,any>

-- Internal-only type that extends the user-facing config
---@class checkmate.InternalLinterConfig : checkmate.LinterConfig
---@field namespace string? -- Which diagnostic namespace to use
---@field virtual_text vim.diagnostic.Opts.VirtualText -- Virtual text options
---@field underline vim.diagnostic.Opts.Underline -- Underline options

M.ns = vim.api.nvim_create_namespace("checkmate_lint")
M.ISSUES = {
  INCONSISTENT_MARKER = "Mixed ordered / unordered list markers at this indent level",
  INDENT_SHALLOW = "List marker indented too little for nesting",
  INDENT_DEEP = "List marker indented too far",
}

-- Default configuration
---@type checkmate.InternalLinterConfig
M._defaults = {
  enabled = true,
  virtual_text = { prefix = "▸" },
  underline = { severity = "WARN" },
  severity = {
    INCONSISTENT_MARKER = vim.diagnostic.severity.INFO,
    INDENT_SHALLOW = vim.diagnostic.severity.WARN,
    INDENT_DEEP = vim.diagnostic.severity.WARN,
  },
}

--- Helpers
------------------------------------------------------------

---Return the 0‑based column of the first non‑blank char after `idx`
---@param line string The line to examine
---@param idx integer The 0-based starting position
---@return integer The column of the first non-blank character
local function first_non_space(line, idx)
  local pos = line:find("[^ \t]", idx + 1)
  return pos and (pos - 1) or #line
end

local function push(tbl, v)
  tbl[#tbl + 1] = v
end

---Pop items from stack until we reach a parent whose marker column is less than `col`
---@param stack table The stack of parent list items
---@param col integer The marker column to compare against
---@return table|nil result The parent node, or nil if no suitable parent found
local function pop_parent(stack, col)
  while #stack > 0 and stack[#stack].marker_col >= col do
    stack[#stack] = nil
  end
  return stack[#stack]
end

--- Pattern compilation
------------------------------------------------------------

---Compile patterns for all types of list markers
---@return table<{regex:string,marker_type:string}>
local function compile_patterns()
  local parser = require("checkmate.parser")

  local markers = parser.list_item_markers
  local pats = {}

  -- Unordered list markers
  for _, m in ipairs(markers) do
    pats[#pats + 1] = {
      regex = string.format("^(%%s*)(%s)%%s+(.*)$", vim.pesc(m)),
      marker_type = "unordered",
    }
  end

  -- Ordered list markers ("1." / "1)")
  pats[#pats + 1] = {
    regex = "^(%s*)(%d+[.)])%s+(.*)$",
    marker_type = "ordered",
  }

  return pats
end

local PATTERNS = compile_patterns()

---Parse a line to determine if it's a list item and extract its structure
---@param line string Line to parse
---@return nil|{marker_col:integer,content_col:integer,marker_type:string}
local function parse_list_item(line)
  for _, pat in ipairs(PATTERNS) do
    local indent, marker = line:match(pat.regex)
    if indent then
      local mc = #indent -- marker column (0‑based)
      return {
        marker_col = mc,
        content_col = first_non_space(line, mc + #marker),
        marker_type = pat.marker_type,
      }
    end
  end
end

---Add a diagnostic to the diagnostics table
---@param bufnr integer Buffer number
---@param diags table Table of diagnostics
---@param key string The issue key from M.ISSUES
---@param row integer The 0-based row number
---@param col integer The 0-based column number
local function add_diag(bufnr, diags, key, row, col)
  table.insert(diags, {
    bufnr = bufnr,
    lnum = row,
    col = col,
    end_lnum = row,
    end_col = col + 1,
    severity = cfg.severity[key],
    message = M.ISSUES[key],
    source = "checkmate",
  })
end

--- Public API
------------------------------------------------------------

---Set up the linter with given options
---@param opts checkmate.LinterConfig? User configuration options
---@return checkmate.InternalLinterConfig config Merged configuration
function M.setup(opts)
  cfg = vim.tbl_deep_extend("force", vim.deepcopy(M._defaults), opts or {})

  if not cfg.enabled then
    M.disable()
    return cfg
  end

  vim.diagnostic.config({
    virtual_text = cfg.virtual_text,
    underline = cfg.underline,
    severity_sort = true,
  }, M.ns)

  M.config = cfg

  return cfg
end

---@param bufnr? integer
---@return table diagnostics
function M.lint_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not (cfg.enabled and vim.api.nvim_buf_is_valid(bufnr)) then
    return {}
  end

  local diags = {} ---@type vim.Diagnostic[]
  local stack = {} ---@type table<{marker_col:integer,content_col:integer}>
  local level_marker_type = {} ---@type table<integer,string>
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for i, line in ipairs(lines) do
    local row = i - 1 -- diagnostics are 0‑based
    local list_item_info = parse_list_item(line)

    if list_item_info then
      -- Marker‑type consistency among siblings
      local sibling_type = level_marker_type[list_item_info.marker_col]
      if sibling_type and sibling_type ~= list_item_info.marker_type then
        add_diag(bufnr, diags, "INCONSISTENT_MARKER", row, list_item_info.marker_col)
      else
        level_marker_type[list_item_info.marker_col] = list_item_info.marker_type
      end

      -- Parent/child indentation rules
      local parent = pop_parent(stack, list_item_info.marker_col)
      if parent then
        if list_item_info.marker_col < parent.content_col then
          add_diag(bufnr, diags, "INDENT_SHALLOW", row, list_item_info.marker_col)
        elseif list_item_info.marker_col > parent.content_col + 3 then
          add_diag(bufnr, diags, "INDENT_DEEP", row, list_item_info.marker_col)
        end
      end

      push(stack, list_item_info)
    end
  end

  vim.diagnostic.set(M.ns, bufnr, diags)
  return diags
end

-- Disable linting
---@param bufnr integer? Buffer number, if nil disables for all buffers
function M.disable(bufnr)
  if bufnr then
    vim.diagnostic.reset(M.ns, bufnr)
  else
    vim.diagnostic.reset(M.ns)
  end
end

return M
