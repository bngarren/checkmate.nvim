local M = {}

local function Validator()
  local errors = {}

  local function add_error(path, message)
    table.insert(errors, string.format("%s: %s", path, message))
  end

  local function check(path, value, validator_fn, optional)
    if value == nil then
      if not optional then
        add_error(path, "required field is missing")
      end
      return
    end

    local ok, err = validator_fn(value)
    if not ok then
      add_error(path, err or "validation failed")
    end
  end

  local function get_errors()
    return errors
  end

  local function has_errors()
    return #errors > 0
  end

  return {
    check = check,
    add_error = add_error,
    get_errors = get_errors,
    has_errors = has_errors,
  }
end

local validators = {
  is_boolean = function(v)
    if type(v) == "boolean" then
      return true
    end
    return false, "must be boolean"
  end,

  is_string = function(v)
    if type(v) == "string" then
      return true
    end
    return false, "must be string"
  end,

  is_number = function(v)
    if type(v) == "number" then
      return true
    end
    return false, "must be number"
  end,

  is_table = function(v)
    if type(v) == "table" then
      return true
    end
    return false, "must be table"
  end,

  is_function = function(v)
    if type(v) == "function" then
      return true
    end
    return false, "must be function"
  end,

  enum = function(valid_values)
    return function(v)
      if vim.tbl_contains(valid_values, v) then
        return true
      end
      return false, "must be one of: " .. table.concat(valid_values, ", ")
    end
  end,

  one_of_types = function(types)
    return function(v)
      local vtype = type(v)
      if vim.tbl_contains(types, vtype) then
        return true
      end
      return false, "must be one of types: " .. table.concat(types, ", ")
    end
  end,

  non_empty_string = function(v)
    if type(v) == "string" and #v > 0 then
      return true
    end
    return false, "must be non-empty string"
  end,

  range = function(min, max)
    return function(v)
      if type(v) == "number" and v >= min and v <= max then
        return true
      end
      return false, string.format("must be number between %d and %d", min, max)
    end
  end,
}

local function validate_keymap(mapping)
  local errors = {}

  if mapping == false then
    return errors
  end

  if type(mapping) ~= "table" then
    table.insert(errors, "must be false or table")
    return errors
  end

  local rhs = mapping.rhs or mapping[1]
  if not rhs then
    table.insert(errors, "missing rhs")
  elseif type(rhs) ~= "string" and type(rhs) ~= "function" then
    table.insert(errors, "rhs must be string or function")
  end

  local desc = mapping.desc or mapping[2]
  if desc ~= nil and type(desc) ~= "string" then
    table.insert(errors, "desc must be string if provided")
  end

  local modes = mapping.modes or mapping[3]
  if modes ~= nil then
    if type(modes) ~= "table" then
      table.insert(errors, "modes must be table of strings")
    else
      for i, m in ipairs(modes) do
        if type(m) ~= "string" then
          table.insert(errors, string.format("modes[%d] must be string", i))
        end
      end
    end
  end

  return errors
end

local function validate_todo_states(states)
  local errors = {}

  if not states then
    return errors
  end

  if type(states) ~= "table" then
    table.insert(errors, "must be table")
    return errors
  end

  local seen_markers = {}
  local seen_markdown = {}

  for name, def in pairs(states) do
    local prefix = name

    if type(def) ~= "table" then
      table.insert(errors, string.format("%s: must be table", prefix))
    else
      if type(def.marker) ~= "string" then
        table.insert(errors, string.format("%s.marker: must be string", prefix))
      else
        local trimmed_marker = vim.trim(def.marker)
        if #trimmed_marker == 0 then
          table.insert(errors, string.format("%s.marker: cannot be empty", prefix))
        else
          if seen_markers[def.marker] then
            table.insert(
              errors,
              string.format("%s and %s have duplicate marker: %s", name, seen_markers[def.marker], def.marker)
            )
          else
            seen_markers[def.marker] = name
          end
        end
      end

      if def.order ~= nil and type(def.order) ~= "number" then
        table.insert(errors, string.format("%s.order: must be number", prefix))
      end

      if def.type ~= nil then
        local valid_types = { "incomplete", "complete", "inactive" }
        if not vim.tbl_contains(valid_types, def.type) then
          table.insert(errors, string.format("%s.type: must be one of: %s", prefix, table.concat(valid_types, ", ")))
        end
      end

      local markdown = def.markdown

      if name == "unchecked" then
        markdown = markdown or " "
      elseif name == "checked" then
        markdown = markdown or { "x", "X" }
      elseif not markdown then
        table.insert(errors, string.format("%s.markdown: required for custom states", prefix))
        markdown = nil
      end

      if markdown then
        local markdown_array = type(markdown) == "string" and { markdown } or markdown

        if type(markdown_array) ~= "table" then
          table.insert(errors, string.format("%s.markdown: must be string or table", prefix))
        else
          for i, md in ipairs(markdown_array) do
            if type(md) ~= "string" then
              table.insert(errors, string.format("%s.markdown[%d]: must be string", prefix, i))
            else
              if seen_markdown[md] then
                table.insert(
                  errors,
                  string.format("%s and %s have duplicate markdown: [%s]", name, seen_markdown[md], md)
                )
              else
                seen_markdown[md] = name
              end
            end
          end
        end
      end
    end
  end

  return errors
end

local function validate_metadata(metadata)
  local errors = {}

  if not metadata then
    return errors
  end

  if type(metadata) ~= "table" then
    table.insert(errors, "must be table")
    return errors
  end

  for name, props in pairs(metadata) do
    local prefix = name

    if type(props) ~= "table" then
      table.insert(errors, string.format("%s: must be table", prefix))
    else
      if props.style ~= nil then
        local style_type = type(props.style)
        if style_type ~= "table" and style_type ~= "function" then
          table.insert(errors, string.format("%s.style: must be table or function", prefix))
        end
      end

      if props.get_value ~= nil and type(props.get_value) ~= "function" then
        table.insert(errors, string.format("%s.get_value: must be function", prefix))
      end

      if props.choices ~= nil then
        local choices_type = type(props.choices)
        if choices_type == "table" then
          for i, choice in ipairs(props.choices) do
            if type(choice) ~= "string" then
              table.insert(errors, string.format("%s.choices[%d]: must be string", prefix, i))
            end
          end
        elseif choices_type ~= "function" then
          table.insert(errors, string.format("%s.choices: must be table or function", prefix))
        end
      end

      if props.key ~= nil then
        local key_type = type(props.key)
        if key_type == "string" then
          -- valid
        elseif key_type == "table" then
          if #props.key == 2 and type(props.key[1]) == "string" and type(props.key[2]) == "string" then
            -- valid tuple form
          else
            for i, k in ipairs(props.key) do
              if type(k) ~= "string" then
                table.insert(errors, string.format("%s.key[%d]: must be string", prefix, i))
              end
            end
          end
        else
          table.insert(errors, string.format("%s.key: must be string or table", prefix))
        end
      end

      if props.aliases ~= nil then
        if type(props.aliases) ~= "table" then
          table.insert(errors, string.format("%s.aliases: must be table", prefix))
        else
          for i, alias in ipairs(props.aliases) do
            if type(alias) ~= "string" then
              table.insert(errors, string.format("%s.aliases[%d]: must be string", prefix, i))
            end
          end
        end
      end

      if props.sort_order ~= nil and type(props.sort_order) ~= "number" then
        table.insert(errors, string.format("%s.sort_order: must be number", prefix))
      end

      if props.jump_to_on_insert ~= nil and props.jump_to_on_insert ~= false then
        if not vim.tbl_contains({ "tag", "value" }, props.jump_to_on_insert) then
          table.insert(errors, string.format("%s.jump_to_on_insert: must be 'tag', 'value', or false", prefix))
        end
      end

      if props.select_on_insert ~= nil and type(props.select_on_insert) ~= "boolean" then
        table.insert(errors, string.format("%s.select_on_insert: must be boolean", prefix))
      end

      if props.on_add ~= nil and type(props.on_add) ~= "function" then
        table.insert(errors, string.format("%s.on_add: must be function", prefix))
      end

      if props.on_remove ~= nil and type(props.on_remove) ~= "function" then
        table.insert(errors, string.format("%s.on_remove: must be function", prefix))
      end

      if props.on_change ~= nil and type(props.on_change) ~= "function" then
        table.insert(errors, string.format("%s.on_change: must be function", prefix))
      end
    end
  end

  return errors
end

local function validate_list_continuation(list_cont)
  local errors = {}

  if not list_cont then
    return errors
  end

  if type(list_cont) ~= "table" then
    table.insert(errors, "must be table")
    return errors
  end

  if list_cont.enabled ~= nil and type(list_cont.enabled) ~= "boolean" then
    table.insert(errors, "enabled: must be boolean")
  end

  if list_cont.split_line ~= nil and type(list_cont.split_line) ~= "boolean" then
    table.insert(errors, "split_line: must be boolean")
  end

  if list_cont.keys ~= nil then
    if type(list_cont.keys) ~= "table" then
      table.insert(errors, "keys: must be table")
    else
      for key, mapping in pairs(list_cont.keys) do
        if type(key) ~= "string" then
          table.insert(errors, string.format("keys: key must be string (got %s)", type(key)))
        else
          local mapping_type = type(mapping)
          if mapping_type == "function" then
            -- valid
          elseif mapping_type == "table" then
            local rhs = mapping.rhs or mapping[1]
            if type(rhs) ~= "function" then
              table.insert(errors, string.format("keys.%s: rhs must be function", key))
            end
            local desc = mapping.desc or mapping[2]
            if desc ~= nil and type(desc) ~= "string" then
              table.insert(errors, string.format("keys.%s: desc must be string if provided", key))
            end
          else
            table.insert(errors, string.format("keys.%s: must be function or {rhs=function, desc?=string}", key))
          end
        end
      end
    end
  end

  return errors
end

local function validate_smart_toggle(smart_toggle)
  local errors = {}

  if not smart_toggle then
    return errors
  end

  if type(smart_toggle) ~= "table" then
    table.insert(errors, "must be table")
    return errors
  end

  if smart_toggle.enabled ~= nil and type(smart_toggle.enabled) ~= "boolean" then
    table.insert(errors, "enabled: must be boolean")
  end

  if smart_toggle.include_cycle ~= nil and type(smart_toggle.include_cycle) ~= "boolean" then
    table.insert(errors, "include_cycle: must be boolean")
  end

  local valid_propagation = { "all_children", "direct_children", "none" }
  local propagation_fields = { "check_down", "uncheck_down", "check_up", "uncheck_up" }

  for _, field in ipairs(propagation_fields) do
    if smart_toggle[field] ~= nil then
      if not vim.tbl_contains(valid_propagation, smart_toggle[field]) then
        table.insert(errors, string.format("%s: must be one of: %s", field, table.concat(valid_propagation, ", ")))
      end
    end
  end

  return errors
end

local function validate_archive(archive)
  local errors = {}

  if not archive then
    return errors
  end

  if type(archive) ~= "table" then
    table.insert(errors, "must be table")
    return errors
  end

  if archive.parent_spacing ~= nil and type(archive.parent_spacing) ~= "number" then
    table.insert(errors, "parent_spacing: must be number")
  end

  if archive.newest_first ~= nil and type(archive.newest_first) ~= "boolean" then
    table.insert(errors, "newest_first: must be boolean")
  end

  if archive.heading ~= nil then
    if type(archive.heading) ~= "table" then
      table.insert(errors, "heading: must be table")
    else
      if archive.heading.title ~= nil and type(archive.heading.title) ~= "string" then
        table.insert(errors, "heading.title: must be string")
      end

      if archive.heading.level ~= nil then
        if type(archive.heading.level) ~= "number" then
          table.insert(errors, "heading.level: must be number")
        elseif archive.heading.level < 1 or archive.heading.level > 6 then
          table.insert(errors, "heading.level: must be between 1 and 6")
        end
      end
    end
  end

  return errors
end

local function validate_linter(linter)
  local errors = {}

  if not linter then
    return errors
  end

  if type(linter) ~= "table" then
    table.insert(errors, "must be table")
    return errors
  end

  if linter.enabled ~= nil and type(linter.enabled) ~= "boolean" then
    table.insert(errors, "enabled: must be boolean")
  end

  if linter.verbose ~= nil and type(linter.verbose) ~= "boolean" then
    table.insert(errors, "verbose: must be boolean")
  end

  if linter.severity ~= nil then
    if type(linter.severity) ~= "table" then
      table.insert(errors, "severity: must be table")
    end
  end

  return errors
end

local function validate_ui(ui)
  local errors = {}

  if not ui then
    return errors
  end

  if type(ui) ~= "table" then
    table.insert(errors, "must be table")
    return errors
  end

  if ui.picker ~= nil then
    local picker_type = type(ui.picker)
    if picker_type == "string" then
      if not vim.tbl_contains({ "telescope", "snacks", "mini" }, ui.picker) then
        table.insert(errors, "picker: must be one of: telescope, snacks, mini")
      end
    elseif picker_type ~= "function" and ui.picker ~= false then
      table.insert(errors, "picker: must be string, function, or false")
    end
  end

  return errors
end

---@param opts checkmate.Config
---@return boolean success
---@return string[]? errors
function M.validate_options(opts)
  if not opts then
    return true, nil
  end

  if type(opts) ~= "table" then
    return false, { "options must be a table" }
  end

  local v = Validator()

  v.check("enabled", opts.enabled, validators.is_boolean, true)
  v.check("notify", opts.notify, validators.is_boolean, true)
  v.check("enter_insert_after_new", opts.enter_insert_after_new, validators.is_boolean, true)
  v.check("show_todo_count", opts.show_todo_count, validators.is_boolean, true)
  v.check("todo_count_recursive", opts.todo_count_recursive, validators.is_boolean, true)
  v.check("use_metadata_keymaps", opts.use_metadata_keymaps, validators.is_boolean, true)
  v.check("disable_ts_highlights", opts.disable_ts_highlights, validators.is_boolean, true)

  v.check("todo_count_position", opts.todo_count_position, validators.enum({ "eol", "inline" }), true)
  v.check("default_list_marker", opts.default_list_marker, validators.enum({ "-", "*", "+" }), true)

  v.check("todo_count_formatter", opts.todo_count_formatter, validators.is_function, true)

  v.check("log", opts.log, validators.is_table, true)
  v.check("style", opts.style, validators.is_table, true)

  if opts.files ~= nil then
    v.check("files", opts.files, validators.is_table)
    if type(opts.files) == "table" then
      for i, pattern in ipairs(opts.files) do
        v.check(string.format("files[%d]", i), pattern, validators.non_empty_string)
      end
    end
  end

  if opts.log then
    v.check("log.use_file", opts.log.use_file, validators.is_boolean, true)
    v.check("log.file_path", opts.log.file_path, validators.is_string, true)
    v.check("log.max_file_size", opts.log.max_file_size, validators.is_number, true)
    v.check("log.level", opts.log.level, validators.one_of_types({ "string", "number" }), true)
  end

  if opts.keys and opts.keys ~= false then
    v.check("keys", opts.keys, validators.is_table)
    if type(opts.keys) == "table" then
      for lhs, mapping in pairs(opts.keys) do
        if type(lhs) ~= "string" then
          v.add_error("keys", string.format("key '%s' must be string", tostring(lhs)))
        else
          local keymap_errors = validate_keymap(mapping)
          for _, err in ipairs(keymap_errors) do
            v.add_error("keys." .. lhs, err)
          end
        end
      end
    end
  end

  ---@deprecated Remove next version
  if opts.todo_markers then
    if type(opts.todo_markers) == "table" then
      v.check("todo_markers.checked", opts.todo_markers.checked, validators.non_empty_string, true)
      v.check("todo_markers.unchecked", opts.todo_markers.unchecked, validators.non_empty_string, true)
    else
      v.add_error("todo_markers", "must be table")
    end
  end

  if opts.style and type(opts.style) == "table" then
    for group, hl in pairs(opts.style) do
      if type(hl) ~= "table" then
        v.add_error("style." .. tostring(group), "must be table (highlight definition)")
      end
    end
  end

  if opts.todo_states then
    local state_errors = validate_todo_states(opts.todo_states)
    for _, err in ipairs(state_errors) do
      v.add_error("todo_states", err)
    end
  end

  if opts.metadata then
    local meta_errors = validate_metadata(opts.metadata)
    for _, err in ipairs(meta_errors) do
      v.add_error("metadata", err)
    end
  end

  if opts.list_continuation then
    local lc_errors = validate_list_continuation(opts.list_continuation)
    for _, err in ipairs(lc_errors) do
      v.add_error("list_continuation", err)
    end
  end

  if opts.smart_toggle then
    local st_errors = validate_smart_toggle(opts.smart_toggle)
    for _, err in ipairs(st_errors) do
      v.add_error("smart_toggle", err)
    end
  end

  if opts.archive then
    local archive_errors = validate_archive(opts.archive)
    for _, err in ipairs(archive_errors) do
      v.add_error("archive", err)
    end
  end

  if opts.linter then
    local linter_errors = validate_linter(opts.linter)
    for _, err in ipairs(linter_errors) do
      v.add_error("linter", err)
    end
  end

  if opts.ui then
    local ui_errors = validate_ui(opts.ui)
    for _, err in ipairs(ui_errors) do
      v.add_error("ui", err)
    end
  end

  if v.has_errors() then
    return false, v.get_errors()
  end

  return true, nil
end

return M
