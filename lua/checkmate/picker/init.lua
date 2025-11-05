local M = {}
local H = {}

---@class checkmate.picker.Item
---@field text string Display text
---@field value any Payload

---@alias checkmate.picker.Items (string|checkmate.picker.Item)[]

---@alias checkmate.picker.BackendName "auto"|"telescope"|"snacks"|"mini"|"native"

---@class checkmate.picker.PickOpts
---@field prompt? string
---@field kind? string
---@field backend? "auto"|"telescope"|"snacks"|"mini"|"native"
---@field backend_opts? table<string, any> -- backend name -> opts (safer), or a raw table passed as-is
---@field preview? boolean If true, attempts to open picker with preview, if supported
---@field format_item? fun(item: checkmate.picker.Item): string
---@field on_choice? fun(value: any, item: checkmate.picker.Item)
---@field on_cancel? fun()
---picker_fn is a full override. Call resolve(item) on accept, resolve(nil) on cancel
---@field picker_fn? fun(items: checkmate.picker.Item[], opts?: checkmate.picker.PickOpts, resolve: fun(choice_item: any))

---@class checkmate.picker.AdapterContext
---@field items checkmate.picker.Item[]
---@field prompt? string
---@field kind? string
---@field format_item fun(item: checkmate.picker.Item): string
---@field backend_opts table<string, any>
---@field preview? boolean
---@field on_accept fun(item: checkmate.picker.Item)
---@field on_cancel fun()

---@class checkmate.picker.Adapter
---@field pick fun(ctx: checkmate.picker.AdapterContext)

--- If `opts.picker_fn` is provided, it *fully overrides* the backend call
---@param items checkmate.picker.Items
---@param opts? checkmate.picker.PickOpts
function M.pick(items, opts)
  opts = opts or {}

  local norm_items = H.normalize_items(items)
  local format_item = opts.format_item or H.default_format_item

  if type(opts.picker_fn) == "function" then
    local ok, err = pcall(function()
      opts.picker_fn(norm_items, opts, function(choice_item)
        if choice_item == nil then
          if type(opts.on_cancel) == "function" then
            pcall(opts.on_cancel)
          end
        else
          if type(opts.on_choice) == "function" then
            pcall(opts.on_choice, choice_item.value, choice_item)
          end
        end
      end)
    end)
    if not ok then
      H.notify_err("picker_fn error: " .. tostring(err))
    end
    return
  end

  local backend = opts.backend
  if backend == "auto" or backend == nil then
    backend = H.detect_backend()
  end

  local ok, adapter = pcall(H.get_adapter, backend)
  if not ok then
    H.notify_err("failed to load picker backend '" .. tostring(backend) .. "': " .. tostring(adapter))
    return
  end

  local backend_opts = {}
  if type(opts.backend_opts) == "table" then
    backend_opts = opts.backend_opts[backend] or opts.backend_opts
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
      on_accept = function(choice_item)
        if choice_item and type(opts.on_choice) == "function" then
          pcall(opts.on_choice, choice_item.value, choice_item)
        end
      end,
      on_cancel = function()
        if type(opts.on_cancel) == "function" then
          pcall(opts.on_cancel)
        end
      end,
    }
    adapter.pick(ctx)
  end)

  if not ok_run then
    H.notify_err("picker adapter error (" .. backend .. "): " .. tostring(err_run))
  end
end

-- ---- helpers -------------------------------------------------------------

---@param items string|checkmate.picker.Item
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
