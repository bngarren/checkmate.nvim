describe("Parser", function()
  local h = require("tests.checkmate.helpers")

  lazy_setup(function()
    -- Hide nvim_echo from polluting test output
    stub(vim.api, "nvim_echo")
  end)

  lazy_teardown(function()
    ---@diagnostic disable-next-line: undefined-field
    vim.api.nvim_echo:revert()
  end)

  -- Reset state before each test
  before_each(function()
    -- Reset the plugin state to ensure tests are isolated
    _G.reset_state()
  end)

  -- Helper to find a specific todo in the todo_map by pattern matching on the todo text
  local function find_todo_by_text(todo_map, pattern)
    for _, todo in pairs(todo_map) do
      if todo.todo_text:match(pattern) then
        return todo
      end
    end
    return nil
  end

  -- Helper to verify todo range is consistent with its content
  local function verify_todo_range_matches_content(bufnr, todo)
    -- End row should not exceed buffer line count
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    assert.is_true(todo.range["end"].row < line_count)

    -- Start row should be less than or equal to end row
    assert.is_true(todo.range.start.row <= todo.range["end"].row)

    -- If multi-line, end column should be at end of line
    if todo.range.start.row < todo.range["end"].row then
      local end_line = vim.api.nvim_buf_get_lines(bufnr, todo.range["end"].row, todo.range["end"].row + 1, false)[1]
      assert.equal(#end_line, todo.range["end"].col)
    end

    -- Todo marker should be within text bounds
    assert.is_true(todo.todo_marker.position.row >= todo.range.start.row)
    assert.is_true(todo.todo_marker.position.row <= todo.range["end"].row)
    assert.is_true(todo.todo_marker.position.col >= 0)
  end

  describe("list item discovery", function()
    it("should find all list items", function()
      local parser = require("checkmate.parser")
      local content = [[
- Parent list item A
  - Child list item a.1
  - Child list item a.2
    - Child list item a.2.1
    - Child list item a.2.2

- Parent list item B
    - Child list item b.1 (indented 4-spaces)
- Parent list item C

* Parent list item D

1. Parent list item E
   - Child list item e.1
   * Child list item e.2
   + Child list item e.3
      ]]

      local bufnr = h.create_test_buffer(content)
      local list_items = parser.get_all_list_items(bufnr)

      assert.equal(#list_items, 13)

      local sorted_list_items = {}

      for _, li in ipairs(list_items) do
        table.insert(sorted_list_items, li)
      end

      table.sort(sorted_list_items, function(a, b)
        return a.range.start.row < b.range.start.row -- ascending order
      end)

      local assert_range = function(range, start_row, start_col, end_row, end_col)
        assert.is_not_nil(range)
        if start_row then
          assert.equal(start_row, range.start.row)
        end
        if start_col then
          assert.equal(start_col, range.start.col)
        end
        if end_row then
          assert.equal(end_row, range["end"].row)
        end
        if end_col then
          assert.equal(end_col, range["end"].col)
        end
      end

      local assert_num_children = function(list_item, expected)
        assert.equal(#list_item.children, expected)
      end

      ---@param node TSNode
      local assert_list_marker_range = function(node, expected_start_row, expected_start_col)
        local start_row, start_col, _, _ = node:range()
        assert.equal(start_row, expected_start_row)
        assert.equal(start_col, expected_start_col)
      end

      -- Parent list item A
      assert_range(list_items[1].range, 0)
      assert.is_nil(list_items[1].parent_node)
      assert_num_children(list_items[1], 2) -- 2 direct children
      assert_list_marker_range(list_items[1].list_marker.node, 0, 0)

      -- Child list item a.2
      assert_range(list_items[3].range, 2, 2)
      assert.equal(list_items[3].parent_node, list_items[1].node)
      assert_num_children(list_items[3], 2) -- 2 direct children
      assert_list_marker_range(list_items[3].list_marker.node, 2, 2)

      -- Parent list item B
      assert_range(list_items[6].range, 6)
      assert.is_nil(list_items[6].parent_node)
      assert_num_children(list_items[6], 1) -- 1 direct children
      assert_list_marker_range(list_items[6].list_marker.node, 6, 0)

      -- Parent list item D
      assert_range(list_items[9].range, 10)
      assert.is_nil(list_items[9].parent_node)
      assert_num_children(list_items[9], 0) -- 0 direct children
      assert_list_marker_range(list_items[9].list_marker.node, 10, 0)

      -- Parent list item E
      assert_range(list_items[10].range, 12)
      assert.is_nil(list_items[10].parent_node)
      assert_num_children(list_items[10], 3) -- 3 direct children
      assert_list_marker_range(list_items[10].list_marker.node, 12, 0)

      -- Child list item e.1
      assert.equal(list_items[10].node, list_items[11].parent_node)
      -- Child list item e.2
      assert.equal(list_items[10].node, list_items[12].parent_node)
      -- Child list item e.3
      assert.equal(list_items[10].node, list_items[13].parent_node)
    end)
  end)

  describe("todo discovery", function()
    it("should calculate correct ranges for todos with different lengths", function()
      local config = require("checkmate.config")
      local parser = require("checkmate.parser")
      local unchecked = config.options.todo_markers.unchecked

      local content = [[
# Range Test
- ]] .. unchecked .. [[ Single line todo
- ]] .. unchecked .. [[ Multi-line todo
  with one continuation
- ]] .. unchecked .. [[ Three line
  todo with
  two continuations]]

      local bufnr = h.create_test_buffer(content)
      local todo_map = parser.discover_todos(bufnr)

      -- Find our test todos by text pattern
      local single_line = find_todo_by_text(todo_map, "Single line")
      local multi_line = find_todo_by_text(todo_map, "Multi%-line")
      local three_line = find_todo_by_text(todo_map, "Three line")

      assert.is_not_nil(single_line)
      ---@cast single_line checkmate.TodoItem
      assert.is_not_nil(multi_line)
      ---@cast multi_line checkmate.TodoItem
      assert.is_not_nil(three_line)
      ---@cast three_line checkmate.TodoItem

      -- Single line tests
      assert.equal(1, single_line.range.start.row)
      assert.equal(1, single_line.range["end"].row)

      -- Multi-line tests (2 lines)
      assert.equal(2, multi_line.range.start.row)
      assert.equal(3, multi_line.range["end"].row)

      -- Three-line tests
      assert.equal(4, three_line.range.start.row)
      assert.equal(6, three_line.range["end"].row)

      -- Additional validation for each todo
      verify_todo_range_matches_content(bufnr, single_line)
      verify_todo_range_matches_content(bufnr, multi_line)
      verify_todo_range_matches_content(bufnr, three_line)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    -- Test complex hierarchical todos with various indentation patterns
    it("should correctly handle complex hierarchical todos with various indentations", function()
      local config = require("checkmate.config")
      local parser = require("checkmate.parser")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      local content = [[
# Complex Hierarchy
- ]] .. unchecked .. [[ Level 1 todo
  - ]] .. checked .. [[ Level 2 todo with 2-space indent
    - ]] .. unchecked .. [[ Level 3 todo with 4-space indent
      - ]] .. checked .. [[ Level 4 todo with 6-space indent
        - ]] .. unchecked .. [[ Level 5 todo with 8-space indent
  - ]] .. unchecked .. [[ Another Level 2 with 2-space indent
  - ]] .. checked .. [[ Tab indentation
  	- ]] .. unchecked .. [[ Double tab indentation

- ]] .. unchecked .. [[ Another top-level todo
    - ]] .. checked .. [[ Direct jump to Level 3 (unusual)
- ]] .. unchecked .. [[ Todo with empty content after marker
- ]] .. unchecked .. [[ ]]

      local bufnr = h.create_test_buffer(content)
      local todo_map = parser.discover_todos(bufnr)

      -- First verify total count (updated for new todos)
      local total_todos = 0
      for _ in pairs(todo_map) do
        total_todos = total_todos + 1
      end
      assert.equal(12, total_todos)

      -- Find top-level todos
      local level1_todo = find_todo_by_text(todo_map, "Level 1 todo")
      local another_top = find_todo_by_text(todo_map, "Another top%-level todo")
      local empty_content = find_todo_by_text(todo_map, "Todo with empty content")
      local empty_line = find_todo_by_text(todo_map, "- " .. unchecked .. " %s*$") -- Empty line after marker

      assert.is_not_nil(level1_todo)
      ---@cast level1_todo checkmate.TodoItem
      assert.is_not_nil(another_top)
      ---@cast another_top checkmate.TodoItem
      assert.is_not_nil(empty_content)
      ---@cast empty_content checkmate.TodoItem
      assert.is_not_nil(empty_line)
      ---@cast empty_line checkmate.TodoItem

      -- Verify parent-child relationships
      assert.equal(3, #level1_todo.children)
      assert.equal(1, #another_top.children)
      assert.equal(0, #empty_content.children)
      assert.equal(0, #empty_line.children)

      -- Find level 2 todo
      local level2_todo = nil
      for _, child_id in ipairs(level1_todo.children) do
        local child = todo_map[child_id]
        if child.todo_text:match("Level 2 todo") then
          level2_todo = child
          break
        end
      end

      assert.is_not_nil(level2_todo)
      ---@cast level2_todo checkmate.TodoItem
      assert.equal(1, #level2_todo.children)

      -- Find level 3 via level 2
      local level3_todo = nil
      for _, child_id in ipairs(level2_todo.children) do
        level3_todo = todo_map[child_id]
        break
      end

      assert.is_not_nil(level3_todo)
      ---@cast level3_todo checkmate.TodoItem
      assert.equal(1, #level3_todo.children)

      -- Find level 4 and verify it has level 5 child
      local level4_todo = nil
      for _, child_id in ipairs(level3_todo.children) do
        level4_todo = todo_map[child_id]
        break
      end

      assert.is_not_nil(level4_todo)
      ---@cast level4_todo checkmate.TodoItem
      assert.equal(1, #level4_todo.children)

      -- Verify deep nesting to level 5
      local level5_todo = find_todo_by_text(todo_map, "Level 5 todo")
      assert.is_not_nil(level5_todo)
      ---@cast level5_todo checkmate.TodoItem
      assert.equal(level4_todo.node:id(), level5_todo.parent_id)
      -- verify expected TS nodes above it
      assert.equal("list_item", level5_todo.node:parent():parent():type())
      assert.equal("list", level5_todo.node:parent():type())

      -- Verify tab indentation is handled properly
      local tab_indent = find_todo_by_text(todo_map, "Tab indentation")
      local double_tab = find_todo_by_text(todo_map, "Double tab indentation")
      assert.is_not_nil(tab_indent)
      ---@cast tab_indent checkmate.TodoItem
      assert.is_not_nil(double_tab)
      ---@cast double_tab checkmate.TodoItem

      -- Tab indented item should be child of Another Level 2
      local another_level2 = find_todo_by_text(todo_map, "Another Level 2")
      assert.is_not_nil(another_level2)
      ---@cast another_level2 checkmate.TodoItem

      assert.equal(level1_todo.node:id(), tab_indent.parent_id)
      assert.equal(tab_indent.node:id(), double_tab.parent_id)

      -- Verify unusual hierarchy jump (top level to level 3)
      local unusual = find_todo_by_text(todo_map, "Direct jump to Level 3")
      assert.is_not_nil(unusual)
      ---@cast unusual checkmate.TodoItem
      assert.equal(another_top.node:id(), unusual.parent_id)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("should build correct parent-child relationships with mixed list types", function()
      local config = require("checkmate.config")
      local parser = require("checkmate.parser")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      local content = [[
# Mixed List Types
- ]] .. unchecked .. [[ Parent with dash
  * ]] .. unchecked .. [[ Child with asterisk
  + ]] .. checked .. [[ Child with plus
    - ]] .. unchecked .. [[ Grandchild with dash
1. ]] .. unchecked .. [[ Ordered parent
   1) ]] .. checked .. [[ Ordered child
      1. ]] .. unchecked .. [[ Ordered grandchild
   * ]] .. unchecked .. [[ Unordered child with asterisk in ordered parent
]]

      local bufnr = h.create_test_buffer(content)
      local todo_map = parser.discover_todos(bufnr)

      -- Find todos with different list types
      local parent_dash = find_todo_by_text(todo_map, "Parent with dash")
      local child_asterisk = find_todo_by_text(todo_map, "Child with asterisk")
      local child_plus = find_todo_by_text(todo_map, "Child with plus")
      local ordered_parent = find_todo_by_text(todo_map, "Ordered parent")
      local ordered_child = find_todo_by_text(todo_map, "Ordered child")
      local mixed_child = find_todo_by_text(todo_map, "Unordered child with asterisk")

      assert.is_not_nil(parent_dash)
      ---@cast parent_dash checkmate.TodoItem
      assert.is_not_nil(child_asterisk)
      ---@cast child_asterisk checkmate.TodoItem
      assert.is_not_nil(child_plus)
      ---@cast child_plus checkmate.TodoItem
      assert.is_not_nil(ordered_parent)
      ---@cast ordered_parent checkmate.TodoItem
      assert.is_not_nil(ordered_child)
      ---@cast ordered_child checkmate.TodoItem
      assert.is_not_nil(mixed_child)
      ---@cast mixed_child checkmate.TodoItem

      -- Verify parent-child relationships
      assert.equal(2, #parent_dash.children)
      assert.equal(2, #ordered_parent.children)

      -- Verify mixed list marker relationships
      assert.equal(
        parent_dash.node:id(),
        child_asterisk.parent_id,
        "Child with asterisk should be child of parent with dash"
      )
      assert.equal(parent_dash.node:id(), child_plus.parent_id)
      assert.equal(ordered_parent.node:id(), ordered_child.parent_id, "Ordered child should be child of ordered parent")
      assert.equal(ordered_parent.node:id(), mixed_child.parent_id, "Unordered child should be child of ordered parent")

      -- Verify list marker type is correctly detected
      assert.equal("unordered", parent_dash.list_marker.type)
      assert.equal("unordered", child_asterisk.list_marker.type)
      assert.equal("unordered", child_plus.list_marker.type)
      assert.equal("ordered", ordered_parent.list_marker.type)
      assert.equal("ordered", ordered_child.list_marker.type)
      assert.equal("unordered", mixed_child.list_marker.type)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("should handle edge cases", function()
      local config = require("checkmate.config")
      local parser = require("checkmate.parser")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      local content = [[
- ]] .. unchecked .. [[ Todo at document start
Some non-todo content in between
- ]] .. unchecked .. [[ Parent todo
  - ]] .. checked .. [[ Checked child
  - ]] .. unchecked .. [[ Unchecked child
Line that should not affect parent-child relationship
  Not a todo but indented
- ]] .. unchecked .. [[ Todo at document end]]

      local bufnr = h.create_test_buffer(content)
      local todo_map = parser.discover_todos(bufnr)

      -- Find todos in edge positions
      local start_todo = find_todo_by_text(todo_map, "Todo at document start")
      local parent_todo = find_todo_by_text(todo_map, "Parent todo")
      local checked_child = find_todo_by_text(todo_map, "Checked child")
      local unchecked_child = find_todo_by_text(todo_map, "Unchecked child")
      local end_todo = find_todo_by_text(todo_map, "Todo at document end")

      assert.is_not_nil(start_todo)
      ---@cast start_todo checkmate.TodoItem
      assert.is_not_nil(parent_todo)
      ---@cast parent_todo checkmate.TodoItem
      assert.is_not_nil(checked_child)
      ---@cast checked_child checkmate.TodoItem
      assert.is_not_nil(unchecked_child)
      ---@cast unchecked_child checkmate.TodoItem
      assert.is_not_nil(end_todo)
      ---@cast end_todo checkmate.TodoItem

      -- Verify edge position todos
      assert.is_nil(start_todo.parent_id)
      assert.is_nil(end_todo.parent_id)

      -- Verify parent-child with content in between
      assert.equal(2, #parent_todo.children)
      assert.equal(parent_todo.node:id(), checked_child.parent_id)
      assert.equal(parent_todo.node:id(), unchecked_child.parent_id)

      -- Verify checked state is maintained in hierarchy
      assert.equal("unchecked", parent_todo.state)
      assert.equal("checked", checked_child.state)
      assert.equal("unchecked", unchecked_child.state)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  -- Test todo item state detection
  describe("todo item detection", function()
    it("should detect unchecked todo items with default marker", function()
      local parser = require("checkmate.parser")
      local unchecked_marker = require("checkmate.config").options.todo_markers.unchecked
      local line = "- " .. unchecked_marker .. " This is an unchecked todo"
      local state = parser.get_todo_item_state(line)

      assert.equal("unchecked", state)
    end)

    it("should detect checked todo items with default marker", function()
      local parser = require("checkmate.parser")
      local checked_marker = require("checkmate.config").options.todo_markers.checked
      local line = "- " .. checked_marker .. " This is a checked todo"
      local state = parser.get_todo_item_state(line)

      assert.equal("checked", state)
    end)

    it("should detect unchecked todo items with various list markers", function()
      local parser = require("checkmate.parser")
      local unchecked_marker = require("checkmate.config").options.todo_markers.unchecked

      -- Test with different list markers
      local list_markers = { "-", "+", "*" }
      for _, marker in ipairs(list_markers) do
        local line = marker .. " " .. unchecked_marker .. " Todo with " .. marker
        local state = parser.get_todo_item_state(line)
        assert.equal("unchecked", state)
      end
    end)

    it("should detect todo items with indentation", function()
      local parser = require("checkmate.parser")
      local unchecked_marker = require("checkmate.config").options.todo_markers.unchecked
      local line = "    - " .. unchecked_marker .. " Indented todo"
      local state = parser.get_todo_item_state(line)

      assert.equal("unchecked", state)
    end)

    it("should detect todo items with ordered list markers", function()
      local parser = require("checkmate.parser")
      local unchecked_marker = require("checkmate.config").options.todo_markers.unchecked

      -- Test with different numbered list formats
      local formats = { "1. ", "1) ", "50. " }
      for _, format in ipairs(formats) do
        local line = format .. unchecked_marker .. " Numbered todo"
        local state = parser.get_todo_item_state(line)
        assert.equal("unchecked", state)
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
        assert.equal(expected[i], state)
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
      assert.equal(1, #metadata.entries)
      assert.equal("priority", metadata.entries[1].tag)
      assert.equal("high", metadata.entries[1].value)
      assert.same(metadata.entries[1], metadata.by_tag.priority)

      -- Check range
      assert.equal(0, metadata.entries[1].range.start.row)
      assert.equal(16, metadata.entries[1].range.start.col)
      assert.equal(0, metadata.entries[1].range["end"].row)
      assert.equal(31, metadata.entries[1].range["end"].col)
    end)

    it("should extract multiple metadata tags", function()
      local parser = require("checkmate.parser")
      local line = "- □ Task @priority(high) @due(2023-04-01) @tags(important,urgent)"
      local row = 0

      local metadata = parser.extract_metadata(line, row)

      -- Check basic structure
      assert.equal(3, #metadata.entries)

      -- Check first metadata tag
      assert.equal("priority", metadata.entries[1].tag)
      assert.equal("high", metadata.entries[1].value)

      -- Check second metadata tag
      assert.equal("due", metadata.entries[2].tag)
      assert.equal("2023-04-01", metadata.entries[2].value)

      -- Check third metadata tag
      assert.equal("tags", metadata.entries[3].tag)
      assert.equal("important,urgent", metadata.entries[3].value)

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

      assert.equal(1, #metadata.entries)
      assert.equal("note", metadata.entries[1].tag)
      assert.equal("this is a note with spaces", metadata.entries[1].value)
    end)

    it("should handle metadata with trailing and leading spaces in values", function()
      local parser = require("checkmate.parser")
      local line = "- □ Task @note(  spaced value  )"
      local row = 0

      local metadata = parser.extract_metadata(line, row)

      assert.equal(1, #metadata.entries)
      assert.equal("note", metadata.entries[1].tag)
      assert.equal("spaced value", metadata.entries[1].value) -- Spaces should be trimmed
    end)

    it("should properly track position_in_line", function()
      local parser = require("checkmate.parser")
      local line = "- □ Task @first(1) text in between @second(2)"
      local row = 0

      local metadata = parser.extract_metadata(line, row)

      assert.equal(2, #metadata.entries)
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
      assert.equal(2, #metadata.entries)

      assert.equal("pri", metadata.entries[1].tag)
      assert.equal("priority", metadata.entries[1].alias_for)

      assert.equal("p", metadata.entries[2].tag)
      assert.equal("priority", metadata.entries[2].alias_for)

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

      assert.equal(2, #metadata.entries)
      assert.equal("tag-with-hyphens", metadata.entries[1].tag)
      assert.equal("tag_with_underscores", metadata.entries[2].tag)
    end)

    it("should return empty structure when no metadata present", function()
      local parser = require("checkmate.parser")
      local line = "- □ Task with no metadata"
      local row = 0

      local metadata = parser.extract_metadata(line, row)

      assert.equal(0, #metadata.entries)
      assert.same({}, metadata.by_tag)
    end)

    it("should correctly handle multiple tag instances of the same type", function()
      local parser = require("checkmate.parser")
      local line = "- □ Task @priority(low) Some text @priority(high)"
      local row = 0

      local metadata = parser.extract_metadata(line, row)

      -- Should have both entries
      assert.equal(2, #metadata.entries)

      -- Last one should win in the by_tag lookup
      assert.equal("high", metadata.by_tag.priority.value)
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

        assert.equal("# Todo List", converted_lines[1]) -- Heading unchanged
        assert.equal("", converted_lines[2]) -- Empty line unchanged
        assert.equal("- " .. unchecked .. " Unchecked task", converted_lines[3])
        assert.equal("- " .. checked .. " Checked task", converted_lines[4])
        assert.equal("- " .. checked .. " Checked task with capital X", converted_lines[5])
        assert.equal("* " .. unchecked .. " Unchecked with asterisk", converted_lines[6])
        assert.equal("+ " .. checked .. " Checked with plus", converted_lines[7])
        assert.equal("1. " .. unchecked .. " Numbered unchecked task", converted_lines[8])
        assert.equal("2. " .. checked .. " Numbered checked task", converted_lines[9])
        assert.equal("", converted_lines[10]) -- Empty line unchanged
        assert.equal("- Not a task", converted_lines[11]) -- Regular list item unchanged

        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)

      it("should convert only single-space [ ] checkboxes", function()
        local parser = require("checkmate.parser")
        local config = require("checkmate.config")
        local unchecked = config.options.todo_markers.unchecked

        local content = [[
- [ ] valid
- [  ] too many spaces
- [ ]another -- missing space after ]
- [ ]   This is okay
]]

        local bufnr = h.create_test_buffer(content)

        parser.convert_markdown_to_unicode(bufnr)
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        -- Only the first line should convert
        assert.equal("- " .. unchecked .. " valid", lines[1])
        assert.equal("- [  ] too many spaces", lines[2])
        assert.equal("- [ ]another -- missing space after ]", lines[3])
        assert.equal("- " .. unchecked .. "   This is okay", lines[4])

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
        assert.equal("# Todo List", converted_lines[1]) -- Heading unchanged
        assert.equal("", converted_lines[2]) -- Empty line unchanged
        assert.equal("- [ ] Unchecked task", converted_lines[3])
        assert.equal("- [x] Checked task", converted_lines[4])
        assert.equal("* [ ] Unchecked with asterisk", converted_lines[5])
        assert.equal("+ [x] Checked with plus", converted_lines[6])
        assert.equal("1. [ ] Numbered unchecked task", converted_lines[7])
        assert.equal("2. [x] Numbered checked task", converted_lines[8])
        assert.equal("", converted_lines[9]) -- Empty line unchanged
        assert.equal("- Not a task", converted_lines[10]) -- Regular list item unchanged

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
        assert.equal("# Todo List", converted_lines[1])
        assert.equal("- [ ] Parent task", converted_lines[2])
        assert.equal("  - [ ] Indented child task", converted_lines[3])
        assert.equal("    - [x] Deeply indented task", converted_lines[4])

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
        assert.equal(line, final_lines[i])
      end

      -- Clean up
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe("performance", function()
    -- Test very large and complex document
    it("should handle large documents with many todos at different levels", function()
      local config = require("checkmate.config")
      local parser = require("checkmate.parser")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      local content_lines = { "# Large Document Test" }

      -- Helper to generate todo content
      local function add_todo(level, state, text, metadata)
        local indent = string.rep("  ", level - 1)
        local marker = state == "checked" and checked or unchecked
        local meta_text = metadata or ""
        if metadata then
          meta_text = " " .. meta_text
        end

        table.insert(content_lines, indent .. "- " .. marker .. " " .. text .. meta_text)
      end

      -- Add lots of todos with various properties
      for i = 1, 5 do -- 5 top level sections
        table.insert(content_lines, "")
        table.insert(content_lines, "## Section " .. i)

        for j = 1, 10 do -- 10 top level todos per section
          local top_state = (j % 3 == 0) and "checked" or "unchecked"
          add_todo(1, top_state, "Top level todo " .. i .. "." .. j)

          -- Add some children to each top level todo
          for k = 1, 3 do
            local child_state = (k % 2 == 0) and "checked" or "unchecked"
            add_todo(2, child_state, "Child todo " .. i .. "." .. j .. "." .. k)

            -- Add grandchildren to some children
            if k % 2 == 1 then
              add_todo(3, "unchecked", "Grandchild todo " .. i .. "." .. j .. "." .. k .. ".1", "@priority(high)")
              add_todo(3, "checked", "Grandchild todo " .. i .. "." .. j .. "." .. k .. ".2", "@due(2025-06-01)")
            end
          end
        end
      end

      local content = table.concat(content_lines, "\n")
      local bufnr = h.create_test_buffer(content)

      -- Measure performance
      local start_time = vim.fn.reltime()
      local todo_map = parser.discover_todos(bufnr)
      local end_time = vim.fn.reltimefloat(vim.fn.reltime(start_time))

      -- Check we found the expected number of todos
      local total_todos = 0
      for _ in pairs(todo_map) do
        total_todos = total_todos + 1
      end

      -- We should have:
      -- 5 sections × 10 top level todos = 50 top level
      -- 50 top level × 3 children = 150 children
      -- Half of children get 2 grandchildren each = 75 × 2 = 150 grandchildren
      -- Total: 50 + 150 + 150 = 350 todos
      assert.is_true(total_todos >= 300)

      -- Check structure - select a specific known todo and verify its hierarchy
      local section3_todo2 = nil
      for _, todo in pairs(todo_map) do
        if todo.todo_text:match("Top level todo 3%.2$") then
          section3_todo2 = todo
          break
        end
      end

      assert.is_not_nil(section3_todo2)
      ---@cast section3_todo2 checkmate.TodoItem
      assert.equal(3, #section3_todo2.children)

      -- Pick one child and verify its properties
      local child_id = section3_todo2.children[1]
      local child = todo_map[child_id]

      assert.is_not_nil(child)
      assert.equal(section3_todo2.node:id(), child.parent_id)

      -- Spot check some selected todos to ensure they all have valid ranges
      local count = 0
      for _, todo in pairs(todo_map) do
        if count % 20 == 0 then -- Check every 20th todo
          verify_todo_range_matches_content(bufnr, todo)
        end
        count = count + 1
      end

      -- Verify that todos with metadata have it properly extracted
      local found_metadata = 0
      for _, todo in pairs(todo_map) do
        if #todo.metadata.entries > 0 then
          found_metadata = found_metadata + 1

          -- Verify at least one priority and one due date metadata
          if todo.metadata.by_tag.priority then
            assert.equal("high", todo.metadata.by_tag.priority.value)
          end
          if todo.metadata.by_tag.due then
            assert.equal("2025-06-01", todo.metadata.by_tag.due.value)
          end
        end
      end

      assert.is_true(found_metadata > 0)

      -- print("large doc time: " .. end_time * 1000 .. "ms")

      -- Performance should be reasonable even for large documents
      assert.is_true(end_time < 0.1) -- 100 ms

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
end)
