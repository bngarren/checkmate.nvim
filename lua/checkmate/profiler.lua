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
M._enabled = false
M._active = false
M._session = nil
M._next_span_id = 1

-- Settings
M._settings = {
  max_samples = 10, -- Reduced for performance
  orphan_timeout_ms = 5000, -- Spans older than this are considered orphaned
}

-- Get current time in nanoseconds
local function get_time_ns()
  return vim.uv.hrtime()
end

-- Convert nanoseconds to milliseconds
local function ns_to_ms(ns)
  return ns / 1000000
end

-- Initialize a new session
local function new_session(name)
  return {
    name = name or os.date("%Y-%m-%d %H:%M:%S"),
    start_time = get_time_ns(),
    measurements = {}, -- label -> measurement data
    active_spans = {}, -- span_id -> span data
    span_stack = {}, -- stack of span IDs (LIFO)
    span_labels = {}, -- span_id -> label mapping
  }
end

-- Clean up orphaned spans (those that were never stopped)
local function cleanup_orphaned_spans(session)
  if not session or vim.tbl_isempty(session.active_spans) then
    return
  end

  local current_time = get_time_ns()
  local orphaned = {}

  -- Find orphaned spans
  local age_ms
  for span_id, span in pairs(session.active_spans) do
    age_ms = ns_to_ms(current_time - span.start_time)
    if age_ms > M._settings.orphan_timeout_ms then
      table.insert(orphaned, span_id)
    end
  end

  -- Clean up orphaned spans
  for _, span_id in ipairs(orphaned) do
    local label = session.span_labels[span_id]

    -- Remove from stack
    for i = #session.span_stack, 1, -1 do
      if session.span_stack[i] == span_id then
        table.remove(session.span_stack, i)
        break
      end
    end

    -- Remove from active spans
    session.active_spans[span_id] = nil
    session.span_labels[span_id] = nil

    -- Log warning
    if label then
      vim.schedule(function()
        vim.notify(
          string.format("Profiler: Orphaned span '%s' cleaned up (age: %.1f ms)", label, age_ms),
          vim.log.levels.WARN
        )
      end)
    end
  end
end

function M.enable()
  M._enabled = true
  M._next_span_id = 1
  require("checkmate.util").notify("Performance profiling enabled", vim.log.levels.INFO)
end

function M.disable()
  if M._active then
    M.stop_session()
  end
  M._enabled = false
  M._session = nil
  require("checkmate.util").notify("Performance profiling disabled", vim.log.levels.INFO)
end

function M.is_enabled()
  return M._enabled
end

function M.is_active()
  return M._active
end

function M.start_session(name)
  local util = require("checkmate.util")

  if not M._enabled then
    util.notify("Profiler not enabled. Use :CheckmateDebugProfilerStart", vim.log.levels.WARN)
    return false
  end

  if M._active then
    -- Force stop the current session
    M.stop_session()
  end

  -- Create fresh session - this ensures no old data persists
  M._session = new_session(name)
  M._active = true
  M._next_span_id = 1

  util.notify("Performance profiling session started", vim.log.levels.INFO)
  return true
end

function M.stop_session()
  if not M._active or not M._session then
    return false
  end

  local util = require("checkmate.util")

  -- Clean up any remaining active spans
  cleanup_orphaned_spans(M._session)

  -- Auto-close remaining spans in reverse order (LIFO)
  local stack = M._session.span_stack
  for i = #stack, 1, -1 do
    local span_id = stack[i]
    local label = M._session.span_labels[span_id]
    if label then
      M._stop_span(span_id, true) -- force stop
    end
  end

  -- Calculate session duration
  M._session.duration = ns_to_ms(get_time_ns() - M._session.start_time)

  -- Store session (keeping just the measurements for the report)
  M._last_session = {
    name = M._session.name,
    duration = M._session.duration,
    measurements = M._session.measurements,
    timestamp = os.time(),
  }

  -- Clear active session
  M._active = false
  M._session = nil

  util.notify("Performance profiling session stopped", vim.log.levels.INFO)
  return true
end

-- Internal function to stop a span by ID
function M._stop_span(span_id, force)
  if not M._session or not M._session.active_spans[span_id] then
    return nil
  end

  local span = M._session.active_spans[span_id]
  local label = M._session.span_labels[span_id]
  local duration_ms = ns_to_ms(get_time_ns() - span.start_time)

  -- Validate stack order (unless forced)
  if not force and #M._session.span_stack > 0 then
    local top_id = M._session.span_stack[#M._session.span_stack]
    if top_id ~= span_id then
      -- Find the span's position in the stack
      local stack_pos = nil
      for i, id in ipairs(M._session.span_stack) do
        if id == span_id then
          stack_pos = i
          break
        end
      end

      if stack_pos then
        vim.schedule(function()
          vim.notify(
            string.format(
              "Profiler: Span '%s' stopped out of order (expected '%s')",
              label,
              M._session.span_labels[top_id] or "unknown"
            ),
            vim.log.levels.WARN
          )
        end)
      end
    end
  end

  -- Initialize measurement if needed
  if not M._session.measurements[label] then
    M._session.measurements[label] = {
      count = 0,
      total_time = 0,
      self_time = 0,
      min_time = math.huge,
      max_time = 0,
      samples = {},
      children = {},
    }
  end

  local measurement = M._session.measurements[label]

  -- Update basic stats
  measurement.count = measurement.count + 1
  measurement.total_time = measurement.total_time + duration_ms
  measurement.min_time = math.min(measurement.min_time, duration_ms)
  measurement.max_time = math.max(measurement.max_time, duration_ms)

  -- Calculate self time
  local children_time = span.children_time or 0
  local self_time = math.max(0, duration_ms - children_time) -- Ensure non-negative
  measurement.self_time = measurement.self_time + self_time

  -- Update samples
  table.insert(measurement.samples, duration_ms)
  if #measurement.samples > M._settings.max_samples then
    table.remove(measurement.samples, 1)
  end

  -- Update parent's children time
  if span.parent_id and M._session.active_spans[span.parent_id] then
    local parent = M._session.active_spans[span.parent_id]
    parent.children_time = (parent.children_time or 0) + duration_ms

    -- Track child relationship
    local parent_label = M._session.span_labels[span.parent_id]
    if parent_label and M._session.measurements[parent_label] then
      local parent_measurement = M._session.measurements[parent_label]
      parent_measurement.children[label] = parent_measurement.children[label]
        or {
          count = 0,
          total_time = 0,
        }
      parent_measurement.children[label].count = parent_measurement.children[label].count + 1
      parent_measurement.children[label].total_time = parent_measurement.children[label].total_time + duration_ms
    end
  end

  -- Remove from stack
  for i = #M._session.span_stack, 1, -1 do
    if M._session.span_stack[i] == span_id then
      table.remove(M._session.span_stack, i)
      break
    end
  end

  -- Clean up
  M._session.active_spans[span_id] = nil
  M._session.span_labels[span_id] = nil

  return duration_ms
end

function M.start(label)
  if not M._enabled or not M._active or not M._session then
    return nil
  end

  -- Periodic cleanup of orphaned spans
  if M._next_span_id % 100 == 0 then
    cleanup_orphaned_spans(M._session)
  end

  -- Generate unique span ID
  local span_id = M._next_span_id
  M._next_span_id = M._next_span_id + 1

  -- Determine parent from stack
  local parent_id = nil
  if #M._session.span_stack > 0 then
    parent_id = M._session.span_stack[#M._session.span_stack]
  end

  -- Create span
  M._session.active_spans[span_id] = {
    start_time = get_time_ns(),
    parent_id = parent_id,
    children_time = 0,
  }

  -- Track label mapping
  M._session.span_labels[span_id] = label

  -- Push to stack
  table.insert(M._session.span_stack, span_id)

  return span_id
end

function M.stop(label_or_id)
  if not M._enabled or not M._active or not M._session then
    return nil
  end

  local span_id

  if type(label_or_id) == "number" then
    -- Direct span ID provided
    span_id = label_or_id
  elseif type(label_or_id) == "string" then
    -- Label provided - find most recent matching span in stack
    for i = #M._session.span_stack, 1, -1 do
      local id = M._session.span_stack[i]
      if M._session.span_labels[id] == label_or_id then
        span_id = id
        break
      end
    end
  elseif not label_or_id and #M._session.span_stack > 0 then
    -- No argument - stop the top of stack
    span_id = M._session.span_stack[#M._session.span_stack]
  end

  if not span_id then
    return nil
  end

  return M._stop_span(span_id, false)
end

-- Generate a performance report
function M.report()
  local measurements
  local session_info = ""

  if M._active and M._session then
    -- Use current session
    measurements = M._session.measurements
    session_info = string.format("Active Session: %s", M._session.name)
  elseif M._last_session then
    -- Use last completed session
    measurements = M._last_session.measurements
    session_info = string.format("Session: %s (Duration: %.2f ms)", M._last_session.name, M._last_session.duration or 0)
  else
    return "No performance data available. Start profiling with :CheckmateDebugProfilerStart"
  end

  local lines = {
    "Checkmate Performance Report",
    "============================",
    session_info,
    "",
  }

  -- Prepare and sort data
  local sorted = {}
  for name, data in pairs(measurements) do
    if data.count > 0 then
      -- Calculate average times
      data.avg_total = data.total_time / data.count
      data.avg_self = data.self_time / data.count
      table.insert(sorted, { name = name, data = data })
    end
  end

  -- Sort by total time descending
  table.sort(sorted, function(a, b)
    return a.data.total_time > b.data.total_time
  end)

  -- Summary table
  table.insert(lines, "Summary (sorted by total time)")
  table.insert(lines, string.rep("-", 100))
  table.insert(
    lines,
    string.format(
      "%-30s %8s %12s %12s %12s %8s",
      "Operation",
      "Calls",
      "Total (ms)",
      "Self (ms)",
      "Avg (ms)",
      "Min-Max"
    )
  )
  table.insert(lines, string.rep("-", 100))

  for _, item in ipairs(sorted) do
    local name = item.name
    local data = item.data
    local self_percent = data.total_time > 0 and (data.self_time / data.total_time) * 100 or 100

    table.insert(
      lines,
      string.format(
        "%-30s %8d %12.2f %12.2f %12.2f %8s",
        name:sub(1, 30),
        data.count,
        data.total_time,
        data.self_time,
        data.avg_total,
        string.format("%.1f-%.1f", data.min_time, data.max_time)
      )
    )
  end

  -- Detailed breakdown
  table.insert(lines, "")
  table.insert(lines, "Detailed Breakdown")
  table.insert(lines, string.rep("-", 100))

  for _, item in ipairs(sorted) do
    local name = item.name
    local data = item.data
    local self_percent = data.total_time > 0 and (data.self_time / data.total_time) * 100 or 100

    table.insert(lines, "")
    table.insert(lines, string.format("%s", name))
    table.insert(lines, string.rep("-", math.min(#name, 100)))
    table.insert(lines, string.format("  Calls:      %d", data.count))
    table.insert(lines, string.format("  Total time: %.2f ms", data.total_time))
    table.insert(lines, string.format("  Self time:  %.2f ms (%.1f%% of total)", data.self_time, self_percent))
    table.insert(lines, string.format("  Average:    %.2f ms", data.avg_total))
    table.insert(lines, string.format("  Range:      %.2f - %.2f ms", data.min_time, data.max_time))

    -- Show children if any
    if not vim.tbl_isempty(data.children) then
      local child_list = {}
      for child_name, child_data in pairs(data.children) do
        table.insert(child_list, {
          name = child_name,
          data = child_data,
          percent = (child_data.total_time / data.total_time) * 100,
        })
      end

      table.sort(child_list, function(a, b)
        return a.data.total_time > b.data.total_time
      end)

      table.insert(lines, "  Children:")
      for _, child in ipairs(child_list) do
        table.insert(
          lines,
          string.format(
            "    %-26s %4d calls, %8.2f ms (%.1f%%)",
            child.name:sub(1, 26),
            child.data.count,
            child.data.total_time,
            child.percent
          )
        )
      end
    end
  end

  return table.concat(lines, "\n")
end

-- Display the report in a floating window
function M.show_report()
  local report = M.report()

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(report, "\n"))
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

  -- Calculate window size
  local width = math.min(102, vim.o.columns - 4)
  local height = math.min(40, vim.o.lines - 4)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Create window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Checkmate Performance Report ",
    title_pos = "center",
  })

  -- Set options
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })

  -- Keymaps
  local opts = { noremap = true, silent = true, buffer = buf }
  vim.keymap.set("n", "q", ":close<CR>", opts)
  vim.keymap.set("n", "<Esc>", ":close<CR>", opts)

  -- Simple syntax highlighting
  vim.cmd([[
    syn clear
    syn match ProfilerHeader /^.*Performance Report$/
    syn match ProfilerHeader /^=\+$/
    syn match ProfilerSection /^Summary\|^Detailed Breakdown/
    syn match ProfilerSeparator /^-\+$/
    syn match ProfilerNumber /\d\+\.\d\+ ms/
    syn match ProfilerPercent /\d\+\.\d\+%/
    hi link ProfilerHeader Title
    hi link ProfilerSection Statement
    hi link ProfilerSeparator Comment
    hi link ProfilerNumber Number
    hi link ProfilerPercent Special
  ]])

  return buf, win
end

return M
