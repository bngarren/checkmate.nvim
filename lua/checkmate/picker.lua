local M = {}

local function has_module(name)
  return pcall(require, name)
end

local function get_preferred_picker()
  local config = require("checkmate.config")
  local ui = config.options.ui

  if ui and ui.picker == false then
    return false
  end

  if not ui or not ui.picker then
    return nil
  end

  return ui.picker
end

-- default picker window dimensions
local DEFAULT_WIDTH = 0.4
local DEFAULT_HEIGHT = 20
local DEFAULT_MIN_WIDTH = 40

---@class SelectOpts
---@field prompt? string
---@field format_item? fun(item: string): string
--- matches the `vim.ui.select` |on_choice| signature (item?, idx?)
---@field on_choice? fun(choice?: any, ...)
---@field backend? checkmate.Picker
---@field kind? string Hint for picker plugins (passed to vim.ui.select)

--- Wraps on_choice to ensure it's only called once and handles cleanup
---@param on_choice fun(choice: string|nil, idx: integer|nil)
---@param cleanup? fun()
---@return fun(choice: string|nil, idx: integer|nil)
local function wrap_on_choice(on_choice, cleanup)
  local called = false
  return function(choice, idx)
    if called then
      return
    end
    called = true

    if cleanup then
      -- pcall to ensure cleanup doesn't break the callback
      pcall(cleanup)
    end

    on_choice(choice, idx)
  end
end

--- Opens a picker with 'items'
--- Uses the following rules to determine picker implementation:
---  - If config.ui.picker == false, use native vim.ui.select
---  - If config.ui.picker is nil (default), attempt to use an installed picker UI, or fallback to native
---  - If config.ui.picker is a function, run this in pcall, if fails, fallback to installed or native
---@param items string[] List of choices
---@param opts SelectOpts
function M.select(items, opts)
  opts = opts or {}

  if not items or #items == 0 then
    if opts.on_choice then
      opts.on_choice(nil, nil)
    end
    return
  end

  local backend = opts.backend or get_preferred_picker()

  local width = math.max(math.floor(vim.o.columns * DEFAULT_WIDTH), DEFAULT_MIN_WIDTH)
  local height = math.min(#items + 8, DEFAULT_HEIGHT)

  -- user passed a custom picker backend
  if type(backend) == "function" then
    local ok, result = pcall(function()
      return backend(
        items,
        { prompt = opts.prompt, format_item = opts.format_item, on_choice = opts.on_choice, kind = opts.kind }
      )
    end)
    if not ok then
      vim.notify("Checkmate: error with custom picker: " .. tostring(result), vim.log.levels.ERROR)
      -- reset backend and let it fall through
      backend = nil
    end
    return result
  end

  -- telescope
  if (backend == nil or backend == "telescope") and has_module("telescope.pickers") then
    local ok = pcall(function()
      local pickers = require("telescope.pickers")
      local finders = require("telescope.finders")
      local conf = require("telescope.config").values
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")
      local themes = require("telescope.themes")

      local wrapped_choice = wrap_on_choice(opts.on_choice)

      local theme_opts = themes.get_dropdown({
        winblend = 10,
        width = width,
        height = height,
        prompt_title = opts.prompt or "Select one of:",
        previewer = false,
        layout_config = {
          width = DEFAULT_WIDTH,
          height = height / vim.o.lines,
        },
      })

      pickers
        .new(theme_opts, {
          finder = finders.new_table({
            results = items,
            entry_maker = function(item)
              return {
                value = item,
                display = opts.format_item and opts.format_item(item) or item,
                ordinal = item,
              }
            end,
          }),
          sorter = conf.generic_sorter({}),
          attach_mappings = function(prompt_bufnr, map)
            -- handle selection
            actions.select_default:replace(function()
              local selection = action_state.get_selected_entry()
              actions.close(prompt_bufnr)

              if selection then
                -- find the index of the selected item
                local idx = nil
                for i, item in ipairs(items) do
                  if item == selection.value then
                    idx = i
                    break
                  end
                end
                wrapped_choice(selection.value, idx)
              else
                wrapped_choice(nil, nil)
              end
            end)

            -- handle cancellation (Esc, Ctrl-C)
            map("i", "<esc>", function()
              actions.close(prompt_bufnr)
              wrapped_choice(nil, nil)
            end)

            map("n", "<esc>", function()
              actions.close(prompt_bufnr)
              wrapped_choice(nil, nil)
            end)

            return true
          end,
        })
        :find()
    end)

    if ok then
      return
    end
    -- telescope failed, continue to next backend
  end

  -- snacks
  if (backend == nil or backend == "snacks") and has_module("snacks") then
    local ok = pcall(function()
      local snacks = require("snacks")

      ---@type snacks.picker.ui_select
      snacks.picker.select(items, {
        prompt = opts.prompt or "Select an item",
        format_item = opts.format_item,
        preview = false,
        kind = opts.kind,
      }, function(item, idx)
        -- snacks handles the callback, no need to wrap
        -- It calls with (nil, nil) on cancellation
        if opts.on_choice then
          opts.on_choice(item, idx)
        end
      end)
    end)

    if ok then
      return
    end
    -- snacks failed, continue to next
  end

  -- mini.pick
  if (backend == nil or backend == "mini") and has_module("mini.pick") then
    local ok = pcall(function()
      local pick = require("mini.pick")
      local wrapped_choice = wrap_on_choice(opts.on_choice)

      -- center position
      local row = math.floor((vim.o.lines - height) / 2)
      local col = math.floor((vim.o.columns - width) / 2)

      pick.ui_select(items, {
        prompt = opts.prompt or "Select an item",
        format_item = opts.format_item,
      }, function(item)
        -- mini.pick passes the item but not the index
        -- find the index manually
        local idx = nil
        if item then
          for i, v in ipairs(items) do
            if v == item then
              idx = i
              break
            end
          end
        end
        wrapped_choice(item, idx)
      end, {
        window = {
          config = {
            border = "rounded",
            width = width,
            height = height,
            relative = "editor",
            anchor = "NW",
            row = row,
            col = col,
            title = opts.prompt or "Select an item",
            title_pos = "center",
          },
        },
      })
    end)

    if ok then
      return
    end
    -- mini.pick failed, continue to native
  end

  -- Fallback to native vim.ui.select
  -- Note: If plugins like fzf-lua have registered their own vim.ui.select,
  -- this will use their implementation
  vim.ui.select(items, {
    prompt = opts.prompt,
    format_item = opts.format_item,
    kind = opts.kind or "checkmate_metadata",
  }, function(item, idx)
    if opts.on_choice then
      opts.on_choice(item, idx)
    end
  end)
end

return M
