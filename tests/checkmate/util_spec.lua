describe("Util", function()
  local util = require("checkmate.util")

  it("should determine end of line", function()
    -- including whitespace
    local cases = {
      { line = "test", col = 3, expected = true },
      { line = "trailing  ", col = 9, expected = true },
      { line = "trailing  ", col = 7, expected = false },
      { line = "  pre", col = 4, expected = true },
    }
    for _, case in ipairs(cases) do
      assert.equal(
        case.expected,
        util.string.is_end_of_line(case.line, case.col), -- default is to include whitespace if not `opts.include_whitespace` passed
        string.format("'%s' end at col %d? %s", case.line, case.col, case.expected)
      )
    end

    -- ignoring whitespace
    cases = {
      { line = "test", col = 3, expected = true },
      { line = "trailing  ", col = 9, expected = false },
      { line = "trailing  ", col = 7, expected = true },
      { line = "  pre", col = 4, expected = true },
    }
    for _, case in ipairs(cases) do
      assert.equal(
        case.expected,
        util.string.is_end_of_line(case.line, case.col, { include_whitespace = false }),
        string.format("'%s' end at col %d? %s", case.line, case.col, case.expected)
      )
    end
  end)

  describe("string operations", function()
    it("should convert snake case to camel case", function()
      assert.equal("HelloWorld", util.string.snake_to_camel("hello_world"))
      assert.equal("ThisIsATest", util.string.snake_to_camel("this_is_a_test"))
      assert.equal("ABC", util.string.snake_to_camel("a_b_c"))
      assert.equal("SnakeCASEInput", util.string.snake_to_camel("snake_CASE_input"))

      -- preserves existing capitalization
      assert.equal("AlreadyCamel", util.string.snake_to_camel("alreadyCamel"))
      assert.equal("MixedUPAndDown", util.string.snake_to_camel("mixed_UP_and_down"))

      -- numbers pass through
      assert.equal("User123Name", util.string.snake_to_camel("user_123_name"))
      assert.equal("GetHttp2Response", util.string.snake_to_camel("get_http2_response"))

      -- edge‐cases
      assert.equal("", util.string.snake_to_camel(""))
      assert.equal("PrivateVariable", util.string.snake_to_camel("_private_variable"))
      assert.equal("Trailing_", util.string.snake_to_camel("trailing_"))
    end)

    it("should get next ordered marker", function()
      assert.equal("2.", util.string.get_next_ordered_marker("1. [ ] A"))
      assert.equal("11.", util.string.get_next_ordered_marker("10. [ ] B"))
      assert.equal("50)", util.string.get_next_ordered_marker("49) [ ] C"))
      assert.equal("2)", util.string.get_next_ordered_marker("  1) [ ] D"))
      assert.equal(nil, util.string.get_next_ordered_marker("- [ ] E"))
    end)
  end)
end)
