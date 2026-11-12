-- End-to-end through the user commands against a fake bridge.
local h = require("helpers")

local function load_plugin()
  vim.cmd.runtime("plugin/omp_nvim.lua")
end

return {
  {
    ":OmpAsk with a range reaches the omp at the repo root with a path relative to it",
    function()
      local root = h.tmpdir()
      local fake = h.fake_omp(root)
      h.cd(root .. "/")
      vim.cmd.edit(vim.fn.fnameescape(h.write(root .. "/sub/f.txt", h.lines(8))))
      h.cd(root .. "/sub")
      load_plugin()

      vim.cmd("5,6OmpAsk why is this here?")
      h.wait(function()
        return #fake.frames == 1
      end)
      h.eq("why is this here?\n\nsub/f.txt lines 5-6:\n```text\nline5\nline6\n```", fake.frames[1].text)
      h.eq(true, fake.frames[1].submit)
    end,
  },
  {
    ":OmpAsk! fills omp's input instead of sending",
    function()
      local root = h.tmpdir()
      local fake = h.fake_omp(root)
      h.cd(root)
      local messages = h.capture_notify()
      load_plugin()

      vim.cmd("OmpAsk! summarize the plan")
      h.wait(function()
        return #messages > 0
      end)
      h.eq({ text = "summarize the plan", submit = false, busy = "followUp", type = "prompt" }, fake.frames[1])
      h.truthy(messages[1].msg:find("press Enter there", 1, true), messages[1].msg)
    end,
  },
  {
    "a busy omp queues the prompt and says so",
    function()
      local root = h.tmpdir()
      h.fake_omp(root, { delivery = "followUp" })
      h.cd(root)
      local messages = h.capture_notify()
      load_plugin()
      vim.cmd("OmpAsk next step")
      h.wait(function()
        return #messages > 0
      end)
      h.truthy(messages[1].msg:find("queued", 1, true), messages[1].msg)
    end,
  },
  {
    "the editor reopens with the text when a placeholder cannot resolve",
    function()
      local root = h.tmpdir()
      local fake = h.fake_omp(root)
      h.cd(root)
      vim.cmd.edit(vim.fn.fnameescape(h.write(root .. "/f.txt", { "x" })))
      local messages = h.capture_notify()
      load_plugin()

      require("omp_nvim").ask({ default = "@diagnostics why" })
      h.feed("<CR>")
      h.truthy(messages[1].msg:find("no diagnostics", 1, true), vim.inspect(messages))
      h.eq({ "@diagnostics why" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      h.eq("omp_prompt", vim.bo.filetype)
      h.eq({}, fake.frames)
    end,
  },
  {
    "no omp for this directory points at :OmpSelect",
    function()
      local root = h.tmpdir()
      h.fake_omp(h.tmpdir())
      h.cd(root)
      local messages = h.capture_notify()
      load_plugin()
      vim.cmd("OmpAsk hello")
      h.truthy(messages[1].msg:find(":OmpSelect", 1, true), vim.inspect(messages))
    end,
  },
}
