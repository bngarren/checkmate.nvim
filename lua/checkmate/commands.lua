---@class CheckmateCommand
---@field name string Command name (without "Checkmate" prefix)
---@field cmd string Full command name
---@field func function Function to call
---@field opts table Command options

local M = {}

-- Set to true during development to include debug commands
local INCLUDE_DEBUG_COMMANDS = false

-- Regular commands that are always available
---@type CheckmateCommand[]
M.regular_commands = {
  {
    name = "Toggle",
    cmd = "CheckmateToggle",
    func = function()
      require("checkmate").toggle()
    end,
    opts = { desc = "Toggle todo item state" },
  },
  {
    name = "Create",
    cmd = "CheckmateCreate",
    func = function()
      require("checkmate").create()
    end,
    opts = { desc = "Create a new todo item" },
  },
  {
    name = "Check",
    cmd = "CheckmateCheck",
    func = function()
      require("checkmate").check()
    end,
    opts = { desc = "Set todo item to checked state" },
  },
  {
    name = "Uncheck",
    cmd = "CheckmateUncheck",
    func = function()
      require("checkmate").uncheck()
    end,
    opts = { desc = "Set todo item to unchecked state" },
  },
  {
    name = "Remove All Metadata",
    cmd = "CheckmateRemoveAllMetadata",
    func = function()
      require("checkmate").remove_all_metadata()
    end,
    opts = { desc = "Remove all metadata from todo item" },
  },
  {
    name = "Archive",
    cmd = "CheckmateArchive",
    func = function()
      require("checkmate").archive()
    end,
    opts = { desc = "Archive checked todo items" },
  },
  {
    name = "Lint",
    cmd = "CheckmateLint",
    func = function()
      require("checkmate").lint()
    end,
    opts = { desc = "Identify Checkmate formatting issues" },
  },
  -- TODO: auto-fix

  --[[ {
    name = "Auto Fix",
    cmd = "CheckmateFix",
    func = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local linter = require("checkmate.linter")
      local result, fixed = linter.fix_issues(bufnr)

      if result then
        if fixed > 0 then
          vim.notify("Auto fixable issues fixed", vim.log.levels.INFO)
        else
          vim.notify("No auto fixable issues found", vim.log.levels.INFO)
        end
      else
        vim.notify("Could not fix auto-fixable issues", vim.log.levels.WARN)
      end
    end,
    opts = { desc = "Check for Markdown formatting issues" },
  }, ]]
}

-- Debug commands only available when INCLUDE_DEBUG_COMMANDS is true
---@type CheckmateCommand[]
M.debug_commands = {
  {
    name = "DebugLog",
    cmd = "CheckmateDebugLog",
    func = function()
      require("checkmate").debug_log()
    end,
    opts = { desc = "Open the debug log" },
  },
  {
    name = "DebugClear",
    cmd = "CheckmateDebugClear",
    func = function()
      require("checkmate").debug_clear()
    end,
    opts = { desc = "Clear the debug log" },
  },
  {
    name = "DebugAtCursor",
    cmd = "CheckmateDebugAtCursor",
    func = function()
      require("checkmate").debug_at_cursor()
    end,
    opts = { desc = "Inspect the todo item under the cursor" },
  },
  {
    name = "DebugPrintTodoMap",
    cmd = "CheckmateDebugPrintTodoMap",
    func = function()
      require("checkmate").debug_print_todo_map()
    end,
    opts = { desc = "Print this buffer's todo_map" },
  },
  {
    name = "DebugProfilerStart",
    cmd = "CheckmateDebugProfilerStart",
    func = function()
      require("checkmate.profiler").start_session()
    end,
    opts = { desc = "Start performance profiling" },
  },
  {
    name = "DebugProfilerStop",
    cmd = "CheckmateDebugProfilerStop",
    func = function()
      local profiler = require("checkmate.profiler")
      profiler.stop_session()
    end,
    opts = { desc = "Stop performance profiling" },
  },
  {
    name = "DebugProfilerReport",
    cmd = "CheckmateDebugProfilerReport",
    func = function()
      local profiler = require("checkmate.profiler")
      if profiler.is_active() then
        profiler.stop_session()
      end
      require("checkmate.profiler").show_report()
    end,
    opts = { desc = "Show performance profiling report" },
  },
}

-- Combine commands based on debug flag
M.commands = {}

-- Register all commands
function M.setup()
  -- Always include regular commands
  for _, command in ipairs(M.regular_commands) do
    table.insert(M.commands, command)
  end

  -- Include debug commands if enabled
  if INCLUDE_DEBUG_COMMANDS then
    for _, command in ipairs(M.debug_commands) do
      table.insert(M.commands, command)
    end
  end

  -- Register all selected commands
  for _, command in ipairs(M.commands) do
    vim.api.nvim_create_user_command(command.cmd, command.func, command.opts)
  end
end

return M
