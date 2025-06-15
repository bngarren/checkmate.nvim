describe("Highlights", function()
  local h = require("tests.checkmate.helpers")
  local checkmate = require("checkmate")

  before_each(function()
    _G.reset_state()

    checkmate.setup()
  end)

  after_each(function()
    checkmate.stop()
  end)

  describe("list marker", function()
    it("should correctly highlight the todo LIST marker", function()
      local config = require("checkmate.config")
      local highlights = require("checkmate.highlights")
      local unchecked = config.get_defaults().todo_markers.unchecked
      local checked = config.get_defaults().todo_markers.checked

      local content = [[
- ]] .. unchecked .. [[ Todo A 
- ]] .. unchecked .. [[ Todo B 
  - ]] .. checked .. [[ Todo B.1 
    - ]] .. checked .. [[ Todo B.1.1 
]]

      local bufnr = h.create_test_buffer(content)

      vim.api.nvim_buf_clear_namespace(bufnr, config.ns, 0, -1)

      highlights.apply_highlighting(bufnr, { debug_reason = "test" })

      local extmarks = h.get_extmarks(bufnr, config.ns)
      local got = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == "CheckmateListMarkerUnordered" then
          table.insert(got, {
            start = { row = mark[2], col = mark[3] },
            ["end"] = { row = d.end_row, col = d.end_col },
          })
        end
      end

      local expected = {
        { start = { row = 0, col = 0 }, ["end"] = { row = 0, col = 1 } },
        { start = { row = 1, col = 0 }, ["end"] = { row = 1, col = 1 } },
        { start = { row = 2, col = 2 }, ["end"] = { row = 2, col = 3 } },
        { start = { row = 3, col = 4 }, ["end"] = { row = 3, col = 5 } },
      }

      assert.equal(#expected, #got)
      assert.same(expected, got)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should correctly highlight within-todo list markers", function()
      local config = require("checkmate.config")
      local highlights = require("checkmate.highlights")
      local unchecked = config.get_defaults().todo_markers.unchecked

      local content = [[
- ]] .. unchecked .. [[ Todo A 
  - Non Todo 1
    - Non Todo 1.1
  1. Ordered
]]

      local bufnr = h.create_test_buffer(content)

      vim.api.nvim_buf_clear_namespace(bufnr, config.ns, 0, -1)

      highlights.apply_highlighting(bufnr, { debug_reason = "test" })

      local extmarks = h.get_extmarks(bufnr, config.ns)

      -- UNORDERED

      local got_unordered = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == "CheckmateListMarkerUnordered" then
          table.insert(got_unordered, {
            start = { row = mark[2], col = mark[3] },
            ["end"] = { row = d.end_row, col = d.end_col },
          })
        end
      end

      local expected = {
        { start = { row = 0, col = 0 }, ["end"] = { row = 0, col = 1 } },
        { start = { row = 1, col = 2 }, ["end"] = { row = 1, col = 3 } },
        { start = { row = 2, col = 4 }, ["end"] = { row = 2, col = 5 } },
      }

      assert.equal(#expected, #got_unordered)
      assert.same(expected, got_unordered)

      -- ORDERED

      local got_ordered = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == "CheckmateListMarkerOrdered" then
          table.insert(got_ordered, {
            start = { row = mark[2], col = mark[3] },
            ["end"] = { row = d.end_row, col = d.end_col },
          })
        end
      end

      expected = {
        { start = { row = 3, col = 2 }, ["end"] = { row = 3, col = 4 } },
      }

      assert.equal(#expected, #got_ordered)
      assert.same(expected, got_ordered)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)

    it("should correctly highlight the todo marker", function()
      local config = require("checkmate.config")
      local highlights = require("checkmate.highlights")
      local unchecked = config.get_defaults().todo_markers.unchecked
      local checked = config.get_defaults().todo_markers.checked

      local content = [[
- ]] .. unchecked .. [[ Todo A 
- ]] .. unchecked .. [[ Todo B 
  - ]] .. checked .. [[ Todo B.1 
    - ]] .. checked .. [[ Todo B.1.1 
]]

      local bufnr = h.create_test_buffer(content)

      vim.api.nvim_buf_clear_namespace(bufnr, config.ns, 0, -1)

      highlights.apply_highlighting(bufnr, { debug_reason = "test" })

      local extmarks = h.get_extmarks(bufnr, config.ns)

      -- UNCHECKED marker

      local got_unchecked = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == "CheckmateUncheckedMarker" then
          table.insert(got_unchecked, {
            start = { row = mark[2], col = mark[3] },
            ["end"] = { row = d.end_row, col = d.end_col },
          })
        end
      end

      -- remember, this is byte length here...
      local expected = {
        { start = { row = 0, col = 2 }, ["end"] = { row = 0, col = 2 + #unchecked } },
        { start = { row = 1, col = 2 }, ["end"] = { row = 1, col = 2 + #unchecked } },
      }

      assert.equal(#expected, #got_unchecked)
      assert.same(expected, got_unchecked)

      -- CHECKED marker

      local got_checked = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == "CheckmateCheckedMarker" then
          table.insert(got_checked, {
            start = { row = mark[2], col = mark[3] },
            ["end"] = { row = d.end_row, col = d.end_col },
          })
        end
      end

      expected = {
        { start = { row = 2, col = 4 }, ["end"] = { row = 2, col = 4 + #checked } },
        { start = { row = 3, col = 6 }, ["end"] = { row = 3, col = 6 + #checked } },
      }

      assert.equal(#expected, #got_checked)
      assert.same(expected, got_checked)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)
  end)

  describe("content", function()
    it("should correctly highlight main and additional content", function()
      local config = require("checkmate.config")
      local highlights = require("checkmate.highlights")
      local unchecked = config.get_defaults().todo_markers.unchecked
      local checked = config.get_defaults().todo_markers.checked

      local content = [[
- ]] .. unchecked .. [[ Todo A main content
  Additional content line 1
  Additional content line 2
- ]] .. checked .. [[ Todo B main content
  - Regular list item
  More additional content
]]

      local bufnr = h.create_test_buffer(content)

      vim.api.nvim_buf_clear_namespace(bufnr, config.ns, 0, -1)

      highlights.apply_highlighting(bufnr, { debug_reason = "test" })

      local extmarks = h.get_extmarks(bufnr, config.ns)

      -- MAIN CONTENT (first line of each todo)
      local got_main = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and (d.hl_group == "CheckmateUncheckedMainContent" or d.hl_group == "CheckmateCheckedMainContent") then
          table.insert(got_main, {
            hl_group = d.hl_group,
            start = { row = mark[2], col = mark[3] },
            ["end"] = { row = d.end_row, col = d.end_col },
          })
        end
      end

      -- Main content should start after "- □ " (or "- ✔ ")
      local expected_main = {
        {
          hl_group = "CheckmateUncheckedMainContent",
          start = { row = 0, col = 2 + #unchecked + 1 },
          ["end"] = { row = 0, col = #"- " .. unchecked .. " Todo A main content" },
        },
        {
          hl_group = "CheckmateCheckedMainContent",
          start = { row = 3, col = 2 + #checked + 1 },
          ["end"] = { row = 3, col = #"- " .. checked .. " Todo B main content" },
        },
      }

      assert.equal(#expected_main, #got_main)
      assert.same(expected_main, got_main)

      -- ADDITIONAL CONTENT (subsequent lines)
      local got_additional = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if
          d
          and (d.hl_group == "CheckmateUncheckedAdditionalContent" or d.hl_group == "CheckmateCheckedAdditionalContent")
        then
          table.insert(got_additional, {
            hl_group = d.hl_group,
            start = { row = mark[2], col = mark[3] },
            ["end"] = { row = d.end_row, col = d.end_col },
          })
        end
      end

      -- additional content should start at first non-whitespace (skipping list markers)
      local expected_additional = {
        {
          hl_group = "CheckmateUncheckedAdditionalContent",
          start = { row = 1, col = 2 },
          ["end"] = { row = 1, col = #"  Additional content line 1" },
        },
        {
          hl_group = "CheckmateUncheckedAdditionalContent",
          start = { row = 2, col = 2 },
          ["end"] = { row = 2, col = #"  Additional content line 2" },
        },
        {
          hl_group = "CheckmateCheckedAdditionalContent",
          start = { row = 4, col = 4 },
          ["end"] = { row = 4, col = #"  - Regular list item" },
        },
        {
          hl_group = "CheckmateCheckedAdditionalContent",
          start = { row = 5, col = 2 },
          ["end"] = { row = 5, col = #"  More additional content" },
        },
      }

      assert.equal(#expected_additional, #got_additional)
      assert.same(expected_additional, got_additional)

      finally(function()
        h.cleanup_buffer(bufnr)
      end)
    end)
  end)

  describe("metadata", function()
    it("should apply metadata tag highlights", function()
      local config = require("checkmate.config")
      local highlights = require("checkmate.highlights")
      local unchecked = config.get_defaults().todo_markers.unchecked

      local content = [[
# Test Todo List

- ]] .. unchecked .. [[ Todo with @priority(high) metadata
]]

      local bufnr = h.create_test_buffer(content)

      highlights.apply_highlighting(bufnr, { debug_reason = "test" })

      local extmarks = h.get_extmarks(bufnr, config.ns)

      local found_metadata = false

      for _, mark in ipairs(extmarks) do
        local details = mark[4]
        if details and details.hl_group:match("^CheckmateMeta_") then
          found_metadata = true
          break
        end
      end

      assert.is_true(found_metadata)

      finally(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    end)
  end)
  describe("todo count", function()
    it("should display todo count when configured", function()
      local config = require("checkmate.config")
      local highlights = require("checkmate.highlights")
      local unchecked = config.get_defaults().todo_markers.unchecked
      local checked = config.get_defaults().todo_markers.checked

      config.options.show_todo_count = true

      local content = [[
# Test Todo List

- ]] .. unchecked .. [[ Parent todo
  - ]] .. unchecked .. [[ Child 1
  - ]] .. checked .. [[ Child 2
  - ]] .. unchecked .. [[ Child 3
]]

      local bufnr = h.create_test_buffer(content)

      highlights.apply_highlighting(bufnr, { debug_reason = "test" })

      local extmarks = h.get_extmarks(bufnr, config.ns)

      local found_count = false

      for _, mark in ipairs(extmarks) do
        local details = mark[4]
        if details and details.virt_text then
          for _, text_part in ipairs(details.virt_text) do
            -- virtual text has the expected format (1/3)
            if text_part[1]:match("%d+/%d+") then
              found_count = true
              break
            end
          end
        end
      end

      assert.is_true(found_count)

      finally(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    end)
  end)
end)
