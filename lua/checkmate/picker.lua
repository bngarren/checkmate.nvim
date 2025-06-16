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

-- Default window dimensions
local DEFAULT_WIDTH = 0.4
local DEFAULT_HEIGHT = 20
local DEFAULT_MIN_WIDTH = 40

---@class SelectOpts
---@field prompt? string
---@field format_item? fun(item: string): string
---@field on_choice? fun(choice: string|nil, ...)
---@field backend? checkmate.Picker

---Opens a picker with 'items'
---Uses the following rules to determine picker implementation:
--- - If config.ui.picker == false, use native vim.ui.select
--- - If config.ui.picker is nil (default), attempt to use an installed picker UI, or fallback to native
--- - If config.ui.picker is a function, run this in pcall, if fails, fallback to installed or native
---@param items string[] List of choices
---@param opts SelectOpts
function M.select(items, opts)
  opts = opts or {}

  local backend = opts.backend or get_preferred_picker()

  local width = math.max(math.floor(vim.o.columns * DEFAULT_WIDTH), DEFAULT_MIN_WIDTH)
  local height = math.min(#items + 8, DEFAULT_HEIGHT)

  -- user passed a custom picker backend
  if type(backend) == "function" then
    local ok, result = pcall(function()
      return backend(items, { on_choice = opts.on_choice })
    end)
    if not ok then
      vim.notify("Checkmate: error with custom picker: " .. tostring(result), vim.log.levels.ERROR)
      -- reset backend and let it fall through
      backend = nil
    end
    return result
  end

  if (backend == nil or backend == "telescope") and has_module("telescope.pickers") then
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local themes = require("telescope.themes")

    local theme_opts = themes.get_dropdown({
      winblend = 10,
      width = width,
      height = height,
      prompt_title = opts.prompt or "Edit metadata value",
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
          actions.select_default:replace(function()
            actions.close(prompt_bufnr)
            local selection = action_state.get_selected_entry()
            if opts.on_choice then
              opts.on_choice(selection and selection.value or nil)
            end
          end)

          map("i", "<esc>", function()
            actions.close(prompt_bufnr)
            if opts.on_choice then
              opts.on_choice(nil)
            end
          end)

          return true -- keep other default mappings
        end,
      })
      :find()
    return
  end

  if (backend == nil or backend == "snacks") and has_module("snacks") then
    ---@type snacks.picker.ui_select
    require("snacks").picker.select(items, {
      prompt = opts.prompt or "Select an item",
      format_item = opts.format_item,
      preview = false,
    }, function(item)
      opts.on_choice(item)
    end)
    return
  end

  if (backend == nil or backend == "mini") and has_module("mini.pick") then
    local pick = require("mini.pick")

    -- center position
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    pick.ui_select(
      items,
      {
        prompt = opts.prompt or "Select an item",
        format_item = opts.format_item,
      },
      opts.on_choice,
      {
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
      }
    )
    return
  end

  vim.ui.select(items, {
    prompt = opts.prompt,
    format_item = opts.format_item,
    kind = "checkmate_metadata",
  }, opts.on_choice)
end

return M
