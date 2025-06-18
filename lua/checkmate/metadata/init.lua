local M = {}

M._deprecation_msg_shown = false

---Creates a metadata context object
---@param todo_item checkmate.TodoItem Todo item containing the metadata
---@param meta_name string The metadata tag name (canonical, not alias)
---@param value string Metadata value
---@param bufnr integer Buffer number
---@return checkmate.MetadataContext
function M.create_context(todo_item, meta_name, value, bufnr)
  local todo = require("checkmate.util").build_todo(todo_item)
  return {
    value = value,
    name = meta_name,
    ---@type checkmate.Todo
    todo = todo,
    buffer = bufnr,
  }
end

---Evaluates a `metadata.style` (table or getter function) to return a highlight tbl
---Handles both legacy and new function signatures
--- TODO: remove legacy in v0.10+
---
---@param meta_props checkmate.MetadataProps Metadata properties, from the configuration
---@param context checkmate.MetadataContext
---@return vim.api.keyset.highlight hl The highlight table
function M.evaluate_style(meta_props, context)
  local style = meta_props.style
  if type(style) ~= "function" then
    ---@cast style vim.api.keyset.highlight
    -- return static style as-is
    return style
  end
  ---@cast style checkmate.StyleFn

  --we determine new vs. legacy by just trying it and seeing if new fails
  local success, result = pcall(style, context)

  if success then
    return result
  else
    -- failed, try legacy signature
    M.show_deprecation_msg()
    success, result = pcall(style, context.value)
    if success then
      return result
    else
      return {}
    end
  end
end

---Evaluates a metadata value getter function
---Handles both legacy and new signatures
---
--- TODO: remove legacy in v0.10+
---
---@param meta_props checkmate.MetadataProps Metadata properties, from the configuration
---@param context checkmate.MetadataContext?
---@return string value value
function M.evaluate_value(meta_props, context)
  local get_value = meta_props.get_value
  if not get_value then
    return ""
  end

  local success, result = pcall(function()
    local info = debug.getinfo(get_value, "u")

    -- if no params, this is legacy
    if info.nparams == 0 or not context then
      return tostring(get_value() or "")
    end

    return tostring(get_value(context) or "")
  end)

  if success then
    return result
  else
    vim.notify("Checkmate: error calling get_value: " .. result, vim.log.levels.ERROR)
    return ""
  end
end

---@param meta_props checkmate.MetadataProps
---@param context checkmate.MetadataContext
---@param cb fun(items: string[])
---@return table?
function M.evaluate_choices(meta_props, context, cb)
  local choices = meta_props.choices or {}

  if not choices then
    return cb({})
  end

  local function get_sanitized_items(items)
    if type(items) ~= "table" then
      return {}
    end
    local sanitized = {}
    for _, item in pairs(items) do
      if type(item) == "string" then
        local trimmed = vim.trim(item)
        if trimmed ~= "" then
          table.insert(sanitized, trimmed)
        end
      elseif type(item) == "number" then
        table.insert(sanitized, tostring(item))
      else
        -- wrong type of 'item'
      end
    end
    return sanitized
  end

  if type(choices) == "table" then
    local sanitized = get_sanitized_items(choices)
    return cb(sanitized)
  elseif type(choices) == "function" then
    local state = {
      callback_invoked = false,
      timer = nil, ---@type uv.uv_timer_t|nil
      bufnr = context.buffer,
    }

    local function cleanup()
      if state.timer then
        state.timer:stop()
        state.timer:close()
        state.timer = nil
      end
    end

    local wrapped_callback = function(items)
      if state.callback_invoked then
        vim.notify(
          string.format(
            "Checkmate: 'choices' function for @%s invoked callback multiple times -- check your implementation",
            context.name
          ),
          vim.log.levels.WARN
        )
        return
      end

      if not vim.api.nvim_buf_is_valid(state.bufnr) then
        cleanup()
        return
      end

      state.callback_invoked = true
      cleanup()

      if type(items) ~= "table" then
        vim.notify(
          string.format("Checkmate: 'choices' for @%s must return a table, got %s", context.name, type(items)),
          vim.log.levels.WARN
        )
        return cb({})
      end

      local sanitized = get_sanitized_items(items)
      return cb(sanitized)
    end

    local success, result = pcall(choices, context, vim.schedule_wrap(wrapped_callback))

    if success then
      -- user returned items directly (sync)
      if type(result) == "table" and not state.callback_invoked then
        cleanup()
        local sanitized = get_sanitized_items(result)
        return cb(sanitized)
      end

      -- user using async pattern
      if not state.callback_invoked then
        state.timer = vim.uv.new_timer()
        state.timer:start(
          5000,
          0,
          vim.schedule_wrap(function()
            if not state.callback_invoked then
              state.callback_invoked = true
              cleanup()
              vim.notify(
                string.format("Checkmate: 'choices' function timed out for @%s", context.name),
                vim.log.levels.WARN
              )
              cb({})
            end
          end)
        )
      end
      -- async handling via callback
      return
    end

    -- 2-param call failed, try with just context
    success, result = pcall(choices, context)
    if success and type(result) == "table" then
      cleanup()
      local sanitized = get_sanitized_items(result)
      return cb(sanitized)
    end

    -- try with no params
    success, result = pcall(choices)
    if success and type(result) == "table" then
      cleanup()
      local sanitized = get_sanitized_items(result)
      return cb(sanitized)
    end

    -- all attempts failed
    vim.notify(string.format("Checkmate: failed to get choices for @%s", context.name), vim.log.levels.ERROR)
    cleanup()
    cb({})
  end
end

---Gets choices for a metadata tag
---Requires a todo item and buffer to provide sufficient context
---to the 'choices' function supplied by the user
---@param meta_name string The metadata tag name (or alias)
---@param callback fun(items: string[])
---@param todo_item checkmate.TodoItem
---@param bufnr integer
function M.get_choices(meta_name, callback, todo_item, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return callback({})
  end

  local canonical_name = M.get_canonical_name(meta_name)
  if not canonical_name then
    return callback({})
  end

  local meta_props = M.get_meta_props(canonical_name)
  if not meta_props then
    return callback({})
  end

  ---@type checkmate.MetadataEntry
  local entry = todo_item.metadata and todo_item.metadata.by_tag and todo_item.metadata.by_tag[canonical_name]
  local value = entry and entry.value or ""

  local context = M.create_context(todo_item, canonical_name, value, bufnr)

  M.evaluate_choices(meta_props, context, callback)
end

---Gets the canonical name for a metadata tag (resolving aliases)
---@param meta_name string The metadata tag name (might be an alias)
---@return string|nil canonical_name The canonical metadata name, or nil if it doesn't exist
function M.get_canonical_name(meta_name)
  local config = require("checkmate.config")

  -- already a canonical name
  if config.options.metadata[meta_name] then
    return meta_name
  end

  -- check aliases
  for canonical_name, meta_props in pairs(config.options.metadata) do
    if meta_props.aliases then
      for _, alias in ipairs(meta_props.aliases) do
        if alias == meta_name then
          return canonical_name
        end
      end
    end
  end

  return nil
end

---Gets metadata properties by name
---@param meta_name string Metadata name or alias
---@return checkmate.MetadataProps? meta_props The metadata props (config)
function M.get_meta_props(meta_name)
  local config = require("checkmate.config")
  local canonical = M.get_canonical_name(meta_name)
  return config.options.metadata[canonical]
end

---Checks if a todo item has a specific metadata tag
---@param todo_item checkmate.TodoItem Todo item
---@param meta_name string Metadata tag name (or alias)
---@param predicate? string|fun(meta_value):boolean
---@return boolean has_metadata Whether the given todo has the metadata, only if passing the given value predicate (optional)
---@return checkmate.MetadataEntry? entry Metadata entry if found
function M.has_metadata(todo_item, meta_name, predicate)
  if not todo_item.metadata or not todo_item.metadata.by_tag then
    return false, nil
  end

  local canonical = M.get_canonical_name(meta_name)
  local entry = todo_item.metadata.by_tag[canonical] or todo_item.metadata.by_tag[meta_name]

  if not entry then
    return false, nil
  end

  if predicate ~= nil then
    local pass = false
    if type(predicate) == "string" then
      pass = entry.value == predicate
    end
    if type(predicate) == "function" then
      pass = predicate(entry.value)
    end
    if pass then
      return true, entry
    else
      return false
    end
  else
    return true, entry
  end
end

--- Find metadata entry at col position on todo line
---@param todo_item checkmate.TodoItem
---@param col integer 0-based column position
---@return checkmate.MetadataEntry?
function M.find_metadata_at_col(todo_item, col)
  local metadata = todo_item.metadata.entries
  if not metadata or #metadata == 0 then
    return nil
  end

  for _, entry in ipairs(metadata) do
    -- range is end-exclusive so we check col < end_col
    if col >= entry.range.start.col and col < entry.range["end"].col then
      return entry
    end
  end

  return nil
end

function M.show_deprecation_msg()
  if not M._deprecation_msg_shown then
    vim.schedule(function()
      vim.notify(
        "Checkmate: One or more metadata are using the deprecated `style` function. Please update to accept a `MetadataContext` object.",
        vim.log.levels.WARN
      )
      M._deprecation_msg_shown = true
    end)
  end
end

---Reset internal state
function M.reset()
  M._deprecation_msg_shown = false
end

return M
