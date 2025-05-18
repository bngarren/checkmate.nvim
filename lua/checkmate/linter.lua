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

-- Define linter rules
M.RULES = {
  INCONSISTENT_MARKER = {
    id = "INCONSISTENT_MARKER",
    message = "Mixed ordered / unordered list markers at this indent level",
    severity = vim.diagnostic.severity.INFO,
  },
  INDENT_SHALLOW = {
    id = "INDENT_SHALLOW",
    message = "List marker indented too little for nesting",
    severity = vim.diagnostic.severity.WARN,
  },
  INDENT_DEEP = {
    id = "INDENT_DEEP",
    message = "List marker indented too far",
    severity = vim.diagnostic.severity.WARN,
  },
}

-- Default configuration
---@type checkmate.InternalLinterConfig
M._defaults = {
  enabled = true,
  virtual_text = { prefix = "▸" },
  underline = { severity = "WARN" },
  severity = {}, -- will be initialized from M.RULES
  verbose = false,
}

-- Initialize default severities from rules
for id, rule in pairs(M.RULES) do
  M._defaults.severity[id] = rule.severity
end

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

-- Diagnostic handling
------------------------------------------------------------

---Add a diagnostic to the diagnostics table
---@param bufnr integer Buffer number
---@param diags table Table of diagnostics
---@param rule_id string The rule ID from M.RULES
---@param row integer The 0-based row number
---@param col integer The 0-based column number
---@param extra_info? string Optional context to append to message
local function add_diag(bufnr, diags, rule_id, row, col, extra_info)
  local rule = M.RULES[rule_id]
  if not rule then
    return
  end

  local message = rule.message
  if extra_info and M.config.verbose then
    message = message .. " " .. extra_info
  end

  table.insert(diags, {
    bufnr = bufnr,
    lnum = row,
    col = col,
    end_lnum = row,
    end_col = col + 1,
    severity = cfg.severity[rule_id],
    message = message,
    source = "checkmate",
    code = rule_id,
  })
end

-- Rule validator implementation
------------------------------------------------------------

---@class LintContext
---@field bufnr integer Buffer being linted
---@field diags table Diagnostics collection
---@field list_item table Current list item
---@field row integer Current row (0-indexed)
---@field marker_types table Map of marker columns to marker types
---@field parent table|nil Parent list item (if any)

---@class LinterRuleValidator
---@field validate fun(ctx:LintContext):boolean
local Validator = {}

---Create validator for checking inconsistent markers
---@return LinterRuleValidator
function Validator.inconsistent_marker()
  return {
    validate = function(ctx)
      local sibling_type = ctx.marker_types[ctx.list_item.marker_col]
      if sibling_type and sibling_type ~= ctx.list_item.marker_type then
        add_diag(ctx.bufnr, ctx.diags, "INCONSISTENT_MARKER", ctx.row, ctx.list_item.marker_col)
        return true
      else
        ctx.marker_types[ctx.list_item.marker_col] = ctx.list_item.marker_type
        return false
      end
    end,
  }
end

---Create validator for checking shallow indentation
---@return LinterRuleValidator
function Validator.indent_shallow()
  return {
    validate = function(ctx)
      if ctx.parent and ctx.list_item.marker_col < ctx.parent.content_col then
        local extra_info = string.format("(should be at column %d or greater)", ctx.parent.content_col)
        add_diag(ctx.bufnr, ctx.diags, "INDENT_SHALLOW", ctx.row, ctx.list_item.marker_col, extra_info)
        return true
      end
      return false
    end,
  }
end

---Create validator for checking excessive indentation
---@return LinterRuleValidator
function Validator.indent_deep()
  return {
    validate = function(ctx)
      if ctx.parent and ctx.list_item.marker_col > ctx.parent.content_col + 3 then
        local extra_info = string.format("(maximum allowed is column %d)", ctx.parent.content_col + 3)
        add_diag(ctx.bufnr, ctx.diags, "INDENT_DEEP", ctx.row, ctx.list_item.marker_col, extra_info)
        return true
      end
      return false
    end,
  }
end

-- The list of validators to run
local validators = {
  Validator.inconsistent_marker(),
  Validator.indent_shallow(),
  Validator.indent_deep(),
}

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

---Lint a buffer against CommonMark list formatting rules
---@param bufnr? integer Buffer number (defaults to current buffer)
---@return table diagnostics Table of diagnostic issues
function M.lint_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not (cfg.enabled and vim.api.nvim_buf_is_valid(bufnr)) then
    return {}
  end

  local diags = {} ---@type vim.Diagnostic[]
  local stack = {} ---@type table<{marker_col:integer,content_col:integer}>
  local marker_types = {} ---@type table<integer,string>
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for i, line in ipairs(lines) do
    local row = i - 1 -- diagnostics are 0‑based
    local list_item = parse_list_item(line)

    if list_item then
      -- Get parent (if any) for nested list item checks
      local parent = pop_parent(stack, list_item.marker_col)

      -- Create a context for validation
      local ctx = {
        bufnr = bufnr,
        diags = diags,
        list_item = list_item,
        row = row,
        marker_types = marker_types,
        parent = parent,
      }

      -- Run all validators
      for _, validator in ipairs(validators) do
        validator.validate(ctx)
      end

      -- Add this item to the stack for future children
      push(stack, list_item)
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

---Register a new validator
---@param factory function Factory function that creates a validator
---@return integer Index of the new validator
function M.register_validator(factory)
  local validator = factory()
  table.insert(validators, validator)
  return #validators
end

---Register a new rule definition
---@param id string Rule identifier
---@param rule {message:string, severity:integer} Rule definition
function M.register_rule(id, rule)
  if M.RULES[id] then
    error("Rule ID '" .. id .. "' already exists")
  end

  M.RULES[id] = {
    id = id,
    message = rule.message,
    severity = rule.severity or vim.diagnostic.severity.WARN,
  }

  -- Set default severity
  if not cfg.severity then
    cfg.severity = {}
  end
  cfg.severity[id] = rule.severity
end

-- For testing - get validators
function M._get_validators()
  return validators
end

return M
