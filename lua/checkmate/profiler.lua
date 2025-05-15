-- lua/checkmate/profiler.lua

--[[
Checkmate Performance Profiler
==============================

OVERVIEW:
---------
The profiler helps identify performance bottlenecks by measuring execution time
of operations and their relationship to each other. It tracks both total time 
and self time (exclusive of child operations) to identify where optimization 
efforts should be focused.

KEY CONCEPTS:
------------
- Session: A complete profiling period with start and end markers
- Span: A single measured operation with a label, start time, and end time
- Measurement: Statistical data about all spans with the same label
- Active Span: A currently running span that hasn't been stopped yet
- Call Stack: Hierarchical record of active spans to track parent-child relationships
- Checkpoint: A time marker within a span to measure progress of sub-operations
- Self Time: Time spent in a function excluding time spent in child operations
- Total Time: Complete time spent in a function including all child operations
- Child Time: Accumulated time of all child operations

INTERPRETING RESULTS:
--------------------
- Functions with high total time but low self time have slow child operations
- Functions with high self time are bottlenecks that should be optimized first
- Child operations showing high percentage of parent time indicate critical paths
- Checkpoint deltas show which parts of an operation are slowest

IMPLEMENTATION NOTES:
--------------------
- Timing uses high-resolution timer vim.uv.hrtime() (nanosecond precision)
- Minimal performance impact when not actively profiling
- Safe to leave profiling code in production (disabled by default)
- Automatically detects parent-child relationships based on call order
- Maintains a history of recent profiling sessions

]]

local M = {}

-- Internal state
M._enabled = false -- is the profiler feature ON?
M._active = false -- are we currently collecting measurements
M._session_name = ""
M._session_start_time = nil
M._measurements = {} -- current profile session measurements
M._history = {}
M._active_spans = {}
M._call_stack = {} -- For tracking call tree and relationships

-- Settings
M._settings = {
  -- Maximum number of samples to keep for each measurement
  max_samples = 20,
}

-- Get time in ms since start
local function time_since(start_ns)
  return (vim.uv.hrtime() - start_ns) / 1000000
end

function M.enable()
  local util = require("checkmate.util")
  if M._enabled then
    util.notify("Profiler already enabled", vim.log.levels.INFO)
    return
  end

  M._enabled = true
  util.notify("Performance profiling enabled", vim.log.levels.INFO)
end

function M.disable()
  if not M._enabled then
    return
  end

  if M._active then
    M.stop_session()
  else
    M.save_measurements()
  end

  M._enabled = false
  require("checkmate.util").notify("Performance profiler disabled", vim.log.levels.INFO)
end

function M.start_session(name)
  local util = require("checkmate.util")
  if not M._enabled then
    util.notify("Profiler not enabled", vim.log.levels.WARN)
    return false
  end

  if M._active then
    util.notify("Profiler session already running", vim.log.levels.WARN)
    return false
  end

  -- Initialize a new measurement session
  M._active = true
  M._measurements = {}
  M._active_spans = {}
  M._call_stack = {}
  M._session_name = name or os.date("%Y-%m-%d %H:%M:%S")
  M._session_start_time = vim.uv.hrtime()

  util.notify("Performance profiling session started", vim.log.levels.INFO)
  return true
end

function M.stop_session()
  if not M.enabled then
    return false
  end

  local util = require("checkmate.util")

  if not M._active then
    util.notify("No profiler session is running", vim.log.levels.WARN)
    return false
  end

  -- Auto-close any active spans
  for label, _ in pairs(M._active_spans) do
    M.stop(label)
  end

  -- Store the current session in history
  local session = {
    name = M._session_name,
    measurements = vim.deepcopy(M._measurements),
    duration = time_since(M._session_start_time),
    timestamp = os.time(),
  }

  -- Add to history (limited to last 5 sessions for memory)
  table.insert(M._history, 1, session)
  if #M._history > 5 then
    table.remove(M._history)
  end

  -- Reset current session state
  M._active = false
  M._active_spans = {}
  M._call_stack = {}
  M._session_name = ""
  M._session_start_time = nil

  util.notify("Performance profiling session stopped", vim.log.levels.INFO)
  return true
end

function M.is_enabled()
  return M._enabled
end

function M.is_active()
  return M._active
end

-- Start measuring a new time span
function M.start(label, parent_label)
  if not M._enabled or not M._active then
    return
  end

  table.insert(M._call_stack, label)

  -- Handle auto nesting by checking call stack
  if not parent_label and #M._call_stack > 1 then
    parent_label = M._call_stack[#M._call_stack - 1]
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
    children = {},
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

  -- Handle case where label isn't specified but we want to close the most recent span
  if not label and #M._call_stack > 0 then
    label = M._call_stack[#M._call_stack]
  end

  -- If span doesn't exist or already ended, just return
  if not M._active_spans[label] then
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

  -- Update parent's children time and measurements
  if span.parent and M._active_spans[span.parent] then
    local parent_span = M._active_spans[span.parent]
    parent_span.children_time = (parent_span.children_time or 0) + time_ms

    -- Update parent's measurement children data
    if M._measurements[span.parent] then
      M._measurements[span.parent].children[label] = M._measurements[span.parent].children[label]
        or {
          count = 0,
          total_time = 0,
        }
      M._measurements[span.parent].children[label].count = M._measurements[span.parent].children[label].count + 1
      M._measurements[span.parent].children[label].total_time = M._measurements[span.parent].children[label].total_time
        + time_ms

      -- Update parent's total child time
      M._measurements[span.parent].child_time = (M._measurements[span.parent].child_time or 0) + time_ms
    end
  elseif span.parent and M._measurements[span.parent] then
    -- Parent span already closed but we still track relationship in measurements
    M._measurements[span.parent].children[label] = M._measurements[span.parent].children[label]
      or {
        count = 0,
        total_time = 0,
      }
    M._measurements[span.parent].children[label].count = M._measurements[span.parent].children[label].count + 1
    M._measurements[span.parent].children[label].total_time = M._measurements[span.parent].children[label].total_time
      + time_ms

    -- Update parent's total child time
    M._measurements[span.parent].child_time = (M._measurements[span.parent].child_time or 0) + time_ms
  end

  -- Update call stack - remove this span
  for i = #M._call_stack, 1, -1 do
    if M._call_stack[i] == label then
      table.remove(M._call_stack, i)
      break
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

  -- If label isn't specified, use the most recent span
  if not label and #M._call_stack > 0 then
    label = M._call_stack[#M._call_stack]
  end

  if not M._active_spans[label] then
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

-- Save current measurements as last measurements
function M.save_measurements()
  local session = {
    name = M._session_name or "Unnamed session",
    measurements = vim.deepcopy(M._measurements),
    timestamp = os.time(),
  }

  table.insert(M._history, 1, session)
  if #M._history > 5 then
    table.remove(M._history, #M._history)
  end
end

-- Generate a performance report
function M.report()
  if not M._enabled and vim.tbl_isempty(M._history) then
    return "No performance data available. Start profiling with :CheckmateDebugProfilerStart"
  end

  local measurements
  if M._active then
    -- Use current active measurements
    measurements = M._measurements
  elseif #M._history > 0 then
    -- Use most recent history entry
    measurements = M._history[1].measurements
  else
    -- No data available
    return "No performance data available. Start profiling with :CheckmateDebugProfilerStart"
  end

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
    if data.count > 0 then
      table.insert(sorted, { name = name, data = data })
    end
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
    self_percent = math.min(self_percent, 100)

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
      for _, time in ipairs(data.samples) do
        table.insert(samples, string.format("%.2f", time))
      end
      table.insert(lines, table.concat(samples, ", "))
    end

    -- Show checkpoints if present
    if data.checkpoints and #data.checkpoints > 0 then
      -- Group checkpoints by parent
      local checkpoints_by_parent = {}

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
        percent = math.min(percent, 100)
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
