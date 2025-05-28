describe("Util", function()
  local util = require("checkmate.util")

  --[[ describe("debugging char_to_byte_col", function()
    it("should show what vim.str_byteindex actually returns", function()
      local line = "- □ Test"

      print("\nDebugging line: '" .. line .. "'")
      print("Line byte length: " .. #line)

      -- Let's check each character position
      for char_pos = 0, 8 do
        local ok, byte_idx = pcall(vim.str_byteindex, line, "utf-8", char_pos)
        if ok then
          print(string.format("char_pos=%d -> byte_idx=%d", char_pos, byte_idx))
        else
          print(string.format("char_pos=%d -> ERROR: %s", char_pos, tostring(byte_idx)))
        end
      end

      -- Let's also check what each byte contains
      print("\nByte-by-byte breakdown:")
      for i = 1, #line do
        local byte = line:byte(i)
        print(
          string.format(
            "byte[%d] = %d (0x%02X) = '%s'",
            i - 1,
            byte,
            byte,
            byte >= 32 and byte <= 126 and string.char(byte) or "?"
          )
        )
      end

      -- Check UTF-8 encoding of □
      local box = "□"
      print("\nUTF-8 encoding of '□':")
      for i = 1, #box do
        print(string.format("  byte[%d] = %d (0x%02X)", i, box:byte(i), box:byte(i)))
      end
    end)

    it("should verify our understanding of vim.str_byteindex", function()
      -- Test with simple ASCII
      local ascii_line = "hello"
      assert.equal(0, vim.str_byteindex(ascii_line, "utf-8", 0))
      assert.equal(1, vim.str_byteindex(ascii_line, "utf-8", 1))
      assert.equal(2, vim.str_byteindex(ascii_line, "utf-8", 2))

      -- Test with Unicode
      local unicode_line = "a□b" -- 'a' at byte 0, '□' at bytes 1-3, 'b' at byte 4
      print("\nTesting line: 'a□b'")
      print("Total bytes: " .. #unicode_line)

      -- Character positions vs byte positions:
      -- char 0 ('a') -> byte 0
      -- char 1 ('□') -> byte 1
      -- char 2 ('b') -> byte 4

      local result0 = vim.str_byteindex(unicode_line, "utf-8", 0)
      local result1 = vim.str_byteindex(unicode_line, "utf-8", 1)
      local result2 = vim.str_byteindex(unicode_line, "utf-8", 2)

      print(string.format("char 0 -> byte %d (expected 0)", result0))
      print(string.format("char 1 -> byte %d (expected 1)", result1))
      print(string.format("char 2 -> byte %d (expected 4)", result2))

      assert.equal(0, result0)
      assert.equal(1, result1)
      assert.equal(4, result2)
    end)

    it("should test the actual util.char_to_byte_col function", function()
      local line = "- □ Test"

      -- Let's trace through what happens
      print("\nTracing util.char_to_byte_col for: '" .. line .. "'")

      -- Test each position
      local positions = {
        { char = 0, expected_byte = 0, desc = "start of line" },
        { char = 1, expected_byte = 1, desc = "'-' to ' '" },
        { char = 2, expected_byte = 2, desc = "' ' to '□'" },
        { char = 3, expected_byte = 5, desc = "'□' to ' '" },
        { char = 4, expected_byte = 6, desc = "' ' to 'T'" },
      }

      for _, pos in ipairs(positions) do
        local result = util.char_to_byte_col(line, pos.char)
        print(
          string.format("char_to_byte_col(%d) = %d (expected %d) -- %s", pos.char, result, pos.expected_byte, pos.desc)
        )

        -- For debugging, let's also check what vim.str_byteindex returns directly
        local ok, vim_result = pcall(vim.str_byteindex, line, "utf-8", pos.char)
        if ok then
          print(string.format("  vim.str_byteindex(%d) = %d", pos.char, vim_result))
        else
          print(string.format("  vim.str_byteindex(%d) = ERROR", pos.char))
        end
      end
    end)

    it("should test different approaches", function()
      local line = "- □ Test"

      print("\n=== Testing different Neovim APIs ===")
      print("Line: '" .. line .. "'")
      print("Byte length: " .. #line)

      -- Method 1: Using string.len vs vim.fn.strchars
      print("\nMethod 1: String length functions")
      print("string.len: " .. string.len(line))
      print("vim.fn.strchars: " .. vim.fn.strchars(line))
      print("vim.fn.strlen: " .. vim.fn.strlen(line))
      print("vim.fn.strdisplaywidth: " .. vim.fn.strdisplaywidth(line))

      -- Method 2: Testing vim.fn.byteidx
      print("\nMethod 2: vim.fn.byteidx")
      for char_idx = 0, 6 do
        local byte_idx = vim.fn.byteidx(line, char_idx)
        print(string.format("char %d -> byte %d", char_idx, byte_idx))
      end

      -- Method 3: Testing vim.fn.charidx
      print("\nMethod 3: vim.fn.charidx")
      for byte_idx = 0, 9 do
        local char_idx = vim.fn.charidx(line, byte_idx)
        print(string.format("byte %d -> char %d", byte_idx, char_idx))
      end

      -- Method 4: Let's manually verify the byte structure
      print("\nManual byte verification:")
      local i = 1
      local char_count = 0
      while i <= #line do
        local byte = string.byte(line, i)
        local char_start = i - 1 -- Convert to 0-based

        if byte < 0x80 then
          print(string.format("Char %d: ASCII '%s' at byte %d", char_count, string.sub(line, i, i), char_start))
          i = i + 1
        elseif byte >= 0xE0 and byte < 0xF0 then
          print(string.format("Char %d: 3-byte UTF-8 at bytes %d-%d", char_count, char_start, char_start + 2))
          i = i + 3
        else
          print(string.format("Char %d: Unknown at byte %d", char_count, char_start))
          i = i + 1
        end
        char_count = char_count + 1
      end
    end)
    it("should confirm nvim_buf_set_text uses byte positions", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "- □ Test" })

      -- Replace "□" (at byte 2, length 3) with "✔"
      vim.api.nvim_buf_set_text(bufnr, 0, 2, 0, 5, { "✔" })

      local result = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
      assert.equal("- ✔ Test", result)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("should confirm nvim_buf_set_extmark uses byte positions", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local ns = vim.api.nvim_create_namespace("test")
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "- □ Test" })

      -- Highlight "□" (bytes 2-5)
      local id = vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 2, {
        end_col = 5,
        hl_group = "Error",
      })

      local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, id, { details = true })
      assert.equal(2, mark[2]) -- start col
      assert.equal(5, mark[3].end_col) -- end col

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("should confirm nvim_win_get_cursor returns byte position", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "- □ Test" })

      local win = vim.api.nvim_open_win(bufnr, true, {
        relative = "editor",
        width = 20,
        height = 1,
        row = 1,
        col = 1,
        style = "minimal",
      })

      -- Set cursor after "□" (byte position 5)
      vim.api.nvim_win_set_cursor(win, { 1, 5 })
      local cursor = vim.api.nvim_win_get_cursor(win)
      assert.equal(5, cursor[2]) -- Confirms it's byte position

      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end) ]]

  describe("util conversion functions", function()
    it("should correctly convert between byte and character positions for ASCII", function()
      local line = "- [ ] Simple task"

      -- Test char_to_byte_col
      assert.equal(0, util.char_to_byte_col(line, 0)) -- Start of line
      assert.equal(2, util.char_to_byte_col(line, 2)) -- '[' character
      assert.equal(6, util.char_to_byte_col(line, 6)) -- 'S' character
      assert.equal(17, util.char_to_byte_col(line, 17)) -- End of line

      -- Test byte_to_char_col
      assert.equal(0, util.byte_to_char_col(line, 0)) -- Start of line
      assert.equal(2, util.byte_to_char_col(line, 2)) -- '[' character
      assert.equal(6, util.byte_to_char_col(line, 6)) -- 'S' character
      assert.equal(17, util.byte_to_char_col(line, 17)) -- End of line
    end)

    it("should correctly convert between byte and character positions for Unicode", function()
      -- □ is 3 bytes, ✔ is 3 bytes
      local line = "- □ Test with ✔ symbols"

      -- Test char_to_byte_col
      assert.equal(0, util.char_to_byte_col(line, 0)) -- Start of line
      assert.equal(2, util.char_to_byte_col(line, 2)) -- Start of □ (byte 2)
      assert.equal(5, util.char_to_byte_col(line, 3)) -- Space after □ (byte 5 = 2 + 3)
      assert.equal(6, util.char_to_byte_col(line, 4)) -- 'T' (byte 6)
      assert.equal(15, util.char_to_byte_col(line, 13)) -- Space before ✔ (byte 15)
      assert.equal(16, util.char_to_byte_col(line, 14)) -- Start of ✔ (byte 16)
      assert.equal(19, util.char_to_byte_col(line, 15)) -- Space after ✔ (byte 19 = 16 + 3)

      -- Test byte_to_char_col
      assert.equal(0, util.byte_to_char_col(line, 0)) -- Start of line
      assert.equal(2, util.byte_to_char_col(line, 2)) -- Start of □
      assert.equal(3, util.byte_to_char_col(line, 5)) -- Space after □
      assert.equal(4, util.byte_to_char_col(line, 6)) -- 'T'
      assert.equal(12, util.byte_to_char_col(line, 14)) -- Space before ✔
      assert.equal(13, util.byte_to_char_col(line, 15)) -- Start of ✔
      assert.equal(14, util.byte_to_char_col(line, 18)) -- Space after ✔
    end)

    it("should handle multi-byte Unicode characters correctly", function()
      -- Test with various Unicode characters of different byte lengths
      local line = "🚀 火 € → test" -- 🚀=4 bytes, 火=3 bytes, €=3 bytes, →=3 bytes

      -- Verify byte positions
      assert.equal(0, util.char_to_byte_col(line, 0)) -- Start
      assert.equal(4, util.char_to_byte_col(line, 1)) -- Space after 🚀
      assert.equal(5, util.char_to_byte_col(line, 2)) -- Start of 火
      assert.equal(8, util.char_to_byte_col(line, 3)) -- Space after 火
      assert.equal(9, util.char_to_byte_col(line, 4)) -- Start of €
      assert.equal(12, util.char_to_byte_col(line, 5)) -- Space after €
      assert.equal(13, util.char_to_byte_col(line, 6)) -- Start of →
      assert.equal(16, util.char_to_byte_col(line, 7)) -- Space after →
    end)

    it("should handle edge cases correctly", function()
      -- Empty string
      assert.equal(0, util.char_to_byte_col("", 0))
      assert.equal(0, util.byte_to_char_col("", 0))

      -- Position beyond string length
      local line = "test"
      assert.equal(4, util.char_to_byte_col(line, 10)) -- Should clamp to string length
      assert.equal(4, util.byte_to_char_col(line, 10)) -- Should clamp to string length
    end)
  end)
end)
