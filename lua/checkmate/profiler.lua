local M = {}

M._enabled = false
M._active = false
M._session = nil
M._next_span_id = 1

M._settings = {
  max_samples = 10,
  orphan_timeout_ms = 5000,
}

local function get_time_ns()
  return vim.uv.hrtime()
end

local function ns_to_ms(ns)
  return ns / 1000000
end

local function new_session(name)
  return {
    name = name or os.date("%Y-%m-%d %H:%M:%S"),
    start_time = get_time_ns(),
    measurements = {}, -- label -> measurement data
    active_spans = {}, -- span_id -> span data
    completed_spans = {}, -- span_id -> stopped span info (duration, label)
    span_stack = {}, -- stack of span IDs (LIFO)
    span_labels = {}, -- span_id -> label mapping
  }
end

local function get_caller_info(skip_level)
  skip_level = skip_level or 2
  local info = debug.getinfo(skip_level, "Sln")

  if not info then
    return {
      source = "<unknown>",
      func = "<unknown>",
      line = 0,
      full = "<unknown>",
    }
  end

  -- Extract filename from path
  local source = info.source:match("([^/\\]+)$") or info.source
  local func_name = info.name or "<anonymous>"
  local line = info.currentline or 0

  return {
    source = source,
    func = func_name,
    line = line,
    full = string.format("%s:%d in %s()", source, line, func_name),
  }
end

local function cleanup_orphaned_spans(session)
  if not session or vim.tbl_isempty(session.active_spans) then
    return
  end

  local current_time = get_time_ns()
  local orphaned = {}
  local age_ms
  for span_id, span in pairs(session.active_spans) do
    age_ms = ns_to_ms(current_time - span.start_time)
    if age_ms > M._settings.orphan_timeout_ms then
      table.insert(orphaned, span_id)
    end
  end

  for _, span_id in ipairs(orphaned) do
    local label = session.span_labels[span_id]
    for i = #session.span_stack, 1, -1 do
      if session.span_stack[i] == span_id then
        table.remove(session.span_stack, i)
        break
      end
    end
    session.active_spans[span_id] = nil
    session.span_labels[span_id] = nil
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
    util.notify("Profiler not enabled. Use :Checkmate debug profiler enable", vim.log.levels.WARN)
    return false
  end
  if M._active then
    M.stop_session()
  end
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
  cleanup_orphaned_spans(M._session)
  local stack = M._session.span_stack
  for i = #stack, 1, -1 do
    local span_id = stack[i]
    local label = M._session.span_labels[span_id]
    if label then
      M._stop_span(span_id, true)
    end
  end
  M._session.duration = ns_to_ms(get_time_ns() - M._session.start_time)
  M._last_session = {
    name = M._session.name,
    duration = M._session.duration,
    measurements = M._session.measurements,
    timestamp = os.time(),
  }
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

  -- Remove from stack
  for i = #M._session.span_stack, 1, -1 do
    if M._session.span_stack[i] == span_id then
      table.remove(M._session.span_stack, i)
      break
    end
  end

  -- Remove from active
  M._session.active_spans[span_id] = nil
  M._session.span_labels[span_id] = nil

  -- -- Save to completed_spans for parent lookup
  M._session.completed_spans[span_id] = {
    label = label,
    duration = duration_ms,
    children = span.children,
  }

  -- -- Initialize measurement if needed
  if not M._session.measurements[label] then
    M._session.measurements[label] = {
      count = 0,
      total_time = 0,
      self_time = 0,
      min_time = math.huge,
      max_time = 0,
      samples = {},
      children = {}, -- child label -> count, total_time
      callers = {},
    }
  end

  local measurement = M._session.measurements[label]

  -- -- Update basic stats
  measurement.count = measurement.count + 1
  measurement.total_time = measurement.total_time + duration_ms
  measurement.min_time = math.min(measurement.min_time, duration_ms)
  measurement.max_time = math.max(measurement.max_time, duration_ms)
  table.insert(measurement.samples, duration_ms)
  if #measurement.samples > M._settings.max_samples then
    table.remove(measurement.samples, 1)
  end

  -- -- SUM all direct child durations from completed_spans
  local children_time = 0
  local child_label_counts = {}
  local child_label_times = {}
  if span.children and #span.children > 0 then
    for _, child_id in ipairs(span.children) do
      local child_info = M._session.completed_spans[child_id]
      if child_info then
        children_time = children_time + child_info.duration
        -- track for report
        child_label_counts[child_info.label] = (child_label_counts[child_info.label] or 0) + 1
        child_label_times[child_info.label] = (child_label_times[child_info.label] or 0) + child_info.duration
      end
    end
  end

  -- -- Store in measurement.children for report
  for child_label, count in pairs(child_label_counts) do
    measurement.children[child_label] = measurement.children[child_label] or { count = 0, total_time = 0 }
    measurement.children[child_label].count = measurement.children[child_label].count + count
    measurement.children[child_label].total_time = measurement.children[child_label].total_time
      + (child_label_times[child_label] or 0)
  end

  local self_time = math.max(0, duration_ms - children_time)
  measurement.self_time = measurement.self_time + self_time

  -- Store caller information
  if span.caller then
    local caller_key = span.caller.full
    if not measurement.callers[caller_key] then
      measurement.callers[caller_key] = {
        count = 0,
        total_time = 0,
        avg_time = 0,
      }
    end
    measurement.callers[caller_key].count = measurement.callers[caller_key].count + 1
    measurement.callers[caller_key].total_time = measurement.callers[caller_key].total_time + duration_ms
    measurement.callers[caller_key].avg_time = measurement.callers[caller_key].total_time
      / measurement.callers[caller_key].count
  end

  return duration_ms
end

function M.start(label)
  if not M._enabled or not M._active or not M._session then
    return nil
  end

  if M._next_span_id % 100 == 0 then
    cleanup_orphaned_spans(M._session)
  end

  local span_id = M._next_span_id
  M._next_span_id = M._next_span_id + 1

  local parent_id = nil
  if #M._session.span_stack > 0 then
    parent_id = M._session.span_stack[#M._session.span_stack]
  end

  local caller = get_caller_info(4)

  M._session.active_spans[span_id] = {
    start_time = get_time_ns(),
    parent_id = parent_id,
    children = {}, -- span_id list
    caller = caller,
  }

  M._session.span_labels[span_id] = label

  -- track in parent's children array
  if parent_id then
    local parent = M._session.active_spans[parent_id]
    table.insert(parent.children, span_id)
  end

  table.insert(M._session.span_stack, span_id)

  return span_id
end

function M.stop(label_or_id)
  if not M._enabled or not M._active or not M._session then
    return nil
  end

  local span_id

  if type(label_or_id) == "number" then
    span_id = label_or_id
  elseif type(label_or_id) == "string" then
    for i = #M._session.span_stack, 1, -1 do
      local id = M._session.span_stack[i]
      if M._session.span_labels[id] == label_or_id then
        span_id = id
        break
      end
    end
  elseif not label_or_id and #M._session.span_stack > 0 then
    span_id = M._session.span_stack[#M._session.span_stack]
  end

  if not span_id then
    return nil
  end

  return M._stop_span(span_id, false)
end

local function calculate_percentile(samples, p)
  if #samples == 0 then
    return 0
  end
  local sorted = vim.deepcopy(samples)
  table.sort(sorted)
  local idx = math.ceil(#sorted * p / 100)
  return sorted[math.min(idx, #sorted)]
end

function M.report()
  local measurements
  local session_info = ""
  if M._active and M._session then
    measurements = M._session.measurements
    session_info = string.format("Active Session: %s", M._session.name)
  elseif M._last_session then
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

  local sorted = {}
  for name, data in pairs(measurements) do
    if data.count > 0 then
      data.avg_total = data.total_time / data.count
      data.avg_self = data.self_time / data.count
      data.p50 = calculate_percentile(data.samples, 50)
      data.p95 = calculate_percentile(data.samples, 95)
      data.p99 = calculate_percentile(data.samples, 99)
      table.insert(sorted, { name = name, data = data })
    end
  end

  table.sort(sorted, function(a, b)
    return a.data.total_time > b.data.total_time
  end)

  table.insert(lines, "Summary (sorted by total time)")
  table.insert(lines, string.rep("-", 100))
  table.insert(
    lines,
    string.format(
      "%-30s %8s %12s %12s %8s %8s %8s",
      "Operation",
      "Calls",
      "Total (ms)",
      "Self (ms)",
      "P50",
      "P95",
      "Min-Max"
    )
  )
  table.insert(lines, string.rep("-", 100))

  for _, item in ipairs(sorted) do
    local name = item.name
    local data = item.data
    table.insert(
      lines,
      string.format(
        "%-30s %8d %12.2f %12.2f %8.2f %8.2f %8s",
        name:sub(1, 30),
        data.count,
        data.total_time,
        data.self_time,
        data.p50,
        data.p95,
        string.format("%.1f-%.1f", data.min_time, data.max_time)
      )
    )
  end

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

    -- Show caller breakdown
    if not vim.tbl_isempty(data.callers) then
      local caller_list = {}
      for caller_key, caller_data in pairs(data.callers) do
        table.insert(caller_list, {
          key = caller_key,
          data = caller_data,
        })
      end
      -- Sort by frequency
      table.sort(caller_list, function(a, b)
        return a.data.count > b.data.count
      end)

      table.insert(lines, "  Called from:")
      local shown = 0
      for _, caller in ipairs(caller_list) do
        if shown >= 5 then
          table.insert(lines, string.format("    ... and %d more locations", #caller_list - shown))
          break
        end
        table.insert(
          lines,
          string.format(
            "    %-40s %4d calls, %8.2f ms avg",
            caller.key:sub(1, 40),
            caller.data.count,
            caller.data.avg_time
          )
        )
        shown = shown + 1
      end
    end
  end

  return table.concat(lines, "\n")
end

function M.show_report()
  local report = M.report()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(report, "\n"))
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

  local width = math.min(102, vim.o.columns - 4)
  local height = math.min(40, vim.o.lines - 4)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

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

  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("cursorline", true, { win = win })

  local opts = { noremap = true, silent = true, buffer = buf }
  vim.keymap.set("n", "q", ":close<CR>", opts)
  vim.keymap.set("n", "<Esc>", ":close<CR>", opts)

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
