-- custom_reporter.lua
local term = require("term")
local colors = term.colors
local pretty = require("pl.pretty")
local io_write = io.write
local io_flush = io.flush
local string_format = string.format
local string_gsub = string.gsub

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
    return use_color and colors.yellow("→") or "→"
  end

  -- Add cyan for file names
  local function cyan_text(text)
    return use_color and colors.cyan(text) or text
  end

  -- Add dim for file paths
  local function dim_text(text)
    return use_color and colors.dim(text) or text
  end

  -- State
  local indentLevel = 0
  local passCount, failCount, skipCount = 0, 0, 0
  local totalTests = 0
  local fileCount = 0
  local filesPassed = 0
  local filesFailed = 0
  local startTime = 0
  local currentFile = nil
  local currentFileFailed = false
  local hasOutput = false -- Track if we've already output anything

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
    startTime = os.clock()
  end

  handler.suiteStart = function()
    startTime = os.clock()
    hasOutput = false
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
    println(cyan_text("● " .. filename))
    println(dim_text("  " .. currentFile))
    println("")

    hasOutput = true
    indentLevel = 1 -- Start the file's content at indent level 1
  end

  handler.fileEnd = function(element)
    -- Mark file as passed or failed
    if not currentFileFailed then
      filesPassed = filesPassed + 1
    else
      filesFailed = filesFailed + 1
    end

    -- Add space after a file ends
    println("")
  end

  -- Handle entering a describe/context block
  handler.describeStart = function(element)
    println(string.rep("  ", indentLevel) .. element.name)
    indentLevel = indentLevel + 1
  end

  -- Handle exiting a describe/context block
  handler.describeEnd = function(element)
    indentLevel = math.max(indentLevel - 1, 0)
  end

  handler.testStart = function(element, parent)
    totalTests = totalTests + 1
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
      println(indent .. red_mark() .. " " .. name)

      -- Get error details
      local t = (status == "failure") and handler.failures[#handler.failures] or handler.errors[#handler.errors]
      local msg = t.message or "Nil error"
      if type(msg) ~= "string" then
        msg = pretty.write(msg)
      end

      -- Indent error message with a different color and prefix
      local error_indent = indent .. "  "
      println(error_indent .. colors.red("❯ " .. element.name))

      -- Format multi-line error message
      local first_line = true
      for line in msg:gmatch("[^\r\n]+") do
        -- Skip duplicated test name in error
        if first_line and line:match(element.name) then
          -- Skip
        else
          println(error_indent .. "  " .. line)
        end
        first_line = false
      end

      -- Add file/line info if available in trace
      if t.trace and t.trace.short_src and t.trace.currentline then
        println(error_indent .. "  " .. dim_text("at " .. t.trace.short_src .. ":" .. t.trace.currentline))
      end

      println("") -- Add empty line after error
    end

    io_flush()
  end

  handler.error = function() end

  handler.suiteEnd = function(element)
    -- Only print summary at the very end
    if element.descriptor ~= "suite" then
      return
    end

    -- Calculate duration
    local duration = os.clock() - startTime
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
    local test_text = string_format("Tests       %d passed", passCount)
    if failCount > 0 then
      test_text = test_text .. string_format(", %d failed", failCount)
    end
    if skipCount > 0 then
      test_text = test_text .. string_format(", %d skipped", skipCount)
    end
    test_text = test_text .. string_format(", %d total", totalTests)
    println(test_text)

    -- Time info
    println(string_format("Time        %s", duration_text))

    -- Final status line
    if failCount > 0 then
      println(colors.red("\n✗ Tests failed. See above for more details."))
    else
      println(colors.green("\n✓ All tests passed!"))
    end

    io_flush()
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
  busted.subscribe({ "suite", "end" }, handler.suiteEnd)

  return handler
end
