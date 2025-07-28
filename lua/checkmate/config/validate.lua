local M = {}

-- new vim.validate signature in 0.11
local has_new_validate = vim.fn.has("nvim-0.11") == 1

-- compatibility wrapper
-- TODO: this can be removed when we drop support for v0.10
-- e.g. `local validate = vim.validate`
local validate = has_new_validate and vim.validate
  or function(name, value, expected, optional_or_msg, msg)
    local spec = {}

    local optional = false
    local message = nil

    if type(optional_or_msg) == "boolean" then
      optional = optional_or_msg
      message = msg
    elseif type(optional_or_msg) == "string" then
      message = optional_or_msg
    end

    if type(expected) == "string" then
      spec[name] = { value, expected, optional }
    elseif type(expected) == "table" then
      spec[name] = { value, expected, optional }
    elseif type(expected) == "function" then
      spec[name] = { value, expected, message or "custom validation failed" }
    end

    -- pre-0.11-style vim.validate
    vim.validate(spec)
  end

-- create enum validators
local function enum(valid_values)
  return function(value)
    if vim.tbl_contains(valid_values, value) then
      return true
    end
    return false, "must be one of: " .. table.concat(valid_values, ", ")
  end
end

-- create custom validators
local function custom(validator_fn, error_msg)
  return function(value)
    local ok = validator_fn(value)
    return ok, not ok and error_msg or nil
  end
end

local function validate_keymap(mapping, key)
  if mapping == false then
    return true
  end

  if type(mapping) ~= "table" then
    return false, string.format("keys.%s must be false or a table", key)
  end

  -- get rhs from either dict or sequence form
  local rhs = mapping.rhs or mapping[1]
  if not rhs then
    return false, string.format("keys.%s missing rhs", key)
  end

  local rhs_type = type(rhs)
  if rhs_type ~= "string" and rhs_type ~= "function" then
    return false, string.format("keys.%s.rhs must be string or function", key)
  end

  return true
end

local function validate_todo_states(states)
  if not states then
    return true
  end

  local seen_markers = {}
  local seen_markdown = {}

  for name, def in pairs(states) do
    validate(name, def, "table")
    validate(name .. ".marker", def.marker, "string")
    validate(name .. ".order", def.order, "number", true)

    -- `marker` validations
    if #def.marker == 0 then
      return false, string.format("todo_states.%s.marker cannot be empty", name)
    end

    -- `markdown` validation
    local markdown = def.markdown
    if name == "unchecked" then
      markdown = markdown or " "
    elseif name == "checked" then
      markdown = markdown or { "x", "X" }
    elseif not markdown then
      return false, string.format("todo_states.%s.markdown is required for custom states", name)
    end

    -- normalize markdown to array
    if markdown then
      markdown = type(markdown) == "string" and { markdown } or markdown
      if type(markdown) ~= "table" then
        return false, string.format("todo_states.%s.markdown must be string or table", name)
      end

      for i, md in ipairs(markdown) do
        if type(md) ~= "string" then
          return false, string.format("todo_states.%s.markdown[%d] must be string", name, i)
        end
      end
    end

    -- check duplicates
    if seen_markers[def.marker] then
      return false,
        string.format("todo_states '%s' and '%s' have duplicate marker: %s", name, seen_markers[def.marker], def.marker)
    end
    seen_markers[def.marker] = name

    if markdown then
      for _, md in ipairs(markdown) do
        if seen_markdown[md] then
          return false,
            string.format("todo_states '%s' and '%s' have duplicate markdown: [%s]", name, seen_markdown[md], md)
        end
        seen_markdown[md] = name
      end
    end
  end

  return true
end

local function validate_metadata(metadata)
  if not metadata then
    return true
  end

  for name, props in pairs(metadata) do
    validate("metadata." .. name, props, "table")

    validate(name .. ".get_value", props.get_value, "function", true)
    validate(name .. ".sort_order", props.sort_order, "number", true)
    validate(name .. ".on_add", props.on_add, "function", true)
    validate(name .. ".on_remove", props.on_remove, "function", true)
    validate(name .. ".on_change", props.on_change, "function", true)
    validate(name .. ".select_on_insert", props.select_on_insert, "boolean", true)

    -- style (can be table or function)
    if props.style ~= nil then
      validate(name .. ".style", props.style, function(v)
        return type(v) == "table" or type(v) == "function"
      end, "table or function")
    end

    if props.jump_to_on_insert ~= nil and props.jump_to_on_insert ~= false then
      validate(
        name .. ".jump_to_on_insert",
        props.jump_to_on_insert,
        enum({ "tag", "value" }),
        "'tag', 'value', or false"
      )
    end

    if props.choices then
      validate(name .. ".choices", props.choices, function(v)
        return type(v) == "table" or type(v) == "function"
      end, "table or function")

      if type(props.choices) == "table" then
        for i, choice in ipairs(props.choices) do
          validate(name .. ".choices[" .. i .. "]", choice, "string")
        end
      end
    end

    if props.key then
      validate(name .. ".key", props.key, { "string", "table" }, "string or table")
    end

    if props.aliases then
      validate(name .. ".aliases", props.aliases, "table")
      for i, alias in ipairs(props.aliases) do
        validate(name .. ".aliases[" .. i .. "]", alias, "string")
      end
    end
  end

  return true
end

function M.validate_options(opts)
  if not opts then
    return true
  end

  if type(opts) ~= "table" then
    return false, "Options must be a table"
  end

  local ok, err = pcall(function()
    validate("enabled", opts.enabled, "boolean", true)
    validate("notify", opts.notify, "boolean", true)
    validate("enter_insert_after_new", opts.enter_insert_after_new, "boolean", true)
    validate("files", opts.files, "table", true)
    validate("show_todo_count", opts.show_todo_count, "boolean", true)
    validate("todo_count_recursive", opts.todo_count_recursive, "boolean", true)
    validate("use_metadata_keymaps", opts.use_metadata_keymaps, "boolean", true)
    validate("disable_ts_highlights", opts.disable_ts_highlights, "boolean", true)
    validate("log", opts.log, "table", true)
    validate("ui", opts.ui, "table", true)
    validate("style", opts.style, "table", true)
    validate("smart_toggle", opts.smart_toggle, "table", true)
    validate("archive", opts.archive, "table", true)
    validate("linter", opts.linter, "table", true)

    if opts.todo_count_position ~= nil then
      validate("todo_count_position", opts.todo_count_position, enum({ "eol", "inline" }))
    end

    if opts.default_list_marker ~= nil then
      validate("default_list_marker", opts.default_list_marker, enum({ "-", "*", "+" }))
    end

    if opts.todo_count_formatter ~= nil then
      validate("todo_count_formatter", opts.todo_count_formatter, "function")
    end

    if opts.files then
      for i, pattern in ipairs(opts.files) do
        validate("files[" .. i .. "]", pattern, "string")
      end
    end

    if opts.log then
      validate("log.use_buffer", opts.log.use_buffer, "boolean", true)
      validate("log.use_file", opts.log.use_file, "boolean", true)
      validate("log.file_path", opts.log.file_path, "string", true)

      if opts.log.level ~= nil then
        validate("log.level", opts.log.level, function(v)
          return type(v) == "string" or type(v) == "number"
        end, "string or number")
      end
    end

    if opts.keys and opts.keys ~= false then
      validate("keys", opts.keys, "table")
      for lhs, mapping in pairs(opts.keys) do
        local keymap_ok, keymap_err = validate_keymap(mapping, lhs)
        if not keymap_ok then
          error(keymap_err)
        end
      end
    end

    ---Remove in v0.11
    ---@deprecated todo_markers
    if opts.todo_markers then
      validate("todo_markers", opts.todo_markers, "table")

      if opts.todo_markers.checked then
        validate("todo_markers.checked", opts.todo_markers.checked, "string")
        validate(
          "todo_markers.checked",
          opts.todo_markers.checked,
          custom(function(v)
            return #v > 0
          end, "non-empty string")
        )
      end

      if opts.todo_markers.unchecked then
        validate("todo_markers.unchecked", opts.todo_markers.unchecked, "string")
        validate(
          "todo_markers.unchecked",
          opts.todo_markers.unchecked,
          custom(function(v)
            return #v > 0
          end, "non-empty string")
        )
      end
    end

    -- todo_states
    local states_ok, states_err = validate_todo_states(opts.todo_states)
    if not states_ok then
      error(states_err)
    end

    if opts.ui and opts.ui.picker then
      local picker = opts.ui.picker
      if type(picker) == "string" then
        validate("ui.picker", picker, enum({ "telescope", "snacks", "mini" }), "one of: telescope, snacks, mini")
      else
        validate("ui.picker", picker, function(v)
          return type(v) == "function" or v == false
        end, "string, function, or false")
      end
    end

    if opts.style then
      for group, hl in pairs(opts.style) do
        validate("style." .. group, hl, "table", "highlight definition table")
      end
    end

    if opts.smart_toggle then
      validate("smart_toggle.enabled", opts.smart_toggle.enabled, "boolean", true)
      validate("smart_toggle.include_cycle", opts.smart_toggle.include_cycle, "boolean", true)

      local toggle_validator = enum({ "all_children", "direct_children", "none" })
      for _, field in ipairs({ "check_down", "uncheck_down", "check_up", "uncheck_up" }) do
        if opts.smart_toggle[field] ~= nil then
          validate("smart_toggle." .. field, opts.smart_toggle[field], toggle_validator)
        end
      end
    end

    if opts.archive then
      validate("archive.parent_spacing", opts.archive.parent_spacing, "number", true)
      validate("archive.newest_first", opts.archive.newest_first, "boolean", true)
      validate("archive.heading", opts.archive.heading, "table", true)

      if opts.archive.heading then
        validate("archive.heading.title", opts.archive.heading.title, "string", true)

        if opts.archive.heading.level ~= nil then
          validate(
            "archive.heading.level",
            opts.archive.heading.level,
            custom(function(v)
              return type(v) == "number" and v >= 1 and v <= 6
            end, "number between 1-6")
          )
        end
      end
    end

    if opts.linter then
      validate("linter.enabled", opts.linter.enabled, "boolean", true)
      validate("linter.severity", opts.linter.severity, "table", true)
      validate("linter.verbose", opts.linter.verbose, "boolean", true)
    end

    local meta_ok, meta_err = validate_metadata(opts.metadata)
    if not meta_ok then
      error(meta_err)
    end
  end)

  if not ok then
    -- get the actual error message from vim.validate
    local error_msg = tostring(err):match("^[^:]+:%d+:%s*(.+)$") or tostring(err)
    return false, error_msg
  end

  return true
end

return M
