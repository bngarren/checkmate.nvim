---@diagnostic disable: unused-local
---
local term = require("term")
local colors = term.colors
local pretty = require("pl.pretty")
local io_write = io.write
local io_flush = io.flush
local string_format = string.format

local function println(msg)
  io_write(msg .. "\n")
end

return function(options)
  local busted = require("busted")
  local handler = require("busted.outputHandlers.base")()

  -- Parse options
  local use_color = false
  for _, v in ipairs(options.arguments or {}) do
    if v == "color" then
      use_color = true
      break
    end
  end

  -- Use busted's built-in term.color lib
  local function green_mark()
    return use_color and colors.green("✓") or "✓"
  end
  local function red_mark()
    return use_color and colors.red("✗") or "✗"
  end
  local function yellow_mark()
    return use_color and colors.yellow("☉") or "☉"
  end

  local function underscore_text(text)
    return use_color and colors.underscore(text) or text
  end

  local function cyan_text(text)
    return use_color and colors.cyan(text) or text
  end

  local function magenta_text(text)
    return use_color and colors.magenta(text) or text
  end

  local function dim_text(text)
    return use_color and colors.dim(text) or text
  end

  -- Format error messages consistently
  local function format_error(err_obj, context_name)
    local msg = err_obj.message or "Unknown error"
    if type(msg) ~= "string" then
      msg = pretty.write(msg)
    end

    local context = context_name or err_obj.name or "Unknown context"
    local trace = err_obj.trace or {}
    local formatted = ""

    -- Add error message with proper indentation
    local first_line = false
    for line in msg:gmatch("[^\r\n]+") do
      if not first_line then
        formatted = formatted .. colors.red("➤") .. " " .. line .. "\n"
        first_line = true
      else
        formatted = formatted .. "  " .. line .. "\n"
      end
    end

    return formatted
  end

  -- Track failed tests for summary
  local failedTests = {}

  -- State
  local indentLevel = 0
  local passCount, failCount, skipCount = 0, 0, 0
  local totalTests = 0
  local fileCount = 0
  local filesPassed = 0
  local filesFailed = 0
  local currentFile = nil
  local currentFileFailed = false
  local hasOutput = false -- Track if we've already output anything
  local fileDurations = {}

  handler.suiteReset = function()
    indentLevel = 0
    passCount, failCount, skipCount = 0, 0, 0
    totalTests = 0
    fileCount = 0
    filesPassed = 0
    filesFailed = 0
    currentFile = nil
    currentFileFailed = false
    hasOutput = false
    fileDurations = {}
    return nil, true
  end

  handler.suiteStart = function(suite)
    -- Use Busted's built-in timing
    hasOutput = false
    return nil, true
  end

  -- Handle file events
  handler.fileStart = function(element)
    currentFile = element.name
    fileCount = fileCount + 1
    currentFileFailed = false -- Reset for new file

    if hasOutput then
      -- Add blank line between files
      println("")
    end

    -- Extract just the filename part with clever string patterns
    local filename = currentFile:match("([^/\\]+)$") or currentFile

    -- Output file header
    println(magenta_text("◼︎ ") .. underscore_text(filename))
    println("")

    hasOutput = true
    indentLevel = 1 -- Start the file's content at indent level 1

    return nil, true
  end

  handler.fileEnd = function(element)
    -- Store the file's duration from Busted's own timing
    local duration = element.duration
    if duration then
      if fileDurations and currentFile then
        fileDurations[currentFile] = duration
      end
      -- Show file duration
      println(dim_text(string.format("  Time: %.3fs", duration)))
    end

    -- Mark file as passed or failed
    if not currentFileFailed then
      filesPassed = filesPassed + 1
    else
      filesFailed = filesFailed + 1
    end

    -- Add space after a file ends
    println("")

    return nil, true
  end

  -- Handle entering a describe/context block
  handler.describeStart = function(element)
    println(string.rep("  ", indentLevel) .. cyan_text(element.name))
    indentLevel = indentLevel + 1
    return nil, true
  end

  -- Handle exiting a describe/context block
  handler.describeEnd = function(element)
    indentLevel = math.max(indentLevel - 1, 0)
    return nil, true
  end

  handler.testStart = function(element, parent)
    totalTests = totalTests + 1
    return nil, true
  end

  handler.testEnd = function(element, parent, status)
    -- Extract just the test name (not the full hierarchy with describe blocks)
    local name = element.name
    local indent = string.rep("  ", indentLevel)

    if status == "success" then
      passCount = passCount + 1
      println(indent .. green_mark() .. " " .. name)
    elseif status == "pending" then
      skipCount = skipCount + 1
      println(indent .. yellow_mark() .. " " .. name .. " (skipped)")
    elseif status == "failure" or status == "error" then
      failCount = failCount + 1
      currentFileFailed = true -- Mark the current file as failed
      println(indent .. red_mark() .. " " .. colors.red(name))

      -- Get error details
      local t = (status == "failure") and handler.failures[#handler.failures] or handler.errors[#handler.errors]

      println(t.trace.traceback)

      -- Store failed test info for summary
      table.insert(failedTests, {
        name = t.name,
        file = currentFile,
      })

      -- Format and display error
      local error_indent = indent .. "  "
      local error_lines = format_error(t, element.name)
      for line in error_lines:gmatch("[^\r\n]+") do
        println(error_indent .. line)
      end

      println("") -- Add empty line after error
    end

    io_flush()
    return nil, true
  end

  -- Improved error handler for all types of errors
  handler.error = function(element, message, parent, trace)
    currentFileFailed = true

    return nil, true
  end

  -- Handle specific failure/error events
  handler.failure = function(element, parent, message, trace)
    if element.descriptor ~= "it" then
      handler.error(element, parent, message, trace)
    end
    return nil, true
  end

  handler.suiteEnd = function(suite)
    -- Only print summary at the very end
    if not suite or suite.descriptor ~= "suite" then
      return nil, true
    end

    -- Calculate duration using Busted's built-in timing
    local duration = suite.duration
    local duration_text = string_format("%.2fs", duration)

    -- Print summary border
    println(
      dim_text(
        "─────────────────────────────────────────────────"
      )
    )

    -- Print test files results
    local result_text = string_format("Test Files  %d passed", filesPassed)

    -- Only show failures if there were any
    if filesFailed > 0 then
      result_text = result_text .. string_format(", %d failed", filesFailed)
    end

    -- Total file count
    result_text = result_text .. string_format(", %d total", fileCount)
    println(result_text)

    -- Print test counts
    local test_text = "Tests       "
    if failCount == 0 then
      test_text = test_text .. colors.green(string_format("%d passed", passCount))
    else
      test_text = test_text .. string_format("%d passed", passCount)
    end
    if failCount > 0 then
      test_text = test_text .. ", " .. colors.red(string_format("%d failed", failCount))
    end
    if skipCount > 0 then
      test_text = test_text .. ", " .. colors.yellow(string_format("%d skipped", skipCount))
    end
    test_text = test_text .. string_format(" (%d total)", totalTests)
    println(test_text)

    -- Time info - using Busted's own timing for accuracy
    println(string_format("Time        %s", duration_text))

    -- Final status line
    if failCount > 0 then
      -- Add failed tests summary
      println("\nFailed Tests:")
      for i, test in ipairs(failedTests) do
        println(dim_text(string.format("  %d) ", i)) .. colors.red(test.name) .. dim_text("  " .. test.file))
      end
    else
      println(colors.green("\n✓ All tests passed!"))
    end

    io_flush()
    return nil, true
  end

  -- Subscribe events
  busted.subscribe({ "suite", "reset" }, handler.suiteReset)
  busted.subscribe({ "suite", "start" }, handler.suiteStart)
  busted.subscribe({ "file", "start" }, handler.fileStart)
  busted.subscribe({ "file", "end" }, handler.fileEnd)
  busted.subscribe({ "describe", "start" }, handler.describeStart)
  busted.subscribe({ "describe", "end" }, handler.describeEnd)
  busted.subscribe({ "test", "start" }, handler.testStart, { predicate = handler.cancelOnPending })
  busted.subscribe({ "test", "end" }, handler.testEnd, { predicate = handler.cancelOnPending })
  busted.subscribe({ "error" }, handler.error)
  busted.subscribe({ "failure" }, handler.failure)
  busted.subscribe({ "suite", "end" }, handler.suiteEnd)

  return handler
end
