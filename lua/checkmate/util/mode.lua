local M = {}

-- Return a normalized family: "n" | "v" | "i" | nil (if none of those)
---@param m? string  -- optional raw mode (for testing); defaults to current
---@return "n"|"v"|"i"|nil
function M.mode_family(m)
  m = m or vim.api.nvim_get_mode().mode
  -- visual family: visual char/line/block, and select modes behave like visual
  if m:find("^[vV\022]") or m:find("^s") then
    return "v"
  end
  -- insert family: insert + its variants (ic, ix, etc.)
  if m:find("^i") then
    return "i"
  end
  -- normal family: normal + operator-pending + normal-insert variants (niI, no, nov, nt…)
  if m:find("^n") then
    return "n"
  end
  return nil
end

function M.is_normal_mode(m)
  return M.mode_family(m) == "n"
end

function M.is_visual_mode(m)
  return M.mode_family(m) == "v"
end

function M.is_insert_mode(m)
  return M.mode_family(m) == "i"
end

---@return "n"|"v"|"i"|string
function M.get_mode()
  local raw = vim.api.nvim_get_mode().mode
  return M.mode_family(raw) or raw
end

return M
