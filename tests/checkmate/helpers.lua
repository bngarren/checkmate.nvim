local M = {}

-- Create a temporary file for testing
function M.create_temp_file()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local file_path = temp_dir .. "/test.todo"
  return file_path
end

-- Read file contents directly (not via Neovim buffer)
function M.read_file_content(file_path)
  local f = io.open(file_path, "r")
  if not f then
    return nil
  end
  local content = f:read("*all")
  f:close()
  return content
end

-- Write content to file directly
function M.write_file_content(file_path, content)
  local f = io.open(file_path, "w")
  if not f then
    return false
  end
  f:write(content)
  f:close()
  return true
end

-- Helper function to create a test buffer with todo content
function M.create_test_buffer(content)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content, "\n"))
  vim.bo[bufnr].filetype = "markdown"
  return bufnr
end

function M.get_extmarks(bufnr, ns)
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

function M.ensure_normal_mode()
  local mode = vim.fn.mode()
  if mode ~= "n" then
    -- Exit any mode back to normal mode
    vim.cmd([[noautocmd normal! <Esc>]])
    vim.cmd("stopinsert")
    vim.cmd("redraw")
  end
end

return M
