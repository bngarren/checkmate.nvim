---@class CheckmateCommand
---@field name string Command name (without "Checkmate" prefix)
---@field cmd string Full command name
---@field func function Function to call
---@field opts table Command options

local M = {}

-- Set to true during development to include debug commands
local INCLUDE_DEBUG_COMMANDS = true

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
