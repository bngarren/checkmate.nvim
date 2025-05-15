-- lua/checkmate/profiler.lua
local M = {}

-- Internal state
M._enabled = false
M._measurements = {}
M._last_measurements = {}
M._active_spans = {}

-- For tracking call tree and relationships
M._call_tree = {}

-- Settings
M._settings = {
  -- Maximum number of samples to keep for each measurement
  max_samples = 20,
}

function M.enable()
  M._enabled = true
  M._measurements = {}
  M._call_tree = {}
  M._active_spans = {}
  require("checkmate.util").notify("Performance profiling started", vim.log.levels.INFO)
end

function M.disable()
  -- Auto-close any active spans
  for label, _ in pairs(M._active_spans) do
    M.stop(label)
  end

  M._enabled = false
  M.save_measurements()
  require("checkmate.util").notify("Performance profiling stopped", vim.log.levels.INFO)
end

function M.is_enabled()
  return M._enabled
end

-- Get time in ms since start
local function time_since(start_ns)
  return (vim.uv.hrtime() - start_ns) / 1000000
end

-- Start measuring a new time span
function M.start(label, parent_label)
  if not M._enabled then
    return
  end

  -- Handle auto nesting if parent_label not specified
  if not parent_label then
    -- Find the most recently started span that's still active
    local most_recent = nil
    local most_recent_time = 0

    for other_label, span in pairs(M._active_spans) do
      if span.start_time > most_recent_time then
        most_recent = other_label
        most_recent_time = span.start_time
      end
    end

    parent_label = most_recent
  end

  -- Initialize the measurement if it doesn't exist
  if not M._measurements[label] then
    M._measurements[label] = {
      count = 0,
      total_time = 0,
      self_time = 0,
      min_time = math.huge,
      max_time = 0,
      avg_time = 0,
      samples = {},
      checkpoints = {},
      children = {},
      child_time = 0,
    }
  end

  -- Record the new active span
  M._active_spans[label] = {
    start_time = vim.uv.hrtime(),
    parent = parent_label,
    children_time = 0,
    checkpoints = {},
  }

  -- If this span has a parent, register it as a child
  if parent_label and M._active_spans[parent_label] then
    M._active_spans[parent_label].children = M._active_spans[parent_label].children or {}
    M._active_spans[parent_label].children[label] = true
  end

  return label
end

-- End measuring a time span
function M.stop(label)
  if not M._enabled or not M._active_spans[label] then
    return
  end

  local span = M._active_spans[label]
  local time_ms = time_since(span.start_time)

  -- Update measurement statistics
  local measurement = M._measurements[label]
  measurement.count = measurement.count + 1
  measurement.total_time = measurement.total_time + time_ms
  measurement.min_time = math.min(measurement.min_time, time_ms)
  measurement.max_time = math.max(measurement.max_time, time_ms)
  measurement.avg_time = measurement.total_time / measurement.count

  -- Calculate self time (excluding children)
  local self_time = time_ms - (span.children_time or 0)
  measurement.self_time = measurement.self_time + self_time

  -- Update samples (keep limited history)
  table.insert(measurement.samples, time_ms)
  if #measurement.samples > M._settings.max_samples then
    table.remove(measurement.samples, 1)
  end

  -- If there were checkpoints, add them to the measurement
  if span.checkpoints and #span.checkpoints > 0 then
    measurement.checkpoints = measurement.checkpoints or {}
    for _, cp in ipairs(span.checkpoints) do
      table.insert(measurement.checkpoints, cp)
    end
  end

  -- Update parent's children time
  if span.parent and M._active_spans[span.parent] then
    local parent_span = M._active_spans[span.parent]
    parent_span.children_time = (parent_span.children_time or 0) + time_ms

    -- Also update the parent's measurement
    if M._measurements[span.parent] then
      -- Add this as a child to the parent measurement
      M._measurements[span.parent].children[label] = M._measurements[span.parent].children[label]
        or {
          count = 0,
          total_time = 0,
        }
      M._measurements[span.parent].children[label].count = M._measurements[span.parent].children[label].count + 1
      M._measurements[span.parent].children[label].total_time = M._measurements[span.parent].children[label].total_time
        + time_ms

      -- Update parent's total child time
      M._measurements[span.parent].child_time = M._measurements[span.parent].child_time + time_ms
    end
  end

  -- Clean up
  M._active_spans[label] = nil
end

-- Record a checkpoint within the current measurement
function M.checkpoint(label, checkpoint_label)
  if not M._enabled or not M._active_spans[label] then
    return 0
  end

  local span = M._active_spans[label]
  local elapsed_ms = time_since(span.start_time)

  span.checkpoints = span.checkpoints or {}

  local checkpoint = {
    label = checkpoint_label,
    time_ms = elapsed_ms,
    parent = label,
  }

  table.insert(span.checkpoints, checkpoint)

  return elapsed_ms
end

-- For backward compatibility and convenience - wraps start/end in a function
function M.measure(name, fn, ...)
  if not M._enabled then
    return fn(...)
  end

  M.start(name)
  local results = { pcall(fn, ...) }
  M.stop(name)

  local success = table.remove(results, 1)

  if not success then
    error(results[1])
  end

  return unpack(results)
end

-- Save current measurements as last measurements
function M.save_measurements()
  M._last_measurements = vim.deepcopy(M._measurements)
end

-- Generate a performance report
function M.report()
  if not M._enabled and vim.tbl_isempty(M._last_measurements) then
    return "No performance data available. Start profiling with :CheckmateDebugProfilerStart"
  end

  -- Use current measurements if enabled, otherwise use last measurements
  local measurements = M._enabled and M._measurements or M._last_measurements

  local lines = {
    "Checkmate Performance Report",
    "============================",
  }

  -- Operations section
  table.insert(lines, "")
  table.insert(lines, "Operations (sorted by total time)")
  table.insert(lines, "--------------------------------")

  -- Prepare data for sorting
  local sorted = {}
  for name, data in pairs(measurements) do
    table.insert(sorted, { name = name, data = data })
  end

  -- Sort by total time descending
  table.sort(sorted, function(a, b)
    return a.data.total_time > b.data.total_time
  end)

  -- Add main measurements
  for _, item in ipairs(sorted) do
    local name, data = item.name, item.data
    local avg = data.count > 0 and (data.total_time / data.count) or 0

    -- Calculate self vs. child time
    local self_percent = data.total_time > 0 and (data.self_time / data.total_time) * 100 or 100

    table.insert(lines, "")
    table.insert(lines, name)
    table.insert(lines, string.rep("-", #name))
    table.insert(lines, string.format("Calls:      %d times", data.count))
    table.insert(lines, string.format("Total time: %.2f ms", data.total_time))
    table.insert(lines, string.format("Self time:  %.2f ms (%.1f%%)", data.self_time, self_percent))
    table.insert(
      lines,
      string.format(
        "Average:    %.2f ms (range: %.2f-%.2f ms)",
        avg,
        data.min_time ~= math.huge and data.min_time or 0,
        data.max_time
      )
    )

    -- Show recent samples distribution
    if data.samples and #data.samples > 0 then
      table.insert(lines, "")
      table.insert(lines, "Recent execution times (ms):")
      local samples = {}
      for i, time in ipairs(data.samples) do
        table.insert(samples, string.format("%.2f", time))
      end
      table.insert(lines, table.concat(samples, ", "))
    end

    -- Show checkpoints if present
    if data.checkpoints and #data.checkpoints > 0 then
      -- Group checkpoints by parent
      local checkpoints_by_parent = {}

      -- Group checkpoints by parent
      for _, cp in ipairs(data.checkpoints) do
        checkpoints_by_parent[cp.parent] = checkpoints_by_parent[cp.parent] or {}
        table.insert(checkpoints_by_parent[cp.parent], cp)
      end

      -- Only show checkpoints for this operation
      if checkpoints_by_parent[name] then
        local checkpoints = checkpoints_by_parent[name]

        -- Sort checkpoints by time
        table.sort(checkpoints, function(a, b)
          return a.time_ms < b.time_ms
        end)

        table.insert(lines, "")
        table.insert(lines, "Checkpoints:")

        -- Calculate deltas
        local last_time = 0
        for i, cp in ipairs(checkpoints) do
          local delta = i == 1 and cp.time_ms or (cp.time_ms - last_time)
          table.insert(lines, string.format("  %-30s | Time: %8.2f ms | +%.2f ms", cp.label, cp.time_ms, delta))
          last_time = cp.time_ms
        end
      end
    end

    -- Show children if present
    if not vim.tbl_isempty(data.children) then
      -- Prepare children for sorting
      local sorted_children = {}
      for child_name, child_data in pairs(data.children) do
        table.insert(sorted_children, { name = child_name, data = child_data })
      end

      -- Sort children by total time
      table.sort(sorted_children, function(a, b)
        return a.data.total_time > b.data.total_time
      end)

      table.insert(lines, "")
      table.insert(lines, "Child operations:")

      for _, child in ipairs(sorted_children) do
        -- Calculate child's percentage of parent's time
        local percent = (child.data.total_time / data.total_time) * 100
        table.insert(
          lines,
          string.format(
            "  %-30s | Calls: %4d | Total: %8.2f ms | %.1f%% of parent",
            child.name,
            child.data.count,
            child.data.total_time,
            percent
          )
        )
      end
    end
  end

  return table.concat(lines, "\n")
end

-- Display the report in a floating window
function M.show_report()
  -- Save current measurements before displaying
  if M._enabled then
    M.save_measurements()
  end

  local report = M.report()

  -- Create a scratch buffer for the report
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(report, "\n"))

  -- Set buffer options
  vim.api.nvim_set_option_value("filetype", "text", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

  -- Calculate window size and position
  local width = math.min(120, vim.o.columns - 10)
  local height = math.min(#vim.split(report, "\n"), vim.o.lines - 6)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Create window
  local opts = {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Checkmate Performance Profile ",
    title_pos = "center",
  }

  local win = vim.api.nvim_open_win(buf, true, opts)

  -- Set window-local options
  vim.api.nvim_set_option_value("wrap", true, { win = win })
  vim.api.nvim_set_option_value("foldenable", false, { win = win })

  -- Close with 'q' or ESC
  vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", { noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", { noremap = true, silent = true })

  -- Set up syntax highlighting for the report
  local cmds = {
    "syn clear",
    -- Section headers
    "syn match ProfilerHeader /^=\\+$/",
    "syn match ProfilerHeader /^-\\+$/",
    "syn match ProfilerSection /^\\(.\\+\\)\\n-\\+$/",
    -- Numbers
    "syn match ProfilerNumber /\\d\\+\\.\\d\\+ ms/",
    "syn match ProfilerPercent /\\d\\+\\.\\d\\+%/",
    "syn match ProfilerCount /\\d\\+ times/",
    -- Labels
    "syn match ProfilerLabel /^\\s*Calls:\\|^\\s*Total time:\\|^\\s*Self time:\\|^\\s*Average:/",
    "syn match ProfilerLabel /^Recent execution times\\|^Checkpoints:\\|^Child operations:/",
    -- Highlights
    "hi ProfilerHeader ctermfg=1 guifg=#ff5555",
    "hi ProfilerSection ctermfg=4 guifg=#6699ff gui=bold",
    "hi ProfilerNumber ctermfg=2 guifg=#88dd88",
    "hi ProfilerPercent ctermfg=3 guifg=#ddcc88",
    "hi ProfilerCount ctermfg=5 guifg=#dd88dd",
    "hi ProfilerLabel ctermfg=6 guifg=#88ddcc gui=italic",
  }

  for _, cmd in ipairs(cmds) do
    vim.cmd(string.format("silent! %s", cmd))
  end

  return buf, win
end

return M
