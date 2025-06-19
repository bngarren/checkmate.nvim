local M = {}

---@type checkmate.Config
---@diagnostic disable-next-line: missing-fields
M.base = {
  keys = {
    ["<leader>T?"] = {
      desc = "Open debug menu",
      modes = { "n" },
      rhs = "<cmd>Checkmate debug menu<cr>",
    },
  },
  metadata = {
    branch = {
      key = "<leader>Tb",
      choices = function(_, callback)
        local out = vim.system({ "git", "branch", "-r", "--format=%(refname:short)" }):wait()

        if out.code == 0 then
          local items = vim.split(out.stdout, "\n", { trimempty = true })

          items = vim.tbl_filter(function(branch)
            return not branch:match("^origin/HEAD%s*->")
          end, items)

          items = vim.tbl_map(function(branch)
            return branch:gsub("^origin/", "")
          end, items)

          callback(items)
        else
          callback({})
        end
      end,
    },
  },
}

---@param config checkmate.Config
---@return checkmate.Config config
function M.with(config)
  return vim.tbl_deep_extend("force", M.base, config)
end

return M
