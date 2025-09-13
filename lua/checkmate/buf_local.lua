-- all buffer-local plugin state lives under vim.b[bufnr][<namespace>]

---@class checkmate.BufferLocalHandle
---@field get fun(self, name: string, default?: any): any
---@field set fun(self, name: string, value: any)
---@field update fun(self: checkmate.BufferLocalHandle, name: string, fn: fun(prev: any): any, default: any|nil): any
---@field del fun(self, name: string)
---@field table fun(self): table

local M = {}

local BL_NS ---@type string|nil
local function get_ns()
  if BL_NS ~= nil then
    return BL_NS
  end
  local ok, cfg = pcall(require, "checkmate.config")
  if ok and cfg then
    BL_NS = cfg.buffer_local_ns
  end
  BL_NS = "_checkmate"
  return BL_NS
end

---@return string
function M.get_namespace()
  return get_ns()
end

local function resolve_bufnr(bufnr)
  return (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
end

local function assert_valid_buf(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error(("checkmate.buf_local: invalid bufnr: %s"):format(tostring(bufnr)))
  end
end

-- public

---Get the buffer-local state table (creates if missing)
---@param bufnr? integer
---@return table bl
function M.get_table(bufnr)
  bufnr = resolve_bufnr(bufnr)
  assert_valid_buf(bufnr)
  local ns = get_ns()
  local tbl = vim.b[bufnr][ns]
  if tbl == nil then
    tbl = {}
    vim.b[bufnr][ns] = tbl
  end
  return tbl
end

---@param bufnr? integer
---@return table
function M.bl(bufnr)
  return M.get_table(bufnr)
end

---Get a value from the buffer-local state
---@param name string
---@param opts? {bufnr?: integer, default?: any, create?: boolean}
---@return any
function M.get(name, opts)
  vim.validate({ name = { name, "string" } })
  opts = opts or {}
  local bufnr = resolve_bufnr(opts.bufnr)

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return opts.default
  end

  -- non-creating lookup if requested
  if opts.create == false then
    local ns = get_ns()
    local tbl = vim.b[bufnr][ns]
    return (tbl and tbl[name]) ~= nil and tbl[name] or opts.default
  end

  local tbl = M.get_table(bufnr)
  local v = tbl[name]
  if v == nil then
    return opts.default
  end
  return v
end

---Set a value in the buffer-local state
---@param name string
---@param value any
---@param opts? {bufnr?: integer}
function M.set(name, value, opts)
  vim.validate({ name = { name, "string" } })
  opts = opts or {}
  local bufnr = resolve_bufnr(opts.bufnr)
  assert_valid_buf(bufnr)
  M.get_table(bufnr)[name] = value
end

---Update a value via a function: next = fn(prev). If fn returns nil, the key is deleted
---@param name string
---@param fn fun(prev:any): any
---@param opts? {bufnr?: integer, default?: any}
---@return any new_value
function M.update(name, fn, opts)
  vim.validate({
    name = { name, "string" },
    fn = { fn, "function" },
  })
  opts = opts or {}
  local bufnr = resolve_bufnr(opts.bufnr)
  assert_valid_buf(bufnr)

  local tbl = M.get_table(bufnr)
  local prev = (tbl[name] ~= nil) and tbl[name] or opts.default
  local nextv = fn(prev)
  if nextv == nil then
    tbl[name] = nil
  else
    tbl[name] = nextv
  end
  return nextv
end

---Delete a key from the buffer-local state
---@param name string
---@param opts? {bufnr?: integer}
function M.del(name, opts)
  vim.validate({ name = { name, "string" } })
  opts = opts or {}
  local bufnr = resolve_bufnr(opts.bufnr)
  assert_valid_buf(bufnr)
  M.get_table(bufnr)[name] = nil
end

---Clear the entire buffer-local state table (keeps the namespace table but empties it)
---@param opts? {bufnr?: integer}
function M.clear(opts)
  opts = opts or {}
  local bufnr = resolve_bufnr(opts.bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ns = get_ns()
  vim.b[bufnr][ns] = {}
end

---Return a small handle bound to a specific buffer for easy access
---@param bufnr? integer
---@return checkmate.BufferLocalHandle
function M.handle(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local h = {}
  local mt = {
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
      table = function(_)
        return M.get_table(bufnr)
      end,
    },
  }
  return setmetatable(h, mt)
end

return M
