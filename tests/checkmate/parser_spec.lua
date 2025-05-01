describe("Parser", function()
  -- Reset state before each test
  before_each(function()
    -- Reset the plugin state to ensure tests are isolated
    _G.reset_state()
  end)

  -- Test todo item state detection
  describe("todo item detection", function()
    it("should detect unchecked todo items with default marker", function()
      local parser = require("checkmate.parser")
      local unchecked_marker = require("checkmate.config").options.todo_markers.unchecked
      local line = "- " .. unchecked_marker .. " This is an unchecked todo"
      local state = parser.get_todo_item_state(line)

      assert.equals("unchecked", state)
    end)

    it("should detect checked todo items with default marker", function()
      local parser = require("checkmate.parser")
      local checked_marker = require("checkmate.config").options.todo_markers.checked
      local line = "- " .. checked_marker .. " This is a checked todo"
      local state = parser.get_todo_item_state(line)

      assert.equals("checked", state)
    end)

    it("should detect unchecked todo items with various list markers", function()
      local parser = require("checkmate.parser")
      local unchecked_marker = require("checkmate.config").options.todo_markers.unchecked

      -- Test with different list markers
      local list_markers = { "-", "+", "*" }
      for _, marker in ipairs(list_markers) do
        local line = marker .. " " .. unchecked_marker .. " Todo with " .. marker
        local state = parser.get_todo_item_state(line)
        assert.equals("unchecked", state)
      end
    end)

    it("should detect todo items with indentation", function()
      local parser = require("checkmate.parser")
      local unchecked_marker = require("checkmate.config").options.todo_markers.unchecked
      local line = "    - " .. unchecked_marker .. " Indented todo"
      local state = parser.get_todo_item_state(line)

      assert.equals("unchecked", state)
    end)

    it("should detect todo items with ordered list markers", function()
      local parser = require("checkmate.parser")
      local unchecked_marker = require("checkmate.config").options.todo_markers.unchecked

      -- Test with different numbered list formats
      local formats = { "1. ", "1) ", "50. " }
      for _, format in ipairs(formats) do
        local line = format .. unchecked_marker .. " Numbered todo"
        local state = parser.get_todo_item_state(line)
        assert.equals("unchecked", state)
      end
    end)

    it("should return nil for non-todo items", function()
      local parser = require("checkmate.parser")
      local unchecked_marker = require("checkmate.config").options.todo_markers.unchecked

      local lines = {
        "Regular text",
        "- Just a list item",
        "1. Numbered list item",
        "* Another list item",
        unchecked_marker .. " A todo marker but not a list item, therefore not a todo item",
      }

      for _, line in ipairs(lines) do
        local state = parser.get_todo_item_state(line)
        assert.is_nil(state)
      end
    end)

    it("should handle custom todo markers from config", function()
      local parser = require("checkmate.parser")
      -- Temporarily modify config
      local config = require("checkmate.config")
      local original_markers = vim.deepcopy(config.options.todo_markers)

      -- Set custom markers
      config.options.todo_markers = {
        unchecked = "[ ]",
        checked = "[x]",
      }

      -- Test with custom markers
      local lines = {
        "- [ ] Custom unchecked",
        "- [x] Custom checked",
      }

      local expected = {
        "unchecked",
        "checked",
      }

      for i, line in ipairs(lines) do
        local state = parser.get_todo_item_state(line)
        assert.equals(expected[i], state)
      end

      -- Restore original markers
      config.options.todo_markers = original_markers
    end)
  end)

  describe("extract_metadata", function()
    it("should extract a single metadata tag", function()
      local parser = require("checkmate.parser")
      local line = "- □ Task with @priority(high) tag"
      local row = 0

      local metadata = parser.extract_metadata(line, row)

      -- Check structure
      assert.is_table(metadata)
      assert.is_table(metadata.entries)
      assert.is_table(metadata.by_tag)

      -- Check content
      assert.equals(1, #metadata.entries)
      assert.equals("priority", metadata.entries[1].tag, "tag should have the correct name")
      assert.equals("high", metadata.entries[1].value, "tag should have the correct value")
      assert.same(metadata.entries[1], metadata.by_tag.priority)

      -- Check range
      assert.equals(0, metadata.entries[1].range.start.row)
      assert.equals(16, metadata.entries[1].range.start.col, "tag should have correct start col")
      assert.equals(0, metadata.entries[1].range["end"].row)
      assert.equals(30, metadata.entries[1].range["end"].col, "tag should have correct end col")
    end)

    it("should extract multiple metadata tags", function()
      local parser = require("checkmate.parser")
      local line = "- □ Task @priority(high) @due(2023-04-01) @tags(important,urgent)"
      local row = 0

      local metadata = parser.extract_metadata(line, row)

      -- Check basic structure
      assert.equals(3, #metadata.entries)

      -- Check first metadata tag
      assert.equals("priority", metadata.entries[1].tag)
      assert.equals("high", metadata.entries[1].value)

      -- Check second metadata tag
      assert.equals("due", metadata.entries[2].tag)
      assert.equals("2023-04-01", metadata.entries[2].value)

      -- Check third metadata tag
      assert.equals("tags", metadata.entries[3].tag)
      assert.equals("important,urgent", metadata.entries[3].value)

      -- Check by_tag lookup
      assert.same(metadata.entries[1], metadata.by_tag.priority)
      assert.same(metadata.entries[2], metadata.by_tag.due)
      assert.same(metadata.entries[3], metadata.by_tag.tags)
    end)

    it("should handle metadata with spaces in values", function()
      local parser = require("checkmate.parser")
      local line = "- □ Task @note(this is a note with spaces)"
      local row = 0

      local metadata = parser.extract_metadata(line, row)

      assert.equals(1, #metadata.entries)
      assert.equals("note", metadata.entries[1].tag)
      assert.equals("this is a note with spaces", metadata.entries[1].value)
    end)

    it("should handle metadata with trailing and leading spaces in values", function()
      local parser = require("checkmate.parser")
      local line = "- □ Task @note(  spaced value  )"
      local row = 0

      local metadata = parser.extract_metadata(line, row)

      assert.equals(1, #metadata.entries)
      assert.equals("note", metadata.entries[1].tag)
      assert.equals("spaced value", metadata.entries[1].value) -- Spaces should be trimmed
    end)

    it("should properly track position_in_line", function()
      local parser = require("checkmate.parser")
      local line = "- □ Task @first(1) text in between @second(2)"
      local row = 0

      local metadata = parser.extract_metadata(line, row)

      assert.equals(2, #metadata.entries)
      assert.is_true(metadata.entries[1].position_in_line < metadata.entries[2].position_in_line)
    end)

    it("should handle metadata aliases", function()
      local parser = require("checkmate.parser")
      local config = require("checkmate.config")

      -- Add an alias to the config
      config.options.metadata.priority = config.options.metadata.priority or {}
      config.options.metadata.priority.aliases = { "p", "pri" }

      local line = "- □ Task @pri(high) @p(medium)"
      local row = 0

      local metadata = parser.extract_metadata(line, row)

      -- Check that aliases are correctly marked
      assert.equals(2, #metadata.entries)

      assert.equals("pri", metadata.entries[1].tag)
      assert.equals("priority", metadata.entries[1].alias_for)

      assert.equals("p", metadata.entries[2].tag)
      assert.equals("priority", metadata.entries[2].alias_for)

      -- Check by_tag has entries for both alias and canonical name
      assert.same(metadata.entries[1], metadata.by_tag.pri)
      assert.same(metadata.entries[2], metadata.by_tag.p)
      assert.same(metadata.entries[2], metadata.by_tag.priority) -- Last alias wins for canonical name
    end)

    it("should handle tag names with hyphens and underscores", function()
      local parser = require("checkmate.parser")
      local line = "- □ Task @tag-with-hyphens(value) @tag_with_underscores(value)"
      local row = 0

      local metadata = parser.extract_metadata(line, row)

      assert.equals(2, #metadata.entries)
      assert.equals("tag-with-hyphens", metadata.entries[1].tag)
      assert.equals("tag_with_underscores", metadata.entries[2].tag)
    end)

    it("should return empty structure when no metadata present", function()
      local parser = require("checkmate.parser")
      local line = "- □ Task with no metadata"
      local row = 0

      local metadata = parser.extract_metadata(line, row)

      assert.equals(0, #metadata.entries)
      assert.same({}, metadata.by_tag)
    end)

    it("should correctly handle multiple tag instances of the same type", function()
      local parser = require("checkmate.parser")
      local line = "- □ Task @priority(low) Some text @priority(high)"
      local row = 0

      local metadata = parser.extract_metadata(line, row)

      -- Should have both entries
      assert.equals(2, #metadata.entries)

      -- Last one should win in the by_tag lookup
      assert.equals("high", metadata.by_tag.priority.value)
    end)
  end)

  -- Test Markdown/Unicode conversion functions
  describe("format conversion", function()
    -- Test convert_markdown_to_unicode
    describe("convert_markdown_to_unicode", function()
      it("should convert markdown checkboxes to unicode symbols", function()
        local parser = require("checkmate.parser")
        local config = require("checkmate.config")

        -- Create a test buffer with markdown content
        local bufnr = vim.api.nvim_create_buf(false, true)
        local markdown_lines = {
          "# Todo List",
          "",
          "- [ ] Unchecked task",
          "- [x] Checked task",
          "- [X] Checked task with capital X",
          "* [ ] Unchecked with asterisk",
          "+ [x] Checked with plus",
          "1. [ ] Numbered unchecked task",
          "2. [x] Numbered checked task",
          "",
          "- Not a task",
        }

        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, markdown_lines)

        -- Run the conversion
        local was_modified = parser.convert_markdown_to_unicode(bufnr)

        -- Should report modification happened
        assert.is_true(was_modified)

        -- Get the converted content
        local converted_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        -- Check that appropriate conversions happened
        local unchecked = config.options.todo_markers.unchecked
        local checked = config.options.todo_markers.checked

        assert.equals("# Todo List", converted_lines[1]) -- Heading unchanged
        assert.equals("", converted_lines[2]) -- Empty line unchanged
        assert.equals("- " .. unchecked .. " Unchecked task", converted_lines[3])
        assert.equals("- " .. checked .. " Checked task", converted_lines[4])
        assert.equals("- " .. checked .. " Checked task with capital X", converted_lines[5])
        assert.equals("* " .. unchecked .. " Unchecked with asterisk", converted_lines[6])
        assert.equals("+ " .. checked .. " Checked with plus", converted_lines[7])
        assert.equals("1. " .. unchecked .. " Numbered unchecked task", converted_lines[8])
        assert.equals("2. " .. checked .. " Numbered checked task", converted_lines[9])
        assert.equals("", converted_lines[10]) -- Empty line unchanged
        assert.equals("- Not a task", converted_lines[11]) -- Regular list item unchanged

        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    end)

    -- Test convert_unicode_to_markdown
    describe("convert_unicode_to_markdown", function()
      it("should convert unicode symbols back to markdown checkboxes", function()
        local parser = require("checkmate.parser")
        local config = require("checkmate.config")
        local unchecked = config.options.todo_markers.unchecked
        local checked = config.options.todo_markers.checked

        -- Create a test buffer with unicode content
        local bufnr = vim.api.nvim_create_buf(false, true)
        local unicode_lines = {
          "# Todo List",
          "",
          "- " .. unchecked .. " Unchecked task",
          "- " .. checked .. " Checked task",
          "* " .. unchecked .. " Unchecked with asterisk",
          "+ " .. checked .. " Checked with plus",
          "1. " .. unchecked .. " Numbered unchecked task",
          "2. " .. checked .. " Numbered checked task",
          "",
          "- Not a task",
        }

        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, unicode_lines)

        -- Run the conversion
        local was_modified = parser.convert_unicode_to_markdown(bufnr)

        -- Should report modification happened
        assert.is_true(was_modified)

        -- Get the converted content
        local converted_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        -- Check that appropriate conversions happened
        assert.equals("# Todo List", converted_lines[1]) -- Heading unchanged
        assert.equals("", converted_lines[2]) -- Empty line unchanged
        assert.equals("- [ ] Unchecked task", converted_lines[3])
        assert.equals("- [x] Checked task", converted_lines[4])
        assert.equals("* [ ] Unchecked with asterisk", converted_lines[5])
        assert.equals("+ [x] Checked with plus", converted_lines[6])
        assert.equals("1. [ ] Numbered unchecked task", converted_lines[7])
        assert.equals("2. [x] Numbered checked task", converted_lines[8])
        assert.equals("", converted_lines[9]) -- Empty line unchanged
        assert.equals("- Not a task", converted_lines[10]) -- Regular list item unchanged

        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)

      it("should handle indented todo items", function()
        local parser = require("checkmate.parser")
        local config = require("checkmate.config")
        local unchecked = config.options.todo_markers.unchecked
        local checked = config.options.todo_markers.checked

        -- Create a test buffer with indented unicode content
        local bufnr = vim.api.nvim_create_buf(false, true)
        local unicode_lines = {
          "# Todo List",
          "- " .. unchecked .. " Parent task",
          "  - " .. unchecked .. " Indented child task",
          "    - " .. checked .. " Deeply indented task",
        }

        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, unicode_lines)

        -- Run the conversion
        local was_modified = parser.convert_unicode_to_markdown(bufnr)

        -- Should report modification happened
        assert.is_true(was_modified)

        -- Get the converted content
        local converted_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        -- Check that appropriate conversions happened
        assert.equals("# Todo List", converted_lines[1])
        assert.equals("- [ ] Parent task", converted_lines[2])
        assert.equals("  - [ ] Indented child task", converted_lines[3])
        assert.equals("    - [x] Deeply indented task", converted_lines[4])

        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    end)

    it("should perform round-trip conversion correctly", function()
      local parser = require("checkmate.parser")

      -- Create a test buffer
      local bufnr = vim.api.nvim_create_buf(false, true)

      -- Original markdown content
      local original_lines = {
        "# Todo List",
        "- [ ] Task 1",
        "  - [x] Task 1.1",
        "  - [ ] Task 1.2",
        "- [x] Task 2",
        "  * [ ] Task 2.1",
        "  * [x] Task 2.2",
      }

      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, original_lines)

      -- Convert markdown to unicode
      parser.convert_markdown_to_unicode(bufnr)

      -- Then convert unicode back to markdown
      parser.convert_unicode_to_markdown(bufnr)

      -- Get the final content
      local final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      -- Verify round-trip produces original content
      for i, line in ipairs(original_lines) do
        assert.equals(line, final_lines[i])
      end

      -- Clean up
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
end)
