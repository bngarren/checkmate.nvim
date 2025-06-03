describe("Util", function()
  local util = require("checkmate.util")

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
