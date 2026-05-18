local M = {}

local log = require("checkmate.log")

---@class checkmate.picker.CompletionCommonOpts
---@field schedule? boolean Defaults to true. Set false only for synchronous tests or known synchronous internal paths
---@field source? string label used in log messages
---@field on_cancel? fun()

--- Resolve a backend entry or picker completion value to the original picker item.
---
--- The picker engine's completion contract is item-based: custom picker functions
--- and adapters should call complete(item), where item is a normalized
--- checkmate.picker.Item. Backend adapters may pass their own entry table instead
--- as long as they preserve the normalized item under `__cm_item`.
---@param entry any
---@return checkmate.picker.Item|nil
function M.resolve_item(entry)
  if entry == nil then
    return nil
  end

  if type(entry) ~= "table" then
    return nil
  end

  if entry.__cm_item ~= nil then
    return entry.__cm_item
  end

  if entry.text ~= nil and entry.value ~= nil then
    -- has shape of checkmate.picker.Item, okay to return
    return entry
  end

  return nil
end

---@class checkmate.picker.MakeCompletionFnOpts : checkmate.picker.CompletionCommonOpts
---@field resolve? fun(input: any): any?
---@field on_complete fun(value: any, input: any)
---@field invalid_message? fun(input: any): string

--- Create the shared one-shot latch used by picker selections.
--- i.e., execute once for the initial call
---
--- Public wrappers below decide what a non-nil completion value means:
--- - item completion resolves backend entries to checkmate.picker.Item
--- - value completion accepts the domain value directly
---@param opts checkmate.picker.MakeCompletionFnOpts
---@return fun(input: any?) complete
local function make_completion_fn(opts)
  opts = opts or {}
  local schedule = opts.schedule ~= false
  local source = opts.source or "[picker]"
  local resolve = opts.resolve
  local on_complete = opts.on_complete
  local on_cancel = opts.on_cancel
  local invalid_message = opts.invalid_message
  local completed = false

  local function run(fn)
    if schedule then
      vim.schedule(fn)
    else
      fn()
    end
  end

  return function(input)
    if completed then
      log.fmt_warn("%s `complete` called multiple times", source)
      return
    end
    completed = true

    if input == nil then
      if on_cancel then
        run(function()
          local ok_cancel, err_cancel = pcall(on_cancel)
          if not ok_cancel then
            log.fmt_error("%s cancel callback failed: %s", source, tostring(err_cancel))
          end
        end)
      end
      return
    end

    local value = input
    if resolve then
      value = resolve(input)
      if value == nil then
        if invalid_message then
          log.fmt_warn("%s", invalid_message(input))
        else
          log.fmt_warn("%s invalid completion value: %s", source, vim.inspect(input))
        end
        return
      end
    end

    run(function()
      local ok_complete, err_complete = pcall(on_complete, value, input)
      if not ok_complete then
        log.fmt_error("%s complete callback failed: %s", source, tostring(err_complete))
      end
    end)
  end
end

---@class checkmate.picker.MakeItemCompletionOpts : checkmate.picker.CompletionCommonOpts
---@field after_item_select? fun(item: checkmate.picker.Item, entry: any)

---@alias checkmate.picker.after_item_select fun(item: checkmate.picker.Item, entry: any)

--- Create an item completion callback for picker-engine/backend selections
---
--- Accepts a normalized checkmate.picker.Item or backend entry with __cm_item.
--- Nil cancels. Invalid non-nil completions are ignored with a warning
---@param ctx checkmate.picker.AdapterContext
---@param opts? checkmate.picker.MakeItemCompletionOpts
---@return fun(entry: any) complete
function M.make_item_completion(ctx, opts)
  opts = opts or {}
  local after_item_select = opts.after_item_select

  return make_completion_fn({
    schedule = opts.schedule,
    source = opts.source or "[picker]",
    on_cancel = opts.on_cancel,
    resolve = M.resolve_item,
    invalid_message = function(entry)
      return ("[picker] complete called with invalid picker item: %s"):format(vim.inspect(entry))
    end,
    on_complete = function(item, entry)
      if ctx.on_select_item then
        local ok_sel, err_sel = pcall(ctx.on_select_item, item)
        if not ok_sel then
          log.fmt_error("[picker] on_select_item failed: %s", tostring(err_sel))
        end
      end

      if after_item_select then
        local ok_after, err_after = pcall(after_item_select, item, entry)
        if not ok_after then
          log.fmt_error("[picker] after_item_select failed: %s", tostring(err_after))
        end
      end
    end,
  })
end

---@class checkmate.picker.MakeValueCompletionOpts : checkmate.picker.CompletionCommonOpts

--- Create a value completion callback for feature-level custom pickers
---
--- Accepts the selected domain value directly: a metadata value, a move target,
--- or any other feature-owned payload. Nil cancels
---@param on_complete fun(value: any)
---@param opts? checkmate.picker.MakeValueCompletionOpts
---@return fun(value: any?) complete
function M.make_value_completion(on_complete, opts)
  opts = opts or {}

  return make_completion_fn({
    schedule = opts.schedule,
    source = opts.source or "[picker]",
    on_cancel = opts.on_cancel,
    on_complete = function(value)
      on_complete(value)
    end,
  })
end

return M
