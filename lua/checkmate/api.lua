---Internal buffer operations API - not for public use
---For public API, see checkmate.init module

--[[
INDEXING CONVENTIONS:
- All row/col positions stored in data structures are 0-based byte positions
- string.find() returns 1-based positions - always subtract 1
- nvim_buf_set_text uses 0-based byte positions
- nvim_buf_set_extmark uses 0-based byte positions
- nvim_win_set_cursor uses 1-based row, 0-based byte column
- Ranges are end-exclusive (like Treesitter)
- Always use byte positions internally, only convert to char positions when absolutely necessary

OPERATIONS:
Called from the public API, within a transaction, and should return array `TextDiffHunk[]` for consistency.
The transaction handles batching and applying the diff hunks to the buffer and calling callbacks with updated parse.


HIGHLIGHTING:
To minimize highlighting churn, we don't need to manually call `highlights.apply_highlighting()` for most public API's.
Note: we used to do this in the transaction's post_fn for each transaction.
Instead, if the API is expected to modify the buffer, then we will let our TextChanged and TextChangedI events run `process_buffer`
to perform the highlighting.
If an API is non-editing, then this will need to call apply_highlighting manually.
--]]

local config = require("checkmate.config")
local log = require("checkmate.log")
local parser = require("checkmate.parser")
local ph = require("checkmate.parser.helpers")
local meta_module = require("checkmate.metadata")
local diff = require("checkmate.lib.diff")
local util = require("checkmate.util")
local profiler = require("checkmate.profiler")
local transaction = require("checkmate.transaction")

---@class checkmate.Api
local M = {}

M.buffer_augroup = vim.api.nvim_create_augroup("checkmate_buffer", { clear = false })

---@class checkmate.CreateOptionsInternal : checkmate.CreateOptions
---@field cursor_pos? {row: integer, col: integer} Current cursor position (0-based)

---Callers should check `require("checkmate.file_matcher").should_activate_for_buffer()` before calling setup_buffer
function M.setup_buffer(bufnr)
  if not M.is_valid_buffer(bufnr) then
    return false
  end

  local bl = require("checkmate.buf_local").handle(bufnr)
  local checkmate = require("checkmate")

  -- bail early if we're not running
  if not checkmate.is_running() then
    log.fmt_error("[api] Call to setup_buffer %d but Checkmate is NOT running", bufnr)
    return false
  end

  if checkmate.is_buffer_active(bufnr) and bl:get("setup_complete") == true then
    return true
  end

  -- the main module tracks active checkmate buffers
  checkmate.register_buffer(bufnr)

  -- initial conversion of on-disk raw markdown to our in-buffer representation
  -- "unicode" term is loosely applied
  parser.convert_markdown_to_unicode(bufnr)

  if config.options.linter and config.options.linter.enabled ~= false then
    local linter = require("checkmate.linter")
    linter.lint_buffer(bufnr)
  end

  local highlights = require("checkmate.highlights")
  -- don't use adaptive strategy for first pass on buffer setup--run it synchronously
  highlights.apply_highlighting(bufnr, { strategy = "immediate", debug_reason = "api buffer setup" })

  -- User can opt out of TS highlighting if desired
  if config.options.disable_ts_highlights == true then
    vim.treesitter.stop(bufnr)
  else
    vim.treesitter.start(bufnr, "markdown")
    vim.api.nvim_set_option_value("syntax", "off", { buf = bufnr })
  end

  M.setup_undo(bufnr)
  M.setup_change_watcher(bufnr)
  M.setup_keymaps(bufnr)
  M.setup_autocmds(bufnr)

  bl:set("setup_complete", true)
  bl:set("cleaned_up", false)

  log.fmt_debug("[api] Setup complete for bufnr %d", bufnr)

  return true
end

function M.setup_undo(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local bl = require("checkmate.buf_local").handle(bufnr)

  -- NOTE: We disable buffer-local 'undofile' for Checkmate buffers.
  -- Rationale:
  --  - In-memory text is Unicode; on-disk text is Markdown. Neovim only restores
  --    undofiles whose hash matches file bytes; mismatch => undofile ignored.
  --  - We still provide correct in-session undo/redo; persistent undo is off by design.
  vim.api.nvim_set_option_value("undofile", false, { buf = bufnr })

  -- Baseline tick at attach/first setup; used to infer "no edits since attach".
  -- This lets us distinguish the first "conversion" pass on open from later edits.
  bl:set("baseline_tick", vim.api.nvim_buf_get_changedtick(bufnr))
end

---{mode, lhs}
---@alias checkmate.BufferKeymapItem {[1]: string, [2]: string}
---@alias checkmate.BufferKeymapList checkmate.BufferKeymapItem[]

function M.clear_keymaps(bufnr)
  local bl = require("checkmate.buf_local").handle(bufnr)
  ---@type checkmate.BufferKeymapList|nil
  local items = bl:get("keymaps")
  if not items or #items == 0 then
    return
  end
  for _, item in ipairs(items) do
    -- item = { mode, lhs }
    vim.api.nvim_buf_del_keymap(bufnr, item[1], item[2])
  end
  bl:set("keymaps", {} --[[@as checkmate.BufferKeymapList]])
end

function M.setup_keymaps(bufnr)
  local bl = require("checkmate.buf_local").handle(bufnr)
  local keys = config.options.keys or {}

  local function buffer_map(_bufnr, mode, lhs, rhs, desc)
    local opts = { buffer = _bufnr, silent = true, desc = desc }
    vim.keymap.set(mode, lhs, rhs, opts)
  end

  local has_wk, wk = pcall(require, "which-key")

  -- TODO: need further which-key integration
  if has_wk then
    wk.add({
      "<leader>T",
      buffer = bufnr,
      group = "Checkmate [T]odos",
      icon = "⊡",
    })
  end

  bl:set("keyamps", {})

  local DEFAULT_DESC = "Checkmate <unnamed>"
  local DEFAULT_MODES = { "n" }

  for key, value in pairs(keys) do
    if value ~= false then
      ---@type checkmate.KeymapConfig
      local mapping_config = {}

      if type(value) == "table" then
        -- sequence of {rhs, desc, modes}
        if value[1] ~= nil then
          local rhs, desc, modes = unpack(value)
          mapping_config = { rhs = rhs, desc = desc, modes = modes }
        else -- dict like table
          mapping_config = vim.deepcopy(value)
        end
      else
      end

      if mapping_config and mapping_config.rhs then
        -- defaults
        mapping_config.modes = mapping_config.modes or DEFAULT_MODES
        mapping_config.desc = mapping_config.desc or DEFAULT_DESC

        for _, mode in ipairs(mapping_config.modes) do
          local success = false

          if mapping_config.rhs then
            success = pcall(function()
              buffer_map(bufnr, mode, key, mapping_config.rhs, mapping_config.desc)
            end)
          end

          if success then
            bl:update("keymaps", function(prev)
              prev = prev or {}
              ---@cast prev checkmate.BufferKeymapList
              prev[#prev + 1] = { mode, key }
              return prev
            end)
          end
        end
      end
    end
  end

  -- Setup list continuation keymaps (insert mode)
  if config.options.list_continuation and config.options.list_continuation.enabled then
    local continuation_keys = config.options.list_continuation.keys or {}

    for key, key_config in pairs(continuation_keys) do
      local handler, desc

      if type(key_config) == "function" then
        handler = key_config
        desc = "List continuation for " .. key
      elseif type(key_config) == "table" then
        if type(key_config.rhs) == "function" then
          handler = key_config.rhs
          desc = key_config.desc or ("List continuation for " .. key)
        end
      end

      if handler then
        local orig_key = vim.api.nvim_replace_termcodes(key, true, false, true)

        local expr_fn = function()
          local cursor = vim.api.nvim_win_get_cursor(0)
          local line = vim.api.nvim_get_current_line()

          local todo = ph.match_todo(line)
          if not todo then
            -- not on a todo, return the original key
            return orig_key
          end

          -- check if cursor position is valid (after the checkbox)
          local col = cursor[2] -- 0-based in insert mode
          if not util.is_valid_list_continuation_position(col, todo) then
            return orig_key
          end

          -- split_line behavior
          local at_eol = col >= #line
          if not at_eol and config.options.list_continuation.split_line == false then
            return orig_key
          end

          -- Add undo breakpoint for non-markdown todos
          if not todo.is_markdown then
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g>u", true, false, true), "n", false)
          end

          vim.schedule(function()
            handler()
          end)

          return "" -- swallow the key
        end

        local ok, err = pcall(function()
          vim.keymap.set("i", key, expr_fn, {
            buffer = bufnr,
            expr = true,
            silent = true,
            desc = desc,
          })

          bl:update("keymaps", function(prev)
            prev = prev or {}
            ---@cast prev checkmate.BufferKeymapList
            prev[#prev + 1] = { "i", key }
            return prev
          end)
        end)
        if not ok then
          log.fmt_debug("[api] Failed to set list continuation keymap for %s: %s", key, err)
        end
      end
    end
  end

  -- Setup metadata keymaps
  if config.options.use_metadata_keymaps then
    for meta_name, meta_props in pairs(config.options.metadata) do
      if meta_props.key then
        local modes = { "n", "v" }

        -- Map metadata actions to both normal and visual modes
        for _, mode in ipairs(modes) do
          local key, desc
          -- we allow user to pass [key, desc] tuple
          if type(meta_props.key) == "table" then
            key = meta_props.key[1]
            desc = meta_props.key[2]
          else
            key = tostring(meta_props.key)
            desc = "Toggle '@" .. meta_name .. "' metadata"
          end

          local rhs = function()
            require("checkmate").toggle_metadata(meta_name)
          end

          buffer_map(bufnr, mode, key, rhs, desc)

          bl:update("keymaps", function(prev)
            prev = prev or {}
            ---@cast prev checkmate.BufferKeymapList
            prev[#prev + 1] = { mode, key }
            return prev
          end)
        end
      end
    end
  end
end

function M.setup_autocmds(bufnr)
  local bl = require("checkmate.buf_local").handle(bufnr)
  if not bl:get("autocmds_setup") then
    -- This implementation addresses several subtle behavior issues:
    --   1. Atomic write operation - ensures data integrity (either complete write success or
    -- complete failure, with preservation of the original buffer) by using temp file with a
    -- rename operation (which is atomic at the POSIX filesystem level)
    --   2. A temp buffer is used to perform the unicode to markdown conversion in order to
    -- keep a consistent visual experience for the user, maintain a clean undo history, and
    -- maintain a clean separation between the display format (unicode) and storage format (Markdown)
    --   3. BufWritePre and BufWritePost are called manually so that other plugins can still hook into the write events
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = M.buffer_augroup,
      buffer = bufnr,
      desc = "Checkmate: Convert and save checkmate.nvim files",
      callback = function()
        -- Guard against re-entrancy
        -- Previously had bug due to setting modified flag causing BufWriteCmd to run multiple times
        if vim.b[bufnr]._checkmate_writing then
          return
        end
        vim.b[bufnr]._checkmate_writing = true

        -- this allows other plugins like conform.nvim to format before we save
        -- see #133
        vim.api.nvim_exec_autocmds("BufWritePre", {
          buffer = bufnr,
          modeline = false,
        })

        local uv = vim.uv
        local was_modified = vim.bo[bufnr].modified

        local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local filename = vim.api.nvim_buf_get_name(bufnr)

        -- create temp buffer and convert to markdown
        local temp_bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(temp_bufnr, 0, -1, false, current_lines)

        local success = parser.convert_unicode_to_markdown(temp_bufnr)
        if not success then
          vim.api.nvim_buf_delete(temp_bufnr, { force = true })
          vim.notify("Checkmate: Failed to save when attemping to convert to Markdown", vim.log.levels.ERROR)
          vim.b[bufnr]._checkmate_writing = false
          return false
        end

        local markdown_lines = vim.api.nvim_buf_get_lines(temp_bufnr, 0, -1, false)

        -- ensure that we maintain ending new line per POSIX style
        if #markdown_lines == 0 or markdown_lines[#markdown_lines] ~= "" then
          table.insert(markdown_lines, "")
        end

        local temp_filename = filename .. ".tmp"

        -- write to temp file first
        -- we use binary mode here to ensure byte-by-byte precision and no unexpected newline behaviors
        local write_result = vim.fn.writefile(markdown_lines, temp_filename, "b")

        vim.api.nvim_buf_delete(temp_bufnr, { force = true })

        if write_result == 0 then
          -- atomically rename the temp file to the target file
          local ok, rename_err = pcall(function()
            uv.fs_rename(temp_filename, filename)
          end)

          if not ok then
            -- If rename fails, try to clean up and report error
            pcall(function()
              uv.fs_unlink(temp_filename)
            end)
            vim.notify("Checkmate: Failed to save file", vim.log.levels.ERROR)
            vim.bo[bufnr].modified = was_modified
            vim.b[bufnr]._checkmate_writing = false
            return false
          end

          parser.convert_markdown_to_unicode(bufnr)

          -- For :wq to work, we need to set modified=false synchronously
          vim.bo[bufnr].modified = false
          vim.cmd("set nomodified")

          vim.api.nvim_exec_autocmds("BufWritePost", {
            buffer = bufnr,
            modeline = false,
          })

          vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
              vim.b[bufnr]._checkmate_writing = false
            end
          end, 0)
        else
          -- Failed to write temp file
          -- Try to clean up
          pcall(function()
            uv.fs_unlink(temp_filename)
          end)
          util.notify("Failed to write file", vim.log.levels.ERROR)
          vim.bo[bufnr].modified = was_modified
          vim.b[bufnr]._checkmate_writing = nil

          return false
        end
      end,
    })

    vim.api.nvim_create_autocmd({ "InsertEnter" }, {
      group = M.buffer_augroup,
      buffer = bufnr,
      callback = function()
        bl:set("insert_enter_tick", vim.api.nvim_buf_get_changedtick(bufnr))
      end,
    })

    vim.api.nvim_create_autocmd({ "InsertLeave" }, {
      group = M.buffer_augroup,
      buffer = bufnr,
      callback = function()
        local tick = vim.api.nvim_buf_get_changedtick(bufnr)
        local modified = bl:get("insert_enter_tick") ~= tick
        if modified then
          M.process_buffer(bufnr, "full", "InsertLeave")
        end
      end,
    })

    vim.api.nvim_create_autocmd({ "TextChanged" }, {
      group = M.buffer_augroup,
      buffer = bufnr,
      callback = function()
        local tick = vim.api.nvim_buf_get_changedtick(bufnr)
        if transaction.is_active(bufnr) or bl:get("last_conversion_tick") == tick then
          return
        end
        M.process_buffer(bufnr, "full", "TextChanged")
      end,
    })

    vim.api.nvim_create_autocmd({ "TextChangedI" }, {
      group = M.buffer_augroup,
      buffer = bufnr,
      callback = function()
        if transaction.is_active(bufnr) then
          return
        end
        M.process_buffer(bufnr, "highlight_only", "TextChangedI")
      end,
    })

    -- cleanup buffer when buffer is deleted or unloaded
    vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload" }, {
      group = M.buffer_augroup,
      buffer = bufnr,
      callback = function()
        M.shutdown(bufnr)
      end,
    })
    bl:set("autocmds_setup", true)
  end
end

-- Tracks edited row-span via on_lines
-- this is used in `process_buffer` to region-scope highlight only passes
-- Important: this returns as INCLUSIVE end row. Callers should +1 to get end-exclusive row
-- also tracks a `last_user_tick` which is a changedtick that doesn't occur during markdown<->unicode conversion
function M.setup_change_watcher(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local bl = require("checkmate.buf_local").handle(bufnr)

  if bl:get("change_watcher_attached") then
    return
  end

  bl:set("last_changed_region", nil)

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, _, changedtick, firstline, lastline, new_lastline)
      -- ignore our own writes
      if bl:get("in_conversion") then
        return
      end

      -- record last user changedtick for potential :undojoin by the parser during conversion
      bl:set("last_user_tick", changedtick)

      -- firstline is 0-based. Replace old [firstline, lastline) with new [firstline, new_lastline)
      -- inclusive end row that covers either the removed or the inserted span
      local old_end = (lastline > firstline) and (lastline - 1) or firstline
      local new_end = (new_lastline > firstline) and (new_lastline - 1) or firstline
      local srow = firstline
      local erow = math.max(old_end, new_end)

      -- keep and merge 1 span for the entire debounce window
      -- when process_buffer eventually runs, it will clear "last_changed_region"
      local prev = bl:get("last_changed_region")
      if prev then
        srow = math.min(srow, prev.s)
        erow = math.max(erow, prev.e)
      end
      bl:set("last_changed_region", { s = srow, e = erow, tick = changedtick })
    end,
    on_detach = function()
      bl:set("change_watcher_attached", nil)
      bl:set("last_changed_region", nil)
    end,
    utf_sizes = false,
  })

  bl:set("change_watcher_attached", true)
end

-- functions that process the buffer need to be debounced and stored
---@type table<number, table<string, Debounced>>
M._debounced_processors = {} -- bufnr -> { process_type -> debounced_fn }

-- we can "process" the buffer different ways depending on the need, the frequency we expect it
-- to occur, etc.
-- e.g. we don't want to convert during TextChangedI
M.PROCESS_CONFIGS = {
  full = {
    debounce_ms = 100,
    include_conversion = true,
    include_linting = true,
    include_highlighting = true,
  },
  highlight_only = {
    debounce_ms = 30,
    include_conversion = false,
    include_linting = false,
    include_highlighting = true,
  },
}

function M.process_buffer(bufnr, process_type, reason)
  process_type = process_type or "full"
  local process_config = M.PROCESS_CONFIGS[process_type]
  if not process_config then
    return
  end
  local bl = require("checkmate.buf_local").handle(bufnr)

  -- do not react to our own conversion writes
  if bl:get("in_conversion") then
    return
  end

  if not M._debounced_processors[bufnr] then
    M._debounced_processors[bufnr] = {}
  end

  -- store runner-specific things in here to avoid process_impl() using stale closure
  M._last_call_ctx = M._last_call_ctx or {}
  M._last_call_ctx[bufnr] = M._last_call_ctx[bufnr] or {}
  M._last_call_ctx[bufnr][process_type] = {
    reason = reason,
  }

  if not M._debounced_processors[bufnr][process_type] then
    local function process_impl()
      bl = require("checkmate.buf_local").handle(bufnr)

      if not vim.api.nvim_buf_is_valid(bufnr) then
        M._debounced_processors[bufnr] = nil
        M._last_call_ctx[bufnr] = nil
        return
      end

      -- pull outside data from ctx to avoid stale closure
      local ctx = (M._last_call_ctx[bufnr] and M._last_call_ctx[bufnr][process_type]) or {}
      local run_reason = ctx.reason or "unknown"

      log.fmt_trace("process_buffer (debounced), type '%s', due to %s", process_type, run_reason)
      -- vim.notify(string.format("running process_buffer '%s' due to %s", process_type, run_reason))

      local start_time = vim.uv.hrtime() / 1000000

      ---@type "none" | "regional" | "adaptive_full"
      local highlight_plan = "none"

      -- region-scoped highlighting
      ---@type { start_row: integer, end_row: integer, affected_roots: checkmate.TodoItem[] }|nil
      local region

      -- this type is used by TextChangedI (insert mode), thus we
      -- try to optimize by only re-highlighting a region rather than full buffer
      if process_type == "highlight_only" then
        local changed = bl:get("last_changed_region")

        if changed and changed.s ~= nil and changed.e ~= nil then
          -- consume the changed region
          bl:set("last_changed_region", nil)

          -- `changed.s` is 0-based start row; `changed.e` is an INCLUSIVE end row from on_lines
          -- add some small padding around the changed region to be extra conservative
          local PADDING = 1
          local line_count = vim.api.nvim_buf_line_count(bufnr)
          local max_row = math.max(0, line_count - 1)
          local start_row = math.max(0, changed.s - PADDING)
          local end_row = math.min(max_row, changed.e + PADDING)
          local end_row_excl = end_row + 1

          local todo_map = parser.get_todo_map(bufnr)

          -- find root todos overlapping this span
          local affected_roots = {}
          for _, it in pairs(todo_map) do
            if not it.parent_id then
              local a_start = it.range.start.row
              -- semantic range has end.row inclusive -> convert to exclusive
              local a_end_excl = it.range["end"].row + 1
              if require("checkmate.util").ranges_overlap(a_start, a_end_excl, start_row, end_row_excl) then
                affected_roots[#affected_roots + 1] = it
              end
            end
          end

          if #affected_roots == 0 then
            highlight_plan = "none"
          else
            -- expand region to cover full extents of affected roots (end-exclusive)
            local min_row, max_row_excl = start_row, end_row_excl
            local total_span = 0
            for _, root in ipairs(affected_roots) do
              local r_s = root.range.start.row
              local r_e_excl = root.range["end"].row + 1 -- inclusive -> exclusive
              if r_s < min_row then
                min_row = r_s
              end
              if r_e_excl > max_row_excl then
                max_row_excl = r_e_excl
              end
              total_span = total_span + (r_e_excl - r_s)
            end

            if total_span <= config.get_region_limit(bufnr) then
              region = {
                start_row = min_row,
                end_row = max_row_excl, -- end-exclusive
                affected_roots = affected_roots,
              }
              highlight_plan = "regional"
            else
              -- no overlapping roots: consider nearest root above within a small window
              local WINDOW = 5
              local nearest_above, nearest_dist = nil, math.huge
              for _, it in pairs(todo_map) do
                if not it.parent_id then
                  local a = it.range.start.row
                  if a <= start_row then
                    local d = start_row - a
                    if d < nearest_dist then
                      nearest_dist = d
                      nearest_above = it
                    end
                  end
                end
              end

              if nearest_above and nearest_dist <= WINDOW then
                min_row = nearest_above.range.start.row
                max_row_excl = nearest_above.range["end"].row + 1 -- inclusive -> exclusive
                if (max_row_excl - min_row) <= config.get_region_limit(bufnr) then
                  region = {
                    start_row = min_row,
                    end_row = max_row_excl, -- end-exclusive
                    affected_roots = { nearest_above },
                  }
                  highlight_plan = "regional"
                else
                  highlight_plan = "adaptive_full"
                end
              else
                highlight_plan = "adaptive_full"
              end
            end
          end
        else
          -- no change info recorded for this debounce window
          highlight_plan = "none"
        end
      end

      if process_config.include_conversion then
        parser.convert_markdown_to_unicode(bufnr)
      end

      if process_config.include_highlighting then
        local highlights = require("checkmate.highlights")

        if process_type == "full" then
          highlights.apply_highlighting(bufnr, { debug_reason = "process_buffer full" })
        else -- highlight_only
          if highlight_plan == "regional" and region then
            highlights.apply_highlighting(bufnr, {
              region = region,
              debug_reason = "process_buffer highlight_only (regional)",
            })
          elseif highlight_plan == "adaptive_full" then
            highlights.apply_highlighting(bufnr, {
              -- no region => adaptive strategy chooses immediate vs progressive
              debug_reason = "process_buffer highlight_only (adaptive full)",
            })
          else
            -- highlight_plan == "none": do nothing here
          end
        end
      end

      if process_config.include_linting and config.options.linter and config.options.linter.enabled then
        require("checkmate.linter").lint_buffer(bufnr)
      end

      local end_time = vim.uv.hrtime() / 1000000
      local elapsed = end_time - start_time
    end

    M._debounced_processors[bufnr][process_type] = util.debounce(process_impl, {
      ms = process_config.debounce_ms,
      -- run first call immediately
      leading = true,
      trailing = true,
    })
  end

  -- update context then trigger the runner
  M._last_call_ctx[bufnr][process_type] = { reason = reason }
  M._debounced_processors[bufnr][process_type]()
end

-- Cleans up all checkmate state associated with a buffer
function M.shutdown(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    local bl = require("checkmate.buf_local").handle(bufnr)

    if bl:get("cleaned_up") then
      return
    end

    -- Attemp to convert buffer back to Markdown to leave the buffer in an expected state
    pcall(parser.convert_unicode_to_markdown, bufnr)
    parser.buf_todo_cache[bufnr] = nil

    M.clear_keymaps(bufnr)

    local highlights = require("checkmate.highlights")
    highlights.clear_buf_line_cache(bufnr)
    highlights.cancel_progressive(bufnr)

    require("checkmate.debug.debug_highlights").dispose(bufnr)
    require("checkmate.metadata.picker").cleanup_ui(bufnr)

    vim.api.nvim_buf_clear_namespace(bufnr, config.ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, config.ns_hl, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, config.ns_todos, 0, -1)

    if package.loaded["checkmate.linter"] then
      pcall(function()
        require("checkmate.linter").disable(bufnr)
      end)
    end

    vim.api.nvim_clear_autocmds({ group = M.buffer_augroup, buffer = bufnr })

    if M._debounced_processors and M._debounced_processors[bufnr] then
      for _, d in pairs(M._debounced_processors[bufnr]) do
        if type(d) == "table" and d.close then
          pcall(function()
            d:close()
          end)
        end
      end
      M._debounced_processors[bufnr] = nil
    end

    require("checkmate").unregister_buffer(bufnr)

    bl:clear()
    bl:set("cleaned_up", true)
  end
end

--- Validates that the buffer is valid (per nvim) and Markdown filetype
function M.is_valid_buffer(bufnr)
  if not bufnr or type(bufnr) ~= "number" then
    vim.notify("Checkmate: Invalid buffer number", vim.log.levels.ERROR)
    return false
  end

  local ok, is_valid = pcall(vim.api.nvim_buf_is_valid, bufnr)
  if not ok or not is_valid then
    vim.notify("Checkmate: Invalid buffer", vim.log.levels.ERROR)
    log.fmt_error("[api] Invalid buffer %d", bufnr)
    return false
  end

  if vim.bo[bufnr].filetype ~= "markdown" then
    vim.notify("Checkmate: Buffer is not markdown filetype", vim.log.levels.ERROR)
    return false
  end

  return true
end

--- Creates todo(s) by converting non-todo lines within the range
---@param ctx checkmate.TransactionContext
---@param start_row integer start of the selection
---@param end_row integer end of the selection
---@param opts? {target_state?: string, list_marker?: string, content?: string}
---@return checkmate.TextDiffHunk[] hunks
function M.create_todos_visual(ctx, start_row, end_row, opts)
  opts = opts or {}
  local bufnr = ctx.get_buf()
  local hunks = {}

  for row = start_row, end_row do
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""

    if not parser.is_todo_item(line) then
      local hunk = M.compute_diff_convert_to_todo(bufnr, row, {
        target_state = opts.target_state,
        list_marker = opts.list_marker,
        content = opts.content, -- if provided, will replace existing content
      })
      if hunk then
        table.insert(hunks, hunk)
      end
    end
  end

  return hunks
end

--- Convert current line or create a new child/sibling todo
---
--- If current line is not a todo and no `opts.position` is passed, the line will be converted to a todo in place
---@param ctx checkmate.TransactionContext
---@param start_row integer Origin/parent row (0-based)
---@param opts? checkmate.CreateOptionsInternal
---@return checkmate.TextDiffHunk[]
function M.create_todo_normal(ctx, start_row, opts)
  opts = opts or {}
  local bufnr = ctx.get_buf()

  local todo_item = ctx.get_todo_by_row(start_row, true)

  if todo_item then
    -- current line is already a todo, create a new one
    local parent_prefix = ph._item_to_prefix(todo_item)

    local new_todo = M._build_todo_line({
      parent_prefix = parent_prefix,
      target_state = opts.target_state,
      inherit_state = opts.inherit_state,
      content = opts.content,
      list_marker = opts.list_marker,
      indent = opts.indent,
    })

    local insert_row = opts.position == "above" and start_row or start_row + 1
    local hunk = diff.make_line_insert(insert_row, new_todo.line)

    -- add callback for entering insert mode if enabled
    if config.options.enter_insert_after_new then
      ctx.add_cb(function()
        local target_row = insert_row
        local new_line = vim.api.nvim_buf_get_lines(bufnr, target_row, target_row + 1, false)[1] or ""
        vim.api.nvim_win_set_cursor(0, { target_row + 1, #new_line })
        vim.cmd("startinsert!")
      end)
    end

    return { hunk }
  else
    -- current line is not a todo
    --  - can either convert the line, or
    --  - create a new line if `position` option indicates `below` or `above`
    if opts.position then
      -- insert new todo above/below, preserve original line
      local new_todo = M._build_todo_line({
        target_state = opts.target_state,
        inherit_state = false, -- no parent to inherit from
        content = opts.content or "",
        list_marker = opts.list_marker,
        indent = opts.indent,
      })

      local insert_row = opts.position == "above" and start_row or start_row + 1
      local hunk = diff.make_line_insert(insert_row, new_todo.line)

      if config.options.enter_insert_after_new then
        ctx.add_cb(function()
          local target_row = insert_row
          local new_line = vim.api.nvim_buf_get_lines(bufnr, target_row, target_row + 1, false)[1] or ""
          vim.api.nvim_win_set_cursor(0, { target_row + 1, #new_line })
          vim.cmd("startinsert!")
        end)
      end

      return { hunk }
    else
      -- convert current line to todo (default behavior)
      local hunk = M.compute_diff_convert_to_todo(bufnr, start_row, {
        target_state = opts.target_state,
        list_marker = opts.list_marker,
        indent = opts.indent,
        content = opts.content, -- can override line content
      })

      if hunk and config.options.enter_insert_after_new then
        ctx.add_cb(function()
          local new_line = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1] or ""
          vim.api.nvim_win_set_cursor(0, { start_row + 1, #new_line })
          vim.cmd("startinsert!")
        end)
      end

      return { hunk }
    end
  end
end

--- Create todo in insert mode with line splitting support
---
--- Works on any line type (todo, list item, or plain text).
---
--- When cursor is mid-line:
---  1. Text after cursor moves to new todo line
---  2. `content` option prepends to this split content
---  3. Cursor positioned after new todo marker + space
---
---@param ctx checkmate.TransactionContext
---@param start_row integer Origin/parent row (not the new row). 0-based
---@param opts checkmate.CreateOptionsInternal
---  - cursor_pos.col: INSERT mode column (0-based insertion point between characters)
---    where col=n means cursor is after char[n-1] and before char[n]
---  - content: Prepends to any split content
---@return checkmate.TextDiffHunk[] hunks
function M.create_todo_insert(ctx, start_row, opts)
  local bufnr = ctx.get_buf()
  local line = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1] or ""

  -- try to match a todo line first, then try to match a regular list item
  ---@type checkmate.TodoPrefix | checkmate.ListItemPrefix | nil
  local current_prefix = ph.match_todo(line)
  if not current_prefix then
    local li = ph.match_list_item(line)
    if li then
      ---@type checkmate.ListItemPrefix
      current_prefix = {
        indent = li.indent,
        list_marker = li.marker,
      }
    end
  end

  local insert_row = opts.position == "above" and start_row or start_row + 1

  -- content to carry forward if splitting
  local content_after = ""

  ---@type checkmate.TextDiffHunk[]
  local hunks = {}

  if opts.cursor_pos then
    local col = opts.cursor_pos.col
    if col < #line then
      content_after = line:sub(col + 1)
      -- update the current line to remove the content after cursor
      local truncated = line:sub(1, col)
      local line_hunk = diff.make_line_replace(start_row, truncated)
      table.insert(hunks, line_hunk)
    end
  end

  -- combine split content with any explicit content option
  local final_content = (opts.content or "") .. content_after

  local new_todo = M._build_todo_line({
    parent_prefix = current_prefix,
    target_state = opts.target_state,
    inherit_state = opts.inherit_state,
    content = final_content,
    list_marker = opts.list_marker,
    indent = opts.indent,
  })

  local hunk = diff.make_line_insert(insert_row, new_todo.line)
  table.insert(hunks, hunk)

  -- adjust the cursor
  ctx.add_cb(function()
    -- position cursor at the end of the new todo marker
    local cursor_col = #new_todo.line - #content_after
    vim.api.nvim_win_set_cursor(0, { insert_row + 1, cursor_col })
  end)

  return hunks
end

---@param indent any The raw indent option value
---@return boolean|integer|nil normalized_indent
local function normalize_indent_option(indent)
  if indent == nil or indent == false then
    return false -- sibling (default)
  elseif indent == true or indent == "nested" then
    return true -- nested child
  elseif type(indent) == "number" and indent >= 0 then
    return math.floor(indent) -- explicit spaces (ensure integer)
  else
    log.fmt_warn("Invalid indent option value: %s. Using default (sibling).", vim.inspect(indent))
    return false
  end
end

---@class BuildTodoLineOpts
---@field parent_prefix? checkmate.TodoPrefix | checkmate.ListItemPrefix Context from parent todo or list item (optional)
---@field target_state? string Explicit todo state (overrides `inherit_state`)
---@field inherit_state? boolean Inherit parent/current todo state
---@field content? string Text after the todo marker
---@field list_marker? string Explicit list marker
---@field indent? boolean|integer|"nested" Indentation control

--- Build a new todo line with the given options
---@private
---@param opts? BuildTodoLineOpts
---@return {line: string, indent: integer, marker: string, state: string}
function M._build_todo_line(opts)
  opts = opts or {}
  local content = opts.content or ""
  local parent_prefix = opts.parent_prefix

  -- state, by precedence
  local target_state
  if opts.target_state then
    -- explicit target_state
    target_state = opts.target_state
  elseif opts.inherit_state and parent_prefix then
    -- inherit from parent/current, if requested
    target_state = parent_prefix.state
  else
    -- default to unchecked
    target_state = "unchecked"
  end

  local state_config = config.options.todo_states[target_state]
  if not state_config then
    log.fmt_error("[api] Invalid todo state: %s", target_state)
    target_state = "unchecked"
    state_config = config.options.todo_states[target_state]
  end

  -- get appropriate todo marker for state and convert to markdown if needed
  local todo_marker = state_config.marker
  if parent_prefix and parent_prefix.is_markdown then
    local markdown_char = state_config.markdown
    markdown_char = type(markdown_char) == "table" and markdown_char[1] or markdown_char
    todo_marker = "[" .. markdown_char .. "]"
  end

  -- indentation
  local indent_opt = normalize_indent_option(opts.indent)
  local indent
  if type(indent_opt) == "number" then
    -- explicit indent in spaces
    indent = indent_opt
  elseif indent_opt == true then
    -- nested child - calculate based on parent
    if parent_prefix then
      indent = parent_prefix.indent + #parent_prefix.list_marker + 1
    else
      -- no parent
      indent = 2
    end
  elseif indent_opt == false then
    -- sibling (default) - same level as parent
    if parent_prefix then
      indent = parent_prefix.indent
    else
      indent = 0
    end
  else
    -- fallback for any unexpected value
    indent = parent_prefix and parent_prefix.indent or 0
  end
  ---@cast indent integer

  -- list marker
  local list_marker
  if opts.list_marker then
    list_marker = opts.list_marker
  elseif parent_prefix then
    -- inherit from parent with auto numbering
    local is_nested = indent_opt == true
    if is_nested then
      -- nested items may reset numbering
      list_marker = util.get_next_ordered_marker(parent_prefix.list_marker, true) or parent_prefix.list_marker
    else
      -- siblings increment numbering
      list_marker = util.get_next_ordered_marker(parent_prefix.list_marker, false) or parent_prefix.list_marker
    end
  else
    -- use default from config or fallback to "-"
    list_marker = config.options.default_list_marker or "-"
  end
  ---@cast list_marker string

  local indent_str = string.rep(" ", indent)
  local line = indent_str .. list_marker .. " " .. todo_marker .. " " .. content

  return {
    line = line,
    indent = indent,
    marker = list_marker,
    state = target_state,
  }
end

--- Convert a regular line into a todo
---@param bufnr integer
---@param row integer 0-based row to convert
---@param opts? {target_state?: string, list_marker?: string, nested?: boolean, indent?: boolean|integer|"nested", content?: string}
---@return checkmate.TextDiffHunk
function M.compute_diff_convert_to_todo(bufnr, row, opts)
  opts = opts or {}
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local list_item = ph.match_list_item(line)
  local target_state = opts.target_state or "unchecked"
  local todo_marker = config.options.todo_states[target_state].marker

  local new_line
  if list_item then
    local new_todo = M._build_todo_line({
      parent_prefix = {
        indent = list_item.indent,
        list_marker = opts.list_marker or list_item.marker,
        is_markdown = false,
      },
      -- pass the list marker here to avoid auto incrementing by _build_todo_line
      list_marker = opts.list_marker or list_item.marker,
      target_state = target_state,
      inherit_state = false,
      content = opts.content or vim.trim(line:gsub("^%s*" .. vim.pesc(list_item.marker) .. "%s*", "")),
      indent = false, -- honor existing indentation; caller can override in opts
    })
    new_line = new_todo.line
  else
    -- not a list item - build from scratch
    local existing_indent = util.get_line_indent(line)
    local existing_content = vim.trim(line)

    local content = opts.content or existing_content

    local indent_opt = normalize_indent_option(opts.indent)
    local final_indent
    if type(indent_opt) == "number" then
      -- explicit indent in spaces
      final_indent = indent_opt
    elseif indent_opt == true then
      -- add nesting indent (2 spaces by default)
      final_indent = #existing_indent + 2
    else
      final_indent = #existing_indent
    end

    local prefix = nil
    if final_indent > 0 or opts.list_marker then
      prefix = {
        indent = final_indent,
        list_marker = opts.list_marker or config.options.default_list_marker or "-",
        state = target_state,
        is_markdown = false,
        todo_marker = todo_marker,
      }
    end

    local new_todo = M._build_todo_line({
      parent_prefix = prefix,
      target_state = target_state,
      inherit_state = false,
      content = content,
      list_marker = opts.list_marker,
      indent = false, -- already calculated above
    })

    new_line = new_todo.line
  end

  return diff.make_line_replace(row, new_line)
end

--- Remove todo marker from items (convert todo → non-todo line)
--- @param ctx checkmate.TransactionContext
--- @param operations table[] array of { id: integer, remove_list_marker?: boolean }
--- @return checkmate.TextDiffHunk[] hunks
function M.remove_todo(ctx, operations)
  local bufnr = ctx.get_buf()
  local hunks = {}

  ---@type checkmate.TodoItem[]
  local removed_todos = {}

  for _, op in ipairs(operations or {}) do
    local item = ctx.get_todo_by_id(op.id)
    if item then
      -- store the range for clearing highlights later
      table.insert(removed_todos, item)
      local h = M.compute_diff_strip_todo_prefix(bufnr, item, not op.remove_list_marker)
      if h then
        table.insert(hunks, h)
      end
    end
  end

  -- we go ahead and directly remove the todo extmarks here as a removed todo won't be collected in
  -- the apply_highlighting pass
  if #removed_todos > 0 then
    ctx.add_cb(function()
      local highlights = require("checkmate.highlights")
      for _, removed_todo in ipairs(removed_todos) do
        highlights.clear_todo_hls(bufnr, removed_todo)
      end
    end)
  end

  return hunks
end

---@param bufnr integer
---@param item checkmate.TodoItem
---@param preserve_list_marker? boolean Whether to keep list marker. Default: true
---@return checkmate.TextDiffHunk
function M.compute_diff_strip_todo_prefix(bufnr, item, preserve_list_marker)
  local r = require("checkmate.lib.range")
  local row = item.range.start.row
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""

  local start_col
  if preserve_list_marker ~= false then
    -- keep "<indent><lm><space>", remove the todo marker (and its trailing space)
    local lm_range = r.range_from_tsnode(item.list_marker.node)
    start_col = lm_range["end"].col -- after the single space following list marker
  else
    -- remove the full list prefix as well
    start_col = item.range.start.col -- from beginning of indent/list
  end

  -- end of the todo marker token
  local end_col = item.todo_marker.position.col + #item.todo_marker.text

  -- include exactly one trailing space after the todo marker if present
  if line:sub(end_col + 1, end_col + 1) == " " then
    end_col = end_col + 1
  end

  return diff.make_text_delete(row, start_col, end_col)
end

--- Toggle state of todo item(s)
---@param ctx checkmate.TransactionContext Transaction context
---@param operations table[] Array of {id: integer, target_state: string}
---@return checkmate.TextDiffHunk[] hunks
function M.toggle_state(ctx, operations)
  profiler.start("api.toggle_state")
  local hunks = {}

  for _, op in ipairs(operations) do
    local item = ctx.get_todo_by_id(op.id)
    local state_def = config.options.todo_states[op.target_state]
    if item and item.state ~= op.target_state and state_def and state_def.marker then
      local hunk = diff.make_marker_replace(item, state_def.marker)
      table.insert(hunks, hunk)
    end
  end
  profiler.stop("api.toggle_state")

  return hunks
end

---Toggle a batch of todo items with proper parent/child propagation
---i.e. 'smart toggle'
---
---Only `checked` and `unchecked` states are propagated.
---Custom states may influence propagation logic (based on their `type`) but don't get changed by it.
--- - Users explicitly set custom states for a reason (e.g., "on_hold", "cancelled")
--- - These states shouldn't arbitrarily change just because a parent was toggled,
---   but they should influence whether a parent becomes checked/unchecked
---
---@param ctx checkmate.TransactionContext Transaction context
---@param items checkmate.TodoItem[] List of initial todo items to toggle
---@param todo_map checkmate.TodoMap
---@param target_state? string Optional target state, otherwise toggle each item
function M.propagate_toggle(ctx, items, todo_map, target_state)
  profiler.start("api.propagate_toggle")

  local smart_config = config.options.smart_toggle

  -- holds which todo's need their state updated
  local desired = {} -- desired[id] = state_name

  -- DOWNWARD PROPAGATION

  local function propagate_down(id, state, depth)
    if desired[id] == state then
      return
    end

    desired[id] = state

    local item = todo_map[id]
    if not item or not item.children or #item.children == 0 then
      return
    end

    -- pick the right down propagation mode
    -- only propagate checked/unchecked states
    local propagate_mode = (state == "checked") and smart_config.check_down
      or (state == "unchecked") and smart_config.uncheck_down
      or "none"

    if propagate_mode == "none" then
      return
    end
    if propagate_mode == "direct_children" and depth > 0 then
      return
    end

    for _, child_id in ipairs(item.children) do
      local child = todo_map[child_id]
      if child then
        local current = (desired[child_id] or child.state)
        -- only change between checked/unchecked, never to/from custom states
        if state == "checked" and current == "unchecked" then
          -- only unchecked children become checked
          propagate_down(child_id, state, depth + 1)
        elseif state == "unchecked" and current == "checked" then
          -- only checked children become unchecked
          propagate_down(child_id, state, depth + 1)
        end
        -- other states (custom states) are left alone
      end
    end
  end

  -- initialize the downward pass for each selected item
  for _, item in ipairs(items) do
    local s = target_state
    if not s then
      -- default toggle behavior
      -- instead of just flipping checked ←→ unchecked, we use the `type` and flip to its opposite default state,
      -- which allows for properly toggling custom states
      local state_type = config.get_todo_state_type(item.state)
      if state_type == "complete" then
        s = "unchecked"
      else -- incomplete or inactive
        s = "checked"
      end
    end
    propagate_down(item.id, s, 0)
  end

  -- UPWARD PROPAGATION

  local function is_complete_type(state)
    return config.get_todo_state_type(state) == "complete"
  end

  local function is_incomplete_type(state)
    return config.get_todo_state_type(state) == "incomplete"
  end

  local function is_inactive_type(state)
    return config.get_todo_state_type(state) == "inactive"
  end

  local function subtree_all(id, pred)
    local item = todo_map[id]
    if not item then
      return true -- empty subtree satisfies "all"
    end

    local state = desired[id] or item.state
    -- skip inactive states from the predicate check
    if not is_inactive_type(state) and not pred(state) then
      return false
    end

    for _, cid in ipairs(item.children or {}) do
      if not subtree_all(cid, pred) then
        return false
      end
    end
    return true
  end

  local function subtree_any(id, pred)
    local item = todo_map[id]
    if not item then
      return false
    end

    local state = desired[id] or item.state
    if pred(state) then
      return true
    end

    for _, cid in ipairs(item.children or {}) do
      if subtree_any(cid, pred) then
        return true
      end
    end
    return false
  end

  -- checks if all relevant children are checked
  local function should_check_parent(parent_id)
    if smart_config.check_up == "none" then
      return false
    end

    local parent = todo_map[parent_id]
    if not parent then
      return false
    end

    -- only check the parent if it has 'incomplete' type
    local parent_state = desired[parent_id] or parent.state
    if not is_incomplete_type(parent_state) then
      return false
    end

    if not parent.children or #parent.children == 0 then
      return true -- no children means we can check it
    end

    if smart_config.check_up == "direct_children" then
      -- check only direct children
      for _, child_id in ipairs(parent.children) do
        local st = (desired[child_id] or todo_map[child_id].state)
        if is_incomplete_type(st) then
          return false
        end
      end
      return true
    else -- "all_children"
      -- check the parent if all children (at any depth) are:
      --  - non-inactive with 'complete' type, or
      --  - inactive
      for _, cid in ipairs(parent.children) do
        if
          not subtree_all(cid, function(st)
            return is_complete_type(st) or is_inactive_type(st)
          end)
        then
          return false
        end
      end
      return true
    end
  end

  local function should_uncheck_parent(parent_id)
    if smart_config.uncheck_up == "none" then
      return false
    end

    local parent = todo_map[parent_id]
    if not parent or not parent.children or #parent.children == 0 then
      return false -- no children means no reason to uncheck
    end

    -- only uncheck parent if it has complete type
    local parent_state = desired[parent_id] or parent.state
    if not is_complete_type(parent_state) then
      return false
    end

    if smart_config.uncheck_up == "direct_children" then
      for _, child_id in ipairs(parent.children) do
        local st = (desired[child_id] or todo_map[child_id].state)
        if is_incomplete_type(st) then
          return true
        end
      end
      return false
    else -- "all_children"
      -- uncheck the parent if any child has incomplete type
      for _, cid in ipairs(parent.children) do
        if subtree_any(cid, is_incomplete_type) then
          return true
        end
      end
      return false
    end
  end

  -- process upward propagation for items becoming checked
  local function propagate_check_up(id)
    local parent_id = todo_map[id] and todo_map[id].parent_id
    if not parent_id then
      return
    end

    if should_check_parent(parent_id) and desired[parent_id] ~= "checked" then
      desired[parent_id] = "checked"
    end
    propagate_check_up(parent_id)
  end

  -- process upward propagation for items becoming unchecked
  local function propagate_uncheck_up(id)
    local parent_id = todo_map[id] and todo_map[id].parent_id
    if not parent_id then
      return
    end

    if should_uncheck_parent(parent_id) and desired[parent_id] ~= "unchecked" then
      desired[parent_id] = "unchecked"
    end
    propagate_uncheck_up(parent_id)
  end

  -- run upward propagation based on what we're setting items to
  for id, desired_state in pairs(desired) do
    local state_type = config.get_todo_state_type(desired_state)
    if state_type == "complete" then
      -- item becoming complete might cause parent to check
      propagate_check_up(id)
    elseif state_type == "incomplete" then
      -- item becoming incomplete might cause parent to uncheck
      propagate_uncheck_up(id)
    end
  end

  local operations = {}

  for id, desired_state in pairs(desired) do
    local item = todo_map[id]
    if item and item.state ~= desired_state then
      table.insert(operations, {
        id = id,
        target_state = desired_state,
      })
    end
  end

  -- single batched operation with all state changes
  if #operations > 0 then
    ctx.add_op(M.toggle_state, operations)
  end
  profiler.stop("api.propagate_toggle")
end

--- Get the next todo state in the cycle
---@param current_state string Current todo state
---@param backward? boolean If true, cycle backward
---@return string next_state The next todo state name
function M.get_next_todo_state(current_state, backward)
  local states = parser.get_ordered_todo_states()
  local current_index = nil

  for i, state in ipairs(states) do
    if state.name == current_state then
      current_index = i
      break
    end
  end

  if not current_index then
    return states[1].name
  end

  local next_index
  if backward then
    next_index = current_index - 1
    if next_index < 1 then
      next_index = #states -- wrap to end
    end
  else
    next_index = current_index + 1
    if next_index > #states then
      next_index = 1 -- wrap to beginning
    end
  end

  return states[next_index].name
end

---@param todo_item checkmate.TodoItem
---@param meta_name string
---@param bufnr integer
---@return {row: integer, col: integer, insert_after_space: boolean}
function M.find_metadata_insert_position(todo_item, meta_name, bufnr)
  local meta_config = config.options.metadata[meta_name] or {}
  local incoming_sort_order = meta_config.sort_order or 100

  -- IMPORTANT: if there are no metadata entries for this todo, we find the end
  -- of the todo's `first_inline_range` which is essentially the first line + continuation lines
  if util.tbl_isempty_or_nil(todo_item.metadata.entries) then
    local flr = todo_item.first_inline_range
    local lines = vim.api.nvim_buf_get_lines(bufnr, flr.start.row, flr["end"].row + 1, false)

    -- find last non-whitespace position
    local best_row = flr.start.row
    local best_col = 0
    local needs_space = false

    for i = #lines, 1, -1 do
      local line = lines[i]
      local row = flr.start.row + i - 1

      local start_col = (i == 1) and flr.start.col or 0
      local end_col = (i == #lines) and flr["end"].col or #line

      -- get the relevant portion
      local content = line:sub(start_col + 1, end_col)

      -- get last non-whitespace in this portion
      local trimmed = content:match("^(.-)%s*$")
      if trimmed and #trimmed > 0 then
        best_row = row
        best_col = start_col + #trimmed
        -- check if we need a space before our metadata
        needs_space = content:sub(#trimmed, #trimmed) ~= " "
        break
      end
    end

    return {
      row = best_row,
      col = best_col,
      insert_after_space = needs_space,
    }
  end
  -- Existing metadata are present for this todo item, so we need to calculate where to put this new entry
  -- according to sort_order

  -- get metadata entry with the highest sort order that's still less than ours
  local predecessor_entry = nil -- closest predecessor (its order ≤ this one)
  local predecessor_order = -1 -- its sort_order

  -- also get the entry with the lowest sort order that's greater than ours
  local successor_entry = nil
  local successor_order = math.huge

  -- basically we loop through each metadata entry and calculate if it's
  -- the closest predecessor and/or closest successor to the incoming metadata
  for _, entry in ipairs(todo_item.metadata.entries) do
    local entry_config = meta_module.get_meta_props(entry.tag) or {}
    local entry_order = entry_config.sort_order or 100

    if entry_order <= incoming_sort_order and entry_order > predecessor_order then
      -- found a closer predecessor
      predecessor_entry = entry
      predecessor_order = entry_order
    elseif entry_order > incoming_sort_order and entry_order < successor_order then
      -- found a closer successor
      successor_entry = entry
      successor_order = entry_order
    end
  end

  if predecessor_entry then
    -- insert after the predecessor
    return {
      row = predecessor_entry.range["end"].row,
      col = predecessor_entry.range["end"].col,
      insert_after_space = true, -- always need space after existing metadata
    }
  elseif successor_entry then
    -- or, insert before the successor
    return {
      row = successor_entry.range.start.row,
      col = successor_entry.range.start.col,
      insert_after_space = false, -- add space after our tag, not before
    }
  else
    -- fallback
    -- add after all existing metadata (find the last one)
    local last_entry = todo_item.metadata.entries[#todo_item.metadata.entries]
    return {
      row = last_entry.range["end"].row,
      col = last_entry.range["end"].col,
      insert_after_space = true,
    }
  end
end

---@param bufnr integer
---@param item checkmate.TodoItem
---@param meta_name string Metadata tag name
---@param meta_value string Metadata default value
---@return checkmate.TextDiffHunk? hunk, {old_value: string, new_value: string}? changed
--- `hunk`: the diff hunk representing the new/updated metadata, or `nil` if no buffer change would result
--- `changed`: allows the caller to fire on_change callbacks if we actually update a value
function M.compute_diff_add_metadata(bufnr, item, meta_name, meta_value)
  local meta_props = meta_module.get_meta_props(meta_name)
  if not meta_props then
    return nil, nil
  end

  ---@type checkmate.TextDiffHunk?
  local hunk = nil

  local value = meta_value -- target value
  local existing_entry = item.metadata.by_tag[meta_name]

  local changed

  if existing_entry then
    if existing_entry.value ~= value then
      changed = { old_value = existing_entry.value, new_value = value }

      local line =
        vim.api.nvim_buf_get_lines(bufnr, existing_entry.range.start.row, existing_entry.range.start.row + 1, false)[1]

      if line then
        hunk = M.compute_diff_update_metadata(existing_entry, value)
      end
    end
  else
    -- doesn't exist yet, new insertion
    local insert_pos = M.find_metadata_insert_position(item, meta_name, bufnr)

    local metadata_text = "@" .. meta_name .. "(" .. value .. ")"
    local insert_text

    if insert_pos.insert_after_space then
      insert_text = " " .. metadata_text
    else
      -- inserting before something, add space after
      insert_text = metadata_text .. " "
    end

    hunk = diff.make_text_insert(insert_pos.row, insert_pos.col, insert_text)
  end
  return hunk, changed
end

--- Add metadata to todo items
---@param ctx checkmate.TransactionContext Transaction context
---@param operations table[] Array of {id: integer, meta_name: string, meta_value?: string}
---@return checkmate.TextDiffHunk[] hunks
function M.add_metadata(ctx, operations)
  local bufnr = ctx.get_buf()
  local hunks = {}
  local to_jump = nil

  -- group by metadata type for callbacks
  local new_adds_by_meta = {} -- track new additions for on_add callbacks
  local changes_by_meta = {} -- track changes for on_change callbacks

  for _, op in ipairs(operations) do
    local item = ctx.get_todo_by_id(op.id)
    if not item then
      return {}
    end

    local meta_props = meta_module.get_meta_props(op.meta_name)
    if not meta_props then
      return {}
    end

    -- get value with fallback to get_value()
    local context = meta_module.create_context(item, op.meta_name, "", bufnr)
    local meta_value = op.meta_value or meta_module.evaluate_value(meta_props, context)

    local item_hunk, item_changes = M.compute_diff_add_metadata(bufnr, item, op.meta_name, meta_value)
    if not util.tbl_isempty_or_nil(item_hunk) then
      table.insert(hunks, item_hunk)
    end

    -- add callbacks
    if item_changes then
      changes_by_meta[op.meta_name] = changes_by_meta[op.meta_name] or {}
      table.insert(changes_by_meta[op.meta_name], {
        id = op.id,
        old_value = item_changes.old_value,
        new_value = item_changes.new_value,
      })
    elseif not item.metadata.by_tag[op.meta_name] and meta_props.on_add then
      -- only queue on_add if it's actually a new addition
      new_adds_by_meta[op.meta_name] = new_adds_by_meta[op.meta_name] or {}
      table.insert(new_adds_by_meta[op.meta_name], op.id)
    end

    -- track jump target (for single item operations)
    if #operations == 1 and meta_props.jump_to_on_insert then
      to_jump = { item = item, meta_name = op.meta_name, meta_config = meta_props }
    end
  end

  -- queue on_add cbs
  for meta_name, ids in pairs(new_adds_by_meta) do
    local meta_config = config.options.metadata[meta_name]
    for _, id in ipairs(ids) do
      ctx.add_cb(function(tx_ctx)
        local updated_item = tx_ctx.get_todo_by_id(id)
        if updated_item then
          meta_config.on_add(updated_item)
        end
      end)
    end
  end

  -- queue on_change cbs
  for meta_name, changes in pairs(changes_by_meta) do
    local meta_config = config.options.metadata[meta_name]
    if meta_config.on_change then
      for _, change in ipairs(changes) do
        ctx.add_cb(function(tx_ctx)
          local updated_item = tx_ctx.get_todo_by_id(change.id)
          if updated_item then
            meta_config.on_change(updated_item, change.old_value, change.new_value)
          end
        end)
      end
    end
  end

  if to_jump then
    ctx.add_cb(function(tx_ctx)
      local updated_item = tx_ctx.get_todo_by_id(to_jump.item.id)
      if updated_item then
        M._handle_metadata_cursor_jump(bufnr, updated_item, to_jump.meta_name, to_jump.meta_config)
      end
    end)
  end

  return hunks
end

--- Compute diff hunks for removing specific metadata entries
---@param bufnr integer
---@param entries checkmate.MetadataEntry[]
---@return checkmate.TextDiffHunk[]
function M.compute_diff_remove_metadata(bufnr, entries)
  local hunks = {}

  -- reverse order to avoid offset issues when removing
  local sorted_entries = vim.deepcopy(entries)
  table.sort(sorted_entries, function(a, b)
    if a.range.start.row ~= b.range.start.row then
      return a.range.start.row > b.range.start.row
    end
    return a.range.start.col > b.range.start.col
  end)

  for _, entry in ipairs(sorted_entries) do
    local hunk = M.compute_metadata_removal_hunk(bufnr, entry)
    if hunk then
      table.insert(hunks, hunk)
    end
  end

  return hunks
end

--- Helper to compute hunk for removing a single metadata entry
--- It handles metadata that span multiple lines
---@param bufnr integer
---@param entry checkmate.MetadataEntry
---@return checkmate.TextDiffHunk
function M.compute_metadata_removal_hunk(bufnr, entry)
  local start_row = entry.range.start.row
  local start_col = entry.range.start.col
  local end_row = entry.range["end"].row
  local end_col = entry.range["end"].col

  -- metadata spans a single line
  if start_row == end_row then
    local line = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1]

    -- fix surrounding whitespace
    if start_col > 0 and line:sub(start_col, start_col) == " " then
      start_col = start_col - 1
    elseif end_col < #line and line:sub(end_col + 1, end_col + 1) == " " then
      end_col = end_col + 1
    end

    return diff.make_text_delete(start_row, start_col, end_col)
  end

  -- metadata breaks across more than 1 line
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
  local new_lines = {}

  for i, line in ipairs(lines) do
    local row = start_row + i - 1

    if row == start_row then
      -- preserve everything up to the metadata start
      local before = line:sub(1, start_col)
      if before:match(" $") then
        before = before:sub(1, -2)
      end
      table.insert(new_lines, before)
    elseif row == end_row then
      -- preserve everything after the metadata end
      local after = line:sub(end_col + 1)
      -- ensure it is set back to the original indent
      local indent = line:match("^%s*") or ""
      if after:match("^ ") then
        after = after:sub(2)
      end
      table.insert(new_lines, indent .. after)
    else
      -- middle lines: remove entirely (they only contained metadata)
    end
  end

  -- if the last line is now empty, remove it
  if #new_lines > 1 and new_lines[#new_lines]:match("^%s*$") then
    table.remove(new_lines)
  end

  return diff.make_line_replace({ start_row, end_row }, new_lines)
end

--- Helper to collect metadata entries to remove based on meta_names
---@private
---@param item checkmate.TodoItem
---@param meta_names string[]|boolean true means remove all
---@return checkmate.MetadataEntry[]
function M._collect_entries_to_remove(item, meta_names)
  if not item.metadata or not item.metadata.entries or #item.metadata.entries == 0 then
    return {}
  end

  -- remove all of them
  if meta_names == true then
    return vim.deepcopy(item.metadata.entries)
  end
  ---@cast meta_names string[]

  -- remove specific metadata by name
  local entries = {}

  for _, meta_name in ipairs(meta_names) do
    local entry = item.metadata.by_tag[meta_name]

    -- if not found, try canonical name lookup
    if not entry then
      local canonical = meta_module.get_canonical_name(meta_name)
      if canonical then
        entry = item.metadata.by_tag[canonical]
      end
    end

    if entry then
      table.insert(entries, entry)
    end
  end

  return entries
end

--- Queue removal callbacks
---@private
---@param ctx checkmate.TransactionContext
---@param callbacks {id: integer, canonical_name: string}[]
function M._queue_removal_callbacks(ctx, callbacks)
  for _, callback_info in ipairs(callbacks) do
    local meta_config = config.options.metadata[callback_info.canonical_name]
    if meta_config and meta_config.on_remove then
      ctx.add_cb(function(tx_ctx)
        local updated_item = tx_ctx.get_todo_by_id(callback_info.id)
        if updated_item then
          meta_config.on_remove(updated_item)
        end
      end)
    end
  end
end

--- Remove metadata from todo items
--- `operations` is a table of todo_item id and metadata tag names to remove
---@param ctx checkmate.TransactionContext Transaction context
---@param operations {id: integer, meta_names: string[]|boolean}
---@return checkmate.TextDiffHunk[] hunks
function M.remove_metadata(ctx, operations)
  local hunks = {}
  local pending_callbacks = {} -- Array of {id, canonical_name} for on_remove callbacks

  for _, op in ipairs(operations) do
    local item = ctx.get_todo_by_id(op.id)
    if item then
      local entries_to_remove = M._collect_entries_to_remove(item, op.meta_names)

      -- make the diff hunks
      if #entries_to_remove > 0 then
        local item_hunks = M.compute_diff_remove_metadata(ctx.get_buf(), entries_to_remove)
        vim.list_extend(hunks, item_hunks)

        -- collect callbacks
        for _, entry in ipairs(entries_to_remove) do
          local canonical = entry.alias_for or entry.tag
          local meta_config = config.options.metadata[canonical]
          if meta_config and meta_config.on_remove then
            table.insert(pending_callbacks, {
              id = op.id,
              canonical_name = canonical,
            })
          end
        end
      end
    end
  end

  -- queue the callbacks in the transaction
  M._queue_removal_callbacks(ctx, pending_callbacks)

  return hunks
end

--- Toggle metadata on todo items
---@param ctx checkmate.TransactionContext Transaction context
---@param operations table[] Array of {id: integer, meta_name: string, custom_value?: string}
---@return checkmate.TextDiffHunk[] hunks
function M.toggle_metadata(ctx, operations)
  local hunks = {}

  local to_add = {}
  local to_remove = {}

  for _, op in ipairs(operations) do
    local item = ctx.get_todo_by_id(op.id)
    if item then
      local has_metadata = item.metadata.by_tag and item.metadata.by_tag[op.meta_name]
      if has_metadata then
        table.insert(to_remove, { id = op.id, meta_names = { op.meta_name } })
      else
        table.insert(to_add, { id = op.id, meta_name = op.meta_name, meta_value = op.custom_value })
      end
    end
  end

  if #to_remove > 0 then
    local remove_hunks = M.remove_metadata(ctx, to_remove)
    vim.list_extend(hunks, remove_hunks)
  end

  if #to_add > 0 then
    local add_hunks = M.add_metadata(ctx, to_add)
    vim.list_extend(hunks, add_hunks)
  end

  return hunks
end

---@param ctx checkmate.TransactionContext
---@param metadata checkmate.MetadataEntry
---@param new_value string
---@return checkmate.TextDiffHunk[]
function M.set_metadata_value(ctx, metadata, new_value)
  local bufnr = ctx.get_buf()
  local row = metadata.range.start.row

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return {}
  end

  -- queue on_change callback
  if metadata.value ~= new_value then
    local canonical_name = metadata.alias_for or metadata.tag
    local meta_config = config.options.metadata[canonical_name]

    if meta_config and meta_config.on_change then
      local todo_item = ctx.get_todo_by_row(row)
      if todo_item then
        ctx.add_cb(function(tx_ctx)
          local updated_item = tx_ctx.get_todo_by_id(todo_item.id)
          if updated_item then
            meta_config.on_change(updated_item, metadata.value, new_value)
          end
        end)
      end
    end
  end

  return { M.compute_diff_update_metadata(metadata, new_value) }
end

---@param metadata checkmate.MetadataEntry
---@param value string
---@return checkmate.TextDiffHunk
function M.compute_diff_update_metadata(metadata, value)
  local value_range = metadata.value_range

  -- For multi-line metadata, we need to handle newlines in the new value
  -- Replace literal newlines with spaces to keep metadata on single line for now
  -- (Future enhancement: support actual multi-line values)
  local sanitized_value = value:gsub("\n", " ")

  return diff.make_text_replace(value_range.start.row, value_range.start.col, value_range["end"].col, sanitized_value)
end

--- moves the cursor forward or backward to the next metadata tag for the todo item
--- under the cursor, if present
---@param bufnr integer
---@param todo_item checkmate.TodoItem
---@param backward boolean? if true, move to previous
function M.move_cursor_to_metadata(bufnr, todo_item, backward)
  if not (todo_item and todo_item.metadata and #todo_item.metadata.entries > 0) then
    return
  end

  -- current cursor (row is 1-based, col is 0-based)
  local win = vim.api.nvim_get_current_win()

  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end

  local cur = vim.api.nvim_win_get_cursor(win)
  local cur_row = cur[1] - 1 -- to 0-based
  local cur_col = cur[2]

  local entries = vim.deepcopy(todo_item.metadata.entries)

  -- sort by row, then column
  table.sort(entries, function(a, b)
    if a.range.start.row ~= b.range.start.row then
      return a.range.start.row < b.range.start.row
    end
    return a.range.start.col < b.range.start.col
  end)

  local target
  local current_idx = nil

  for i, entry in ipairs(entries) do
    local entry_row = entry.range.start.row
    local entry_start_col = entry.range.start.col
    local entry_end_col = entry.range["end"].col

    -- is cursor within this entry
    if cur_row == entry_row and cur_col >= entry_start_col and cur_col < entry_end_col then
      current_idx = i
      break
    end
  end

  if backward then
    if current_idx then
      -- if on an entry, go to previous
      target = entries[current_idx - 1] or entries[#entries]
    else
      -- find the last entry before cursor position
      for i = #entries, 1, -1 do
        local e = entries[i]
        if e.range.start.row < cur_row or (e.range.start.row == cur_row and e.range["end"].col <= cur_col) then
          target = e
          break
        end
      end
      -- wrap to last if none found
      if not target then
        target = entries[#entries]
      end
    end
  else
    if current_idx then
      -- if on an entry, go to next
      target = entries[current_idx + 1] or entries[1]
    else
      -- find the first entry after cursor position
      for _, entry in ipairs(entries) do
        if
          entry.range.start.row > cur_row
          or (entry.range.start.row == cur_row and entry.range.start.col > cur_col)
        then
          target = entry
          break
        end
      end
      -- wrap to first if none found
      if not target then
        target = entries[1]
      end
    end
  end

  if target then
    vim.api.nvim_win_set_cursor(win, { target.range.start.row + 1, target.range.start.col })
  end
end

--- Count completed and total (non-inactive type) child todos for a todo item
---@param todo_item checkmate.TodoItem The parent todo item
---@param todo_map checkmate.TodoMap Full todo map
---@param opts? {recursive: boolean?}
---@return {completed: number, total: number} Counts
function M.count_child_todos(todo_item, todo_map, opts)
  local counts = { completed = 0, total = 0 }

  for _, child_id in ipairs(todo_item.children or {}) do
    local child = todo_map[child_id]
    if child then
      local child_state_type = config.get_todo_state_type(child.state)

      if child_state_type ~= "inactive" then
        counts.total = counts.total + 1
        if child_state_type == "complete" then
          counts.completed = counts.completed + 1
        end
      end

      -- recursively count grandchildren
      if opts and opts.recursive then
        local child_counts = M.count_child_todos(child, todo_map, opts)
        counts.total = counts.total + child_counts.total
        counts.completed = counts.completed + child_counts.completed
      end
    end
  end

  return counts
end

--- Archives completed todo items to a designated section
--- @param opts? {heading?: {title?: string, level?: integer}, include_children?: boolean, newest_first?: boolean} Archive options
--- @return boolean success Whether any items were archived
function M.archive_todos(opts)
  opts = opts or {}

  -- create the Markdown heading that the user has defined, e.g. ## Archived
  local archive_heading_string = util.get_heading_string(
    opts.heading and opts.heading.title or config.options.archive.heading.title or "Archived",
    opts.heading and opts.heading.level or config.options.archive.heading.level or 2
  )
  local include_children = opts.include_children ~= false -- default: true
  local newest_first = opts.newest_first or config.options.archive.newest_first ~= false -- default: true
  local parent_spacing = math.max(config.options.archive.parent_spacing or 0, 0)

  -- helpers

  -- adds blank lines to the end of string[]
  local function add_spacing(lines)
    for _ = 1, parent_spacing do
      lines[#lines + 1] = ""
    end
  end

  local function trim_trailing_blank(lines)
    while #lines > 0 and lines[#lines] == "" do
      lines[#lines] = nil
    end
  end

  -- discover todos and current archive block boundaries

  local bufnr = vim.api.nvim_get_current_buf()
  local todo_map = parser.get_todo_map(bufnr)
  local sorted_todos = util.get_sorted_todo_list(todo_map)
  local current_buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local archive_start_row, archive_end_row
  do
    local heading_level = archive_heading_string:match("^(#+)")
    local heading_level_len = heading_level and #heading_level or 0
    -- The 'next' heading level is a heading at the same or higher level
    -- which represents a new section
    local next_heading_pat = heading_level
        and ("^%s*" .. string.rep("#", heading_level_len, heading_level_len) .. "+%s")
      or "^%s*#+%s"

    for i, line in ipairs(current_buf_lines) do
      if line:match("^%s*" .. vim.pesc(archive_heading_string) .. "%s*$") then
        archive_start_row = i - 1 -- 0-indexed
        archive_end_row = #current_buf_lines - 1

        for j = i + 1, #current_buf_lines do
          if current_buf_lines[j]:match(next_heading_pat) then
            archive_end_row = j - 2
            break
          end
        end
        break
      end
    end
  end

  -- determine which root todos (and descendants) to archive

  local todos_to_archive = {}
  local archived_ranges = {} ---@type {start_row:integer, end_row:integer}[]
  local archived_root_cnt = 0

  for _, entry in ipairs(sorted_todos) do
    ---@cast entry {id: integer, item: checkmate.TodoItem}
    local todo = entry.item
    local id = entry.id
    local in_arch = archive_start_row -- could be nil if no archive section exists
      and todo.range.start.row > archive_start_row
      and todo.range["end"].row <= (archive_end_row or -1)

    if not in_arch and todo.state == "checked" and not todo.parent_id and not todos_to_archive[id] then
      -- mark root
      todos_to_archive[id] = true
      archived_root_cnt = archived_root_cnt + 1
      archived_ranges[#archived_ranges + 1] = {
        start_row = todo.range.start.row,
        end_row = todo.range["end"].row,
      }

      -- mark descendants if requested
      if include_children then
        local function mark_descendants(pid)
          for _, child_id in ipairs(todo_map[pid].children or {}) do
            if not todos_to_archive[child_id] then
              todos_to_archive[child_id] = true
              mark_descendants(child_id)
            end
          end
        end
        mark_descendants(id)
      end
    end
  end

  if archived_root_cnt == 0 then
    util.notify("No completed todo items to archive", vim.log.levels.INFO)
    return false
  end

  table.sort(archived_ranges, function(a, b)
    return a.start_row < b.start_row
  end)

  -- rebuild buffer content
  -- start with re-creating the buffer's 'active' section (non-archived)

  local new_main_content = {} -- lines that will remain in the main document
  local new_archive_content = {} -- lines that will live under the Archive heading
  local newly_archived_lines = {} -- temp storage for newly added archived todos

  -- Walk every line of the current buffer.
  --    we copy it into `new_content` unless it is:
  --       a) part of the existing archive section, or
  --       b) part of a todo block we’re about to archive, or
  --       c) the single blank line that immediately follows such a block
  --         (to avoid stray empty rows after removal).
  local i = 1
  while i <= #current_buf_lines do
    local idx = i - 1 -- 0-indexed (current row)

    -- skip over existing archive section in one jump
    if archive_start_row and idx >= archive_start_row and idx <= archive_end_row then
      i = archive_end_row + 2
    else
      -- skip lines inside newly-archived ranges (plus trailing blank directly after each)
      local skip = false
      for _, r in ipairs(archived_ranges) do
        if idx >= r.start_row and idx <= r.end_row then
          skip = true -- inside a soon-to-be-archived todo
          break
        end
      end
      -- handle spacing preservation
      if not skip and current_buf_lines[i] == "" then
        for _, r in ipairs(archived_ranges) do
          if idx == r.end_row + 1 then
            -- this blank line is immediately after an archived todo
            -- ...so check if there was a blank line before the todo
            local has_blank_before = r.start_row > 0 and current_buf_lines[r.start_row] == ""

            -- check if we already added content (which means there's something before)
            local has_content_before = #new_main_content > 0

            -- Skip this blank line if:
            --  - already have blank line before todo
            --  - the last line we added to new_main_content is blank
            if has_blank_before or (has_content_before and new_main_content[#new_main_content] == "") then
              skip = true
            end
            break
          end
        end
      end

      if not skip then
        new_main_content[#new_main_content + 1] = current_buf_lines[i]
      end
      i = i + 1
    end
  end

  -- If an archive section already exists, copy everything below its heading

  if archive_start_row and archive_end_row and archive_end_row >= archive_start_row + 1 then
    local start = archive_start_row + 2
    while start <= archive_end_row + 1 and current_buf_lines[start] == "" do
      start = start + 1
    end
    for j = start, archive_end_row + 1 do
      new_archive_content[#new_archive_content + 1] = current_buf_lines[j]
    end
    trim_trailing_blank(new_archive_content)
  end

  -- collect newly archived todo items

  if #archived_ranges > 0 then
    for idx, r in ipairs(archived_ranges) do
      for row = r.start_row, r.end_row do
        newly_archived_lines[#newly_archived_lines + 1] = current_buf_lines[row + 1]
      end

      -- spacing after each root todo except the last
      if idx < #archived_ranges and parent_spacing > 0 then
        add_spacing(newly_archived_lines)
      end
    end
  end

  -- combine existing and new archive content based on newest_first option

  if newest_first then
    -- newest items go at the top of the archive section
    local combined_lines = {}

    -- add new items first
    for _, line in ipairs(newly_archived_lines) do
      combined_lines[#combined_lines + 1] = line
    end

    -- add spacing between new and existing content if both exist
    if #newly_archived_lines > 0 and #new_archive_content > 0 and parent_spacing > 0 then
      add_spacing(combined_lines)
    end

    -- add existing archive content
    for _, line in ipairs(new_archive_content) do
      combined_lines[#combined_lines + 1] = line
    end

    new_archive_content = combined_lines
  else
    -- newest items go at the bottom (default behavior)
    if #new_archive_content > 0 and #newly_archived_lines > 0 and parent_spacing > 0 then
      add_spacing(new_archive_content) -- gap between old and new archive content
    end

    for _, line in ipairs(newly_archived_lines) do
      new_archive_content[#new_archive_content + 1] = line
    end
  end

  -- make sure we don't leave more than `parent_spacing`
  -- blank lines at the very end of the archive section.
  trim_trailing_blank(new_archive_content)

  -- inject archive section into document

  if #new_archive_content > 0 then
    -- blank line before archive heading if needed
    if #new_main_content > 0 and new_main_content[#new_main_content] ~= "" then
      new_main_content[#new_main_content + 1] = ""
    end
    new_main_content[#new_main_content + 1] = archive_heading_string
    new_main_content[#new_main_content + 1] = "" -- blank after heading
    for _, line in ipairs(new_archive_content) do
      new_main_content[#new_main_content + 1] = line
    end
  end

  -- write buffer
  util.with_preserved_view(function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_main_content)
  end)

  util.notify(
    ("Archived %d todo item%s"):format(archived_root_cnt, archived_root_cnt > 1 and "s" or ""),
    vim.log.levels.INFO
  )
  return true
end

-- Helper function for handling cursor jumps after metadata operations
---@param bufnr integer
---@param todo_item checkmate.TodoItem
---@param meta_name string
---@param meta_config checkmate.MetadataProps
function M._handle_metadata_cursor_jump(bufnr, todo_item, meta_name, meta_config)
  local jump_to = meta_config.jump_to_on_insert
  if not jump_to or jump_to == false then
    return
  end

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    local row = todo_item.metadata.by_tag[meta_name].range.start.row
    local updated_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
    if not updated_line then
      return
    end

    local tag_byte_pos = updated_line:find("@" .. meta_name .. "%(", 1)
    local value_byte_pos = tag_byte_pos and (updated_line:find("%(", tag_byte_pos) + 1) or nil

    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_win_get_buf(win) == bufnr then
      if jump_to == "tag" and tag_byte_pos then
        vim.api.nvim_win_set_cursor(0, { row + 1, tag_byte_pos - 1 })

        if meta_config.select_on_insert then
          vim.cmd("stopinsert")
          vim.cmd("normal! l" .. string.rep("l", #meta_name) .. "v" .. string.rep("h", #meta_name))
        end
      elseif jump_to == "value" and value_byte_pos then
        vim.api.nvim_win_set_cursor(0, { row + 1, value_byte_pos - 1 })

        if meta_config.select_on_insert then
          vim.cmd("stopinsert")

          local closing_paren = updated_line:find(")", value_byte_pos)
          if closing_paren and closing_paren > value_byte_pos then
            local selection_length = closing_paren - value_byte_pos
            if selection_length > 0 then
              vim.cmd("normal! v" .. string.rep("l", selection_length - 1))
            end
          end
        end
      end
    end
  end)
end

--- Collect todo items under cursor or visual selection
---@param is_visual boolean whether to collect items in visual selection (true) or under cursor (false)
---@return checkmate.TodoItem[] items
---@return checkmate.TodoMap todo_map
function M.collect_todo_items_from_selection(is_visual)
  profiler.start("api.collect_todo_items_from_selection")

  local bufnr = vim.api.nvim_get_current_buf()
  local items = {}

  local full_map = parser.get_todo_map(bufnr)

  if is_visual then
    -- exit visual to freeze `'<`/`'>`
    vim.cmd([[execute "normal! \<Esc>"]])

    -- returns 1-based line/col
    local s = vim.fn.getpos("'<")
    local e = vim.fn.getpos("'>")

    -- convert to 0-based rows
    local s_row = (s[2] > 0 and s[2] - 1 or 0)
    local e_row = (e[2] > 0 and e[2] - 1 or 0)

    -- normalize order
    local start_row, end_row = s_row, e_row
    if end_row < start_row then
      start_row, end_row = end_row, start_row
    end

    -- clamp to buffer bounds
    local max_row = math.max(0, vim.api.nvim_buf_line_count(bufnr) - 1)
    if start_row < 0 then
      start_row = 0
    end
    if end_row > max_row then
      end_row = max_row
    end

    -- include todos whose todo first line lies within [start_row, end_row]
    local seen = {}
    for id, todo in pairs(full_map) do
      local mr = todo.todo_marker.position
      if mr.row >= start_row and mr.row <= end_row and not seen[id] then
        seen[id] = true
        items[#items + 1] = todo
      end
    end

    -- deterministic order
    table.sort(items, function(a, b)
      local ar, br = a.todo_marker.position.row, b.todo_marker.position.row
      if ar == br then
        return a.todo_marker.position.col < b.todo_marker.position.col
      end
      return ar < br
    end)
  else
    local c = vim.api.nvim_win_get_cursor(0)
    local row = c[1] - 1 -- to 0-based
    local col = c[2]
    local todo = parser.get_todo_item_at_position(bufnr, row, col, { todo_map = full_map })
    if todo then
      items[#items + 1] = todo
    end
  end

  profiler.stop("api.collect_todo_items_from_selection")
  return items, full_map
end

return M
