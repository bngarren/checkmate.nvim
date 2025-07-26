return {
  spec = {
    {
      "L3MON4D3/LuaSnip",
      -- follow latest release.
      version = "v2.*", -- Replace <CurrentMajor> by the latest released major (first number of latest release)
      config = function()
        local luasnip = require("luasnip")
        luasnip.setup({
          updateevents = "TextChanged,TextChangedI",
          enable_autosnippets = true,
        })

        vim.keymap.set({ "i" }, "<C-K>", function()
          luasnip.expand({})
        end, { silent = true })

        vim.keymap.set({ "i" }, "<c-u>", function()
          require("checkmate").select_metadata_value()
        end)

        vim.keymap.set({ "i", "s" }, "<C-E>", function()
          if luasnip.choice_active() then
            luasnip.change_choice(1)
          end
        end, { silent = true })

        local ns = vim.api.nvim_create_namespace("my_luasnip_trig")

        vim.api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI" }, {
          group = vim.api.nvim_create_augroup("LuasnipTriggerHighlight", { clear = true }),
          callback = function()
            local ok, ls = pcall(require, "luasnip")
            if not ok then
              return
            end
            local line = vim.api.nvim_get_current_line()
            local row = vim.api.nvim_win_get_cursor(0)[1] - 1

            -- clear old highlight
            vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)

            local by_ft = ls.available(function(snip)
              return snip
            end)
            local snippets = by_ft[vim.bo.filetype] or {}

            for _, snip in ipairs(snippets) do
              -- check if this snippet matches right now
              local params = snip:matches(line, row + 1)
              if params then
                -- compute the region to highlight
                local from_col, to_col
                if params.clear_region then
                  from_col = params.clear_region.from[2]
                  to_col = params.clear_region.to[2]
                else
                  -- default: highlight only the trigger text
                  from_col = #line - #params.trigger
                  to_col = #line
                end

                vim.api.nvim_buf_set_extmark(0, ns, row, from_col, {
                  end_col = to_col,
                  end_row = row,
                  virt_text = { { "● " .. snip.description[1], "Character" } },
                })
                break -- stop after first match
              end
            end
          end,
        })
      end,
    },
    {
      "saghen/blink.cmp",
      opts = {
        keymap = { preset = "default" },
        snippets = {
          preset = "luasnip",
        },
        fuzzy = { implementation = "lua" },
        appearance = {
          kind_icons = {
            Snippet = "㎝",
          },
        },
        sources = {
          providers = {
            snippets = {
              opts = {
                show_autosnippets = false,
              },
            },
          },
        },
      },
    },
    { "nvim-telescope/telescope.nvim", tag = "0.1.8", dependencies = { "nvim-lua/plenary.nvim" } },
  },
  config = function()
    local ls = require("luasnip")
    local checkmate_snippets = require("checkmate.snippets")

    require("luasnip").add_snippets("markdown", {
      ls.s({ trig = ".test", desc = "TEST", priority = 2000 }, { ls.t("- [ ] Test") }),

      checkmate_snippets.todo({ trigger = ".to", desc = "New TODO" }),
      checkmate_snippets.todo({
        trigger = ".bug",
        text = "Description",
        metadata = {
          bug = true,
        },
        ls_context = {
          snippetType = "autosnippet",
        },
      }),
      checkmate_snippets.todo({
        trigger = ".done",
        text = "Completed: ",
        metadata = {
          done = true,
        },
        ls_context = {
          snippetType = "autosnippet",
        },
      }),

      checkmate_snippets.todo({
        trigger = "%.i(%d+)",
        desc = "New ISSUE",
        metadata = {
          issue = function(captures)
            local issue_num = captures[1] or ""
            return "#" .. issue_num
          end,
          url = function(captures)
            local repo = vim.fn
              .system("git remote get-url origin")
              :gsub("\n", "")
              :gsub("%.git$", "")
              :gsub("^.*:", "https://github.com/")
            return string.format("%s/issues/%s", repo, captures[1])
          end,
        },
        ls_context = {
          snippetType = "snippet",
          regTrig = true,
        },
      }),
      checkmate_snippets.metadata({
        trigger = "@p",
        tag = "priority",
        desc = "@priority",
        auto_select = true,
        ls_context = { snippetType = "autosnippet" },
      }),
      checkmate_snippets.metadata({ trigger = "@i", tag = "issue", desc = "@issue" }),
      checkmate_snippets.metadata({ trigger = "@s", tag = "started", desc = "@started" }),
      checkmate_snippets.metadata({ trigger = "@d", tag = "done", desc = "@done" }),
    })

    vim.keymap.set("n", "<leader>o", function()
      -- yank inside parentheses into register z
      vim.cmd('normal! "zyi)')
      local path = vim.fn.getreg("z")
      if path == "" then
        return
      end
      vim.ui.open(path)
    end, { desc = "Open path within parentheses" })
  end,
  ---@diagnostic disable-next-line: missing-fields
  checkmate = require("tests.fixtures.checkmate_config").with({}),
}
