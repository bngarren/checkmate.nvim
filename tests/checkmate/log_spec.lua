describe("Log", function()
  local get_log_file_path = require("checkmate.log")._get_log_file_path

  local default_path = vim.fs.joinpath(vim.fn.stdpath("log"), "checkmate.log")

  ---@type luassert.spy
  local fs_access_stub
  ---@type luassert.spy
  local fs_stat_stub
  ---@type luassert.spy
  local mkdir_stub

  before_each(function()
    fs_access_stub = stub(vim.uv, "fs_access", nil)
    fs_stat_stub = stub(vim.uv, "fs_stat", nil)
    mkdir_stub = stub(vim.fn, "mkdir")
  end)

  after_each(function()
    fs_access_stub:revert()
    fs_stat_stub:revert()
    mkdir_stub:revert()
  end)

  describe("get_log_file_path()", function()
    it("returns default path for nil input", function()
      local path = get_log_file_path(nil)
      assert.equal(default_path, path)
    end)

    it("returns default path for empty string", function()
      local path = get_log_file_path("")
      assert.equal(default_path, path)
    end)

    it("handles directory with trailing slash", function()
      local path = get_log_file_path("/tmp/logs/")
      assert.equal("/tmp/logs/checkmate.log", path)
      fs_access_stub:called_with({ "/tmp/logs" })
    end)

    it("preserves .log extension", function()
      local path = get_log_file_path("/tmp/custom.log")
      assert.equal("/tmp/custom.log", path)
      fs_access_stub:called_with({ "/tmp" })
    end)

    it("treats paths without extension as directories", function()
      local path = get_log_file_path("/tmp/logdir")
      assert.equal("/tmp/logdir/checkmate.log", path)
      fs_access_stub:called_with({ "/tmp/logdir" })
    end)
  end)
end)
