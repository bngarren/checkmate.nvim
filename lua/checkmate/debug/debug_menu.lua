local M = {}

-- `https://github.com/nvzone/menu`
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
    hl = "Exblue",
    cmd = function()
      require("checkmate").debug.at_cursor()
    end,
    rtxt = "w",
  },
  { name = "separator" },
  {
    name = "⏿ Show Todo Map",
    hl = "Normal",
    cmd = function()
      require("checkmate").debug.print_todo_map()
    end,
    rtxt = "t",
  },
  {
    name = "⏿ Show Config",
    hl = "Normal",
    cmd = function()
      require("checkmate").debug.print_config()
    end,
    rtxt = "c",
  },
  { name = "separator" },
  {
    name = "☀︎ Highlight",
    hl = "ExGreen",
    items = {
      {
        name = "Todo > First Inline Range",
        hl = "Normal",
        cmd = "Checkmate debug hl todo inline",
        rtxt = "i",
      },
      {
        name = "Todo > Semantic Range",
        hl = "Normal",
        cmd = "Checkmate debug hl todo semantic",
        rtxt = "s",
      },
      {
        name = "Todo > TS Range",
        hl = "Normal",
        cmd = "Checkmate debug hl todo ts",
        rtxt = "t",
      },
      {
        name = "Todo > Metadata",
        hl = "Normal",
        cmd = "Checkmate debug hl todo metadata",
        rtxt = "m",
      },
      { name = "separator" },
      {
        name = "🆇  Clear highlight under cursor",
        hl = "ExRed",
        cmd = function()
          require("checkmate").debug.clear_highlight()
        end,
        rtxt = "c",
      },
      {
        name = "🆇  Clear all highlights",
        hl = "ExRed",
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
  menu_plugin.open(menu, { border = true })
end

return M
