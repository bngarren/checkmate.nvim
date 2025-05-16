local M = {}

-- Get base foreground and background colors from the current colorscheme
function M.get_base_colors()
  local util = require("checkmate.util")

  -- Get base colors from Normal highlight group
  local bg = util.get_hl_color("Normal", "bg", "#222222")
  local fg = util.get_hl_color("Normal", "fg", "#eeeeee")

  -- Determine if we have a light or dark color scheme
  local is_light_bg = false
  if bg then
    -- Simple brightness calculation - if R+G+B components > 384 (average 128 per channel), consider it light
    local r = tonumber(bg:sub(2, 3), 16) or 0
    local g = tonumber(bg:sub(4, 5), 16) or 0
    local b = tonumber(bg:sub(6, 7), 16) or 0
    is_light_bg = (r + g + b) > 384
  else
    -- If we couldn't get bg color, use vim's background setting
    is_light_bg = vim.o.background == "light"
  end

  return {
    bg = bg,
    fg = fg,
    is_light_bg = is_light_bg,
  }
end

-- Get accent colors from common highlight groups
function M.get_accent_colors()
  local util = require("checkmate.util")

  -- Extract colors from commonly available highlight groups
  local colors = {
    diagnostic_warn = util.get_hl_color({ "DiagnosticWarn" }, "fg"),
    diagnostic_ok = util.get_hl_color({ "DiagnosticOk" }, "fg"),
    comment = util.get_hl_color("Comment", "fg"),
    keyword = util.get_hl_color({ "Keyword", "Statement" }, "fg"),
    special = util.get_hl_color({ "Special", "SpecialChar" }, "fg"),
  }

  return colors
end

-- Generate sensible style defaults based on the current colorscheme
function M.generate_style_defaults()
  local util = require("checkmate.util")
  local base = M.get_base_colors()
  local accents = M.get_accent_colors()

  local style = {}

  -- Choose defaults based on light vs dark background
  if base.is_light_bg then
    -- Light theme defaults

    -- Use base colors to derive muted variants
    style.list_marker_unordered = {
      fg = util.blend(base.fg, base.bg, 0.5), -- 50% between fg and bg
    }

    style.list_marker_ordered = {
      fg = util.blend(base.fg, base.bg, 0.6), -- 60% between fg and bg
    }

    -- Use accent colors if available, fallback to sensible defaults
    style.unchecked_marker = {
      fg = accents.diagnostic_warn or "#ff9500",
      bold = true,
    }

    style.unchecked_main_content = {
      fg = base.fg,
    }

    style.unchecked_additional_content = {
      fg = util.blend(base.fg, base.bg, 0.9),
    }

    style.checked_marker = {
      fg = accents.diagnostic_ok or "#00cc66",
      bold = true,
    }

    style.checked_main_content = {
      fg = util.blend(base.fg, base.bg, 0.5),
      strikethrough = true,
    }

    style.checked_additional_content = {
      fg = util.blend(base.fg, base.bg, 0.5),
    }

    style.todo_count_indicator = {
      fg = accents.special or "#8060a0",
      italic = true,
    }
  else
    -- Dark theme defaults

    style.list_marker_unordered = {
      fg = util.blend(base.fg, base.bg, 0.3), -- 30% between fg and bg
    }

    style.list_marker_ordered = {
      fg = util.blend(base.fg, base.bg, 0.4), -- 40% between fg and bg
    }

    style.unchecked_marker = {
      fg = accents.diagnostic_warn or "#ff9500",
      bold = true,
    }

    style.unchecked_main_content = {
      fg = base.fg,
    }

    style.unchecked_additional_content = {
      fg = util.blend(base.fg, base.bg, 0.9),
    }

    style.checked_marker = {
      fg = accents.diagnostic_ok or "#00cc66",
      bold = true,
    }

    style.checked_main_content = {
      fg = util.blend(base.fg, base.bg, 0.6),
      strikethrough = true,
    }

    style.checked_additional_content = {
      fg = util.blend(base.fg, base.bg, 0.4),
    }

    style.todo_count_indicator = {
      fg = accents.special or "#e3b3ff",
      bg = util.blend(base.fg, base.bg, 0.1),
      italic = true,
    }
  end

  return style
end

return M
