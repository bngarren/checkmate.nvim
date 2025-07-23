--[[
-- Validator-Based Markdown Linter
--
-- This linter enforces two critical CommonMark list indentation rules (spec 0.31.2 §6):
--
-- 1. **Indentation <= 3 spaces** – A child's marker may appear up to
--    three spaces further to the right of its parent's *content* column.
-- 2. **Nested items >= parent content column** – A child's marker must start
--    at or to the right of its parent's content column.

-- It also warns when ordered & unordered markers are mixed at the same indent.

-- Design:
-- The linter uses a validator-based architecture where each rule is encapsulated
-- in a separate validator object implementing a common interface.
--
-- Each validator receives a LintContext containing all necessary information to
-- perform validation and report issues through a simplified reporting function.
--
-- Key Terms:
-- - marker_col: The column position (0-indexed) where a list marker (-,*,+,1.) begins
-- - content_col: The column position where the actual content of a list item begins
--                (after the marker and any whitespace)
-- - marker_type: Either "ordered" (1., 2.) or "unordered" (-,*,+) list type
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
---@param stack LinterListItem[] The stack of parent list items
---@param col integer The marker column to compare against
---@return LinterListItem|nil result The parent node, or nil if no suitable parent found
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
---@return LinterListItem|nil
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

---Create a diagnostic in the diagnostics table
---@param bufnr integer Buffer number
---@param diags table Table of diagnostics
---@param rule_id string The rule ID from M.RULES
---@param row integer The 0-based row number
---@param col integer The 0-based column number
---@param extra_info? string Optional context to append to message
---@return boolean success Whether a diagnostic was added
local function create_diagnostic(bufnr, diags, rule_id, row, col, extra_info)
  local rule = M.RULES[rule_id]
  if not rule then
    return false
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

  return true
end

-- Rule validator implementation
------------------------------------------------------------

---@class LinterListItem
---@field row integer Row position (0-indexed) of this list item
---@field marker_col integer Column position (0-indexed) where the list marker begins
---@field content_col integer Column position where the content begins (after marker and whitespace)
---@field marker_type "ordered"|"unordered" Type of list marker (ordered = 1., unordered = -,*,+)

---Context provided to lint validators when checking a list item
---@class LintContext
---@field bufnr integer Buffer being linted
---@field diags table Collection of diagnostics so far in this buffer
---@field list_item LinterListItem Current list item being validated
---@field row integer Current row being validated (0-indexed)
---@field indent_marker_map table<integer,{type:string,row:integer}> Maps indent positions to marker types
---@field parent LinterListItem|nil Parent list item (if any)
---@field report fun(rule_id:string, col:integer, extra_info?:string):boolean Function to report an issue

---@class LinterRuleValidator
---@field validate fun(ctx:LintContext):boolean

---Collection of rule validator factory functions
local Validator = {}

---Create validator for checking inconsistent markers at the same indentation level
---
---This rule enforces that all list items at the same indentation level
---use the same marker type (either all ordered or all unordered).
---
---Example violations:
---   - Item 1
---   1. Item 2    <-- Mixed unordered/ordered at same indent
---
---@return LinterRuleValidator
function Validator.inconsistent_marker()
  -- Track markers by parent ID and indentation level
  local parent_indent_map = {}

  return {
    ---@param ctx LintContext
    validate = function(ctx)
      -- Skip validation for top-level list items (allow variety at document root)
      if not ctx.parent then
        return false
      end

      -- Create a unique key based on parent row and marker column
      -- This ensures we only compare siblings (items with the same parent)
      local parent_key = string.format("%d:%d", ctx.parent.row, ctx.parent.marker_col)
      local indent_key = ctx.list_item.marker_col

      -- Initialize parent map if needed
      parent_indent_map[parent_key] = parent_indent_map[parent_key] or {}

      -- Check if we've seen a different marker type for siblings at this indent level
      local existing = parent_indent_map[parent_key][indent_key]

      if existing and existing ~= ctx.list_item.marker_type then
        -- We found siblings with different marker types
        ctx.report("INCONSISTENT_MARKER", ctx.list_item.marker_col)
        return true
      else
        -- Remember this marker type for siblings at this indent level
        parent_indent_map[parent_key][indent_key] = ctx.list_item.marker_type
        return false
      end
    end,
  }
end

---Create validator for checking shallow indentation
---
---This rule enforces the CommonMark requirement that a child list item's
---marker must be positioned at or to the right of its parent's content.
---
---Example violations:
---   - Parent
---  - Child      <-- Child marker appears before parent's content
---
---@return LinterRuleValidator
function Validator.indent_shallow()
  return {
    ---@param ctx LintContext
    validate = function(ctx)
      -- Skip if parent already has an indent issue (to avoid redundant errors)
      if ctx.parent then
        -- Check if parent marker position has an existing indent diagnostic
        for _, diag in ipairs(ctx.diags) do
          if
            (diag.code == "INDENT_SHALLOW" or diag.code == "INDENT_DEEP")
            and diag.col == ctx.parent.marker_col
            and diag.lnum == ctx.parent.row
          then
            return false -- Skip validation
          end
        end
      end

      -- Check if this list item's marker is positioned before its parent's content
      if ctx.parent and ctx.list_item.marker_col < ctx.parent.content_col then
        local extra_info = string.format("(should be at column %d or greater)", ctx.parent.content_col)
        ctx.report("INDENT_SHALLOW", ctx.list_item.marker_col, extra_info)
        return true
      end
      return false
    end,
  }
end

---Create validator for checking excessive indentation
---
---This rule enforces the CommonMark requirement that a child list item's
---marker should not be more than 3 spaces to the right of its parent's content.
---
---Example violations:
---   - Parent
---       - Child  <-- Child marker indented more than 3 spaces from parent's content
---
---@return LinterRuleValidator
function Validator.indent_deep()
  return {
    ---@param ctx LintContext
    validate = function(ctx)
      -- Skip if parent already has an indent issue (to avoid redundant errors)
      if ctx.parent then
        -- Check if parent marker position has an existing indent diagnostic
        for _, diag in ipairs(ctx.diags) do
          if
            (diag.code == "INDENT_SHALLOW" or diag.code == "INDENT_DEEP")
            and diag.col == ctx.parent.marker_col
            and diag.lnum == ctx.parent.row
          then
            return false -- Skip validation
          end
        end
      end

      -- Check if this list item's marker is more than 3 spaces to the right of parent's content
      if ctx.parent and ctx.list_item.marker_col > ctx.parent.content_col + 3 then
        local extra_info = string.format("(maximum allowed is column %d)", ctx.parent.content_col + 3)
        ctx.report("INDENT_DEEP", ctx.list_item.marker_col, extra_info)
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
  local stack = {} ---@type LinterListItem[]
  local indent_marker_map = {} ---@type table<integer, {type: string, row: integer}> Maps indentation levels to marker info
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for i, line in ipairs(lines) do
    local row = i - 1 -- diagnostics are 0‑based
    local list_item = parse_list_item(line)

    if list_item then
      list_item.row = row

      -- Get parent (if any) for nested list item checks
      local parent = pop_parent(stack, list_item.marker_col)

      if parent then
        parent.row = parent.row or row - 1 -- Estimate if not set
      end

      -- Create a context for validation
      local ctx = {
        bufnr = bufnr,
        diags = diags,
        list_item = list_item,
        row = row,
        indent_marker_map = indent_marker_map,
        parent = parent,
        -- Pre-bound report function for this row
        report = function(rule_id, col, extra_info)
          return create_diagnostic(bufnr, diags, rule_id, row, col, extra_info)
        end,
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
---@param opts? table Optional settings like priority
---@return integer Index of the new validator
function M.register_validator(factory, opts)
  opts = opts or {}
  local validator = factory()

  if opts.priority and opts.priority < 0 then
    -- Insert at beginning
    table.insert(validators, 1, validator)
    return 1
  elseif opts.priority and opts.priority > 0 then
    -- Insert at specific position
    table.insert(validators, opts.priority, validator)
    return opts.priority
  else
    -- Default: append at end
    table.insert(validators, validator)
    return #validators
  end
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

-- Export Validator for API use
M.Validator = Validator

-- For testing - get validators
function M._get_validators()
  return validators
end

return M
