-- lua/checkmate/linter.lua
local M = {}

-- A dedicated namespace for our linting diagnostics
M.ns = vim.api.nvim_create_namespace("checkmate_lint")

-- Define lint issue types with descriptions
M.ISSUES = {
  INCONSISTENT_MARKER = "List markers should be consistent among siblings",
  MISALIGNED_CONTENT = "Content on continuation lines should align with the first line's content",
  MIXED_LIST_TYPE = "Mixing ordered/unordered lists at same nesting level",
  UNALIGNED_MARKER = "List marker is misaligned",
}

-- Internal-only type that extends the user-facing config
---@class checkmate.InternalLinterConfig : checkmate.LinterConfig
---@field namespace string? -- Which diagnostic namespace to use
---@field virtual_text vim.diagnostic.Opts.VirtualText -- Virtual text options
---@field underline vim.diagnostic.Opts.Underline -- Underline options

-- Default configuration
---@type checkmate.InternalLinterConfig
M.config = {
  enabled = true,
  -- Which diagnostic namespace to use - default will use the plugin's own namespace
  -- Set to another namespace string to integrate with other diagnostic providers
  namespace = nil,
  -- Virtual text options, forwarded to vim.diagnostic.config
  ---@type vim.diagnostic.Opts.VirtualText
  virtual_text = {
    prefix = "▸",
  },
  -- Underline options, forwarded to vim.diagnostic.config
  ---@type vim.diagnostic.Opts.Underline
  underline = { severity = "WARN" },
  auto_fix = false,
  severity = {
    [M.ISSUES.INCONSISTENT_MARKER] = vim.diagnostic.severity.INFO,
    [M.ISSUES.MISALIGNED_CONTENT] = vim.diagnostic.severity.HINT,
    [M.ISSUES.MIXED_LIST_TYPE] = vim.diagnostic.severity.WARN,
    [M.ISSUES.UNALIGNED_MARKER] = vim.diagnostic.severity.WARN,
  },
}

-- Setup linter with user config
---@param opts checkmate.LinterConfig? User configuration options
---@return checkmate.InternalLinterConfig config Merged configuration
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- If disabled, return early
  if not M.config.enabled then
    M.disable()
    return M.config
  end

  -- Configure diagnostics with our options
  vim.diagnostic.config({
    virtual_text = M.config.virtual_text,
    underline = M.config.underline,
    severity_sort = true,
  }, M.ns)

  -- TODO: Run linter when buffer is written
  --[[ vim.api.nvim_create_autocmd("BufWritePre", {
      group = vim.api.nvim_create_augroup("CheckmateLinter", { clear = true }),
      pattern = "*.todo",
      callback = function(args)
        require("checkmate.util").notify("bufwritepre", vim.log.levels.DEBUG)
        if M.config.auto_fix and args.event == "BufWritePre" then
          M.fix_issues(args.buf)
        end
      end,
    }) ]]

  return M.config
end

-- Main lint function
---@param bufnr integer? Buffer number to lint, defaults to current buffer
---@return vim.Diagnostic[] result List of diagnostics produced
function M.lint_buffer(bufnr)
  local parser = require("checkmate.parser")
  local log = require("checkmate.log")
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Skip if buffer is not valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  -- Clear previous diagnostics
  vim.diagnostic.reset(M.ns, bufnr)

  -- List to hold diagnostic items
  ---@type vim.Diagnostic[]
  local diagnostics = {}

  -- Get all list items
  local list_items = parser.get_all_list_items(bufnr)

  -- Sort items by line number for sequential processing
  table.sort(list_items, function(a, b)
    return a.range.start.row < b.range.start.row
  end)

  -- Find nesting level for each list item based on indentation
  -- We don't use TS nesting here because we want to find list items that are misaligned
  -- Thus, we find them by indentation errors
  for i, item in ipairs(list_items) do
    local row = item.range.start.row
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""

    -- Get this item's indentation
    local indent = line:match("^(%s*)") or ""
    local indent_level = #indent

    -- Find the nearest preceding list item with less indentation - that's the parent
    local parent_item = nil
    for j = i - 1, 1, -1 do
      local prev_item = list_items[j]
      local prev_row = prev_item.range.start.row
      local prev_line = vim.api.nvim_buf_get_lines(bufnr, prev_row, prev_row + 1, false)[1] or ""
      local prev_indent = prev_line:match("^(%s*)") or ""

      if #prev_indent < indent_level then
        parent_item = prev_item
        break
      end
    end

    -- If we found a parent, check indentation
    if parent_item then
      local parent_row = parent_item.range.start.row
      local parent_line = vim.api.nvim_buf_get_lines(bufnr, parent_row, parent_row + 1, false)[1] or ""

      local _, _, _, parent_marker_end_col = parent_item.list_marker.node:range()

      -- Find the first non-whitespace character after the parent's marker
      local content_start_idx = parent_line:find("[^%s]", parent_marker_end_col + 1)

      local parent_content_start
      if content_start_idx then
        -- Content starts at the first non-whitespace character
        parent_content_start = content_start_idx - 1 -- Convert to 0-indexed
      else
        -- No content after marker, use CommonMark default (one space after marker)
        parent_content_start = parent_marker_end_col + 1
      end

      -- Get this item's marker position
      local _, marker_col, _, _ = item.list_marker.node:range()

      -- Child list marker should align with the start of parent's content
      if marker_col ~= parent_content_start then
        log.debug(
          string.format(
            "INDENTATION ISSUE: line %d marker at column %d, should be at column %d to align with parent at line %d",
            row + 1,
            marker_col + 1,
            parent_content_start + 1,
            parent_row + 1
          ),
          { module = "linter" }
        )

        table.insert(diagnostics, {
          bufnr = bufnr,
          lnum = row,
          col = 0,
          end_lnum = row,
          end_col = #indent,
          message = M.ISSUES.UNALIGNED_MARKER,
          severity = M.config.severity[M.ISSUES.UNALIGNED_MARKER],
          source = "checkmate",
          user_data = {
            fixable = true,
            -- TODO: implement auto_fix
            --
            --[[ fix_fn = function()
              -- Fix just the first line with the list marker
              local fixed_marker_line = string.rep(" ", parent_content_start) .. line:gsub("^%s*", "")
              vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { fixed_marker_line })

              -- Get the updated list items
              local list_items = parser.get_all_list_items(bufnr)

              -- Find our newly aligned item
              local aligned_item = nil
              for _, item in ipairs(list_items) do
                if item.range.start.row == row then
                  aligned_item = item
                  break
                end
              end

              if aligned_item then
                -- Calculate the full range that needs adjustment
                -- This should now include all children correctly
                local item_node = aligned_item.node
                local start_row, _, end_row, _ = item_node:range()

                -- Calculate the indentation difference we applied
                local original_indent = #(line:match("^%s*") or "")
                local indent_adjustment = parent_content_start - original_indent

                -- Adjust all lines *except* the first one which we already fixed
                for line_row = start_row + 1, end_row do
                  local line_text = vim.api.nvim_buf_get_lines(bufnr, line_row, line_row + 1, false)[1]
                  if line_text then
                    -- Keep relative indentation within the subtree
                    local line_indent = line_text:match("^%s*") or ""
                    local new_indent = string.rep(" ", #line_indent + indent_adjustment)
                    local fixed_line = new_indent .. line_text:gsub("^%s*", "")
                    vim.api.nvim_buf_set_lines(bufnr, line_row, line_row + 1, false, { fixed_line })
                  end
                end
              end
            end ]]
          },
        })
      end
    end
  end

  -- Set diagnostics in the buffer using our namespace
  vim.diagnostic.set(M.ns, bufnr, diagnostics)

  log.debug(string.format("Linted buffer %d, found %d issues", bufnr, #diagnostics), { module = "linter" })

  return diagnostics
end

-- Fix all fixable issues in buffer
---@param bufnr integer? Buffer number, defaults to current buffer
---@return boolean success Whether fixes were applied
---@return integer count Number of issues fixed
function M.fix_issues(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Get current diagnostics from our namespace
  local diagnostics = vim.diagnostic.get(bufnr, { namespace = M.ns })

  -- Track if we've fixed anything
  local fixed = 0

  -- Apply fixes in reverse line order to avoid position shifts
  table.sort(diagnostics, function(a, b)
    return a.lnum > b.lnum
  end)

  for _, diag in ipairs(diagnostics) do
    if diag.user_data and diag.user_data.fixable and diag.user_data.fix_fn then
      diag.user_data.fix_fn()
      fixed = fixed + 1
    end
  end

  -- Re-lint after fixing
  if fixed then
    M.lint_buffer(bufnr)
  end

  return true, fixed
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
