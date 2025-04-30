describe("Highlights", function()
  local h = require("tests.checkmate.helpers")
  -- Reset state before each test
  before_each(function()
    -- Reset the plugin state to ensure tests are isolated
    _G.reset_state()
  end)

  describe("extmark highlighting", function()
    it("should apply metadata tag highlights", function()
      local config = require("checkmate.config")
      local highlights = require("checkmate.highlights")
      local unchecked = config.options.todo_markers.unchecked

      -- Create test content with metadata
      local content = [[
# Test Todo List

- ]] .. unchecked .. [[ Todo with @priority(high) metadata
]]

      -- Create test buffer
      local bufnr = h.create_test_buffer(content)

      -- Apply highlighting
      highlights.apply_highlighting(bufnr, { debug_reason = "test" })

      -- Get extmarks in checkmate namespace
      local extmarks = h.get_extmarks(bufnr, config.ns)

      -- Check for metadata highlights
      local found_metadata = false

      for _, mark in ipairs(extmarks) do
        local details = mark[4]
        if details and details.hl_group:match("^CheckmateMeta_") then
          found_metadata = true
          break
        end
      end

      assert.is_true(found_metadata)

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    end)

    it("should display todo count when configured", function()
      local config = require("checkmate.config")
      local highlights = require("checkmate.highlights")
      local unchecked = config.options.todo_markers.unchecked
      local checked = config.options.todo_markers.checked

      -- Ensure todo count is enabled
      config.options.show_todo_count = true

      -- Create test content with parent and child todos
      local content = [[
# Test Todo List

- ]] .. unchecked .. [[ Parent todo
  - ]] .. unchecked .. [[ Child 1
  - ]] .. checked .. [[ Child 2
  - ]] .. unchecked .. [[ Child 3
]]

      -- Create test buffer
      local bufnr = h.create_test_buffer(content)

      -- Apply highlighting
      highlights.apply_highlighting(bufnr, { debug_reason = "test" })

      -- Get extmarks in checkmate namespace
      local extmarks = h.get_extmarks(bufnr, config.ns)

      -- Check for todo count indicator
      local found_count = false

      for _, mark in ipairs(extmarks) do
        local details = mark[4]
        if details and details.virt_text then
          for _, text_part in ipairs(details.virt_text) do
            -- Check if any virtual text has the expected format (1/3)
            if text_part[1]:match("%d+/%d+") then
              found_count = true
              break
            end
          end
        end
      end

      assert.is_true(found_count)

      finally(function()
        -- Clean up
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end)
    end)
  end)
end)
