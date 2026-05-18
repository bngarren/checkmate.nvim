describe("Log", function()
  local log
  local get_log_file_path
  local config
  local default_path

  ---@type luassert.spy
  local fs_access_stub
  ---@type luassert.spy
  local fs_stat_stub
  ---@type luassert.spy
  local mkdir_stub
  ---@type luassert.spy
  local notify_stub
  ---@type luassert.spy
  local io_open_stub

  before_each(function()
    _G.reset_state()

    log = require("checkmate.log")
    get_log_file_path = log._get_log_file_path
    config = require("checkmate.config")
    config.options = vim.deepcopy(config.get_defaults())
    config.options.log = { level = "trace", use_file = false }
    default_path = vim.fs.joinpath(vim.fn.stdpath("log"), "checkmate.log")

    fs_access_stub = stub(vim.uv, "fs_access", function()
      return true
    end)
    fs_stat_stub = stub(vim.uv, "fs_stat", nil)
    mkdir_stub = stub(vim.fn, "mkdir")
    notify_stub = stub(vim, "notify")
  end)

  after_each(function()
    pcall(function()
      log.shutdown()
    end)

    if io_open_stub then
      io_open_stub:revert()
      ---@diagnostic disable-next-line: cast-local-type
      io_open_stub = nil
    end
    fs_access_stub:revert()
    fs_stat_stub:revert()
    mkdir_stub:revert()
    notify_stub:revert()
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
      assert.stub(fs_access_stub).was.called_with("/tmp/logs", "W")
    end)

    it("preserves .log extension", function()
      local path = get_log_file_path("/tmp/custom.log")
      assert.equal("/tmp/custom.log", path)
      assert.stub(fs_access_stub).was.called_with("/tmp", "W")
    end)

    it("treats paths without extension as directories", function()
      local path = get_log_file_path("/tmp/logdir")
      assert.equal("/tmp/logdir/checkmate.log", path)
      assert.stub(fs_access_stub).was.called_with("/tmp/logdir", "W")
    end)

    it("falls back to the default path when the target directory is not writable", function()
      fs_access_stub:revert()
      fs_access_stub = stub(vim.uv, "fs_access", function()
        return false
      end)

      local path = get_log_file_path("/tmp/custom.log")
      assert.equal(default_path, path)
    end)
  end)

  describe("logger methods", function()
    it("does not error when file writes fail", function()
      config.options.log = {
        level = "trace",
        use_file = true,
        file_path = "/tmp/checkmate.log",
      }

      io_open_stub = stub(io, "open", function()
        return {
          write = function()
            error("write failed")
          end,
          flush = function()
            error("flush failed")
          end,
          close = function() end,
        }
      end)

      assert.has_no_error(function()
        log.setup()
        log.info("after failed setup write")
        log.clear()
      end)
    end)

    it("treats max_file_size as kilobytes", function()
      fs_stat_stub:revert()
      fs_stat_stub = stub(vim.uv, "fs_stat", function()
        return { size = 2 * 1024 }
      end)

      local opened_mode
      io_open_stub = stub(io, "open", function(_, mode)
        opened_mode = mode
        return {
          write = function()
            return true
          end,
          flush = function()
            return true
          end,
          close = function()
            return true
          end,
        }
      end)

      config.options.log = {
        level = "trace",
        use_file = true,
        file_path = "/tmp/checkmate.log",
        max_file_size = 3,
      }

      log.setup()

      assert.equal("a", opened_mode)
    end)
  end)
end)
