return {
  spec = {
    -- {
    --   "sainnhe/sonokai",
    --   lazy = false,
    --   priority = 1000,
    --   config = function()
    --     -- Optionally configure and load the colorscheme
    --     -- directly inside the plugin declaration.
    --     vim.g.sonokai_enable_italic = true
    --     vim.cmd.colorscheme("sonokai")
    --   end,
    -- },
  },
  checkmate = require("checkmate_config").with({
    todo_states = {
      unchecked = {
        marker = "☐",
      },
      checked = { marker = "✔" },
      in_progress = {
        marker = "◐",
        markdown = ".", -- Saved as `- [.]`
        type = "incomplete", -- Counts as "not done"
        order = 50,
      },
      cancelled = {
        marker = "✗",
        markdown = "c", -- Saved as `- [c]`
        type = "complete", -- Counts as "done"
        order = 2,
      },
      on_hold = {
        marker = "⏸",
        markdown = "/", -- Saved as `- [/]`
        type = "inactive", -- Ignored in counts
        order = 100,
      },
    },
    todo_count_position = "eol",
    todo_count_formatter = function(completed, total)
      return string.format("%.0f%%", completed / total * 100)
    end,
    todo_count_recursive = false,
    style = {
      CheckmateTodoCountIndicator = { fg = "#f5e1bc", bg = "#1f1e26" },
      CheckmateCheckedMarker = { fg = "#59db4b", bold = true },
      CheckmateCheckedMainContent = { strikethrough = false },
      CheckmateUncheckedMarker = { fg = "#b6dadb", bold = false },
      CheckmateInProgressMarker = { fg = "#75c3ff", bold = true },
      CheckmateCancelledMarker = { fg = "#fc3268", bold = true },
      CheckmateOnHoldMarker = { fg = "#cfc0b4" },
      CheckmateOnHoldMainContent = { fg = "#cfc0b4" },
    },
    archive = {
      heading = { title = "Completed" },
    },
    metadata = {
      url = {
        style = { fg = "#aea0b8", italic = true },
      },
      branch = {
        style = { fg = "#ff96d0" },
      },
      issue = {
        key = "<leader>Tmi",
        choices = function(_, callback)
          vim.system({
            "curl",
            "-sS",
            "https://api.github.com/repos/bngarren/checkmate.nvim/issues?state=all&per_page=100",
          }, { text = true }, function(out)
            if out.code ~= 0 then
              callback({})
              return
            end

            local ok, issues = pcall(vim.json.decode, out.stdout)
            if not ok or type(issues) ~= "table" then
              callback({})
              return
            end

            local result = vim.tbl_map(function(issue)
              return string.format("#%d %s", issue.number, issue.title)
            end, issues)

            callback(result)
          end)
        end,
        style = { fg = "#ff75a8" },
      },
    },
  }),
}
