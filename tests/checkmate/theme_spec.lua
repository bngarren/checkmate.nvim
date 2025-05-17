--[[
  Unit‑test the calculations and logic in **lua/checkmate/theme.lua**.  These helpers
  do pure color maths (hex‑string validation, relative luminance, brightness
  estimation, WCAG contrast ratio, brightness adjustment and auto‑contrast).

  Why?
  -----------
  *  Plugin users rely on us to generate reasonable and accessible default highlight groups.
  *  Color math is easy to get subtly wrong (gamma/linear mistakes, channel
     order, rounding).  
--]]
describe("Theme", function()
  local theme = require("checkmate.theme")

  before_each(function()
    _G.reset_state()
  end)

  describe("is_valid_hex_color", function()
    it("should accept full 6‑digit hex colors", function()
      assert.is_true(theme.is_valid_hex_color("#ffffff"))
      assert.is_true(theme.is_valid_hex_color("#000000"))
      assert.is_true(theme.is_valid_hex_color("#1a2b3c"))
    end)

    it("should reject malformed or non‑string inputs", function()
      local invalid = { "fff", "#fff", "#gg0000", "123456", 42, nil, {}, function() end }
      for _, value in ipairs(invalid) do
        assert.is_false(theme.is_valid_hex_color(value))
      end
    end)
  end)

  describe("ensure_hex_color", function()
    it("returns the input when it is valid", function()
      assert.equal("#ab12cd", theme.ensure_hex_color("#ab12cd", "#000000"))
    end)

    it("falls back to the provided default when input is invalid", function()
      assert.equal("#ff00ff", theme.ensure_hex_color("not‑a‑color", "#ff00ff"))
    end)

    it("falls back to black when both input and default are invalid", function()
      assert.equal("#000000", theme.ensure_hex_color("foo", "bar"))
    end)
  end)

  describe("get_color_brightness", function()
    it("computes higher brightness for lighter colors", function()
      local white = theme.get_color_brightness("#ffffff")
      local black = theme.get_color_brightness("#000000")
      assert.is_true(white > black)
      assert.is_true(white >= 250) -- near maximum 255
      assert.is_true(black <= 5) -- near minimum 0
    end)

    it("returns mid‑range value for invalid input", function()
      -- Default 128 prevents callers from dividing by zero or creating extremes
      -- when fed garbage
      assert.equal(128, theme.get_color_brightness("not‑hex"))
    end)
  end)

  describe("get_contrast_ratio", function()
    it("returns ~21 for white on black (WCAG maximum)", function()
      local ratio = theme.get_contrast_ratio("#ffffff", "#000000")
      assert.is_true(math.abs(ratio - 21) < 0.1)
    end)

    it("returns 1 when foreground equals background", function()
      local ratio = theme.get_contrast_ratio("#333333", "#333333")
      assert.is_true(math.abs(ratio - 1) < 0.01)
    end)
  end)

  -- Cross‑check against authoritative examples calculated with the WCAG 2.1
  -- formula (sRGB → linear → (L1+0.05)/(L2+0.05)).
  describe("get_contrast_ratio (golden values)", function()
    -- Each triple: { fg, bg, expected_ratio }
    local samples = {
      { "#000000", "#ffffff", 21.0 },
      { "#ff0000", "#00ff00", 2.91 },
      { "#0000ff", "#ffff00", 8.00 },
      { "#444444", "#ffffff", 9.74 },
      { "#666666", "#ffffff", 5.74 },
    }

    for _, s in ipairs(samples) do
      it(string.format("%s on %s ≈ %.2f", s[1], s[2], s[3]), function()
        local ratio = theme.get_contrast_ratio(s[1], s[2])
        assert.is_true(math.abs(ratio - s[3]) < 0.02)
      end)
    end
  end)

  describe("adjust_color_brightness", function()
    it("lightens and darkens colors as expected", function()
      local base = "#808080"
      local lighter = theme.adjust_color_brightness(base, 0.3) -- +30 %
      local darker = theme.adjust_color_brightness(base, -0.3) -- −30 %
      assert.is_true(theme.get_color_brightness(lighter) > theme.get_color_brightness(base))
      assert.is_true(theme.get_color_brightness(darker) < theme.get_color_brightness(base))
    end)

    it("returns the original string when given an invalid color", function()
      assert.equal("oops", theme.adjust_color_brightness("oops", 0.5))
    end)
  end)

  describe("ensure_contrast", function()
    it("returns a color that meets the requested contrast", function()
      local bg = "#6a6a6a" -- medium gray
      local low_contrast = "#666666" -- too close to bg
      assert.is_true(theme.get_contrast_ratio(low_contrast, bg) < 4.5)
      local ensured = theme.ensure_contrast(low_contrast, bg, 4.5)
      local ratio = theme.get_contrast_ratio(ensured, bg)
      assert.is_true(ratio >= 4.5)
    end)

    it("falls back to black/white when given invalid inputs", function()
      assert.equal("#000000", theme.ensure_contrast("bad", "#ffffff", 4.5))
      assert.equal("#ffffff", theme.ensure_contrast("bad", "#000000", 4.5))
    end)
  end)
end)
