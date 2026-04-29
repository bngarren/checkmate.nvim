describe("lib.todo_item", function()
  ---@module "tests.checkmate.helpers"
  local h

  ---@module "checkmate.parser"
  local parser

  lazy_setup(function()
    -- Hide nvim_echo from polluting test output
    stub(vim.api, "nvim_echo")
  end)

  lazy_teardown(function()
    ---@diagnostic disable-next-line: undefined-field
    vim.api.nvim_echo:revert()
  end)

  before_each(function()
    _G.reset_state()

    h = require("tests.checkmate.helpers")
    parser = require("checkmate.parser")

    h.ensure_normal_mode()
  end)

  describe("get parent", function()
    it("should return correct data for get_parent requests on the todo item", function()
      h.run_test_cases({
        {
          name = "get_parent on root todo",
          content = {
            "- [ ] Task A",
            "- [ ] Task B",
            "  - [ ] Task C",
          },
          action = function(_, ctx)
            local taskA = parser.get_todo_item_at_position(ctx.buffer, 0, 0, { todo_map = ctx.todo_map })
            ctx.taskA = taskA
          end,

          assert = function(_, _, ctx)
            local taskA = h.exists(ctx.taskA --[[@as checkmate.TodoItem]])
            assert.is_nil(taskA.parent_id)
            assert.is_nil(taskA:get_parent(ctx.todo_map))
          end,
        },
        {
          -- task C should have parent = task B
          name = "get_parent on todo with parent",
          content = {
            "- [ ] Task A",
            "- [ ] Task B",
            "  - [ ] Task C",
          },
          action = function(_, ctx)
            local taskB = parser.get_todo_item_at_position(ctx.buffer, 1, 0, { todo_map = ctx.todo_map })
            ctx.taskB = taskB
            local taskC = parser.get_todo_item_at_position(ctx.buffer, 2, 0, { todo_map = ctx.todo_map })
            ctx.taskC = taskC
          end,

          assert = function(_, _, ctx)
            local taskB = h.exists(ctx.taskB --[[@as checkmate.TodoItem]])
            local taskC = h.exists(ctx.taskC --[[@as checkmate.TodoItem]])
            assert.equal(taskB.id, taskC.parent_id)
            assert.same(taskB, taskC:get_parent(ctx.todo_map))
          end,
        },
      })
    end)

    it("should return correct data for get_root_todo requests on the todo item", function()
      h.run_test_cases({
        {
          name = "get_root_todo on root todo", -- should return same todo (it is the root)
          content = {
            "- [ ] Task A",
            "- [ ] Task B",
            "  - [ ] Task C",
          },
          action = function(_, ctx)
            local taskA = parser.get_todo_item_at_position(ctx.buffer, 0, 0, { todo_map = ctx.todo_map })
            ctx.taskA = taskA
          end,

          assert = function(_, _, ctx)
            local taskA = h.exists(ctx.taskA --[[@as checkmate.TodoItem]])
            assert.is_nil(taskA.parent_id)
            assert.same(taskA, taskA:get_root_todo(ctx.todo_map))
          end,
        },
        {
          name = "get_root_todo on child todo",
          content = {
            "- [ ] Task A",
            "- [ ] Task B",
            "  - [ ] Task C",
            "    - [x] Task D",
          },
          action = function(_, ctx)
            local taskB = parser.get_todo_item_at_position(ctx.buffer, 1, 0, { todo_map = ctx.todo_map })
            ctx.taskB = taskB
            local taskC = parser.get_todo_item_at_position(ctx.buffer, 2, 0, { todo_map = ctx.todo_map })
            ctx.taskC = taskC
            local taskD = parser.get_todo_item_at_position(ctx.buffer, 3, 0, { todo_map = ctx.todo_map })
            ctx.taskD = taskD
          end,

          assert = function(_, _, ctx)
            local taskB = h.exists(ctx.taskB --[[@as checkmate.TodoItem]])
            local taskC = h.exists(ctx.taskC --[[@as checkmate.TodoItem]])
            local taskD = h.exists(ctx.taskD --[[@as checkmate.TodoItem]])
            -- first child (root is task B)
            assert.equal(taskB.id, taskC.parent_id)
            assert.same(taskB, taskC:get_root_todo(ctx.todo_map))
            -- deeper child (root is also task B)
            assert.equal(taskC.id, taskD.parent_id)
            assert.same(taskB, taskD:get_root_todo(ctx.todo_map))
          end,
        },
      })
    end)
  end)
end)
