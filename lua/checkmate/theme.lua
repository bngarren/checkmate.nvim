-- lua/checkmate/theme.lua
local M = {}

-- Validate hex color format (#RRGGBB)
function M.is_valid_hex_color(color)
  if type(color) ~= "string" then
    return false
  end
  return color:match("^#%x%x%x%x%x%x$") ~= nil
end

-- Ensure we have a valid hex color or use a default
function M.ensure_hex_color(color, default)
  if M.is_valid_hex_color(color) then
    return color
  end
  return M.is_valid_hex_color(default) and default or "#000000"
end

-- Get primary foreground and background colors from current colorscheme
function M.get_base_colors()
  local util = require("checkmate.util")
  local colors = {}

  colors.bg = util.get_hl_color("Normal", "bg")
  colors.fg = util.get_hl_color("Normal", "fg")

  colors.is_light_bg = vim.o.background == "light"

  -- If we couldn't get colors from highlights, use fallbacks based on vim.o.background
  colors.bg = M.ensure_hex_color(colors.bg, colors.is_light_bg and "#ffffff" or "#222222")
  colors.fg = M.ensure_hex_color(colors.fg, colors.is_light_bg and "#000000" or "#eeeeee")

  -- Now that we have valid bg color, determine actual brightness
  local perceived_brightness = M.get_color_brightness(colors.bg)

  -- Override the is_light_bg setting based on actual calculated brightness
  colors.is_light_bg = perceived_brightness > 128

  return colors
end

-- Get accent colors from commonly available highlight groups
function M.get_accent_colors()
  local util = require("checkmate.util")

  -- Extract colors from commonly available highlight groups, with fallbacks
  local colors = {
    -- Warning color (oranges/yellows usually)
    diagnostic_warn = util.get_hl_color({ "DiagnosticWarn", "WarningMsg" }, "fg"),

    -- Success/OK color (greens usually)
    diagnostic_ok = util.get_hl_color({ "DiagnosticOk", "DiagnosticHint", "String" }, "fg"),

    -- Default comments (usually grays)
    comment = util.get_hl_color("Comment", "fg"),

    -- Keywords (often blues or purples)
    keyword = util.get_hl_color({ "Keyword", "Statement", "Function" }, "fg"),

    -- Special chars (often distinct purples or oranges)
    special = util.get_hl_color({ "Special", "SpecialChar", "Type" }, "fg"),
  }

  return colors
end

-- Calculate brightness of a color (0-255 scale)
-- Based on: https://www.w3.org/TR/AERT/#color-contrast
function M.get_color_brightness(hex_color)
  if not M.is_valid_hex_color(hex_color) then
    return 128 -- middle value if invalid
  end

  local r = tonumber(hex_color:sub(2, 3), 16) or 0
  local g = tonumber(hex_color:sub(4, 5), 16) or 0
  local b = tonumber(hex_color:sub(6, 7), 16) or 0

  -- Perceived brightness gives more weight to green, less to blue
  return (r * 299 + g * 587 + b * 114) / 1000
end

-- Calculate WCAG contrast ratio between two colors
-- Returns ratio between 1 and 21
function M.get_contrast_ratio(fg, bg)
  -- Relative luminance calculation
  local function get_luminance(hex)
    if not M.is_valid_hex_color(hex) then
      return 0.5 -- middle value if invalid
    end

    local r = tonumber(hex:sub(2, 3), 16) / 255
    local g = tonumber(hex:sub(4, 5), 16) / 255
    local b = tonumber(hex:sub(6, 7), 16) / 255

    -- Gamma correction
    r = r <= 0.03928 and r / 12.92 or ((r + 0.055) / 1.055) ^ 2.4
    g = g <= 0.03928 and g / 12.92 or ((g + 0.055) / 1.055) ^ 2.4
    b = b <= 0.03928 and b / 12.92 or ((b + 0.055) / 1.055) ^ 2.4

    -- Luminance formula
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  -- Get luminance values
  local lum1 = get_luminance(fg)
  local lum2 = get_luminance(bg)

  -- Ensure the lighter color is first for the division
  local lighter = math.max(lum1, lum2)
  local darker = math.min(lum1, lum2)

  -- Calculate contrast ratio
  return (lighter + 0.05) / (darker + 0.05)
end

-- Simple function to lighten or darken a color by percentage
function M.adjust_color_brightness(hex_color, percent)
  if not M.is_valid_hex_color(hex_color) then
    return hex_color
  end

  local r = tonumber(hex_color:sub(2, 3), 16) or 0
  local g = tonumber(hex_color:sub(4, 5), 16) or 0
  local b = tonumber(hex_color:sub(6, 7), 16) or 0

  if percent > 0 then
    -- Lighten
    r = math.min(255, r + (255 - r) * percent)
    g = math.min(255, g + (255 - g) * percent)
    b = math.min(255, b + (255 - b) * percent)
  else
    -- Darken
    percent = -percent
    r = math.max(0, r * (1 - percent))
    g = math.max(0, g * (1 - percent))
    b = math.max(0, b * (1 - percent))
  end

  return string.format("#%02x%02x%02x", math.floor(r), math.floor(g), math.floor(b))
end

-- Ensure a color has sufficient contrast against background
-- Returns the original color if adequate contrast, otherwise adjusts it
function M.ensure_contrast(color, bg, min_ratio)
  if not M.is_valid_hex_color(color) or not M.is_valid_hex_color(bg) then
    -- Return safe fallback
    return M.get_color_brightness(bg) > 128 and "#000000" or "#ffffff"
  end

  min_ratio = min_ratio or 4.5 -- Default to WCAG AA standard

  -- Check current contrast
  local ratio = M.get_contrast_ratio(color, bg)
  if ratio >= min_ratio then
    return color -- Already has sufficient contrast
  end

  -- Determine if we should lighten or darken based on background
  local bg_brightness = M.get_color_brightness(bg)
  local is_light_bg = bg_brightness > 128

  -- Start with a 20% adjustment and increase in steps until we reach our target
  local adjustment = is_light_bg and -0.2 or 0.2 -- Darken for light bg, lighten for dark bg
  local adjusted = color
  local attempts = 0
  local max_attempts = 5

  --   clamp attempt counter AND force larger steps the closer we are.
  while ratio < min_ratio and attempts < max_attempts do
    local step = adjustment * (1 + attempts) -- 20%, 40%, 60% ...
    adjusted = M.adjust_color_brightness(adjusted, step)
    ratio = M.get_contrast_ratio(adjusted, bg)
    attempts = attempts + 1
  end

  -- If we still don't have adequate contrast, fallback to black/white
  if ratio < min_ratio then
    return is_light_bg and "#000000" or "#ffffff"
  end

  return adjusted
end

-- Generate style defaults based on the current colorscheme
function M.generate_style_defaults()
  -- Detect "startup phase": Normal highlight missing → fg/bg = nil.
  local ok, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  if not ok or (not normal.fg and not normal.bg) then
    return {} -- nothing to work with *yet*
  end

  local util = require("checkmate.util")
  local base = M.get_base_colors()
  local accents = M.get_accent_colors()

  -- Define contrast thresholds
  local text_contrast_ratio = 4.5 -- Standard for normal text (WCAG AA)
  local ui_contrast_ratio = 3.0 -- Standard for UI elements (WCAG AA)
  local dim_contrast_ratio = 2.5 -- For less important elements like done items

  -- Ensure accent colors have adequate contrast against the background
  local colors = {}
  for k, v in pairs(accents) do
    if M.is_valid_hex_color(v) then
      colors[k] = M.ensure_contrast(v, base.bg, ui_contrast_ratio)
    end
  end

  -- Default colors if accent colors weren't available
  local default_warn = M.ensure_contrast(base.is_light_bg and "#e65100" or "#ff9500", base.bg, ui_contrast_ratio) -- orange
  local default_ok = M.ensure_contrast(base.is_light_bg and "#008800" or "#00cc66", base.bg, ui_contrast_ratio) -- green
  local default_special = M.ensure_contrast(base.is_light_bg and "#8060a0" or "#e3b3ff", base.bg, ui_contrast_ratio) -- purple

  -- Style settings for highlights
  local style = {}

  -- List markers - use different colors for ordered vs unordered
  style.list_marker_unordered = {
    fg = colors.comment or M.ensure_contrast(base.is_light_bg and "#888888" or "#aaaaaa", base.bg, ui_contrast_ratio),
  }

  style.list_marker_ordered = {
    fg = colors.keyword or M.ensure_contrast(base.is_light_bg and "#555577" or "#8888aa", base.bg, ui_contrast_ratio),
  }

  -- Unchecked todos - should be very visible
  style.unchecked_marker = {
    fg = colors.diagnostic_warn or default_warn,
    bold = true,
  }

  style.unchecked_main_content = {
    fg = base.fg, -- Use normal text color
  }

  style.unchecked_additional_content = {
    fg = colors.comment or M.ensure_contrast(util.blend(base.fg, base.bg, 0.85), base.bg, text_contrast_ratio),
  }

  -- Checked todos - should look "completed"
  style.checked_marker = {
    fg = colors.diagnostic_ok or default_ok,
    bold = true,
  }

  style.checked_main_content = {
    fg = M.ensure_contrast(util.blend(base.fg, base.bg, 0.6), base.bg, dim_contrast_ratio),
    strikethrough = true,
  }

  style.checked_additional_content = {
    fg = M.ensure_contrast(util.blend(base.fg, base.bg, 0.5), base.bg, dim_contrast_ratio),
  }

  -- For todo count indicators (e.g. "2/5" completed)
  style.todo_count_indicator = {
    fg = colors.special or default_special,
    italic = true,
  }

  return style
end

return M
