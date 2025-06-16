---@class CheckmateCommand
---@field name string Command name (without "Checkmate" prefix)
---@field cmd string Full command name
---@field func function Function to call
---@field opts table Command options

---@deprecated
local M = {}

local has_shown_deprecation_warning = false

---@type CheckmateCommand[]
M.commands = {
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
  {
    name = "Select Metadata Value",
    cmd = "CheckmateSelectMetadataValue",
    func = function()
      require("checkmate").select_metadata_value()
    end,
    opts = { desc = "Update the value in a metadata tag" },
  },
}

-- Register all commands
function M.setup(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  for _, command in ipairs(M.commands) do
    vim.api.nvim_buf_create_user_command(bufnr, command.cmd, function()
      if not has_shown_deprecation_warning then
        vim.notify(
          string.format("'%s' is deprecated. Use `:Checkmate subcommand` syntax.", command.cmd),
          vim.log.levels.WARN
        )
        has_shown_deprecation_warning = true
      end
      command.func()
    end, command.opts)
  end
end

function M.dispose(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, command in ipairs(M.commands) do
    pcall(function()
      vim.api.nvim_buf_del_user_command(bufnr, command.cmd)
    end)
  end
  M.commands = {}
end

return M
