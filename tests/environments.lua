local M = {}

---@type checkmate.Config
---@diagnostic disable-next-line: missing-fields
local checkmate_spec = {
  metadata = {
    test = {
      choices = function(ctx, cb)
        vim.defer_fn(function()
          cb({ "A", "B", "C" })
        end, 10000)
      end,
      key = "<leader>T7",
    },
    elapsed = {
      key = "<leader>T6",
      get_value = function(context)
        local _, started_value = context.todo.get_metadata("started")
        local _, done_value = context.todo.get_metadata("done")

        if started_value and done_value then
          local started_ts = vim.fn.strptime("%m/%d/%y %H:%M", started_value)
          local done_ts = vim.fn.strptime("%m/%d/%y %H:%M", done_value)
          return string.format("%.1f d", (done_ts - started_ts) / 86400)
        end

        return ""
      end,
    },

    branch = {
      key = "<leader>Tb",
      choices = function(context, callback)
        local branches = {}
        vim.fn.jobstart({ "git", "branch", "-r" }, {
          on_stdout = function(_, data)
            for _, line in ipairs(data) do
              if line ~= "" then
                local branch = line:match("origin/(.+)")
                if branch then
                  table.insert(branches, branch)
                end
              end
            end
          end,
          on_exit = function()
            callback(branches)
          end,
        })
      end,
    },

    type = {
      key = "<leader>T5",
      get_value = function(context)
        local text = context.todo.text:lower()

        -- Auto-detect type based on keywords
        if text:match("bug") or text:match("fix") then
          return "bug"
        elseif text:match("feature") or text:match("implement") then
          return "feature"
        elseif text:match("refactor") then
          return "refactor"
        elseif text:match("doc") then
          return "documentation"
        else
          return "task"
        end
      end,
      choices = { "bug", "feature", "refactor", "documentation", "task", "chore" },
      style = function(context)
        local colors = {
          bug = { fg = "#ff5555", bold = true },
          feature = { fg = "#50fa7b" },
          refactor = { fg = "#ff79c6" },
          documentation = { fg = "#f1fa8c" },
          task = { fg = "#8be9fd" },
          chore = { fg = "#6272a4" },
        }
        return colors[context.value] or { fg = "#f8f8f2" }
      end,
      on_change = function(todo_item, old_value, new_value)
        -- vim.notify(
        --   string.format(
        --     "todo item on row %d had @type changed from %s to %s",
        --     todo_item.range.start.row,
        --     old_value,
        --     new_value
        --   )
        -- )
      end,
    },

    pr = {
      key = "<leader>TP",
      get_value = function()
        -- Get current branch's PR number if it exists
        local branch = vim.fn.system("git branch --show-current"):gsub("\n", "")
        local pr_number = branch:match("(%d+)")
        return pr_number or ""
      end,
      style = { fg = "#8be9fd", underline = true },
      jump_to_on_insert = "value",
      select_on_insert = true,
    },

    priority = {
      choices = function()
        return { "low", "medium", "high" }
      end,
    },
    big = {
      choices = function(ctx)
        local result = {}
        for i = 1, 100 do
          table.insert(result, "issue #" .. i)
        end
        return result
      end,
      key = "<leader>T9",
    },
    issue = {
      key = { "<leader>TI", "Add/remove @issue" },
      choices = function(context, callback)
        local co = coroutine.create(function()
          local handle = io.popen('curl -sS "https://api.github.com/repos/bngarren/checkmate.nvim/issues?state=open"')
          if not handle then
            callback({})
            return
          end

          local chunks = {}
          while true do
            local chunk = handle:read(1024) -- Read 1KB at a time
            if not chunk then
              break
            end
            table.insert(chunks, chunk)
            coroutine.yield()
          end

          handle:close()
          local json_text = table.concat(chunks)

          local ok, issues = pcall(vim.json.decode, json_text)
          if not ok then
            callback({})
            return
          end

          local result = {}
          for _, issue in ipairs(issues) do
            local text = string.format("#%d %s", issue.number, issue.title)
            table.insert(result, text)
          end

          callback(result)
        end)

        local function resume()
          if coroutine.status(co) ~= "dead" then
            coroutine.resume(co)
            vim.defer_fn(resume, 10) -- Resume every 10ms
          end
        end

        vim.schedule(resume)
      end,
    },
  },
}

M.configs = {
  default = {
    spec = {
      --
    },
  },
  snacks = {
    spec = {
      {
        "folke/snacks.nvim",
        priority = 1000,
        lazy = false,
        ---@module "snacks"
        ---@type snacks.Config
        opts = {
          bigfile = { enabled = true },
          dashboard = { enabled = false },
          explorer = { enabled = false },
          indent = { enabled = true },
          input = { enabled = true },
          picker = { enabled = true },
          notifier = { enabled = true },
          quickfile = { enabled = true },
          scope = { enabled = false },
          scroll = { enabled = false },
          statuscolumn = { enabled = true },
          words = { enabled = true },
        },
      },
      {
        "folke/which-key.nvim",
        event = "VeryLazy",
        opts = {},
        keys = {
          {
            "<leader>?",
            function()
              require("which-key").show({ global = false })
            end,
            desc = "Buffer Local Keymaps (which-key)",
          },
        },
      },
    },
    checkmate = vim.tbl_deep_extend("force", checkmate_spec, {
      keys = {
        ["<leader>Tt"] = "toggle", -- legacy
        ["<leader>Ta"] = {
          rhs = "<cmd>Checkmate archive<CR>",
          desc = "Archive todos",
          modes = { "n" },
        },
        ["<leader>Tc"] = {
          rhs = function()
            require("checkmate").check()
          end,
          desc = "Check todo",
          modes = { "n", "v" },
        },
        ["<leader>Tu"] = { "<cmd>lua require('checkmate').uncheck()<CR>", "UNCHECK TODO", { "n", "v" } },
      },
      --[[ ui = {
        picker = function(items, opts)
          ---@type snacks.picker.ui_select
          require("snacks").picker.select(items, {
            prompt = "CUSTOM",
            preview = false,
          }, function(item)
            opts.on_choice(item)
          end)
        end,
      }, ]]
    }),
  },
  mini = {
    spec = {
      { "echasnovski/mini.nvim", version = false },
    },
    checkmate = vim.tbl_deep_extend("force", checkmate_spec, {
      ui = {
        picker = "fzf-lua",
      },
    }),
  },
  telescope = {
    spec = {
      "nvim-telescope/telescope.nvim",
      tag = "0.1.8",
      dependencies = { "nvim-lua/plenary.nvim" },
    },
    checkmate = checkmate_spec,
  },
}

function M.get(name)
  return M.configs[name] or M.configs.default
end

return M
