if vim.g.loaded_checkmate_plugin == 1 then
  return
end
vim.g.loaded_checkmate_plugin = 1

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("checkmate_ft", { clear = false }),
  pattern = "markdown",
  callback = function(event)
    local cfg = require("checkmate.config").options
    if not (cfg and cfg.enabled) then
      return
    end

    local init = require("checkmate")
    -- Start plugin if not yet running
    if not init.is_running() then
      init.start()
    end

    -- Then set up this buffer
    if init.should_activate_for_buffer(event.buf, cfg.files) then
      require("checkmate.api").setup_buffer(event.buf)
    end
  end,
})
