-- lua/checkmate/linter.lua
local M = {}

-- Create a dedicated namespace for our linting diagnostics
M.ns = vim.api.nvim_create_namespace("checkmate_lint")

-- Define lint issue types with descriptions
M.ISSUES = {
  INVALID_INDENT = "Improper list item indentation (doesn't follow CommonMark spec)",
  INCONSISTENT_MARKER = "List markers should be consistent among siblings",
  MISALIGNED_CONTENT = "Content on continuation lines should align with the first line's content",
  MIXED_LIST_TYPE = "Mixing ordered/unordered lists at same nesting level",
  UNALIGNED_MARKER = "List marker should be properly aligned under parent's content",
}

-- Default configuration
M.config = {
  enabled = true,
  auto_fix = false,
  severity = {
    [M.ISSUES.INVALID_INDENT] = vim.diagnostic.severity.WARN,
    [M.ISSUES.INCONSISTENT_MARKER] = vim.diagnostic.severity.INFO,
    [M.ISSUES.MISALIGNED_CONTENT] = vim.diagnostic.severity.HINT,
    [M.ISSUES.MIXED_LIST_TYPE] = vim.diagnostic.severity.WARN,
    [M.ISSUES.UNALIGNED_MARKER] = vim.diagnostic.severity.WARN,
  },
}

-- Setup linter with user config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  if M.config.enabled then
    local augroup = vim.api.nvim_create_augroup("CheckmateLinter", { clear = true })

    -- Run linter when buffer is written
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = augroup,
      pattern = "*.todo",
      callback = function(args)
        if M.config.auto_fix and args.event == "BufWritePre" then
          M.fix_issues(args.buf)
        end
      end,
    })
  end

  return M.config
end

-- Main lint function
function M.lint_buffer(bufnr)
  local parser = require("checkmate.parser")
  local log = require("checkmate.log")
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Clear previous diagnostics
  vim.diagnostic.reset(M.ns, bufnr)

  -- List to hold diagnostic items
  local diagnostics = {}

  -- Get all list items, but don't rely on their parent-child relationships
  local list_items = parser.get_all_list_items(bufnr)
  log.debug("Found " .. #list_items .. " list items", { module = "linter" })

  -- Sort items by line number for sequential processing
  table.sort(list_items, function(a, b)
    return a.range.start.row < b.range.start.row
  end)

  -- Find nesting level for each list item based on indentation
  for i, item in ipairs(list_items) do
    -- Get row and line content
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
      -- Get parent row and line
      local parent_row = parent_item.range.start.row
      local parent_line = vim.api.nvim_buf_get_lines(bufnr, parent_row, parent_row + 1, false)[1] or ""

      -- Get parent list marker details
      local _, _, _, parent_marker_end_col = parent_item.list_marker.node:range()

      -- Find the first non-whitespace character after the parent's marker
      -- Directly calculate using the full line for accuracy
      local content_start_idx = parent_line:find("[^%s]", parent_marker_end_col + 1)

      local parent_content_start
      if content_start_idx then
        -- Content starts at the first non-whitespace character
        parent_content_start = content_start_idx - 1 -- Convert to 0-indexed
        log.debug(string.format("Parent content starts at column %d", parent_content_start + 1), { module = "linter" })
      else
        -- No content after marker, use CommonMark default (one space after marker)
        parent_content_start = parent_marker_end_col + 1
        log.debug("No content after parent marker, using default position", { module = "linter" })
      end

      -- Get this item's marker position
      local marker_row, marker_col, _, _ = item.list_marker.node:range()

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
          message = M.ISSUES.UNALIGNED_MARKER .. string.format(
            " (marker should align with parent's content at column %d, currently at column %d)",
            parent_content_start + 1,
            marker_col + 1
          ),
          severity = M.config.severity[M.ISSUES.UNALIGNED_MARKER],
          source = "checkmate-linter",
          user_data = {
            fixable = true,
            fix_fn = function()
              -- Adjust indentation to align marker properly with parent's content
              local fixed_line = string.rep(" ", parent_content_start) .. line:gsub("^%s*", "")
              vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { fixed_line })
            end,
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

-- Check for proper indentation between parent and child
function M.check_indentation(bufnr, parent_item, child_item, diagnostics)
  local log = require("checkmate.log")

  log.debug(
    string.format(
      "Checking indentation: parent at row %d, child at row %d",
      parent_item.range.start.row + 1,
      child_item.range.start.row + 1
    ),
    { module = "linter" }
  )

  -- Skip if parent or child doesn't have list marker info
  if
    not parent_item.list_marker
    or not parent_item.list_marker.node
    or not child_item.list_marker
    or not child_item.list_marker.node
  then
    log.debug("Skipping check due to missing list marker info", { module = "linter" })
    return
  end

  -- Get parent list marker details
  local parent_marker_row, parent_marker_col, _, parent_marker_end_col = parent_item.list_marker.node:range()

  -- Get child list marker details
  local child_marker_row, child_marker_col, _, _ = child_item.list_marker.node:range()

  -- Get the parent and child lines
  local parent_line = vim.api.nvim_buf_get_lines(bufnr, parent_marker_row, parent_marker_row + 1, false)[1]
  local child_line = vim.api.nvim_buf_get_lines(bufnr, child_marker_row, child_marker_row + 1, false)[1]

  -- Extract child's indentation
  local child_indent = child_line:match("^(%s*)") or ""
  log.debug(
    string.format("Child indentation: '%s' (length: %d)", vim.inspect(child_indent), #child_indent),
    { module = "linter" }
  )

  -- According to CommonMark spec:
  -- Calculate where the parent's content starts - this is where the child's list marker should align
  local parent_content_start

  -- Debug the lines
  log.debug(string.format("Parent line: '%s', Child line: '%s'", parent_line, child_line), { module = "linter" })

  -- Get the first non-whitespace character after the list marker
  local parent_after_marker = parent_line:sub(parent_marker_end_col + 1)
  local first_content_char = parent_after_marker:find("[^%s]")

  if first_content_char then
    -- Content starts at first non-whitespace after the marker
    parent_content_start = parent_marker_end_col + first_content_char - 1
  else
    -- No content, use the default CommonMark rule
    parent_content_start = parent_marker_end_col + 1
  end

  -- Child list marker should align with the start of parent's content
  if child_marker_col ~= parent_content_start then
    log.debug(
      string.format(
        "Indentation issue: child at %d, should be at %d (parent content start)",
        child_marker_col,
        parent_content_start
      ),
      { module = "linter" }
    )

    table.insert(diagnostics, {
      bufnr = bufnr,
      lnum = child_marker_row,
      col = 0,
      end_lnum = child_marker_row,
      end_col = #child_indent,
      message = M.ISSUES.UNALIGNED_MARKER .. string.format(
        " (marker should align with parent's content at column %d, currently at column %d)",
        parent_content_start + 1, -- +1 for 1-indexed display
        child_marker_col + 1 -- +1 for 1-indexed display
      ),
      severity = M.config.severity[M.ISSUES.UNALIGNED_MARKER],
      source = "checkmate-linter",
      user_data = {
        fixable = true,
        fix_fn = function()
          -- Adjust indentation to align marker properly with parent's content
          local fixed_line = string.rep(" ", parent_content_start) .. child_line:gsub("^%s*", "")
          vim.api.nvim_buf_set_lines(bufnr, child_marker_row, child_marker_row + 1, false, { fixed_line })
        end,
      },
    })
  end
end

-- Fix all fixable issues in buffer
function M.fix_issues(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Get current diagnostics from our namespace
  local diagnostics = vim.diagnostic.get(bufnr, { namespace = M.ns })

  -- Track if we've fixed anything
  local fixed = false

  -- Apply fixes in reverse line order to avoid position shifts
  table.sort(diagnostics, function(a, b)
    return a.lnum > b.lnum
  end)

  for _, diag in ipairs(diagnostics) do
    if diag.user_data and diag.user_data.fixable and diag.user_data.fix_fn then
      diag.user_data.fix_fn()
      fixed = true
    end
  end

  -- Re-lint after fixing
  if fixed then
    M.lint_buffer(bufnr)
  end

  return fixed
end

-- Disable linting
function M.disable(bufnr)
  if bufnr then
    vim.diagnostic.reset(M.ns, bufnr)
  else
    vim.diagnostic.reset(M.ns)
  end
end

return M
