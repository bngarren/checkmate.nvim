local M = {}

---@class checkmate.picker.MakeChooseOpts
---  If true, run callbacks via vim.schedule(). Default: false.
---@field schedule? boolean
---  Optional backend-specific hook for successful selection
---  `orig`  = original checkmate.picker.Item
---  `proxy` = lightweight, picker-facing representation (e.g. proxy table)
---  `extra` = backend-defined metadata (picker instance, action, index, etc), or
---  with vim.ui.select, extra will be the selected item idx
---@field after_select? checkmate.picker.after_select
---  Optional backend-specific hook for cancel/close
---@field after_cancel? checkmate.picker.after_cancel

---@alias checkmate.picker.after_select fun(orig: checkmate.picker.Item, proxy: any, extra?: any)
---@alias checkmate.picker.after_cancel fun()

---Create a pair of callbacks that:
---  - resolve proxies back to original items
---  - call ctx.on_select_item / ctx.on_cancel exactly once
---  - optionally schedule via vim.schedule
---  - optionally run backend-specific hooks
---
---Will call `cancel` for if `choose` is called with nil
---
---@param ctx checkmate.picker.AdapterContext
---@param resolve fun(proxy: any): any
---@param opts? checkmate.picker.MakeChooseOpts
---@return fun(proxy: any, extra?: any) choose
---@return fun() cancel
function M.make_choose(ctx, resolve, opts)
  opts = opts or {}
  local schedule = opts.schedule
  local after_select = opts.after_select
  local after_cancel = opts.after_cancel

  local completed = false

  local function run(fn)
    if schedule then
      vim.schedule(fn)
    else
      fn()
    end
  end

  local function cancel()
    if completed then
      return
    end
    completed = true
    run(function()
      if ctx.on_cancel then
        pcall(ctx.on_cancel)
      end
      if after_cancel then
        pcall(after_cancel)
      end
    end)
  end

  ---@param proxy any
  ---@param extra any -- backend-specific metadata (e.g. picker instance, action)
  ---or, when handed to vim.ui.select as on_choice, `extra` will be the selected item idx
  local function choose(proxy, extra)
    if completed then
      return
    end

    if proxy == nil then
      return cancel()
    end

    completed = true

    local orig = resolve and resolve(proxy) or proxy

    run(function()
      if ctx.on_select_item and orig then
        pcall(ctx.on_select_item, orig)
      end
      if after_select and orig then
        pcall(after_select, orig, proxy, extra)
      end
    end)
  end

  return choose, cancel
end

-- ==================================================================
-- Proxy
-- ==================================================================

-- Design:
-- - External pickers ONLY see these thin proxy tables
--   Some picker implementations may try to inspect/deepcopy the raw items and can choke.
-- - Instead, we call `proxy.build(items, opts)` to:
--     - create a thin picker-specific representation:
--         { idx = <original index>, text = <display>, ... }
--     - get a `resolve(proxy)` function to map back to the original checkmate.picker.Item
--
-- Backends:
--   1. Call build(ctx.items, { format_item = ..., decorate = ... })
--   2. Pass `proxies` to the picker
--   3. In picker callbacks: `local orig = resolve(chosen) or chosen`

local Proxy = {}

---@class checkmate.picker.ProxyBuildOpts
---@field format_item? fun(item: checkmate.picker.Item): string
--- Optional hook for backend-specific fields
--- Must remain lightweight & picker-safe
---@field decorate? fun(proxy: table, item: checkmate.picker.Item, idx: integer)

---Build lightweight proxy items and a resolver for mapping back
---
---Proxies are:
---  - plain tables (no metatable)
---  - shape: `{ __cm_idx = integer, text = string, ... }`
---  - safe to hand to vim.ui.select, mini.pick, snacks, etc.
---
---@param items checkmate.picker.Item[]
---@param opts? checkmate.picker.ProxyBuildOpts
---@return table[] proxies
---@return fun(proxy: any): checkmate.picker.Item|nil resolve
function Proxy.build(items, opts)
  opts = opts or {}

  local format_item = opts.format_item
  local decorate = opts.decorate

  local proxies = {}

  for i = 1, #items do
    local item = items[i]

    -- normalize weird inputs just in case
    if type(item) ~= "table" then
      item = { text = tostring(item), value = item }
      items[i] = item
    end

    local text
    if type(format_item) == "function" then
      text = format_item(item)
    else
      text = item.text or tostring(item.text or item.value or "")
    end

    local proxy = {
      __cm_idx = i,
      text = text or "",
    }

    if decorate then
      decorate(proxy, item, i)
    end

    proxies[i] = proxy
  end

  ---Resolve a proxy item back to the original rich item
  ---If mapping fails, returns nil
  ---@param proxy any
  ---@return checkmate.picker.Item|nil
  local function resolve(proxy)
    if type(proxy) ~= "table" then
      return nil
    end
    local idx = proxy.__cm_idx
    if type(idx) == "number" then
      return items[idx]
    end
    return nil
  end

  return proxies, resolve
end

M.proxy = Proxy
return M
