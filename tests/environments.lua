local M = {}

M.configs = {
  default = {
    spec = {
      --
    },
  },
}

function M.get(name)
  return M.configs[name] or M.configs.default
end

return M
