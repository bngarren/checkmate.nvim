-- helps manage checkmate buffer local state consistently
--
-- each field is stored at: vim.b[bufnr]["<ns>_<name>"]
-- eg: with ns="_checkmate", key "in_conversion" -> b:_checkmate_in_conversion

---@class checkmate.BufferLocalHandle
---@field get fun(self, name: string, default?: any): any
---@field set fun(self, name: string, value: any)
---@field update fun(self: checkmate.BufferLocalHandle, name: string, fn: (fun(prev: any):any), default: any|nil): any
---@field del fun(self, name: string)
---@field clear fun(self)
---@field table fun(self): table

local M = {}

local BL_NS ---@type string
local BL_PREFIX ---@type string

local function load_ns()
  if BL_NS and BL_PREFIX then
    return
  end
  local ok, cfg = pcall(require, "checkmate.config")
  local ns = (ok and cfg and cfg.buffer_local_ns) or "_checkmate"
  BL_NS = ns
  BL_PREFIX = ns .. "_"
end

---@return string
function M.get_namespace()
  load_ns()
  return BL_NS
end

local function get_prefix()
  load_ns()
  return BL_PREFIX
end

local function resolve_bufnr(bufnr)
  return (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
end

local function assert_valid_buf(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error(("checkmate.buf_local: invalid bufnr: %s"):format(tostring(bufnr)))
  end
end

local function make_key(name)
  return get_prefix() .. name
end

---Mutating the returned table will NOT persist
---Use set/update/del/clear to persist
---@param bufnr? integer
---@return table
function M.get_table(bufnr)
  bufnr = resolve_bufnr(bufnr)
  assert_valid_buf(bufnr)
  local all = vim.fn.getbufvar(bufnr, "")
  local out = {}
  local prefix = get_prefix()
  for k, v in pairs(all) do
    if type(k) == "string" and k:sub(1, #prefix) == prefix then
      out[k:sub(#prefix + 1)] = v
    end
  end
  return out
end

---@param bufnr? integer
---@return table
function M.bl(bufnr)
  return M.get_table(bufnr)
end

---@param name string
---@param opts? { bufnr?: integer, default?: any }
function M.get(name, opts)
  opts = opts or {}
  local bufnr = resolve_bufnr(opts.bufnr)
  local v = vim.b[bufnr][make_key(name)]
  if v == nil then
    return opts.default
  end
  return v
end

---@param name string
---@param value any
---@param opts? { bufnr?: integer }
function M.set(name, value, opts)
  vim.validate({ name = { name, "string" } })
  opts = opts or {}
  local bufnr = resolve_bufnr(opts.bufnr)
  assert_valid_buf(bufnr)
  vim.b[bufnr][make_key(name)] = value
end

---@param name string
---@param fn fun(prev:any): any
---@param opts? { bufnr?: integer, default?: any }
---@return any next
function M.update(name, fn, opts)
  vim.validate({ name = { name, "string" }, fn = { fn, "function" } })
  opts = opts or {}
  local bufnr = resolve_bufnr(opts.bufnr)
  assert_valid_buf(bufnr)
  local key = make_key(name)
  local prev = vim.b[bufnr][key]
  if prev == nil then
    prev = opts.default
  end
  local nextv = fn(prev)
  if nextv == nil then
    vim.b[bufnr][key] = nil
  else
    vim.b[bufnr][key] = nextv
  end
  return nextv
end

---@param name string
---@param opts? { bufnr?: integer }
function M.del(name, opts)
  vim.validate({ name = { name, "string" } })
  opts = opts or {}
  local bufnr = resolve_bufnr(opts.bufnr)
  assert_valid_buf(bufnr)
  vim.b[bufnr][make_key(name)] = nil
end

---Remove all namespaced buffer-local keys
---@param opts? { bufnr?: integer }
function M.clear(opts)
  opts = opts or {}
  local bufnr = resolve_bufnr(opts.bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local all = vim.fn.getbufvar(bufnr, "")
  local prefix = get_prefix()
  for k, _ in pairs(all) do
    if type(k) == "string" and k:sub(1, #prefix) == prefix then
      vim.b[bufnr][k] = nil
    end
  end
end

---Return a handle bound to a specific buffer
---@param bufnr? integer
---@return checkmate.BufferLocalHandle
function M.handle(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local h = {}
  local mt = {
    ---@type checkmate.BufferLocalHandle
    __index = {
      get = function(_, name, default)
        return M.get(name, { bufnr = bufnr, default = default })
      end,
      set = function(_, name, value)
        M.set(name, value, { bufnr = bufnr })
      end,
      update = function(_, name, fn, default)
        return M.update(name, fn, { bufnr = bufnr, default = default })
      end,
      del = function(_, name)
        M.del(name, { bufnr = bufnr })
      end,
      clear = function(_)
        M.clear({ bufnr = bufnr })
      end,
      table = function(_)
        return M.get_table(bufnr)
      end,
    },
  }
  return setmetatable(h, mt)
end

return M
