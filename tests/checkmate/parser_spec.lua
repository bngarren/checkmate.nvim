describe("Parser", function()
  ---@module "tests.checkmate.helpers"
  local h
  ---@module "checkmate"
  local checkmate

  ---@module "checkmate.parser"
  local parser

  local pending_marker = "℗"

  lazy_setup(function()
    -- Hide nvim_echo from polluting test output
    stub(vim.api, "nvim_echo")
  end)

  lazy_teardown(function()
    ---@diagnostic disable-next-line: undefined-field
    vim.api.nvim_echo:revert()
  end)

  before_each(function()
    _G.reset_state()

    h = require("tests.checkmate.helpers")
    checkmate = require("checkmate")
    parser = require("checkmate.parser")

    ---@diagnostic disable-next-line: missing-fields
    checkmate.setup({
      -- add custom states
      todo_states = {
        pending = {
          marker = pending_marker,
          markdown = ".", -- i.e. [.]
        },
      },
    })
  end)

  -- Helper to verify todo range is consistent with its content
  local function verify_todo_range_matches_content(bufnr, todo)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    assert.is_true(todo.range["end"].row < line_count)

    -- start row should be less than or equal to end row
    assert.is_true(todo.range.start.row <= todo.range["end"].row)

    -- if multi-line, end column should be at end of line
    if todo.range.start.row < todo.range["end"].row then
      local end_line = vim.api.nvim_buf_get_lines(bufnr, todo.range["end"].row, todo.range["end"].row + 1, false)[1]
      assert.equal(#end_line, todo.range["end"].col)
    end

    -- todo marker should be within text bounds
    assert.is_true(todo.todo_marker.position.row >= todo.range.start.row)
    assert.is_true(todo.todo_marker.position.row <= todo.range["end"].row)
    assert.is_true(todo.todo_marker.position.col >= 0)
  end

  describe("list item discovery", function()
    it("should find all list items", function()
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

      local bufnr = h.setup_test_buffer(content)
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
      local unchecked = h.get_unchecked_marker()

      local content = [[
# Range Test
- ]] .. unchecked .. [[ Single line todo
- ]] .. unchecked .. [[ Multi-line todo
  with one continuation
- ]] .. unchecked .. [[ Three line
  todo with
  two continuations

New Section
  - ]] .. unchecked .. [[ Indented line]]

      local bufnr = h.setup_test_buffer(content)
      local todo_map = parser.discover_todos(bufnr)

      local single_line = h.exists(h.find_todo_by_text(todo_map, "Single line"))
      local multi_line = h.exists(h.find_todo_by_text(todo_map, "Multi%-line"))
      local three_line = h.exists(h.find_todo_by_text(todo_map, "Three line"))
      local indented_line = h.exists(h.find_todo_by_text(todo_map, "Indented line"))

      assert.equal(1, single_line.range.start.row)
      assert.equal(1, single_line.range["end"].row)

      assert.equal(2, multi_line.range.start.row)
      assert.equal(3, multi_line.range["end"].row)

      assert.equal(4, three_line.range.start.row)
      assert.equal(6, three_line.range["end"].row)

      assert.equal(9, indented_line.range.start.row)
      assert.equal(2, indented_line.range.start.col)
      assert.equal(9, indented_line.range["end"].row)

      verify_todo_range_matches_content(bufnr, single_line)
      verify_todo_range_matches_content(bufnr, multi_line)
      verify_todo_range_matches_content(bufnr, three_line)
      verify_todo_range_matches_content(bufnr, indented_line)
    end)

    it("should correctly handle complex hierarchical todos with various indentations", function()
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

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

      local bufnr = h.setup_test_buffer(content)
      local todo_map = parser.discover_todos(bufnr)

      assert.equal(12, #todo_map)

      local level1_todo = h.exists(h.find_todo_by_text(todo_map, "Level 1 todo"))
      local another_top = h.exists(h.find_todo_by_text(todo_map, "Another top%-level todo"))
      local empty_content = h.exists(h.find_todo_by_text(todo_map, "Todo with empty content"))
      local empty_line = h.exists(h.find_todo_by_text(todo_map, "- " .. unchecked .. " %s*$")) -- Empty line after marker

      -- verify parent-child relationships
      assert.equal(3, #level1_todo.children)
      assert.equal(1, #another_top.children)
      assert.equal(0, #empty_content.children)
      assert.equal(0, #empty_line.children)

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

      local level3_todo = nil
      for _, child_id in ipairs(level2_todo.children) do
        level3_todo = todo_map[child_id]
        break
      end

      assert.is_not_nil(level3_todo)
      ---@cast level3_todo checkmate.TodoItem
      assert.equal(1, #level3_todo.children)

      local level4_todo = nil
      for _, child_id in ipairs(level3_todo.children) do
        level4_todo = todo_map[child_id]
        break
      end

      assert.is_not_nil(level4_todo)
      ---@cast level4_todo checkmate.TodoItem
      assert.equal(1, #level4_todo.children)

      local level5_todo = h.exists(h.find_todo_by_text(todo_map, "Level 5 todo"))

      assert.equal(level4_todo.id, level5_todo.parent_id)
      -- verify expected TS nodes above it
      assert.equal("list_item", level5_todo.node:parent():parent():type())
      assert.equal("list", level5_todo.node:parent():type())

      -- verify tab indentation is handled properly
      local tab_indent = h.exists(h.find_todo_by_text(todo_map, "Tab indentation"))
      local double_tab = h.exists(h.find_todo_by_text(todo_map, "Double tab indentation"))

      -- tab indented item should be child of Another Level 2
      h.exists(h.find_todo_by_text(todo_map, "Another Level 2"))

      assert.equal(level1_todo.id, tab_indent.parent_id)
      assert.equal(tab_indent.id, double_tab.parent_id)

      -- verify unusual hierarchy jump (top level to level 3)
      h.exists(h.find_todo_by_text(todo_map, "Direct jump to Level 3"))
    end)

    it("should parse todos with custom todo states", function()
      local unchecked = h.get_unchecked_marker()

      -- we setup the "pending" state in the top level before_each
      local content = [[
  - ]] .. unchecked .. [[ Default unchecked
  - ]] .. pending_marker .. [[ Pending
      ]]

      local bufnr = h.setup_test_buffer(content)
      local todo_map = parser.discover_todos(bufnr)

      assert.equal(2, #todo_map)

      local pending_todo = h.exists(h.find_todo_by_text(todo_map, "Pending"))
      assert.equal("pending", pending_todo.state)
      assert.equal(pending_marker, pending_todo.todo_marker.text)
    end)

    it("should build correct parent-child relationships with mixed list types", function()
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local content = [[
- ]] .. unchecked .. [[ Parent with dash
  * ]] .. unchecked .. [[ Child with asterisk
  + ]] .. checked .. [[ Child with plus
    - ]] .. unchecked .. [[ Grandchild with dash
1. ]] .. unchecked .. [[ Ordered parent
   1) ]] .. checked .. [[ Ordered child
      1. ]] .. unchecked .. [[ Ordered grandchild
   * ]] .. unchecked .. [[ Unordered child with asterisk in ordered parent
]]

      local bufnr = h.setup_test_buffer(content)
      local todo_map = parser.discover_todos(bufnr)

      local parent_dash = h.exists(h.find_todo_by_text(todo_map, "Parent with dash"))
      local child_asterisk = h.exists(h.find_todo_by_text(todo_map, "Child with asterisk"))
      local child_plus = h.exists(h.find_todo_by_text(todo_map, "Child with plus"))
      local ordered_parent = h.exists(h.find_todo_by_text(todo_map, "Ordered parent"))
      local ordered_child = h.exists(h.find_todo_by_text(todo_map, "Ordered child"))
      local mixed_child = h.exists(h.find_todo_by_text(todo_map, "Unordered child with asterisk"))

      -- parent-child relationships
      assert.equal(2, #parent_dash.children)
      assert.equal(2, #ordered_parent.children)

      -- mixed list marker relationships
      assert.equal(parent_dash.id, child_asterisk.parent_id, "Child with asterisk should be child of parent with dash")
      assert.equal(parent_dash.id, child_plus.parent_id)
      assert.equal(ordered_parent.id, ordered_child.parent_id, "Ordered child should be child of ordered parent")
      assert.equal(ordered_parent.id, mixed_child.parent_id, "Unordered child should be child of ordered parent")

      -- list marker type is correctly detected
      assert.equal("unordered", parent_dash.list_marker.type)
      assert.equal("unordered", child_asterisk.list_marker.type)
      assert.equal("unordered", child_plus.list_marker.type)
      assert.equal("ordered", ordered_parent.list_marker.type)
      assert.equal("ordered", ordered_child.list_marker.type)
      assert.equal("unordered", mixed_child.list_marker.type)
    end)

    it("should handle edge cases", function()
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local content = [[
- ]] .. unchecked .. [[ Todo at document start
Some continuation content in between
- ]] .. unchecked .. [[ Parent todo
  - ]] .. checked .. [[ Checked child
  - ]] .. unchecked .. [[ Unchecked child
Line that should not affect parent-child relationship
  Not a todo but indented
- ]] .. unchecked .. [[ Todo as setext
  @priority(high)
  -
- ]] .. unchecked .. [[ Todo at document end]]

      local bufnr = h.setup_test_buffer(content)
      local todo_map = parser.discover_todos(bufnr)

      local start_todo = h.exists(h.find_todo_by_text(todo_map, "Todo at document start"))
      local parent_todo = h.exists(h.find_todo_by_text(todo_map, "Parent todo"))
      local checked_child = h.exists(h.find_todo_by_text(todo_map, "Checked child"))
      local unchecked_child = h.exists(h.find_todo_by_text(todo_map, "Unchecked child"))
      local end_todo = h.exists(h.find_todo_by_text(todo_map, "Todo at document end"))
      local setext_todo = h.exists(h.find_todo_by_text(todo_map, "Todo as setext"))

      assert.is_nil(start_todo.parent_id)
      assert.is_nil(end_todo.parent_id)

      -- parent-child with content in between
      assert.equal(2, #parent_todo.children)
      assert.equal(parent_todo.id, checked_child.parent_id)
      assert.equal(parent_todo.id, unchecked_child.parent_id)

      -- checked state is maintained in hierarchy
      assert.equal("unchecked", parent_todo.state)
      assert.equal("checked", checked_child.state)
      assert.equal("unchecked", unchecked_child.state)

      -- check that setext_heading todo has metadata parsed correctly
      assert.is_true(require("checkmate.metadata").has_metadata(setext_todo, "priority", function(val)
        return val == "high"
      end))
    end)

    it("should return correct buffer positions for each discovered todo item", function()
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      -- buffer with two todos, one unchecked and one checked
      local file_path = h.create_temp_file()
      local content = [[
- ]] .. unchecked .. [[ Alpha
- ]] .. checked .. [[ Beta
  - ]] .. unchecked .. [[ Charlie
]]
      local bufnr = h.setup_test_buffer(content)

      local todo_map = parser.discover_todos(bufnr)

      assert.equal(3, #todo_map)

      for _, todo in pairs(todo_map) do
        -- the todo position is its extmark pos which is stored by the todo marker pos
        local pos = h.exists(parser.get_todo_position(bufnr, todo.id))

        -- should match the marker's stored position
        assert.equal(todo.todo_marker.position.row, pos.row)
        assert.equal(todo.todo_marker.position.col, pos.col)
      end

      finally(function()
        h.cleanup_file(file_path)
      end)
    end)
  end)

  describe("get todo item and state", function()
    describe("get_todo_item_state", function()
      it("should correctly identify todo item states from line text", function()
        local unchecked_marker = h.get_unchecked_marker()
        local checked_marker = h.get_checked_marker()

        local valid_todos = {
          -- unchecked todos
          { line = "- " .. unchecked_marker .. " This is an unchecked todo", expected = "unchecked" },
          { line = "- " .. unchecked_marker, expected = "unchecked" },
          { line = "* " .. unchecked_marker, expected = "unchecked" },
          { line = "+ " .. unchecked_marker, expected = "unchecked" },
          { line = "1. " .. unchecked_marker, expected = "unchecked" },
          { line = "1) " .. unchecked_marker, expected = "unchecked" },
          { line = "50. " .. unchecked_marker, expected = "unchecked" },

          -- checked todos
          { line = "- " .. checked_marker .. " This is a checked todo", expected = "checked" },
          { line = "- " .. checked_marker, expected = "checked" },
          { line = "* " .. checked_marker, expected = "checked" },
          { line = "+ " .. checked_marker, expected = "checked" },
          { line = "1. " .. checked_marker, expected = "checked" },

          -- custom state (pending) todos
          { line = "- " .. pending_marker .. " This is a pending todo", expected = "pending" },
          { line = "- " .. pending_marker, expected = "pending" },
          { line = "* " .. pending_marker, expected = "pending" },
          { line = "+ " .. pending_marker, expected = "pending" },
          { line = "1. " .. pending_marker, expected = "pending" },

          -- indented
          { line = "    - " .. unchecked_marker .. " Indented todo", expected = "unchecked" },
          { line = "  * " .. checked_marker .. " Another indented", expected = "checked" },
          { line = "\t- " .. pending_marker .. " Tab indented", expected = "pending" },
        }

        for _, test_case in ipairs(valid_todos) do
          local state = parser.get_todo_item_state(test_case.line)
          assert.equal(test_case.expected, state, string.format("Failed to detect state for: %s", test_case.line))
        end

        -- non-todo items that should return nil
        local non_todos = {
          "Regular text",
          "- Just a list item",
          "1. Numbered list item",
          "* Another list item",
          unchecked_marker .. " A todo marker but not a list item",
          "  " .. checked_marker .. " Marker with no list prefix",
          "- [] Missing space in checkbox",
          "- [x] Markdown checkbox (not our format)",
        }

        for _, line in ipairs(non_todos) do
          local state = parser.get_todo_item_state(line)
          assert.is_nil(state)
        end
      end)

      it("should handle multi-char todo markers from config", function()
        local config = require("checkmate.config")

        config.options.todo_states.checked.marker = "[x]"
        config.options.todo_states.unchecked.marker = "[ ]"

        -- force clear the pre-compiled pattern cache
        parser.clear_parser_cache()

        -- {line, expected_state}
        local cases = {
          { "- [ ] Custom unchecked", "unchecked" },
          { "- [x] Custom checked", "checked" },
        }

        for _, case in ipairs(cases) do
          local state = parser.get_todo_item_state(case[1])
          assert.equal(case[2], state)
        end
      end)
    end)

    describe("get_todo_item_at_position", function()
      it("should return todo item with cursor on todo marker line", function()
        local content = [[
- [ ] This is a todo line
This is another line
- [ ] Another todo line
- [.] Pending
        ]]

        ---@diagnostic disable-next-line: missing-fields
        require("checkmate").setup({
          todo_states = {
            pending = {
              marker = pending_marker,
              markdown = ".", -- i.e. [.]
            },
          },
        })

        local bufnr = h.setup_test_buffer(content)

        local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))
        assert.is_truthy(todo_item.todo_text:match("This is a todo line"))

        todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 2, 0))
        assert.is_truthy(todo_item.todo_text:match("Another todo line"))

        todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 3, 0))
        assert.is_truthy(todo_item.todo_text:match("Pending"))
      end)

      it("should return todo item with cursor on continuation line", function()
        local content = [[
- [ ] This is a todo line
This is another line
- [ ] Another todo line
        ]]

        require("checkmate").setup()

        local bufnr = h.setup_test_buffer(content)

        local todo_item1 = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))
        assert.is_truthy(todo_item1.todo_text:match("This is a todo line"))

        local todo_item2 = h.exists(parser.get_todo_item_at_position(bufnr, 1, 0))
        assert.is_truthy(todo_item2.todo_text:match("This is a todo line"))

        assert.equal(todo_item1.id, todo_item2.id)

        local todo_item3 = h.exists(parser.get_todo_item_at_position(bufnr, 2, 0))
        assert.is_truthy(todo_item3.todo_text:match("Another todo line"))

        assert.no.equal(todo_item3.id, todo_item1.id)
      end)

      it("should return todo item with cursor on nested list item", function()
        local content = [[
- [ ] This is a todo line
  - Nested 1
    - Nested 2
      - Nested 3
      - [ ] Separate todo
- [ ] Another todo line
        ]]

        require("checkmate").setup()

        local bufnr = h.setup_test_buffer(content)

        -- test each nested list item
        for i = 1, 3 do
          local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, i, 0))
          assert.is_truthy(todo_item.todo_text:match("This is a todo line"))
        end

        local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 4, 0))
        assert.is_truthy(todo_item.todo_text:match("Separate todo"))
      end)

      it("should handle deeply nested wrapped todos", function()
        local content = [[
- [ ] Parent todo
  - Regular nested item
    - [ ] Deeply nested todo that has a very long line that wraps onto
      the next line with proper indentation maintained
      - Even deeper nesting
- [ ] Another parent
    ]]

        require("checkmate").setup()

        local bufnr = h.setup_test_buffer(content)

        -- cursor on wrapped portion of nested todo
        local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 3, 10))
        assert.is_truthy(todo_item.todo_text:match("Deeply nested todo"))

        assert.is_falsy(todo_item.todo_text:match("Parent todo"))
      end)

      it("should return todo item with cursor within nested todo item", function()
        local content = [[
- [ ] This is a todo line
  - Nested 1
    - [ ] Separate todo
      - Nested 2
- [ ] Another todo line
        ]]

        require("checkmate").setup()

        local bufnr = h.setup_test_buffer(content)

        local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 3, 0))
        assert.is_truthy(todo_item.todo_text:match("Separate todo"))
      end)
    end)
  end)

  describe("extract_metadata", function()
    it("should extract a single metadata tag", function()
      local bufnr = h.setup_test_buffer("- □ Task with @priority(high) tag")

      local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))

      local metadata = parser.extract_metadata(bufnr, todo_item.first_inline_range)

      assert.is_table(metadata)
      assert.is_table(metadata.entries)
      assert.is_table(metadata.by_tag)
      assert.equal(1, #metadata.entries)

      local priority_tag = metadata.by_tag["priority"]

      assert.equal("priority", priority_tag.tag)
      assert.equal("high", priority_tag.value)

      local prefix_length = #"- □ Task with "

      assert.equal(0, priority_tag.range.start.row)
      assert.equal(prefix_length, priority_tag.range.start.col)
      assert.equal(0, priority_tag.range["end"].row)
      -- length in bytes == 1 past the end in 0-based index
      assert.equal(prefix_length + #"@priority(high)", priority_tag.range["end"].col) -- end exclusive

      -- validate value_range
      assert.equal(prefix_length + #"@priority(", priority_tag.value_range.start.col)
      -- length in bytes == 1 past the end in 0-based index
      -- this means that the value_range.end.col points to the `)`
      assert.equal(prefix_length + #"@priority(high", priority_tag.value_range["end"].col) -- end exclusive
    end)

    it("should extract multiple metadata tags", function()
      local line = "- □ Task @priority(high) @due(2023-04-01) @tags(important,urgent)"
      local bufnr = h.setup_test_buffer(line)

      local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))

      local metadata = parser.extract_metadata(bufnr, todo_item.first_inline_range)

      assert.equal(3, #metadata.entries)

      local prefix_length = #"- □ Task "

      -- first metadata tag
      assert.equal("priority", metadata.by_tag["priority"].tag)
      assert.equal("high", metadata.by_tag["priority"].value)
      assert.equal(0, metadata.by_tag["priority"].range.start.row)
      assert.equal(prefix_length, metadata.by_tag["priority"].range.start.col)
      assert.equal(prefix_length + #"@priority(", metadata.by_tag["priority"].value_range.start.col)
      assert.equal(prefix_length + #"@priority(" + #"high", metadata.by_tag["priority"].value_range["end"].col)

      prefix_length = prefix_length + #"@priority(high) "

      -- second metadata tag
      assert.equal("due", metadata.by_tag["due"].tag)
      assert.equal("2023-04-01", metadata.by_tag["due"].value)
      assert.equal(0, metadata.by_tag["due"].range.start.row)
      assert.equal(prefix_length, metadata.by_tag["due"].range.start.col)
      assert.equal(prefix_length + #"@due(", metadata.by_tag["due"].value_range.start.col)
      assert.equal(prefix_length + #"@due(" + #"2023-04-01", metadata.by_tag["due"].value_range["end"].col)

      prefix_length = prefix_length + #"@due(2023-04-01) "

      -- third metadata tag
      assert.equal("tags", metadata.by_tag["tags"].tag)
      assert.equal("important,urgent", metadata.by_tag["tags"].value)
      assert.equal(0, metadata.by_tag["tags"].range.start.row)
      assert.equal(prefix_length, metadata.by_tag["tags"].range.start.col)
      assert.equal(prefix_length + #"@tags(", metadata.by_tag["tags"].value_range.start.col)
      assert.equal(prefix_length + #"@tags(" + #"important,urgent", metadata.by_tag["tags"].value_range["end"].col)

      assert.same(metadata.entries[1], metadata.by_tag.priority)
      assert.same(metadata.entries[2], metadata.by_tag.due)
      assert.same(metadata.entries[3], metadata.by_tag.tags)
    end)

    it("should handle wrapped lines with metadata tags", function()
      local cm = require("checkmate")
      cm.setup()

      local content = [[
- [ ] Todo with metadata @priority(high) @assignee(john) that continues with
  more metadata @due(2024-12-31) on the wrapped line
- [ ] Another todo
    ]]
      local bufnr = h.setup_test_buffer(content)

      local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 1, 20))

      local unchecked = h.get_unchecked_marker()
      local prefix_length = #("- " .. unchecked .. " Todo with metadata ")

      assert.is_not_nil(todo_item.metadata)

      assert.is_not_nil(todo_item.metadata.by_tag.priority)
      assert.equal("high", todo_item.metadata.by_tag.priority.value)
      assert.equal(prefix_length, todo_item.metadata.by_tag["priority"].range.start.col)

      assert.is_not_nil(todo_item.metadata.by_tag.due)
      assert.equal("2024-12-31", todo_item.metadata.by_tag.due.value)
      assert.equal(1, todo_item.metadata.by_tag["due"].range.start.row)
      assert.equal(#"  more metadata ", todo_item.metadata.by_tag["due"].range.start.col)
    end)

    it("should handle metadata split across wrapped lines", function()
      local content = [[
- [ ] Todo with very long metadata value @description(This   is a very long
  description that spans multiple lines) @status(pending)

- [ ] This is a really big hahaha yes, that is funny todo thing that I am just
      writing for the sake of writing @started(06/29/25 20:04) @test(06/29/25
      20:05) @done(06/29/25 20:05)

- [x] This is some extra content @started(06/30/25 20:21) @done(06/30/25 
  20:21) @branch(fix/multi-line-todos)
    ]]
      local bufnr = h.setup_test_buffer(content)

      -- First todo
      local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))

      local unchecked = h.get_unchecked_marker()
      local prefix_length = #("- " .. unchecked .. " Todo with very long metadata value ")

      local desc_tag = todo_item.metadata.by_tag.description
      assert.is_not_nil(desc_tag)
      local expected_value = "This   is a very long description that spans multiple lines"
      assert.matches(expected_value, desc_tag.value)
      assert.equal(0, desc_tag.range.start.row)
      assert.equal(prefix_length, desc_tag.range.start.col)
      assert.equal(1, desc_tag.range["end"].row)
      assert.equal(#"  description that spans multiple lines)", desc_tag.range["end"].col) -- end col is end-exclusive

      assert.is_not_nil(todo_item.metadata.by_tag.status)
      assert.equal("pending", todo_item.metadata.by_tag.status.value)

      -- Second todo
      todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 4, 0))

      local test_tag = todo_item.metadata.by_tag.test
      assert.is_not_nil(test_tag)
      assert.matches("06/29/25 20:05", test_tag.value)
      assert.equal(4, test_tag.range.start.row)
      assert.equal(5, test_tag.range["end"].row)
      assert.equal(#"      20:05)", test_tag.range["end"].col) -- end col is end-exclusive
    end)

    it("should not extract malformed metadata", function()
      local cm = require("checkmate")
      cm.setup()

      -- space between @tag and ()
      local line = "- □ Task @tag (value)"
      local bufnr = h.setup_test_buffer(line)

      local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))

      local metadata = parser.extract_metadata(bufnr, todo_item.first_inline_range)
      assert.equal(0, #metadata.entries)
    end)

    it("should preserve metadata with spaces in and around values", function()
      local cm = require("checkmate")
      cm.setup()

      local content = [[
- [ ] Task @note(this is a note  with   spaces)
- [ ] Task @note( T )]]

      local bufnr = h.setup_test_buffer(content)

      local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))

      local metadata = parser.extract_metadata(bufnr, todo_item.first_inline_range)

      assert.equal(1, #metadata.entries)
      assert.equal("note", metadata.entries[1].tag)
      assert.equal("this is a note  with   spaces", metadata.entries[1].value)

      todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 1, 0))
      metadata = parser.extract_metadata(bufnr, todo_item.first_inline_range)

      -- will preserve whitespace
      assert.equal(1, #metadata.entries)
      assert.equal("note", metadata.entries[1].tag)
      assert.equal(" T ", metadata.entries[1].value)
    end)

    it("should handle metadata with balanced parentheses in value", function()
      local cm = require("checkmate")
      cm.setup()

      local line = "- □ Task @issue(fix(api))"
      local bufnr = h.setup_test_buffer(line)

      local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))

      local metadata = parser.extract_metadata(bufnr, todo_item.first_inline_range)

      assert.equal(1, #metadata.entries)
      assert.equal("issue", metadata.entries[1].tag)
      assert.equal("fix(api)", metadata.entries[1].value)
    end)

    it("should handle metadata with special characters", function()
      local cm = require("checkmate")
      cm.setup()

      local line = "- □ Task @issue(value %with $pecial ch@rs!)"
      local bufnr = h.setup_test_buffer(line)

      local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))

      local metadata = parser.extract_metadata(bufnr, todo_item.first_inline_range)

      assert.equal(1, #metadata.entries)
      assert.equal("issue", metadata.entries[1].tag)
      assert.equal("value %with $pecial ch@rs!", metadata.entries[1].value)
    end)

    it("should handle metadata aliases", function()
      local cm = require("checkmate")
      ---@diagnostic disable-next-line: missing-fields
      cm.setup({
        metadata = {
          priority = {
            aliases = { "p", "pri" },
          },
        },
      })

      local line = "- □ Task @pri(high) @p(medium)"

      local bufnr = h.setup_test_buffer(line)

      local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))

      local metadata = parser.extract_metadata(bufnr, todo_item.first_inline_range)

      assert.equal(2, #metadata.entries)

      assert.equal("pri", metadata.entries[1].tag)
      assert.equal("priority", metadata.entries[1].alias_for)

      assert.equal("p", metadata.entries[2].tag)
      assert.equal("priority", metadata.entries[2].alias_for)

      assert.same(metadata.entries[1], metadata.by_tag.pri)
      assert.same(metadata.entries[2], metadata.by_tag.p)
    end)

    it("should handle tag names with hyphens and underscores", function()
      local cm = require("checkmate")
      cm.setup()

      local line = "- □ Task @tag-with-hyphens(value) @tag_with_underscores(value)"

      local bufnr = h.setup_test_buffer(line)
      local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))

      local metadata = parser.extract_metadata(bufnr, todo_item.first_inline_range)

      assert.equal(2, #metadata.entries)
      assert.equal("tag-with-hyphens", metadata.entries[1].tag)
      assert.equal("tag_with_underscores", metadata.entries[2].tag)
    end)

    it("should return empty structure when no metadata present", function()
      local cm = require("checkmate")
      cm.setup()

      local line = "- □ Task with no metadata"
      local bufnr = h.setup_test_buffer(line)
      local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))

      local metadata = parser.extract_metadata(bufnr, todo_item.first_inline_range)

      assert.equal(0, #metadata.entries)
      assert.same({}, metadata.by_tag)
    end)

    -- TODO: Need more robust test coverage here...
    it("should correctly handle multiple tag instances of the same type", function()
      local cm = require("checkmate")
      cm.setup()

      local line = "- □ Task @priority(low) Some text @priority(high)"
      local bufnr = h.setup_test_buffer(line)
      local todo_item = h.exists(parser.get_todo_item_at_position(bufnr, 0, 0))

      local metadata = parser.extract_metadata(bufnr, todo_item.first_inline_range)

      assert.equal(2, #metadata.entries)

      -- last one should win in the by_tag lookup
      assert.equal("high", metadata.by_tag.priority.value)
    end)
  end)

  -- Markdown/Unicode conversion functions
  describe("format conversion", function()
    describe("convert_markdown_to_unicode", function()
      it("should convert markdown checkboxes to unicode symbols", function()
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
          "- [ ]",
          "- [x]",
          "1. [ ]",
          "1. [x]",
        }

        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, markdown_lines)

        local was_modified = parser.convert_markdown_to_unicode(bufnr)

        assert.is_true(was_modified)

        local converted_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()

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
        assert.equal("- " .. unchecked, converted_lines[12])
        assert.equal("- " .. checked, converted_lines[13])
        assert.equal("1. " .. unchecked, converted_lines[14])
        assert.equal("1. " .. checked, converted_lines[15])
      end)

      it("should convert only single-space [ ] checkboxes", function()
        local unchecked = h.get_unchecked_marker()

        local content = [[
- [ ] valid
- [  ] too many spaces
- [ ]another -- missing space after ]
- [ ]   This is okay
]]

        local bufnr = h.setup_test_buffer(content)

        parser.convert_markdown_to_unicode(bufnr)
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        -- Only the first line should convert
        assert.equal("- " .. unchecked .. " valid", lines[1])
        assert.equal("- [  ] too many spaces", lines[2])
        assert.equal("- [ ]another -- missing space after ]", lines[3])
        assert.equal("- " .. unchecked .. "   This is okay", lines[4])
      end)
    end)

    -- Test convert_unicode_to_markdown
    describe("convert_unicode_to_markdown", function()
      it("should convert unicode symbols back to markdown checkboxes", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()

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

        local was_modified = parser.convert_unicode_to_markdown(bufnr)

        assert.is_true(was_modified)

        local converted_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

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
      end)

      it("should handle indented todo items", function()
        local unchecked = h.get_unchecked_marker()
        local checked = h.get_checked_marker()

        local bufnr = vim.api.nvim_create_buf(false, true)
        local unicode_lines = {
          "# Todo List",
          "- " .. unchecked .. " Parent task",
          "  - " .. unchecked .. " Indented child task",
          "    - " .. checked .. " Deeply indented task",
        }

        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, unicode_lines)

        local was_modified = parser.convert_unicode_to_markdown(bufnr)

        assert.is_true(was_modified)

        local converted_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

        assert.equal("# Todo List", converted_lines[1])
        assert.equal("- [ ] Parent task", converted_lines[2])
        assert.equal("  - [ ] Indented child task", converted_lines[3])
        assert.equal("    - [x] Deeply indented task", converted_lines[4])
      end)
    end)

    it("should perform round-trip conversion correctly", function()
      local bufnr = vim.api.nvim_create_buf(false, true)

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

      parser.convert_markdown_to_unicode(bufnr)

      parser.convert_unicode_to_markdown(bufnr)

      local final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      for i, line in ipairs(original_lines) do
        assert.equal(line, final_lines[i])
      end
    end)

    it("should not add extra lines", function()
      local bufnr = vim.api.nvim_create_buf(false, true)

      local original_lines = {
        "- [ ] Task",
      }

      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, original_lines)

      parser.convert_markdown_to_unicode(bufnr)

      parser.convert_unicode_to_markdown(bufnr)

      local final_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      assert.equal(1, #final_lines)
      assert.equal("- [ ] Task", final_lines[1])
    end)
  end)

  describe("performance", function()
    it("should handle large documents with many todos at different levels", function()
      local unchecked = h.get_unchecked_marker()
      local checked = h.get_checked_marker()

      local content_lines = { "# Large Document Test" }

      local function add_todo(level, state, text, metadata)
        local indent = string.rep("  ", level - 1)
        local marker = state == "checked" and checked or unchecked
        local meta_text = metadata or ""
        if metadata then
          meta_text = " " .. meta_text
        end

        table.insert(content_lines, indent .. "- " .. marker .. " " .. text .. meta_text)
      end

      for i = 1, 5 do -- 5 top level sections
        table.insert(content_lines, "")
        table.insert(content_lines, "## Section " .. i)

        for j = 1, 10 do -- 10 top level todos per section
          local top_state = (j % 3 == 0) and "checked" or "unchecked"
          add_todo(1, top_state, "Top level todo " .. i .. "." .. j)

          -- add some children to each top level todo
          for k = 1, 3 do
            local child_state = (k % 2 == 0) and "checked" or "unchecked"
            add_todo(2, child_state, "Child todo " .. i .. "." .. j .. "." .. k)

            -- add grandchildren to some children
            if k % 2 == 1 then
              add_todo(3, "unchecked", "Grandchild todo " .. i .. "." .. j .. "." .. k .. ".1", "@priority(high)")
              add_todo(3, "checked", "Grandchild todo " .. i .. "." .. j .. "." .. k .. ".2", "@due(2025-06-01)")
            end
          end
        end
      end

      local content = table.concat(content_lines, "\n")
      local bufnr = h.setup_test_buffer(content)

      -- measure performance
      local start_time = vim.fn.reltime()
      local todo_map = parser.discover_todos(bufnr)
      local end_time = vim.fn.reltimefloat(vim.fn.reltime(start_time))

      -- check we found the expected number of todos
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
      assert.equal(section3_todo2.id, child.parent_id)

      -- spot check some selected todos to ensure they all have valid ranges
      local count = 0
      for _, todo in pairs(todo_map) do
        if count % 20 == 0 then -- Check every 20th todo
          verify_todo_range_matches_content(bufnr, todo)
        end
        count = count + 1
      end

      -- todos with metadata properly extracted
      local found_metadata = 0
      for _, todo in pairs(todo_map) do
        if #todo.metadata.entries > 0 then
          found_metadata = found_metadata + 1

          -- at least one priority and one due date metadata
          if todo.metadata.by_tag.priority then
            assert.equal("high", todo.metadata.by_tag.priority.value)
          end
          if todo.metadata.by_tag.due then
            assert.equal("2025-06-01", todo.metadata.by_tag.due.value)
          end
        end
      end

      assert.is_true(found_metadata > 0)

      -- performance should be reasonable even for large documents
      assert.is_true(end_time < 0.1) -- 100 ms
    end)
  end)
end)
