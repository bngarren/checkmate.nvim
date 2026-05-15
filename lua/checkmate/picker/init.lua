--[[

Picker architecture:

  1. Public feature APIs
     Examples: select_metadata_value, select_todo, etc.
     Validates public opts, gathers domain-specific context and delegates
     picker-specific behavior to a domain picker bridge.

  2. Domain picker bridges
     Examples: metadata/picker.lua, todo/picker.lua, etc.
     Translates domain candidates (e.g. choices) into picker items and owns
     feature-level `custom_picker` behavior.

     A feature-level `custom_picker` receives domain payloads:
       custom_picker(metadata_context, complete_value)
       custom_picker(todo_list, complete_todo)
       custom_picker(move_destinations, complete_destination)

  3. Picker engine (this module)
     Works with normalized |checkmate.picker.Item| values. It validates
     picker opts, normalizes candidates, optionally runs picker_fn, resolves a
     backend, and protects on_select callbacks.

     `picker_fn(items, opts, complete)` is a low level override. It receives
     normalized picker items and must call complete(item) or complete(nil). It is
     lower-level than feature custom_picker and skips backend adapters entirely.

  4. Backend adapters
     Files: picker/backends/*.lua. Adapters translate normalized picker items to
     plugin-specific entry shapes, preserving the original item under __cm_item
     when they cannot pass it through directly.

Good things to know:
  - Input candidates may be strings or { text, value } items.
  - After normalization, selection completion is Item-based.
  - complete(nil) means cancellation.
  - complete(item) selects at most once.
  - picker.pick(...) returns true if a picker path was invoked/launched, false
    for validation failure, empty item lists, picker_fn/backend failures, or
    total fallback failure.

Config merging (increasing) priority:
For each backend:
  1. Checkmate's base defaults (defined in the adapter)
  2. Top level AdapterContext fields, such as prompt
  3. `backend_opts` - derived from merge of picker_opts.opts + optional picker_opts[backend] (priority)
]]

local M = {}
local H = {}

local log = require("checkmate.log")
local picker_util = require("checkmate.picker.util")

---@class checkmate.picker.Item
---@field text string Display/search text. Normalized to a string before reaching backends.
---@field value any Non-nil payload passed as the first on_select argument. Use a table for structured candidates.

---@class checkmate.picker.PickOpts
---@field prompt? string
---Updates each item.text to the returned string, before the item is passed to the backend picker.
---Note, the picker implementation may also run a "format" function per item to get the display value
---for the finder/selection buffer.
---The latter should be configured via the apppropriate `picker_opts` field for that picker, if desired.
---  e.g. `snacks.picker.format`
---@field format_item_text? fun(item: checkmate.picker.Item): string
---@field kind? string hint for vim.ui.select
---@field picker_opts? checkmate.PickerOpts
---@field method? checkmate.picker.Method Defaults to `pick`
---@field on_select? fun(value: any, item: checkmate.picker.Item)
---picker_fn is a full picker-engine override. Call complete(item) on select,
---or complete(nil) to cancel. `item` must be a normalized checkmate.picker.Item.
---@field picker_fn? fun(items: checkmate.picker.Item[], opts?: checkmate.picker.PickOpts, complete: fun(choice_item: checkmate.picker.Item?))

---@class checkmate.picker.AdapterContext
---@field items checkmate.picker.Item[]
---@field prompt? string
---@field kind? string
---@field format_item_text fun(item: checkmate.picker.Item): string See `checkmate.PickOpts.format_item_text`
---@field backend_opts table<string, any> Backend-specific config extracted from picker_opts
---@field on_select_item fun(item: checkmate.picker.Item)

---A backend/adapter specific implementation for a specific picker behavior
---@enum checkmate.picker.Method
M.METHODS = {
  -- Generic picker (default)
  PICK = "pick",
  -- Todo picker with preview and jump to buf/line on select/confirm
  PICK_TODO = "pick_todo",
}

--- Backend adapter surface, implements M.METHODS
---@class checkmate.picker.Adapter
---@field [fun(ctx: checkmate.picker.AdapterContext)] checkmate.picker.Method

--- If `opts.picker_fn` is provided, it fully overrides the backend call
---@param items (string|checkmate.picker.Item)[]
---@param opts? checkmate.picker.PickOpts
---@return boolean success true when a picker path was launched or invoked successfully
function M.pick(items, opts)
  local config = require("checkmate.config")

  opts = opts or {}

  local valid, validate_err = H.validate_pick_opts(opts)
  if not valid then
    H.notify_err(validate_err)
    return false
  end

  local picker_opts = opts.picker_opts or {}
  local format_item_text = opts.format_item_text or H.default_format_item_text
  local norm_items = H.normalize_items(items, { formatter = format_item_text })

  ---@param item checkmate.picker.Item
  local function handle_on_select(item)
    if item and type(opts.on_select) == "function" then
      local ok_cb, err_cb = pcall(opts.on_select, item.value, item)
      if not ok_cb then
        H.notify_err("picker on_select failed: " .. tostring(err_cb))
      end
    end
  end

  ---@type checkmate.picker.AdapterContext
  local ctx = {
    items = norm_items,
    prompt = opts.prompt,
    kind = opts.kind,
    format_item_text = format_item_text,
    backend_opts = {},
    on_select_item = handle_on_select,
  }

  if type(opts.picker_fn) == "function" then
    local complete = picker_util.make_item_completion(ctx)
    local ok, picker_fn_err = pcall(opts.picker_fn, norm_items, opts, complete)
    if not ok then
      H.notify_err("picker_fn error: " .. tostring(picker_fn_err))
      return false
    end
    return true
  end

  -- No point in presenting an empty list? Return false to notify "nothing launched"
  if #norm_items == 0 then
    return false
  end

  -- resolve backend
  -- - 1. per-call picker_opts.picker
  -- - 2. config.ui.picker (global default)
  -- - 3. auto choose a backend based on installed plugins, with fallback to vim.ui.select (native)
  --
  -- remember: "native" vim.ui.select can still be overriden/registered by an installed picker plugin
  -- depending on the user's neovim config
  local backend = vim.tbl_get(picker_opts, "picker") or vim.tbl_get(config.options, "ui", "picker")
  if backend == nil then
    backend = H.auto_choose_backend()
  end

  local ok, adapter = pcall(H.get_adapter, backend)
  if not ok then
    log.fmt_warn("[picker] failed to load %s backend: %s\nFalling back to native adapter.", backend, tostring(adapter))

    local ok_native, native_adapter = pcall(H.get_adapter, "native")
    if not ok_native then
      H.notify_err("failed to load native picker backend: " .. tostring(native_adapter))
      return false
    end

    backend = "native"
    adapter = native_adapter
  end

  ctx.backend_opts = H.resolve_backend_opts(picker_opts, backend)

  -- resolve the adapter method
  ---@type checkmate.picker.Method
  local method_name = opts.method or M.METHODS.PICK
  local method = adapter[method_name]

  local function try_adapter_method(adapter_name, try_method, try_method_name)
    if type(try_method) ~= "function" then
      return false, ("method '%s' not found on %s adapter"):format(try_method_name, adapter_name)
    end

    local ok_method, err_method = pcall(try_method, ctx)
    if not ok_method then
      return false, ("method '%s' on %s adapter failed: %s"):format(try_method_name, adapter_name, tostring(err_method))
    end

    return true
  end

  local success, err = try_adapter_method(backend, method, method_name)

  if not success then
    if backend == "native" then
      H.notify_err(("picker error: native backend failed for method '%s': %s"):format(method_name, err))
      return false
    end

    log.fmt_warn(
      "[picker] attempted to call %s backend's '%s' method but failed: %s\nFalling back to native adapter with same method.",
      backend,
      method_name,
      err
    )

    -- fallback to native
    local ok_native, native_adapter = pcall(H.get_adapter, "native")
    if not ok_native then
      H.notify_err("failed to load native picker backend: " .. tostring(native_adapter))
      return false
    end

    ctx.backend_opts = H.resolve_backend_opts(picker_opts, "native")

    local native_method = native_adapter[method_name]
    local native_success, native_err = try_adapter_method("native", native_method, method_name)

    if not native_success then
      H.notify_err(
        ("picker error: both %s and native backends failed for method '%s'. Native error: %s"):format(
          backend,
          method_name,
          native_err
        )
      )
      return false
    end

    return true
  end

  return true
end

-- Map arbitrary tables to {text, value} items
---@param items table[]
---@param text_key string determines which field to use for `text` (required)
---@param value_key? string determines which field to use for `value` (optional, default is entire item)
---@return checkmate.picker.Item[]
function M.map_items(items, text_key, value_key)
  if type(items) ~= "table" then
    return items
  end
  return vim.tbl_map(function(i)
    assert(i[text_key] ~= nil, string.format("text_key '%s' missing from item in `map_items`", text_key))
    if value_key then
      assert(i[value_key] ~= nil, string.format("value_key '%s' missing from item in `map_items`", value_key))
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

  if opts.format_item_text and not vim.is_callable(opts.format_item_text) then
    return false, "`format_item_text` must be callable"
  end

  if opts.picker_fn ~= nil and not vim.is_callable(opts.picker_fn) then
    return false, "`picker_fn` must be callable"
  end

  if opts.method ~= nil then
    if type(opts.method) ~= "string" then
      return false, "`method` must be a string"
    end

    if not vim.tbl_contains(vim.tbl_values(M.METHODS), opts.method) then
      return false,
        string.format(
          "`method` must be one of: %s",
          table.concat(
            vim.tbl_map(function(method)
              return string.format("'%s'", method)
            end, vim.tbl_values(M.METHODS)),
            ", "
          )
        )
    end
  end

  if opts.picker_opts ~= nil and type(opts.picker_opts) ~= "table" then
    return false, "`picker_opts` must be a table"
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

---@param items (string|checkmate.picker.Item)[]
---@param opts? { formatter?: fun(item: checkmate.picker.Item): string }
---@return checkmate.picker.Item[]
function H.normalize_items(items, opts)
  if type(items) ~= "table" then
    return {}
  end

  opts = opts or {}
  local formatter = opts.formatter
  local out = {}

  for i = 1, #items do
    local it = items[i]
    local item_type = type(it)
    local item

    if item_type == "string" then
      item = { text = it, value = it }
    elseif item_type == "table" then
      local text = it.text
      if text == nil then
        text = it[1]
      end

      local value = it.value
      if value == nil then
        value = it[2]
      end

      if value == nil then
        value = tostring(text or "")
      end

      item = {
        text = tostring(text or ""),
        value = value,
      }

      -- preserves extra fields?
      -- for k, v in pairs(it) do
      --   if item[k] == nil then
      --     item[k] = v
      --   end
      -- end
    else
      item = { text = tostring(it), value = it }
    end

    if formatter then
      local ok, formatted = pcall(formatter, item)
      if ok and formatted ~= nil then
        item.text = tostring(formatted)
      end
    end

    out[#out + 1] = item
  end

  return out
end

---@param picker_opts checkmate.PickerOpts
---@param backend checkmate.Picker
---@return table<string, any>
function H.resolve_backend_opts(picker_opts, backend)
  return vim.tbl_deep_extend("force", picker_opts.opts or {}, picker_opts[backend] or {})
end

---@param item checkmate.picker.Item
function H.default_format_item_text(item)
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
