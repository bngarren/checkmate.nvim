local M = {}

---@type checkmate.Config
---@diagnostic disable-next-line: missing-fields
local checkmate_spec = {
  metadata = {
    test = {
      choices = function(ctx, cb)
        return { "A", "B", "C" }
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
      key = "<leader>T8",
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
    },
    checkmate = checkmate_spec,
  },
  mini = {
    spec = {
      { "echasnovski/mini.nvim", version = false },
    },
    checkmate = checkmate_spec,
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
