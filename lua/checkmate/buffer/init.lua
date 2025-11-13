---@alias checkmate.BufferState "uninitialized"|"setting_up"|"active"|"shutting_down"|"disposed"
---@class checkmate.Buffer
---@field bufnr integer
---@field _local checkmate.BufferLocalHandle
---@field private _state checkmate.BufferState
local Buffer = {}
Buffer.__index = Buffer

local parser = require("checkmate.parser")
local util = require("checkmate.util")
local transaction = require("checkmate.transaction")

---@alias checkmate.BufferKeymapItem {[1]: string, [2]: string}
---@alias checkmate.BufferKeymapList checkmate.BufferKeymapItem[]

local function augroup()
  return vim.api.nvim_create_augroup("checkmate_buffer", { clear = false })
end

-- keyed by bufnr
local _instances = {} ---@type table<integer, checkmate.Buffer>

---Check if buffer is valid for Checkmate
---@param bufnr integer
---@return boolean valid
---@return string? error_msg
function Buffer.is_valid(bufnr)
  if not bufnr or type(bufnr) ~= "number" then
    return false, "Invalid buffer number"
  end

  local ok, is_valid = pcall(vim.api.nvim_buf_is_valid, bufnr)
  if not ok or not is_valid then
    return false, "Buffer is not valid"
  end

  if vim.bo[bufnr].filetype ~= "markdown" then
    return false, "Buffer is not markdown filetype"
  end

  return true
end

---@param bufnr integer
---@return boolean
function Buffer.is_active(bufnr)
  local instance = _instances[bufnr]
  return instance ~= nil and instance._state == "active"
end

---@return integer[]
function Buffer.get_active_buffers()
  local buffers = {}
  for bufnr, instance in pairs(_instances) do
    if vim.api.nvim_buf_is_valid(bufnr) and instance._state == "active" then
      buffers[#buffers + 1] = bufnr
    else
      if not vim.api.nvim_buf_is_valid(bufnr) or instance._state == "disposed" then
        _instances[bufnr] = nil
      end
    end
  end
  return buffers
end

---get all active buffers as a map (bufnr -> true)
---@return table<integer, boolean>
function Buffer.get_active_buffer_map()
  local buffers = {}
  for bufnr, instance in pairs(_instances) do
    if vim.api.nvim_buf_is_valid(bufnr) and instance._state == "active" then
      buffers[bufnr] = true
    else
      if not vim.api.nvim_buf_is_valid(bufnr) or instance._state == "disposed" then
        _instances[bufnr] = nil
      end
    end
  end
  return buffers
end

---@return integer
function Buffer.count_active()
  local count = 0
  for bufnr, instance in pairs(_instances) do
    if vim.api.nvim_buf_is_valid(bufnr) and instance._state == "active" then
      count = count + 1
    else
      if not vim.api.nvim_buf_is_valid(bufnr) or instance._state == "disposed" then
        _instances[bufnr] = nil
      end
    end
  end
  return count
end

---get all buffer instances (including non-active states)
---@return checkmate.Buffer[]
function Buffer.get_all_instances()
  local instances = {}
  for _, instance in pairs(_instances) do
    if vim.api.nvim_buf_is_valid(instance.bufnr) then
      instances[#instances + 1] = instance
    end
  end
  return instances
end

function Buffer.shutdown_all()
  local active = Buffer.get_active_buffers()
  for _, bufnr in ipairs(active) do
    local instance = _instances[bufnr]
    if instance then
      instance:shutdown()
    end
  end
end

-- ============================================================================
-- Instance methods
-- ============================================================================

---@param bufnr? integer
---@return checkmate.Buffer
function Buffer.get(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.api.nvim_buf_is_valid(bufnr) then
    error(("Invalid buffer: %d"):format(bufnr))
  end

  if _instances[bufnr] and _instances[bufnr]._state == "disposed" then
    _instances[bufnr] = nil
  end

  if not _instances[bufnr] then
    _instances[bufnr] = setmetatable({
      bufnr = bufnr,
      _local = require("checkmate.buffer.buf_local").handle(bufnr),
      _state = "uninitialized",
    }, Buffer)
  end

  return _instances[bufnr]
end

---Setup buffer for Checkmate usage
---Idempotent - can be called multiple times safely
---@return boolean success
function Buffer:setup()
  local is_valid, valid_msg = Buffer.is_valid(self.bufnr)
  if not is_valid then
    vim.notify_once("Checkmate: " .. valid_msg, vim.log.levels.ERROR)
    return false
  end

  local checkmate = require("checkmate")
  local log = require("checkmate.log")

  if not checkmate._is_running() then
    log.fmt_error("[buffer] Attempted setup on buffer %d but Checkmate is not running", self.bufnr)
    return false
  end

  if self._state == "active" and self._local:get("setup_complete") == true then
    return true
  end

  if self._state == "setting_up" then
    log.fmt_warn("[buffer] Setup already in progress for buffer %d", self.bufnr)
    return false
  end

  self._state = "setting_up"

  -- initial conversion of on-disk raw markdown to our in-buffer representation
  -- "unicode" term is loosely applied
  parser.convert_markdown_to_unicode(self.bufnr)

  -- initial linting
  local config = require("checkmate.config")
  if config.options.linter and config.options.linter.enabled ~= false then
    require("checkmate.linter").lint_buffer(self.bufnr)
  end

  -- initial highlighting
  local highlights = require("checkmate.highlights")
  -- don't use adaptive strategy for first pass on buffer setup--run it synchronously
  highlights.apply_highlighting(self.bufnr, {
    strategy = "immediate",
    debug_reason = "buffer setup",
  })

  -- User can opt out of TS highlighting if desired
  if config.options.disable_ts_highlights == true then
    vim.treesitter.stop(self.bufnr)
  else
    vim.treesitter.start(self.bufnr, "markdown")
    vim.api.nvim_set_option_value("syntax", "off", { buf = self.bufnr })
  end

  -- setup components
  self:_setup_undo()
  self:_setup_change_watcher()
  self:_setup_keymaps()
  self:_setup_autocmds()

  self._local:set("setup_complete", true)
  self._local:set("cleaned_up", false)
  self._state = "active"

  log.fmt_debug("[buffer] Setup complete for buffer %d", self.bufnr)

  return true
end

---@private
function Buffer:_setup_undo()
  if not vim.api.nvim_buf_is_valid(self.bufnr) then
    return
  end

  -- NOTE: We disable buffer-local 'undofile' for Checkmate buffers.
  -- Rationale:
  --  - In-memory text is Unicode; on-disk text is Markdown. Neovim only restores
  --    undofiles whose hash matches file bytes; mismatch => undofile ignored.
  --  - We still provide correct in-session undo/redo; persistent undo is off by design.
  vim.api.nvim_set_option_value("undofile", false, { buf = self.bufnr })

  -- Baseline tick at attach/first setup; used to infer "no edits since attach".
  -- This lets us distinguish the first "conversion" pass on open from later edits.
  self._local:set("baseline_tick", vim.api.nvim_buf_get_changedtick(self.bufnr))
end

---@private
function Buffer:_setup_change_watcher()
  if not vim.api.nvim_buf_is_valid(self.bufnr) then
    return
  end

  if self._local:get("change_watcher_attached") then
    return
  end

  self._local:set("last_changed_region", nil)

  local bufnr = self.bufnr

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, _, changedtick, firstline, lastline, new_lastline)
      -- ignore our own conversion writes
      if self._local:get("in_conversion") then
        return
      end

      -- record last user changedtick for potential :undojoin by the parser during conversion
      self._local:set("last_user_tick", changedtick)

      -- firstline is 0-based. Replace old [firstline, lastline) with new [firstline, new_lastline)
      -- inclusive end row that covers either the removed or the inserted span
      local old_end = (lastline > firstline) and (lastline - 1) or firstline
      local new_end = (new_lastline > firstline) and (new_lastline - 1) or firstline
      local srow = firstline
      local erow = math.max(old_end, new_end)

      -- keep and merge 1 span for the entire debounce window
      -- when process_buffer eventually runs, it will clear "last_changed_region"
      local prev = self._local:get("last_changed_region")
      if prev then
        srow = math.min(srow, prev.s)
        erow = math.max(erow, prev.e)
      end

      self._local:set("last_changed_region", { s = srow, e = erow, tick = changedtick })
    end,

    on_detach = function()
      self._local:set("change_watcher_attached", nil)
      self._local:set("last_changed_region", nil)
    end,

    utf_sizes = false,
  })

  self._local:set("change_watcher_attached", true)
end

function Buffer:_setup_keymaps()
  local config = require("checkmate.config")
  local keys = config.options.keys or {}
  local bufnr = self.bufnr

  local function buffer_map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, {
      buffer = bufnr,
      silent = true,
      desc = desc,
    })
  end

  self._local:set("keymaps", {})

  local DEFAULT_DESC = "Checkmate <unnamed>"
  local DEFAULT_MODES = { "n" }

  -- setup regular keymaps
  for key, value in pairs(keys) do
    if value ~= false then
      ---@type checkmate.KeymapConfig
      local mapping_config = {}

      if type(value) == "table" then
        -- sequence of {rhs, desc, modes}
        if value[1] ~= nil then
          local rhs, desc, modes = unpack(value)
          mapping_config = { rhs = rhs, desc = desc, modes = modes }
        else -- dict-like table
          mapping_config = vim.deepcopy(value)
        end
      end

      if mapping_config and mapping_config.rhs then
        -- defaults
        mapping_config.modes = mapping_config.modes or DEFAULT_MODES
        mapping_config.desc = mapping_config.desc or DEFAULT_DESC

        for _, mode in ipairs(mapping_config.modes) do
          local success = pcall(buffer_map, mode, key, mapping_config.rhs, mapping_config.desc)

          if success then
            self._local:update("keymaps", function(prev)
              ---@type checkmate.BufferKeymapList
              prev = prev or {}
              prev[#prev + 1] = { mode, key }
              return prev
            end)
          end
        end
      end
    end
  end

  self:_setup_list_continuation_keymaps()

  self:_setup_metadata_keymaps()
end

---i.e. insert mode keymaps for todo/list continuation
---@private
function Buffer:_setup_list_continuation_keymaps()
  local config = require("checkmate.config")

  if not (config.options.list_continuation and config.options.list_continuation.enabled) then
    return
  end

  local continuation_keys = config.options.list_continuation.keys or {}
  local bufnr = self.bufnr
  local ph = require("checkmate.parser.helpers")

  for key, key_config in pairs(continuation_keys) do
    local handler, desc

    if type(key_config) == "function" then
      handler = key_config
      desc = "List continuation for " .. key
    elseif type(key_config) == "table" and type(key_config.rhs) == "function" then
      handler = key_config.rhs
      desc = key_config.desc or ("List continuation for " .. key)
    end

    if handler then
      local orig_key = vim.api.nvim_replace_termcodes(key, true, false, true)

      local expr_fn = function()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local line = vim.api.nvim_get_current_line()
        local todo = ph.match_todo(line)

        if not todo then
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

        -- add undo breakpoint for non-markdown todos
        if not todo.is_markdown then
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g>u", true, false, true), "n", false)
        end

        vim.schedule(function()
          handler()
        end)

        return "" --swallow the key
      end

      local ok = pcall(function()
        vim.keymap.set("i", key, expr_fn, {
          buffer = bufnr,
          expr = true,
          silent = true,
          desc = desc,
        })

        self._local:update("keymaps", function(prev)
          ---@type checkmate.BufferKeymapList
          prev = prev or {}
          prev[#prev + 1] = { "i", key }
          return prev
        end)
      end)

      if not ok then
        require("checkmate.log").fmt_debug("[buffer] Failed to set list continuation keymap for %s", key)
      end
    end
  end
end

---@private
function Buffer:_setup_metadata_keymaps()
  local config = require("checkmate.config")

  if not config.options.use_metadata_keymaps then
    return
  end

  local bufnr = self.bufnr

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

        vim.keymap.set(mode, key, rhs, {
          buffer = bufnr,
          silent = true,
          desc = desc,
        })

        self._local:update("keymaps", function(prev)
          ---@type checkmate.BufferKeymapList
          prev = prev or {}
          prev[#prev + 1] = { mode, key }
          return prev
        end)
      end
    end
  end
end

function Buffer:clear_keymaps()
  local items = self._local:get("keymaps") or {}

  for _, item in ipairs(items) do
    pcall(vim.api.nvim_buf_del_keymap, self.bufnr, item[1], item[2])
  end

  self._local:set("keymaps", {})
end

---@private
function Buffer:_setup_autocmds()
  if not self._local:get("autocmds_setup") then
    local api = require("checkmate.api")
    -- This implementation addresses several subtle behavior issues:
    --   1. Atomic write operation - ensures data integrity (either complete write success or
    -- complete failure, with preservation of the original buffer) by using temp file with a
    -- rename operation (which is atomic at the POSIX filesystem level)
    --   2. A temp buffer is used to perform the unicode to markdown conversion in order to
    -- keep a consistent visual experience for the user, maintain a clean undo history, and
    -- maintain a clean separation between the display format (unicode) and storage format (Markdown)
    --   3. BufWritePre and BufWritePost are called manually so that other plugins can still hook into the write events
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = augroup(),
      buffer = self.bufnr,
      desc = "Checkmate: Convert and save checkmate.nvim files",
      callback = function()
        -- Guard against re-entrancy
        -- Previously had bug due to setting modified flag causing BufWriteCmd to run multiple times
        if self._local:get("writing") then
          return
        end
        self._local:set("writing", true)

        local bufnr = self.bufnr

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
          self._local:set("writing", false)
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
          local ok, _ = pcall(function()
            uv.fs_rename(temp_filename, filename)
          end)

          if not ok then
            -- If rename fails, try to clean up and report error
            pcall(function()
              uv.fs_unlink(temp_filename)
            end)
            vim.notify("Checkmate: Failed to save file", vim.log.levels.ERROR)
            vim.bo[bufnr].modified = was_modified
            self._local:set("writing", false)
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
              self._local:set("writing", false)
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
          self._local:set("writing", false)

          return false
        end
      end,
    })

    vim.api.nvim_create_autocmd({ "InsertEnter" }, {
      group = augroup(),
      buffer = self.bufnr,
      callback = function()
        self._local:set("insert_enter_tick", vim.api.nvim_buf_get_changedtick(self.bufnr))
      end,
    })

    vim.api.nvim_create_autocmd({ "InsertLeave" }, {
      group = augroup(),
      buffer = self.bufnr,
      callback = function()
        local bufnr = self.bufnr
        local tick = vim.api.nvim_buf_get_changedtick(bufnr)
        local modified = self._local:get("insert_enter_tick") ~= tick
        if modified then
          api.process_buffer(bufnr, "full", "InsertLeave")
        end
      end,
    })

    vim.api.nvim_create_autocmd({ "TextChanged" }, {
      group = augroup(),
      buffer = self.bufnr,
      callback = function()
        local bufnr = self.bufnr
        local tick = vim.api.nvim_buf_get_changedtick(bufnr)
        if transaction.is_active(bufnr) or self._local:get("last_conversion_tick") == tick then
          return
        end
        api.process_buffer(bufnr, "full", "TextChanged")
      end,
    })

    vim.api.nvim_create_autocmd({ "TextChangedI" }, {
      group = augroup(),
      buffer = self.bufnr,
      callback = function()
        local bufnr = self.bufnr
        if transaction.is_active(bufnr) then
          return
        end
        api.process_buffer(bufnr, "highlight_only", "TextChangedI")
      end,
    })

    -- cleanup buffer when buffer is deleted or unloaded
    vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload" }, {
      group = augroup(),
      buffer = self.bufnr,
      callback = function()
        self:shutdown()
      end,
    })
    self._local:set("autocmds_setup", true)
  end
end

function Buffer:shutdown()
  if not vim.api.nvim_buf_is_valid(self.bufnr) then
    _instances[self.bufnr] = nil
    return
  end

  if self._local:get("cleaned_up") then
    return
  end

  self._state = "shutting_down"

  local bufnr = self.bufnr

  local api = require("checkmate.api")
  local config = require("checkmate.config")

  -- Attempt to convert buffer back to Markdown to leave the buffer in an expected state
  pcall(parser.convert_unicode_to_markdown, bufnr)
  parser.buf_todo_cache[bufnr] = nil

  self:clear_keymaps()

  local highlights = require("checkmate.highlights")
  highlights.clear_buf_line_cache(bufnr)
  highlights.cancel_progressive(bufnr)

  require("checkmate.debug.debug_highlights").dispose(bufnr)

  vim.api.nvim_buf_clear_namespace(bufnr, config.ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, config.ns_hl, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, config.ns_todos, 0, -1)

  if package.loaded["checkmate.linter"] then
    pcall(require("checkmate.linter").disable, bufnr)
  end

  vim.api.nvim_clear_autocmds({ group = augroup(), buffer = bufnr })

  if api._debounced_processors and api._debounced_processors[bufnr] then
    for _, d in pairs(api._debounced_processors[bufnr]) do
      if type(d) == "table" and d.close then
        pcall(d.close)
      end
    end
    api._debounced_processors[bufnr] = nil
  end

  -- clear buffer-local state
  self._local:clear()
  self._local:set("cleaned_up", true)
  self._state = "disposed"

  _instances[bufnr] = nil
end

return Buffer
