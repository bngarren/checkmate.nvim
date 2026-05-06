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
      require("checkmate.debug").at_cursor()
    end,
    rtxt = "w",
  },
  { name = "separator" },
  {
    name = "⏿ Show Todo Map",
    hl = "Normal",
    cmd = function()
      require("checkmate.debug").print_todo_map()
    end,
    rtxt = "t",
  },
  {
    name = "⏿ Show Todo Stats",
    hl = "Normal",
    cmd = function()
      require("checkmate.debug").print_todo_map_stats()
    end,
    rtxt = "s",
  },
  {
    name = "⏿ Show Config",
    hl = "Normal",
    cmd = function()
      require("checkmate.debug").print_config()
    end,
    rtxt = "c",
  },
  {
    name = "ℬ Show Buffer Local Vars",
    hl = "Normal",
    cmd = function()
      require("checkmate.debug").print_buf_local_vars(0)
    end,
    rtxt = "b",
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
          require("checkmate.debug").clear_highlight()
        end,
        rtxt = "c",
      },
      {
        name = "🆇  Clear all highlights",
        hl = "ExRed",
        cmd = function()
          require("checkmate.debug").clear_all_highlights()
        end,
        rtxt = "a",
      },
    },
  },
  { name = "separator" },
  {
    name = "🔍 Open Log File (floating)",
    hl = "Normal",
    cmd = function()
      require("checkmate.debug").log({ type = "floating" })
    end,
    rtxt = "L",
  },
  {
    name = "✍︎ Log...",
    hl = "Normal",
    items = {
      {
        name = "🔍 Open Log File (split)",
        hl = "Normal",
        cmd = function()
          require("checkmate.debug").log({ type = "split" })
        end,
        rtxt = "S",
      },
      { name = "separator" },
      {
        name = "🔄 Clear Log File",
        hl = "Normal",
        cmd = function()
          require("checkmate.debug").clear_log()
        end,
        rtxt = "C",
      },
    },
  },
  {
    name = "⌚︎ Profiler...",
    hl = "Normal",
    items = {
      {
        name = "▶︎ Start Profiling Session",
        hl = "Normal",
        cmd = function()
          require("checkmate.profiler").start_session()
        end,
        rtxt = "1",
      },
      {
        name = "◼︎ Stop Profiling Session",
        hl = "Normal",
        cmd = function()
          require("checkmate.profiler").stop_session()
        end,
        rtxt = "2",
      },
      {
        name = "⎘ Show Report",
        hl = "Normal",
        cmd = function()
          require("checkmate.profiler").show_report()
        end,
        rtxt = "3",
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
