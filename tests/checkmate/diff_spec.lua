local diff = require("checkmate.lib.diff")

describe("Diff", function()
  local bufnr

  local function create_buffer(lines)
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
  end

  local function get_buffer_lines()
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  local function get_line(row)
    local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
    return lines[1] or ""
  end

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  describe("make_line_replace", function()
    it("should replace a single line", function()
      create_buffer({ "line 1", "line 2", "line 3" })

      local hunk = diff.make_line_replace(1, "replaced line")
      hunk:apply(bufnr)

      assert.are.same({ "line 1", "replaced line", "line 3" }, get_buffer_lines())
    end)

    it("should replace multiple lines", function()
      create_buffer({ "line 1", "line 2", "line 3", "line 4" })

      local hunk = diff.make_line_replace({ 1, 2 }, { "new line 2", "new line 3" })
      hunk:apply(bufnr)

      assert.are.same({ "line 1", "new line 2", "new line 3", "line 4" }, get_buffer_lines())
    end)

    it("should handle string input with newlines", function()
      create_buffer({ "line 1", "old", "line 3" })

      local hunk = diff.make_line_replace(1, "multi\nline\ntext")
      hunk:apply(bufnr)

      assert.are.same({ "line 1", "multi", "line", "text", "line 3" }, get_buffer_lines())
    end)

    it("should delete lines when text is nil", function()
      create_buffer({ "line 1", "to delete", "line 3" })

      local hunk = diff.make_line_replace(1, nil)
      hunk:apply(bufnr)

      assert.are.same({ "line 1", "line 3" }, get_buffer_lines())
    end)

    it("replaces last line in buffer", function()
      create_buffer({ "first", "middle", "last" })

      local hunk = diff.make_line_replace(2, "new last")
      hunk:apply(bufnr)

      assert.are.same({ "first", "middle", "new last" }, get_buffer_lines())
    end)

    it("replaces first line in buffer", function()
      create_buffer({ "first", "second" })

      local hunk = diff.make_line_replace(0, "new first")
      hunk:apply(bufnr)

      assert.are.same({ "new first", "second" }, get_buffer_lines())
    end)
  end)

  describe("make_line_insert", function()
    it("should insert a single line", function()
      create_buffer({ "line 1", "line 2" })

      local hunk = diff.make_line_insert(1, "inserted")
      hunk:apply(bufnr)

      assert.are.same({ "line 1", "inserted", "line 2" }, get_buffer_lines())
    end)

    it("should insert multiple lines", function()
      create_buffer({ "first", "last" })

      local hunk = diff.make_line_insert(1, { "new 1", "new 2", "new 3" })
      hunk:apply(bufnr)

      assert.are.same({ "first", "new 1", "new 2", "new 3", "last" }, get_buffer_lines())
    end)

    it("should insert at beginning of buffer", function()
      create_buffer({ "existing" })

      local hunk = diff.make_line_insert(0, "first line")
      hunk:apply(bufnr)

      assert.are.same({ "first line", "existing" }, get_buffer_lines())
    end)

    it("should insert at end of buffer", function()
      create_buffer({ "existing" })

      local hunk = diff.make_line_insert(1, "last line")
      hunk:apply(bufnr)

      assert.are.same({ "existing", "last line" }, get_buffer_lines())
    end)
  end)

  describe("make_line_delete", function()
    it("should delete a single line", function()
      create_buffer({ "line 1", "line 2", "line 3" })

      local hunk = diff.make_line_delete(1)
      hunk:apply(bufnr)

      assert.are.same({ "line 1", "line 3" }, get_buffer_lines())
    end)

    it("should delete multiple lines", function()
      create_buffer({ "keep", "delete 1", "delete 2", "keep" })

      local hunk = diff.make_line_delete({ 1, 2 })
      hunk:apply(bufnr)

      assert.are.same({ "keep", "keep" }, get_buffer_lines())
    end)

    it("should delete all lines", function()
      create_buffer({ "line 1", "line 2" })

      local hunk = diff.make_line_delete({ 0, 1 })
      hunk:apply(bufnr)

      assert.are.same({ "" }, get_buffer_lines())
    end)
  end)

  describe("make_text_replace", function()
    it("should replace text within a line", function()
      create_buffer({ "hello world" })
      -- "hello world" positions: h=0, e=1, l=2, l=3, o=4, space=5, w=6, o=7, r=8, l=9, d=10

      -- end exclusive
      local hunk = diff.make_text_replace(0, 6, 11, "neovim")
      hunk:apply(bufnr)

      assert.equal("hello neovim", get_line(0))
    end)

    it("should replace at beginning of line", function()
      create_buffer({ "old text here" })

      local hunk = diff.make_text_replace(0, 0, 3, "new")
      hunk:apply(bufnr)

      assert.equal("new text here", get_line(0))
    end)

    it("should replace at end of line", function()
      create_buffer({ "keep this old" })
      -- positions: k=0, e=1, e=2, p=3, space=4, t=5, h=6, i=7, s=8, space=9, o=10, l=11, d=12

      -- replace "old" (positions 10-12)
      local hunk = diff.make_text_replace(0, 10, 13, "new")
      hunk:apply(bufnr)

      assert.equal("keep this new", get_line(0))
    end)

    it("should replace entire line content", function()
      create_buffer({ "completely replace me" })

      -- length of "completely replace me" is 21
      local hunk = diff.make_text_replace(0, 0, 21, "brand new")
      hunk:apply(bufnr)

      assert.equal("brand new", get_line(0))
    end)

    it("should handle empty replacement (deletion)", function()
      create_buffer({ "remove middle part" })

      local hunk = diff.make_text_replace(0, 7, 14, "") -- remove "middle " (positions 7-13)
      hunk:apply(bufnr)

      assert.equal("remove part", get_line(0))
    end)
  end)

  describe("make_text_insert", function()
    it("should insert text at position", function()
      create_buffer({ "hello world" })

      local hunk = diff.make_text_insert(0, 5, " beautiful")
      hunk:apply(bufnr)

      assert.equal("hello beautiful world", get_line(0))
    end)

    it("should insert at beginning of line", function()
      create_buffer({ "world" })

      local hunk = diff.make_text_insert(0, 0, "hello ")
      hunk:apply(bufnr)

      assert.equal("hello world", get_line(0))
    end)

    it("should insert at end of line", function()
      create_buffer({ "hello" })

      local hunk = diff.make_text_insert(0, 5, " world")
      hunk:apply(bufnr)

      assert.equal("hello world", get_line(0))
    end)

    it("should handle empty lines", function()
      create_buffer({ "" })

      local hunk = diff.make_text_insert(0, 0, "content")
      hunk:apply(bufnr)

      assert.equal("content", get_line(0))
    end)

    it("should insert at exact positions", function()
      create_buffer({ "abc" })

      -- at position 1 (between 'a' and 'b')
      local hunk = diff.make_text_insert(0, 1, "X")
      hunk:apply(bufnr)

      assert.equal("aXbc", get_line(0))
    end)
  end)

  describe("make_text_delete", function()
    it("should delete text within a line", function()
      create_buffer({ "hello beautiful world" })
      -- positions: h=0, e=1, l=2, l=3, o=4, space=5, b=6...

      -- delete " beautiful" (positions 5-14)
      local hunk = diff.make_text_delete(0, 5, 15)
      hunk:apply(bufnr)

      assert.equal("hello world", get_line(0))
    end)

    it("should delete from beginning", function()
      create_buffer({ "remove this keep this" })

      -- delete "remove this " (positions 0-11)
      local hunk = diff.make_text_delete(0, 0, 12)
      hunk:apply(bufnr)

      assert.equal("keep this", get_line(0))
    end)

    it("should delete to end", function()
      create_buffer({ "keep this remove this" })

      local hunk = diff.make_text_delete(0, 9, 21)
      hunk:apply(bufnr)

      assert.equal("keep this", get_line(0))
    end)

    it("should delete entire line content", function()
      create_buffer({ "delete all" })

      local hunk = diff.make_text_delete(0, 0, 10)
      hunk:apply(bufnr)

      assert.equal("", get_line(0))
    end)

    it("handles single character deletion", function()
      create_buffer({ "test" })

      -- delete character at position 1 ('e')
      local hunk = diff.make_text_delete(0, 1, 2)
      hunk:apply(bufnr)

      assert.equal("tst", get_line(0))
    end)
  end)

  describe("make_line_append", function()
    it("should append text to end of line", function()
      create_buffer({ "hello" })

      local hunk = diff.make_line_append(0, " world", bufnr)
      hunk:apply(bufnr)

      assert.equal("hello world", get_line(0))
    end)

    it("should append to empty line", function()
      create_buffer({ "" })

      local hunk = diff.make_line_append(0, "content", bufnr)
      hunk:apply(bufnr)

      assert.equal("content", get_line(0))
    end)

    it("should handle lines with trailing spaces", function()
      create_buffer({ "text   " })

      local hunk = diff.make_line_append(0, "more", bufnr)
      hunk:apply(bufnr)

      assert.equal("text   more", get_line(0))
    end)
  end)

  describe("make_marker_replace", function()
    it("should replace a todo marker", function()
      create_buffer({ "- [ ] todo item" })

      local todo_item = {
        todo_marker = {
          position = { row = 0, col = 2 },
          text = "[ ]",
        },
      }

      local hunk = diff.make_marker_replace(todo_item, "[x]")
      hunk:apply(bufnr)

      assert.equal("- [x] todo item", get_line(0))
    end)

    it("should handle unicode markers", function()
      create_buffer({ "- □ todo item" })

      local todo_item = {
        todo_marker = {
          position = { row = 0, col = 2 },
          text = "□",
        },
      }

      local hunk = diff.make_marker_replace(todo_item, "✔")
      hunk:apply(bufnr)

      assert.equal("- ✔ todo item", get_line(0))
    end)
  end)

  describe("apply_diff", function()
    it("applies multiple hunks in correct order", function()
      create_buffer({ "line 1", "line 2", "line 3" })

      local hunks = {
        diff.make_text_insert(0, 6, " modified"), -- insert at end of line 1
        diff.make_line_delete(2), -- delete line 3
        diff.make_text_replace(1, 0, 4, "LINE"), -- replace "line" with "LINE" in line 2
      }

      diff.apply_diff(bufnr, hunks)

      assert.are.same({ "line 1 modified", "LINE 2" }, get_buffer_lines())
    end)

    it("should handle empty hunk array", function()
      create_buffer({ "unchanged" })

      diff.apply_diff(bufnr, {})

      assert.are.same({ "unchanged" }, get_buffer_lines())
    end)

    it("should filter out empty hunks", function()
      create_buffer({ "line 1", "line 2" })

      local hunks = {
        diff.make_text_delete(0, 5, 5), -- empty delete (no-op)
        diff.make_text_insert(0, 6, " modified"), -- valid insert
      }

      diff.apply_diff(bufnr, hunks)

      assert.equal("line 1 modified", get_line(0))
    end)

    it("joins all operations in single undo", function()
      create_buffer({ "original" })

      local hunks = {
        diff.make_text_insert(0, 8, " text"),
        diff.make_text_insert(0, 0, "modified "),
      }

      vim.api.nvim_buf_call(bufnr, function()
        -- need this to ensure the test has an undoblock (keeps an undo history)
        vim.bo.undolevels = 1000

        diff.apply_diff(bufnr, hunks)
        assert.equal("modified original text", get_line(0))

        -- single undo should revert all changes
        vim.cmd("silent! undo")
        assert.equal("original", get_line(0))
      end)
    end)
  end)

  describe("misc", function()
    it("should preserve extmarks outside modified ranges", function()
      create_buffer({ "hello world" })

      local ns = vim.api.nvim_create_namespace("test")
      local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 6, {})

      -- modify text before the extmark
      local hunk = diff.make_text_replace(0, 0, 5, "hi")
      hunk:apply(bufnr)

      -- extmark should have moved
      local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark_id, {})
      assert.equal(0, mark[1]) -- still on row 0
      assert.equal(3, mark[2]) -- but column shifted from 6 to 3
    end)

    it("should handle multi-byte UTF-8 characters correctly", function()
      create_buffer({ "hello 世界" }) -- "世界" are 3-byte UTF-8 characters

      -- byte positions: h=0, e=1, l=2, l=3, o=4, space=5, 世=6-8, 界=9-11
      local hunk = diff.make_text_replace(0, 6, 12, "world")
      hunk:apply(bufnr)

      assert.equal("hello world", get_line(0))
    end)
  end)
end)
