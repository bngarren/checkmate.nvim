local M = {}
local H = {}

---@class checkmate.picker.Item
---@field text string Display text
---@field value any Payload

---@alias checkmate.picker.Items (string|checkmate.picker.Item)[]

---@class checkmate.picker.PickOpts
---@field prompt? string
---@field kind? string
---@field backend? checkmate.Picker Defaults to user-specific `config.ui.picker`, an auto-detected installed picker, or native `vim.ui.select`
---@field backend_opts? table<string, any> -- either a plain table or a map: { [backendName]=opts }
---@field adapter_method? string Defaults to `pick`
---@field preview? boolean If true, attempts to open picker with preview, if supported
---@field source_buf? integer Source buffer
---@field format_item? fun(item: checkmate.picker.Item): string
---@field on_select? fun(value: any, item: checkmate.picker.Item)
---@field on_cancel? fun()
---picker_fn is a full override. Call done(item) on select, done(nil) on cancel
---@field picker_fn? fun(items: checkmate.picker.Item[], opts?: checkmate.picker.PickOpts, done: fun(choice_item: any))

---@class checkmate.picker.AdapterContext
---@field items checkmate.picker.Item[]
---@field prompt? string
---@field kind? string
---@field format_item fun(item: checkmate.picker.Item): string
---@field backend_opts table<string, any>
---@field preview? boolean
---@field on_select_item fun(item: checkmate.picker.Item)
---@field on_cancel fun()

--- Backend adapter surface. Must implement `pick()`, others are optional for improved out-of-box UX
--- for checkmate-specific actions
---@class checkmate.picker.Adapter
---@field pick fun(ctx: checkmate.picker.AdapterContext)
---@field pick_todo? fun(ctx: checkmate.picker.AdapterContext)

--- If `opts.picker_fn` is provided, it *fully overrides* the backend call
---@param items checkmate.picker.Items
---@param opts? checkmate.picker.PickOpts
function M.pick(items, opts)
  local log = require("checkmate.log")
  local config = require("checkmate.config")

  opts = opts or {}

  local norm_items = H.normalize_items(items)
  local format_item = opts.format_item or H.default_format_item

  -- full override
  if type(opts.picker_fn) == "function" then
    local ok, err = pcall(function()
      opts.picker_fn(norm_items, opts, function(choice_item)
        if choice_item == nil then
          if type(opts.on_cancel) == "function" then
            pcall(opts.on_cancel)
          end
        else
          if type(opts.on_select) == "function" then
            pcall(opts.on_select, choice_item.value, choice_item)
          end
        end
      end)
    end)
    if not ok then
      H.notify_err("picker_fn error: " .. tostring(err))
    end
    return
  end

  -- resolve backend
  local backend = opts.backend or vim.tbl_get(config.options, "ui", "picker")
  if backend == nil then
    backend = H.detect_backend()
  end

  -- native is `vim.ui.select` (which could still be overriden by an installed picker plugin
  -- depending on the user's neovim config)
  local backend_name = backend == false and "native" or tostring(backend)

  local ok, adapter = pcall(H.get_adapter, backend_name)
  if not ok then
    H.notify_err("failed to load picker backend '" .. backend_name .. "': " .. tostring(adapter))
    return
  end

  local backend_opts = {}
  if type(opts.backend_opts) == "table" then
    if vim.islist(opts.backend_opts) then
      -- plain table of opts
      backend_opts = opts.backend_opts
    else
      -- per-backend map
      backend_opts = opts.backend_opts[backend_name] or {}
    end
  end

  local ok_run, err_run = pcall(function()
    ---@type checkmate.picker.AdapterContext
    local ctx = {
      items = norm_items,
      prompt = opts.prompt,
      kind = opts.kind,
      format_item = format_item,
      backend_opts = backend_opts,
      preview = opts.preview,
      on_select_item = function(choice_item)
        if choice_item and type(opts.on_select) == "function" then
          pcall(opts.on_select, choice_item.value, choice_item)
        end
      end,
      on_cancel = function()
        if type(opts.on_cancel) == "function" then
          pcall(opts.on_cancel)
        end
      end,
    }
    -- resolve the adapter method
    local method_name = opts.adapter_method or "pick"
    local method = adapter[method_name]

    local function fallback()
      if type(adapter.pick) == "function" then
        local ok_fallback, err_fallback = pcall(adapter.pick, ctx)
        if not ok_fallback then
          H.notify_err(
            ("picker adapter error (%s): fallback 'pick' failed: %s"):format(backend_name, tostring(err_fallback))
          )
        end
      else
        H.notify_err(
          ("picker adapter error (%s): method '%s' missing and no 'pick' fallback"):format(backend_name, method_name)
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
    H.notify_err(("picker adapter error (%s): %s"):format(backend_name, tostring(err_run)))
  end
end

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

function H.detect_backend()
  if pcall(require, "telescope") then
    return "telescope"
  end
  if pcall(require, "snacks") then
    return "snacks"
  end
  if pcall(require, "mini.pick") then
    return "mini"
  end
  return false
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
