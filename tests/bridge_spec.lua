local h = require("helpers")

local function pids(list)
  return vim.tbl_map(function(inst)
    return inst.pid
  end, list)
end

return {
  {
    "ranks the same dir, then the nearest ancestor, then descendants; ignores unrelated",
    function()
      local root = h.tmpdir()
      vim.fn.mkdir(root .. "/a/b", "p")
      vim.fn.mkdir(root .. "/other", "p")
      local same = h.fake_omp(root .. "/a")
      local ancestor = h.fake_omp(root)
      local descendant = h.fake_omp(root .. "/a/b")
      h.fake_omp(root .. "/other")
      h.cd(root .. "/a")

      local bridge = require("omp_nvim.bridge")
      h.eq({ same.pid, ancestor.pid, descendant.pid }, pids(bridge.candidates()))
      h.cd(root .. "/a/b")
      h.eq({ descendant.pid, same.pid, ancestor.pid }, pids(bridge.candidates()))
    end,
  },
  {
    "skips dead processes and flags bridges speaking another protocol",
    function()
      local root = h.tmpdir()
      local live = h.fake_omp(root)
      local old = h.fake_omp(root, { version = 1 })
      local dead = h.fake_omp(root)
      vim.uv.kill(dead.pid, 9)
      h.wait(function()
        return select(3, vim.uv.kill(dead.pid, 0)) == "ESRCH"
      end)
      h.cd(root)

      local bridge = require("omp_nvim.bridge")
      h.eq({ live.pid }, pids(bridge.candidates()))
      local outdated = vim.tbl_filter(function(inst)
        return inst.outdated
      end, bridge.list_all())
      h.eq({ old.pid }, pids(outdated))
    end,
  },
  {
    "asks once when sessions tie and remembers the choice",
    function()
      local root = h.tmpdir()
      h.fake_omp(root, { session = "first", started = 2 })
      local second = h.fake_omp(root, { session = "second", started = 1 })
      h.cd(root)
      local asked = 0
      local select = vim.ui.select
      vim.ui.select = function(items, opts, cb)
        asked = asked + 1
        h.eq(
          { "first", "second" },
          vim.tbl_map(function(i)
            return i.session
          end, items)
        )
        h.truthy(opts.format_item(items[2]):find("second", 1, true))
        cb(items[2])
      end
      h.defer(function()
        vim.ui.select = select
      end)

      local bridge = require("omp_nvim.bridge")
      local got = {}
      bridge.resolve(function(inst)
        got[#got + 1] = inst.pid
      end)
      bridge.resolve(function(inst)
        got[#got + 1] = inst.pid
      end)
      h.eq({ second.pid, second.pid }, got)
      h.eq(1, asked)
    end,
  },
  {
    "sends prompts with the configured busy delivery and reports the outcome",
    function()
      local root = h.tmpdir()
      local fake = h.fake_omp(root, { delivery = "followUp" })
      require("omp_nvim.config").setup({ busy = "steer" })
      local bridge = require("omp_nvim.bridge")
      local inst = bridge.list()[1]

      local result
      bridge.prompt(inst, "hello", nil, function(ok, info)
        result = { ok, info }
      end)
      h.wait(function()
        return result
      end)
      h.eq({ true, "followUp" }, result)
      h.eq({ { type = "prompt", text = "hello", submit = true, busy = "steer" } }, fake.frames)
    end,
  },
  {
    "fails the pending prompt when omp drops the connection",
    function()
      local root = h.tmpdir()
      h.fake_omp(root, { drop = true })
      local bridge = require("omp_nvim.bridge")
      local result
      bridge.prompt(bridge.list()[1], "hello", nil, function(ok, info)
        result = { ok, info }
      end)
      h.wait(function()
        return result
      end)
      h.eq(false, result[1])
    end,
  },
}
