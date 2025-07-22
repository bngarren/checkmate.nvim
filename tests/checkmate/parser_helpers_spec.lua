describe("Parser Helpers", function()
  local h, ph

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
    ph = require("checkmate.parser.helpers")
  end)

  describe("create_list_item_patterns", function()
    it("should create a list item pattern for each default bullet marker with capture groups", function()
      local patterns = ph.create_list_item_patterns({ include_ordered_markers = false })

      local bullet_marker_pattern = patterns[1]

      assert.is_not_nil(bullet_marker_pattern)

      local cases = {
        {
          "- [ ] Todo A",
          0,
          "- ",
          "[ ] Todo A",
        },
        {
          "  - Regular",
          2,
          "- ",
          "Regular",
        },
        {
          "* [x] Checked",
          0,
          "* ",
          "[x] Checked",
        },
        {
          "    + This",
          4,
          "+ ",
          "This",
        },
        {
          "  -    Big space",
          2,
          "- ",
          "   Big space", -- the list marker will include 1 of the spaces and the content gets the other 3
        },
        {
          "-\nLine break",
          0,
          "-\n",
          "Line break",
        },
      }

      for _, case in ipairs(cases) do
        local indent, lm, c = case[1]:match(bullet_marker_pattern)
        assert.equal(case[2], #indent)
        assert.equal(case[3], lm)
        assert.equal(case[4], c)
      end
    end)

    it("should create a list item pattern for ordered list markers with capture groups", function()
      local patterns = ph.create_list_item_patterns({ include_ordered_markers = true })

      local ordered_marker_pattern = patterns[2]

      assert.is_not_nil(ordered_marker_pattern)

      local cases = {
        {
          "1. [ ] Todo A",
          0,
          "1. ",
          "[ ] Todo A",
        },
        {
          "  1. Regular",
          2,
          "1. ",
          "Regular",
        },
        {
          "10) [x] Checked",
          0,
          "10) ",
          "[x] Checked",
        },
        {
          "    100) This",
          4,
          "100) ",
          "This",
        },
        {
          "  3.    Big space",
          2,
          "3. ",
          "   Big space", -- the list marker will include 1 of the spaces and the content gets the other 3
        },
        {
          "1.\nLine break",
          0,
          "1.\n",
          "Line break",
        },
      }

      for _, case in ipairs(cases) do
        local indent, lm, c = case[1]:match(ordered_marker_pattern)
        assert.equal(case[2], #indent)
        assert.equal(case[3], lm)
        assert.equal(case[4], c)
      end
    end)
  end)

  describe("match list item", function()
    it("should match a list item and return capture groups", function()
      local cases = {
        {
          "- [ ] Todo",
          0,
          "-",
          " [ ] Todo",
        },
        {
          "  * [x] Another",
          2,
          "*",
          " [x] Another",
        },
        {
          "  3. Numbered",
          2,
          "3.",
          " Numbered",
        },
        {
          "    -    Big space",
          4,
          "-",
          "    Big space",
        },
        {
          "  - Trailing    ",
          2,
          "-",
          " Trailing",
        },
      }

      for _, case in ipairs(cases) do
        local li = ph.match_list_item(case[1])
        assert(li ~= nil)
        assert.equal(case[2], li.indent)
        assert.equal(case[3], li.marker)
        assert.equal(case[4], li.content)
      end
    end)

    it("should return nil when no list item matches", function()
      local cases = {
        "-No space",
        "# Not a default marker",
        "1.) Invalid num",
      }

      for _, case in ipairs(cases) do
        local li = ph.match_list_item(case)
        assert.is_nil(li)
      end
    end)

    it("should match a list item with no content", function()
      local content = "-"
      local li = ph.match_list_item(content)
      assert(li ~= nil)
      assert.equal(0, li.indent)
      assert.equal("-", li.marker)
      assert.equal("", li.content)

      content = "1."
      li = ph.match_list_item(content)
      assert(li ~= nil)
      assert.equal(0, li.indent)
      assert.equal("1.", li.marker)
      assert.equal("", li.content)
    end)
  end)

  describe("create unicode todo patterns", function()
    it("should create correct checked todo pattern without captures", function()
      local checked = h.get_checked_marker()
      local checked_patterns = ph.create_unicode_todo_patterns(checked, { with_captures = false })

      local cases = {
        {
          "- " .. checked .. " Todo A",
          true,
        },
        {
          "  1. " .. checked .. " Todo B",
          true,
        },
        {
          "*" .. checked .. " Missing space 1",
          false,
        },
        {
          "* " .. checked .. "Missing space 2",
          false,
        },
        {
          "- ⅹ Not the marker",
          false,
        },
      }

      for _, case in ipairs(cases) do
        local result = ph.match_first(checked_patterns, case[1])
        assert.equal(case[2], result.matched)
      end
    end)

    it("should create correct checked todo pattern with captures", function()
      local checked = h.get_checked_marker()
      local checked_patterns = ph.create_unicode_todo_patterns(checked, { with_captures = true })

      local cases = {
        {
          "- " .. checked .. " Todo A",
          "- ",
          " Todo A",
        },
        {
          "  1. " .. checked .. " Todo B",
          "  1. ",
          " Todo B",
        },
        {
          "    - " .. checked .. "    Big space",
          "    - ",
          "    Big space",
        },
      }

      for _, case in ipairs(cases) do
        local result = ph.match_first(checked_patterns, case[1])
        assert.equal(true, result.matched)
        assert.equal(case[2], result.captures[1])
        assert.equal(checked, result.captures[2])
        assert.equal(case[3], result.captures[3])
      end
    end)

    it("should create correct unchecked todo pattern with captures", function()
      local unchecked = h.get_unchecked_marker()
      local unchecked_patterns = ph.create_unicode_todo_patterns(unchecked, { with_captures = true })

      local cases = {
        {
          "- " .. unchecked .. " Todo A",
          "- ",
          " Todo A",
        },
        {
          "  1. " .. unchecked .. " Todo B",
          "  1. ",
          " Todo B",
        },
      }

      for _, case in ipairs(cases) do
        local result = ph.match_first(unchecked_patterns, case[1])
        assert.equal(true, result.matched)
        assert.equal(case[2], result.captures[1])
        assert.equal(unchecked, result.captures[2])
        assert.equal(case[3], result.captures[3])
      end
    end)

    it("should create correct checked todo pattern without captures", function()
      local checked = h.get_checked_marker()
      local checked_patterns = ph.create_unicode_todo_patterns(checked, { with_captures = false })

      local cases = {
        {
          "- " .. checked .. " Todo A",
          true,
        },
        {
          "  1. " .. checked .. " Todo B",
          true,
        },
        {
          "*" .. checked .. " Missing space 1",
          false,
        },
        {
          "* " .. checked .. "Missing space 2",
          false,
        },
        {
          "- ⅹ Not the marker",
          false,
        },
      }

      for _, case in ipairs(cases) do
        local result = ph.match_first(checked_patterns, case[1])
        assert.equal(case[2], result.matched)
      end
    end)

    it("should create correct unchecked todo pattern without captures", function()
      local unchecked = h.get_unchecked_marker()
      local unchecked_patterns = ph.create_unicode_todo_patterns(unchecked, { with_captures = false })

      local cases = {
        {
          "- " .. unchecked .. " Todo A",
          true,
        },
        {
          "  1. " .. unchecked .. " Todo B",
          true,
        },
        {
          "*" .. unchecked .. " Missing space 1",
          false,
        },
        {
          "* " .. unchecked .. "Missing space 2",
          false,
        },
        {
          "- ⅹ Not the marker",
          false,
        },
      }

      for _, case in ipairs(cases) do
        local result = ph.match_first(unchecked_patterns, case[1])
        assert.equal(case[2], result.matched)
      end
    end)

    it("should match unicode todo patterns with empty content", function()
      local checked = h.get_checked_marker()
      local patterns = ph.create_unicode_todo_patterns(checked, { with_captures = true })

      local line = "- " .. checked
      local result = ph.match_first(patterns, line)

      assert.is_true(result.matched)
      assert.equal("- ", result.captures[1])
      assert.equal(checked, result.captures[2])
      assert.equal("", result.captures[3] or "")
    end)
  end)

  describe("create markdown checkbox patterns", function()
    -- the "variants" are described in parser.convert_markdown_to_unicode() but, briefly, are used
    -- to match a checkbox at EOL like - [ ], as well as ensure a space after the checkbox when it isn't EOL
    it("should create unchecked checkbox with both variants", function()
      local unchecked_box = ph.create_markdown_checkbox_patterns(" ")

      local cases = {
        {
          "- [ ] Todo", -- line
          0, -- indent
          "- ", -- list marker capture (includes 1st whitespace)
          "[ ]", -- checkbox capture
        },
        {
          "1. [ ] Todo",
          0,
          "1. ",
          "[ ]",
        },
        {
          "  - [ ] Todo",
          2,
          "- ",
          "[ ]",
        },
        {
          "    1) [ ] Todo",
          4,
          "1) ",
          "[ ]",
        },
        {
          "- [ ]", -- at EOL
          0,
          "- ",
          "[ ]",
        },
        {
          "1. [ ]", -- at EOL
          0,
          "1. ",
          "[ ]",
        },
      }

      for _, case in ipairs(cases) do
        local result = ph.match_first(unchecked_box, case[1])
        assert.is_true(result.matched)
        assert.equal(case[2], #result.captures[1])
        assert.equal(case[3], result.captures[2])
        assert.equal(case[4], result.captures[3])
      end

      local result = ph.match_first(unchecked_box, "- [ ]No space")
      assert.is_not_true(result.matched)
    end)

    it("should create checked checkbox with both variants", function()
      local checked_box = ph.create_markdown_checkbox_patterns({ "x", "X" })

      local cases = {
        {
          "- [x] Todo", -- line
          0, -- indent
          "- ", -- list marker capture (includes 1st whitespace)
          "[x]", -- checkbox capture
        },
        {
          "1. [x] Todo",
          0,
          "1. ",
          "[x]",
        },
        {
          "  - [x] Todo",
          2,
          "- ",
          "[x]",
        },
        {
          "    1) [x] Todo",
          4,
          "1) ",
          "[x]",
        },
        {
          "- [x]", -- at EOL
          0,
          "- ",
          "[x]",
        },
        {
          "1. [x]",
          0,
          "1. ",
          "[x]",
        },
        {
          "- [X] Todo", --uppercase
          0,
          "- ",
          "[X]",
        },
      }

      for _, case in ipairs(cases) do
        local result = ph.match_first(checked_box, case[1])
        assert.is_true(result.matched)
        assert.equal(case[2], #result.captures[1])
        assert.equal(case[3], result.captures[2])
        assert.equal(case[4], result.captures[3])
      end

      local result = ph.match_first(checked_box, "- [X]No space")
      assert.is_not_true(result.matched)
    end)
  end)
end)
