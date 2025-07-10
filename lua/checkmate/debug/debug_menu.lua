local M = {}

local menu_plugin
local has_menu_plugin = function()
  if not menu_plugin then
    local ok, res = pcall(require, "menu")
    if not ok then
      return false
    end
    menu_plugin = res
  end
  return true
end

local menu = {
  {
    name = "꛷ What's here?",
    hl = "Type",
    cmd = function()
      require("checkmate").debug.at_cursor()
    end,
    rtxt = "w",
  },
  {
    name = "  Show Todo Map",
    cmd = function()
      require("checkmate").debug.print_todo_map()
    end,
    rtxt = "t",
  },
  {
    name = "  Show Config",
    cmd = function()
      require("checkmate").debug.print_config()
    end,
    rtxt = "c",
  },
  {
    name = "☀︎ Highlight",
    hl = "ExGreen",
    rtxt = "h",
    items = {
      {
        name = "Todo > First Inline Range",
        cmd = "Checkmate debug hl todo inline",
        rtxt = "i",
      },
      {
        name = "Todo > Semantic Range",
        cmd = "Checkmate debug hl todo semantic",
        rtxt = "s",
      },
      {
        name = "Todo > TS Range",
        cmd = "Checkmate debug hl todo ts",
        rtxt = "t",
      },
      {
        name = "Todo > Metadata",
        cmd = "Checkmate debug hl todo metadata",
        rtxt = "m",
      },
      { name = "separator" },
      {
        name = "Clear all highlights",
        cmd = function()
          require("checkmate").debug.clear_all_highlights()
        end,
        rtxt = "a",
      },
    },
  },
}

function M.open()
  if not has_menu_plugin() then
    vim.notify("Missing `nvzone/menu` menu plugin", vim.log.levels.WARN)
    return
  end
  menu_plugin.open(menu, {})
end

return M
