local h = require("tests.checkmate.helpers")

describe("checkmate init and lifecycle", function()
  lazy_setup(function()
    -- Hide nvim_echo from polluting test output
    stub(vim.api, "nvim_echo")
  end)

  lazy_teardown(function()
    ---@diagnostic disable-next-line: undefined-field
    vim.api.nvim_echo:revert()

    _G.reset_state()
  end)

  before_each(function()
    _G.reset_state()
  end)

  describe("setup", function()
    it("should initialize with default configuration", function()
      local checkmate = require("checkmate")
      local config = require("checkmate.config")
      local result = checkmate.setup()
      assert.is_true(result)
      assert.is_true(checkmate.is_running())
      local actual = vim.deepcopy(config.options)
      actual.style = {} -- to match expected because default has style = {}
      actual.todo_markers = nil -- TODO: remove once @deprecated todo_markers is removed
      actual.todo_states.checked.markdown = nil -- won't be in expected/default as it is added during setup
      actual.todo_states.unchecked.markdown = nil
      local expected = config.get_defaults()
      assert.same(expected, actual)
      checkmate.stop()
    end)

    it("should accept custom configuration", function()
      local custom_config = {
        enabled = true,
        files = { "tasks.md", "*.task" },
        todo_markers = {
          checked = "x",
          unchecked = "o",
        },
        notify = false,
      }

      local checkmate = require("checkmate")
      local config = require("checkmate.config")

      local result = checkmate.setup(custom_config)
      assert.is_true(result)
      assert.equal(2, #config.options.files)
      assert.equal("tasks.md", config.options.files[1])
      assert.equal("*.task", config.options.files[2])
      assert.equal("x", config.options.todo_markers.checked)
      assert.equal("o", config.options.todo_markers.unchecked)
      assert.is_false(config.options.notify)

      checkmate.stop()
    end)

    it("should handle invalid configuration gracefully", function()
      local checkmate = require("checkmate")

      ---@diagnostic disable-next-line: missing-fields, assign-type-mismatch
      local result = checkmate.setup({ enabled = "not a boolean" })
      assert.is_false(result)
      assert.is_false(checkmate.is_running())

      _G.reset_state()
      ---@diagnostic disable-next-line: missing-fields, assign-type-mismatch
      result = checkmate.setup({ files = "not a table" })
      assert.is_false(result)
      assert.is_false(checkmate.is_running())

      checkmate.stop()
    end)

    it("should stop existing instance before starting new one", function()
      local checkmate = require("checkmate")
      local config = require("checkmate.config")

      checkmate.setup()
      assert.is_true(checkmate.is_running())

      -- Second setup should stop first instance
      ---@diagnostic disable-next-line: missing-fields, assign-type-mismatch
      local result = checkmate.setup({ notify = false })
      assert.is_true(result)
      assert.is_true(checkmate.is_running())
      assert.is_false(config.options.notify)

      checkmate.stop()
    end)

    it("should not start when enabled is false", function()
      local checkmate = require("checkmate")
      ---@diagnostic disable-next-line: missing-fields, assign-type-mismatch
      local result = checkmate.setup({ enabled = false })
      assert.is_true(result)
      assert.is_false(checkmate.is_running())

      checkmate.stop()
    end)

    it("should activate existing markdown buffers on setup", function()
      local checkmate = require("checkmate")

      vim.cmd("edit todo")
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo[bufnr].filetype = "markdown"

      -- setup should activate this buffer
      checkmate.setup()

      vim.wait(20)

      assert.is_true(vim.b[bufnr].checkmate_setup_complete or false)

      checkmate.stop()
    end)
  end)

  describe("plugin state", function()
    before_each(function()
      _G.reset_state()
    end)

    it("should track running state correctly", function()
      local checkmate = require("checkmate")
      checkmate.setup()

      assert.is_true(checkmate.is_running())

      checkmate.stop()
      assert.is_false(checkmate.is_running())
    end)

    it("should handle multiple start calls", function()
      local checkmate = require("checkmate")
      checkmate.setup()

      assert.is_true(checkmate.is_running())

      checkmate.start()
      assert.is_true(checkmate.is_running())

      checkmate.stop()
    end)

    it("should handle multiple stop calls", function()
      local checkmate = require("checkmate")
      checkmate.setup()

      checkmate.stop()
      assert.is_false(checkmate.is_running())

      checkmate.stop()
      assert.is_false(checkmate.is_running())
    end)

    it("should clean up resources on stop", function()
      local checkmate = require("checkmate")

      checkmate.setup()

      assert.equal(0, checkmate.count_active_buffers())

      local bufnr = h.setup_test_buffer("", "todo")

      vim.wait(50, function()
        return vim.b[bufnr].checkmate_setup_complete == true
      end, 10)

      assert.equal(1, checkmate.count_active_buffers())

      checkmate.stop()

      local config = require("checkmate.config")
      local ns_extmarks = vim.api.nvim_buf_get_extmarks(bufnr, config.ns, 0, -1, {})
      assert.equal(0, #ns_extmarks)

      local ns_todo_extmarks = vim.api.nvim_buf_get_extmarks(bufnr, config.ns_todos, 0, -1, {})
      assert.equal(0, #ns_todo_extmarks)

      assert.equal(0, checkmate.count_active_buffers())

      vim.api.nvim_buf_delete(bufnr, { force = true })

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should handle a disable then enable cycle", function()
      local checkmate = require("checkmate")

      checkmate.setup()

      assert.is_true(checkmate.is_initialized())
      assert.is_true(checkmate.is_running())
      assert.equal(0, checkmate.count_active_buffers())

      local content = [[
- [ ] Todo A
- [ ] Todo B
  - [x] Sub-todo 1
  - [ ] Sub-todo 2

  Regular line
      ]]

      local bufnr = h.setup_test_buffer(content, "todo")

      assert.is_true(checkmate.is_buffer_active(bufnr))
      assert.equal(1, checkmate.count_active_buffers())
      assert.equal(bufnr, checkmate.get_active_buffer_list()[1])

      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local expected_lines = {
        "- " .. unchecked .. " Todo A",
        "- " .. unchecked .. " Todo B",
        "  - " .. checked .. " Sub-todo 1",
        "  - " .. unchecked .. " Sub-todo 2",
      }

      local buf_string = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      local ok = h.verify_content_lines(buf_string, expected_lines)
      assert.is_true(ok)

      checkmate.disable()

      assert.is_false(checkmate.is_running())
      assert.is_false(checkmate.is_buffer_active(bufnr))
      assert.equal(0, checkmate.count_active_buffers())

      buf_string = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      assert.same(content, buf_string)

      checkmate.enable()

      assert.is_true(checkmate.is_buffer_active(bufnr))
      assert.equal(1, checkmate.count_active_buffers())
      assert.equal(bufnr, checkmate.get_active_buffer_list()[1])

      buf_string = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      ok = h.verify_content_lines(buf_string, expected_lines)
      assert.is_true(ok)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)
  end)

  describe("buffer activation", function()
    it("should activate on FileType autocmd for matching files", function()
      local checkmate = require("checkmate")
      checkmate.setup()

      -- Create a buffer with matching filename
      vim.cmd("edit TODO")
      local bufnr = vim.api.nvim_get_current_buf()

      vim.bo[bufnr].filetype = "markdown"

      assert.is_true(vim.b[bufnr].checkmate_setup_complete or false)

      checkmate.stop()

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should not activate for non-matching files", function()
      local checkmate = require("checkmate")
      checkmate.setup()

      vim.cmd("edit NOPE.md") -- does not match defaults
      local bufnr = vim.api.nvim_get_current_buf()

      vim.bo[bufnr].filetype = "markdown"

      assert.is_falsy(vim.b[bufnr].checkmate_setup_complete)

      checkmate.stop()
    end)

    it("should handle buffer deletion", function()
      local checkmate = require("checkmate")

      checkmate.setup()

      vim.cmd("edit todo")
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo[bufnr].filetype = "markdown"

      local active_buffers = checkmate.get_active_buffer_map()

      assert.is_true(active_buffers[bufnr] or false)

      vim.api.nvim_buf_delete(bufnr, { force = true })

      active_buffers = checkmate.get_active_buffer_map()
      assert.is_nil(active_buffers[bufnr])
    end)
  end)

  describe("file patterns", function()
    local checkmate = require("checkmate")
    local file_matcher = require("checkmate.file_matcher")

    lazy_setup(function()
      checkmate.setup()
    end)

    lazy_teardown(function()
      checkmate.stop()
    end)

    local function test_pattern(filename, patterns, should_match, filetype)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, filename)

      if filetype then
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("setfiletype " .. filetype)
        end)
      else
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("setfiletype markdown")
        end)
      end

      local result = file_matcher.should_activate_for_buffer(bufnr, patterns)
      assert.equal(
        should_match,
        result,
        string.format(
          "Pattern match failed for '%s' with patterns %s and filetype '%s' (expected %s, got %s)",
          filename,
          vim.inspect(patterns),
          vim.bo[bufnr].filetype,
          tostring(should_match),
          tostring(result)
        )
      )

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end

    describe("empty or invalid inputs", function()
      it("returns false when patterns = nil", function()
        test_pattern("todo.md", nil, false)
      end)

      it("returns false when patterns = {} (empty list)", function()
        test_pattern("todo.md", {}, false)
      end)

      it("returns false when buffer has no name", function()
        local bufnr = vim.api.nvim_create_buf(false, true)
        -- no name set
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("setfiletype markdown")
        end)
        local result = file_matcher.should_activate_for_buffer(bufnr, { "*.md" })
        assert.is_false(result)
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)

      it("returns false when buffer is invalid", function()
        -- delete immediately to guarantee invalid bufnr
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_delete(bufnr, { force = true })
        local result = file_matcher.should_activate_for_buffer(bufnr, { "*.md" })
        assert.is_false(result)
      end)

      it("returns false if filetype is not markdown, even if pattern matches", function()
        test_pattern("notes.md", { "*.md" }, false, "text")
      end)
    end)

    describe("case sensitivity", function()
      it("demonstrates case sensitivity", function()
        test_pattern("/path/TODO", { "todo" }, false)
        test_pattern("/path/todo", { "TODO" }, false)
        test_pattern("/path/ToDo", { "todo" }, false)

        test_pattern("/path/TODO", { "TODO" }, true)
        test_pattern("/path/todo", { "todo" }, true)
      end)
    end)

    describe("backslash normalization on Windows-style paths", function()
      it("matches even if filename uses backslashes", function()
        test_pattern([[C:\project\todo.md]], { "*.md" }, true)
        test_pattern([[C:\project\todo.txt]], { "*.md" }, false)
      end)

      it("matches even if pattern uses backslashes", function()
        test_pattern("/home/user/todo.md", { [[*\todo.md]] }, true)
        test_pattern("/home/user/todo.md", { [[*\todo.txt]] }, false)
      end)
    end)

    describe("absolute-path vs relative-path logic", function()
      it("only matches absolute globs (starting with /) against full path", function()
        -- pattern="/foo/bar/*.md" must match only if filename begins with exactly "/foo/bar/"
        test_pattern("/foo/bar/a.md", { "/foo/bar/*.md" }, true)
        test_pattern("/x/y/foo/bar/a.md", { "/foo/bar/*.md" }, false)
      end)

      it("only matches '**/' globs anywhere in path", function()
        -- pattern="**/*.md" should match any .md anywhere
        test_pattern("/abc/def/ghi.md", { "**/*.md" }, true)
        test_pattern("ghi.md", { "**/*.md" }, true)
        test_pattern("/abc/def/ghi.txt", { "**/*.md" }, false)
      end)

      it("relative path glob matches any suffix of path", function()
        -- pattern "subdir/*.md" should match if filename ends in "subdir/... .md"
        test_pattern("/foo/bar/subdir/x.md", { "subdir/*.md" }, true)
        test_pattern("/foo/bar/x/subdir/y.md", { "subdir/*.md" }, true)
        test_pattern("/foo/bar/othersubdir/x.md", { "subdir/*.md" }, false)
      end)

      it("absolute path glob does NOT try suffix matching", function()
        -- pattern starts with "/", so no suffix matching
        test_pattern("/foo/bar/subdir/x.md", { "/bar/subdir/*.md" }, false)
        test_pattern("/foo/bar/subdir/x.md", { "/foo/bar/subdir/*.md" }, true)
      end)
    end)

    describe("patterns mixing path and basename", function()
      it("treats patterns without slash as basename only", function()
        -- even if file lives at "/foo/todo", "todo" will match basename
        test_pattern("/foo/todo", { "todo" }, true)
        test_pattern("/foo/not_todo", { "todo" }, false)
        test_pattern("/foo/todo.md", { "todo" }, false)
      end)

      it("treats patterns with slash as requiring a slash in the path", function()
        -- "a/todo" must match any suffix ending in "a/todo"
        test_pattern("/foo/a/todo", { "a/todo" }, true)
        test_pattern("/foo/b/a/todo", { "a/todo" }, true)
        test_pattern("/foo/a/todo.md", { "a/todo" }, false)
      end)
    end)

    describe("documented glob syntax", function()
      it("matches with * in the middle of pattern (*todo*)", function()
        -- "*todo*" matches any file with "todo" in the name
        test_pattern("/path/mytodolist.md", { "*todo*" }, true)
        test_pattern("/path/todoapp.md", { "*todo*" }, true)
        test_pattern("/path/bigtodo", { "*todo*" }, true)
        test_pattern("/path/something.md", { "*todo*" }, false)
        test_pattern("/path/to_do.md", { "*todo*" }, false)
      end)

      it("matches single character with ? wildcard", function()
        -- "?" matches exactly one character
        test_pattern("/path/todo1.md", { "todo?.md" }, true)
        test_pattern("/path/todoA.md", { "todo?.md" }, true)
        test_pattern("/path/todo.md", { "todo?.md" }, false) -- no char between 'todo' and '.md'
        test_pattern("/path/todo22.md", { "todo?.md" }, false) -- two chars instead of one
      end)

      it("matches character sets with [abc]", function()
        -- "[abc]" matches any single character in the set
        test_pattern("/path/todo1.md", { "todo[123].md" }, true)
        test_pattern("/path/todo2.md", { "todo[123].md" }, true)
        test_pattern("/path/todo3.md", { "todo[123].md" }, true)
        test_pattern("/path/todo4.md", { "todo[123].md" }, false)
        test_pattern("/path/todoa.md", { "todo[123].md" }, false)
      end)

      it("matches alternation with {foo,bar}", function()
        -- "{foo,bar}" matches either "foo" or "bar"
        test_pattern("/path/TODO.md", { "{TODO,DONE}.md" }, true)
        test_pattern("/path/DONE.md", { "{TODO,DONE}.md" }, true)
        test_pattern("/path/PENDING.md", { "{TODO,DONE}.md" }, false)

        -- works in paths too
        test_pattern("/home/docs/todo.md", { "{docs,notes}/todo.md" }, true)
        test_pattern("/home/notes/todo.md", { "{docs,notes}/todo.md" }, true)
        test_pattern("/home/other/todo.md", { "{docs,notes}/todo.md" }, false)
      end)
    end)

    describe("edge-case wildcards", function()
      it("'*' at beginning or end still anchors correctly", function()
        -- "*todo" must match names ending in "todo", but not "atetodow"
        test_pattern("mytodo", { "*todo" }, true)
        test_pattern("USETODO", { "*TODO" }, true)
        test_pattern("endTodo", { "*Todo" }, true)
        test_pattern("atetodow", { "*todo" }, false)
      end)

      it("patterns containing only wildcards match correctly", function()
        -- "*" alone (no slash) matches any basename (including empty basename? filename never empty)
        test_pattern("/foo/bar.txt", { "*" }, true)
        test_pattern("/foo/.hidden", { "*" }, true)

        -- "**" alone (no slash) is equivalent to "*" in our implementation
        test_pattern("/foo/bar.txt", { "**" }, true)
      end)

      it("demonstrates equivalence of docs/*.md and **/docs/*.md", function()
        -- both patterns match at any depth due to suffix matching
        local patterns1 = { "docs/*.md" }
        local patterns2 = { "**/docs/*.md" }

        -- both should match identically
        test_pattern("/home/docs/file.md", patterns1, true)
        test_pattern("/home/docs/file.md", patterns2, true)

        test_pattern("/project/src/docs/file.md", patterns1, true)
        test_pattern("/project/src/docs/file.md", patterns2, true)

        test_pattern("/a/b/c/d/docs/file.md", patterns1, true)
        test_pattern("/a/b/c/d/docs/file.md", patterns2, true)
      end)
    end)
  end)

  it("should handle filetype changes", function()
    local checkmate = require("checkmate")
    checkmate.setup()

    vim.cmd("edit todo")
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].filetype = "markdown"

    assert.is_true(vim.b[bufnr].checkmate_setup_complete or false)

    vim.bo[bufnr].filetype = "text"

    vim.wait(10)

    assert.equal(0, checkmate.count_active_buffers())

    vim.bo[bufnr].filetype = "markdown"

    vim.wait(10)
    assert.equal(1, checkmate.count_active_buffers())

    checkmate.stop()
  end)

  pending("should handle configuration changes while running", function()
    local checkmate = require("checkmate")
    local file_matcher = require("checkmate.file_matcher")

    -- Initial setup
    ---@diagnostic disable-next-line: missing-fields
    checkmate.setup({ files = { "todo.md" } })

    vim.cmd("edit todo.md")
    local buf1 = vim.api.nvim_get_current_buf()
    vim.bo[buf1].filetype = "markdown"

    vim.cmd("edit tasks.md")
    local buf2 = vim.api.nvim_get_current_buf()
    vim.bo[buf2].filetype = "markdown"

    local should_buf2 = file_matcher.should_activate_for_buffer(buf2, { "tasks.md" })

    assert.is_true(vim.b[buf1].checkmate_setup_complete or false)
    assert.is_falsy(vim.b[buf2].checkmate_setup_complete)

    -- Change configuration
    ---@diagnostic disable-next-line: missing-fields
    checkmate.setup({ files = { "tasks.md" } })

    -- buf1 should be deactivated, buf2 should be activated
    assert.is_falsy(vim.b[buf1].checkmate_setup_complete)
    assert.is_true(vim.b[buf2].checkmate_setup_complete or false)

    checkmate.stop()
  end)
end)
