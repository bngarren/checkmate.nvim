-- File pattern matching module
-- Handles glob pattern matching for buffer activation

local log = require("checkmate.log")

local M = {}

local api = vim.api
local fn = vim.fn
local split = vim.split
local concat = table.concat

---normalize path separators to forward slashes and expand home dir
---@param path string
---@return string
local function normalize_path(path)
  return vim.fs.normalize(path, { win = true })
end

local function matches_vim_regex(str, vim_regex)
  return fn.match(str, vim_regex) ~= -1
end

---pattern is a path pattern (contains forward slash)
---remember to normalize it first
local function is_path_pattern(pattern)
  return pattern:find("/", 1, true) ~= nil
end

local function is_absolute_pattern(pattern)
  return pattern:sub(1, 1) == "/"
end

local function is_recursive_pattern(pattern)
  return pattern:sub(1, 3) == "**/"
end

---try to match pattern against all suffixes of a path
---
---allows a relative path pattern (like subdir/*.md) to match a file anywhere in the directory tree,
---as long as the file's path ends with a matching suffix
local function match_path_suffixes(path, vim_regex)
  local parts = split(path, "/", { plain = true })

  -- so i don't forget later with my goldfish brain:
  -- Example:
  -- i=1: suffix = "/home/user/projects/myapp/subdir/notes.md"  -- full path
  -- i=2: suffix = "home/user/projects/myapp/subdir/notes.md"
  -- i=3: suffix = "user/projects/myapp/subdir/notes.md"
  -- i=4: suffix = "projects/myapp/subdir/notes.md"
  -- i=5: suffix = "myapp/subdir/notes.md"
  -- i=6: suffix = "subdir/notes.md"                            -- found a match!
  for i = 1, #parts do
    local suffix = concat(parts, "/", i, #parts)
    if matches_vim_regex(suffix, vim_regex) then
      return true
    end
  end

  return false
end

---check if a given pattern matches the given filename
---@param filename string the normalized full path of the file
---@param pattern string the glob pattern to match
---@return boolean
local function pattern_matches(filename, pattern)
  if type(pattern) ~= "string" or pattern == "" then
    return false
  end

  pattern = normalize_path(pattern)

  -- convert glob to vim regex
  local vim_regex = fn.glob2regpat(pattern)

  if is_path_pattern(pattern) then
    -- try direct full-path match
    if matches_vim_regex(filename, vim_regex) then
      return true
    end

    -- for relative path patterns (not starting with / or **/),
    -- also try matching against path suffixes
    if not is_absolute_pattern(pattern) and not is_recursive_pattern(pattern) then
      return match_path_suffixes(filename, vim_regex)
    end
  else
    -- no slash in pattern - match against basename only
    local basename = fn.fnamemodify(filename, ":t")
    return matches_vim_regex(basename, vim_regex)
  end

  return false
end

---check if buffer should be activated based on patterns
---@param bufnr number|nil
---@param patterns table|nil array of glob patterns
---@return boolean
function M.should_activate_for_buffer(bufnr, patterns)
  bufnr = bufnr or api.nvim_get_current_buf()

  if not api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if vim.bo[bufnr].filetype ~= "markdown" then
    return false
  end

  if type(patterns) ~= "table" or vim.tbl_isempty(patterns) then
    return false
  end

  local filename = api.nvim_buf_get_name(bufnr)
  if not filename or filename == "" then
    return false
  end

  filename = normalize_path(filename)

  for _, pattern in ipairs(patterns) do
    if pattern_matches(filename, pattern) then
      return true
    end
  end

  log.fmt_debug("Checkmate not activated for bufnr %d.\n'%s' does not match any pattern: %s", bufnr, filename, patterns)

  return false
end

return M
