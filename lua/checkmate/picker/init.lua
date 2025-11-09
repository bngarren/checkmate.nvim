--[[

Picker architecture:
0. Feature layer (e.g. metadata/picker.lua)
  - Business logic, generates items, handles plugin related callbacks
1. Picker orchestration (this module)
  - Normalizes `items` to checkmate.picker.Item
  - Resolves a backend with fallback to native
  - Dispatches the correct adapter_method -> adapter
2. Backend adapters (pickers/backends/*)
  - Plugin-specific implementations
  - interface via checkmate.picker.Adapter and AdapterContext


Config merging (increasing) priority:
For each backend:
  1. Checkmate's base defaults (defined in the adapter)
  2. Top level AdapterContext fields, such as prompt, format_item
  3. `backend_opts` - derived from merge of picker_opts.config + optional picker_opts[backend] (priority)
]]

local M = {}
local H = {}

local log = require("checkmate.log")

---@class checkmate.picker.Item
---@field text string Display text
---@field value any Payload

---@alias checkmate.picker.Items (string|checkmate.picker.Item)[]

---@class checkmate.picker.PickOpts
---@field prompt? string
---@field format_item? fun(item: checkmate.picker.Item): string
---@field kind? string Kind hint for vim.ui.select
---@field picker_opts? checkmate.PickerOpts
---@field method? checkmate.picker.Method Defaults to `pick`
---@field on_select? fun(value: any, item: checkmate.picker.Item)
---picker_fn is a full override. Call complete(item) on select, complete(nil) on cancel
---@field picker_fn? fun(items: checkmate.picker.Item[], opts?: checkmate.picker.PickOpts, complete: fun(choice_item: any))

---@class checkmate.picker.AdapterContext
---@field items checkmate.picker.Item[]
---@field prompt? string
---@field kind? string
---@field format_item fun(item: checkmate.picker.Item): string
---@field backend_opts table<string, any> Backend-specific config extracted from picker_opts
---@field on_select_item fun(item: checkmate.picker.Item)

---A backend/adapter specific implementation for a specific picker behavior
---@enum checkmate.picker.Method
M.METHODS = {
  -- Generic picker (default)
  PICK = "pick",
  -- Todo picker with preview/jump on select/confirm
  PICK_TODO = "pick_todo",
}

--- Backend adapter surface, implements M.METHODS
---@class checkmate.picker.Adapter
---@field [fun(ctx: checkmate.picker.AdapterContext)] checkmate.picker.Method

--- If `opts.picker_fn` is provided, it *fully overrides* the backend call
---@param items checkmate.picker.Items
---@param opts? checkmate.picker.PickOpts
function M.pick(items, opts)
  local config = require("checkmate.config")

  opts = opts or {}
  local picker_opts = opts.picker_opts or {}

  local valid, validate_err = H.validate_pick_opts(opts)
  if not valid then
    H.notify_err(validate_err)
    return
  end

  local norm_items = H.normalize_items(items)
  local format_item = opts.format_item or H.default_format_item

  -- full override
  if type(opts.picker_fn) == "function" then
    local ok, picker_fn_err = pcall(function()
      opts.picker_fn(norm_items, opts, function(choice_item)
        if choice_item ~= nil then
          if type(opts.on_select) == "function" then
            pcall(opts.on_select, choice_item.value, choice_item)
          end
        end
      end)
    end)
    if not ok then
      H.notify_err("picker_fn error: " .. tostring(picker_fn_err))
    end
    return
  end

  -- resolve backend
  -- - 1. from direct opt.backend.picker argument for this function
  -- - 2. from global config.ui.picker
  -- - 3. auto choose a backend based on what is installed, with fallback to vim.ui.select (native)
  --
  -- remember: "native" vim.ui.select can still be overriden/registered by an installed picker plugin
  -- depending on the user's neovim config
  local backend = vim.tbl_get(picker_opts, "picker") or vim.tbl_get(config.options, "ui", "picker")
  if backend == nil then
    backend = H.auto_choose_backend()
  end

  local ok, adapter = pcall(H.get_adapter, backend)
  if not ok then
    H.notify_err("failed to load picker backend '" .. backend .. "': " .. tostring(adapter))
    return
  end

  -- the backend specific table resolved from picker_opts
  local backend_opts = vim.tbl_extend("force", picker_opts.config or {}, picker_opts[backend] or {}) or {}

  local ok_run, err_run = pcall(function()
    ---@type checkmate.picker.AdapterContext
    local ctx = {
      items = norm_items,
      prompt = opts.prompt,
      kind = opts.kind,
      format_item = format_item,
      backend_opts = backend_opts,
      on_select_item = function(choice_item)
        if choice_item and type(opts.on_select) == "function" then
          pcall(opts.on_select, choice_item.value, choice_item)
        end
      end,
    }
    -- resolve the adapter method
    ---@type checkmate.picker.Method
    local method_name = opts.method or "pick"
    local method = adapter[method_name]

    local function fallback()
      if type(adapter.pick) == "function" then
        local ok_fallback, err_fallback = pcall(adapter.pick, ctx)
        if not ok_fallback then
          H.notify_err(
            ("picker adapter error (%s): fallback 'pick' failed: %s"):format(backend, tostring(err_fallback))
          )
        end
      else
        H.notify_err(
          ("picker adapter error (%s): method '%s' missing and no 'pick' fallback"):format(backend, method_name)
        )
      end
    end

    if type(method) == "function" then
      local adapter_method_ok, adapter_method_err = pcall(method, ctx)
      if not adapter_method_ok then
        log.fmt_error(
          "[picker] attempted to call %s backend's '%s' but failed: %s\nFallback to `pick` method.",
          backend,
          method_name,
          adapter_method_err
        )
        fallback()
      end
    else
      fallback()
    end
  end)

  if not ok_run then
    H.notify_err(("picker adapter error (%s): %s"):format(backend, tostring(err_run)))
  end
end

-- for a list of items, converts each to a {text, value}
-- `text_key` determines which field to use for `text` (required)
-- `value_key` determines which field to use for `value` (optional, default is entire item)
function M.map_items(items, text_key, value_key)
  if type(items) ~= "table" then
    return items
  end
  return vim.tbl_map(function(i)
    assert(i[text_key], string.format("text_key '%s' missing from item in `map_items`", text_key))
    if value_key then
      assert(i[value_key], string.format("value_key '%s' missing from item in `map_items`", value_key))
    end
    return { text = i[text_key], value = (value_key and i[value_key] or i) }
  end, items)
end

-- ---- helpers -------------------------------------------------------------

---@param opts checkmate.picker.PickOpts
function H.validate_pick_opts(opts)
  local PICKERS = require("checkmate").PICKERS

  if not opts then
    return true
  end

  local must_be_one_of = string.format(
    "must be one of: %s",
    table.concat(
      vim.tbl_map(function(i)
        return string.format("'%s'", i)
      end, vim.tbl_values(PICKERS)),
      ", "
    )
  )

  if opts.picker_opts then
    local picker = opts.picker_opts.picker
    if picker and type(picker) ~= "string" then
      return false, "`picker` must be a string and " .. must_be_one_of
    end

    if picker and not vim.tbl_contains(vim.tbl_values(PICKERS), picker) then
      return false, string.format("Invalid picker backend: '%s',\n%s", picker, must_be_one_of)
    end

    for backend, cfg in pairs(opts.picker_opts) do
      if backend ~= "picker" and type(cfg) ~= "table" then
        return false, string.format("Backend config for '%s' must be a table, got %s", backend, type(cfg))
      end
    end
  end

  return true
end

---@param items checkmate.picker.Items
---@return checkmate.picker.Item[]
function H.normalize_items(items)
  if type(items) ~= "table" then
    return {}
  end
  local out = {}
  for i = 1, #items do
    local it = items[i]
    if type(it) == "string" then
      out[#out + 1] = { text = it, value = it }
    elseif type(it) == "table" then
      local text = it.text or it[1]
      local value = (it.value ~= nil) and it.value or text
      out[#out + 1] = { text = tostring(text or ""), value = value }
    else
      out[#out + 1] = { text = tostring(it), value = it }
    end
  end
  return out
end

---@param item checkmate.picker.Item
function H.default_format_item(item)
  return item.text or ""
end

---@return checkmate.Picker
function H.auto_choose_backend()
  if pcall(require, "telescope") then
    return "telescope"
  end
  if pcall(require, "snacks") then
    return "snacks"
  end
  if pcall(require, "mini.pick") then
    return "mini"
  end
  return "native"
end

function H.get_adapter(name)
  if name == "telescope" then
    return require("checkmate.picker.backends.telescope")
  end
  if name == "snacks" then
    return require("checkmate.picker.backends.snacks")
  end
  if name == "mini" then
    return require("checkmate.picker.backends.mini")
  end
  return require("checkmate.picker.backends.native")
end

function H.notify_err(msg)
  vim.schedule(function()
    vim.notify("Checkmate: " .. msg, vim.log.levels.ERROR)
  end)
end

return M
