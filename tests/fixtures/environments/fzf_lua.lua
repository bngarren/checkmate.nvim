return {
  spec = {
    { "junegunn/fzf.vim", dependencies = { "junegunn/fzf" } },
    {
      "ibhagwan/fzf-lua",
      dependencies = { "nvim-tree/nvim-web-devicons" },
      opts = {},
    },
  },
  ---@diagnostic disable-next-line: missing-fields
  checkmate = require("tests.fixtures.checkmate_config").with({
    ui = {
      picker = function(items, opts)
        require("fzf-lua").fzf_exec(items, {
          actions = {
            ["default"] = function(selected)
              opts.on_choice(selected[1])
            end,
          },
          winopts = {
            on_close = function()
              opts.on_choice(nil)
            end,
          },
        })
      end,
    },
  }),
  --[[ config = function()
    require("fzf-lua").register_ui_select()
  end, ]]
}
