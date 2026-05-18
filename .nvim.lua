local group = vim.api.nvim_create_augroup("ProjectLuaFolds", { clear = true })

local function close_lua_folds(args)
  if vim.bo[args.buf].filetype ~= "lua" then
    return
  end

  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(args.buf) then
      vim.cmd("normal! zM")
    end
  end, 10)
end

vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = "lua",
  callback = close_lua_folds,
})

vim.api.nvim_create_autocmd("BufWinEnter", {
  group = group,
  pattern = "*.lua",
  callback = close_lua_folds,
})
