local h = require("helpers")

local function edit(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

return {
  {
    "placeholders need word boundaries and unknown @words stay as written",
    function()
      local root = h.tmpdir()
      edit(h.write(root .. "/f.txt", { "x" }))
      local ctx = require("omp_nvim.context").new()
      h.eq("mail a@this, @thisx, @foo and @f.txt", ctx:render("mail a@this, @thisx, @foo and @this", root))
    end,
  },
  {
    "file references are relative to the target omp's cwd, absolute outside it",
    function()
      local root = h.tmpdir()
      local file = h.write(root .. "/sub/f.txt", h.lines(5))
      edit(file)
      local ctx = require("omp_nvim.context").new({ 2, 3 })
      h.eq("@sub/f.txt:2-3", ctx:render("@this", root))
      h.eq("@f.txt:2-3", ctx:render("@this", root .. "/sub"))
      h.eq("@" .. file .. ":2-3", ctx:render("@this", h.tmpdir()))
      h.eq("@sub/f.txt", ctx:render("@buffer", root))
    end,
  },
  {
    "unsaved edits are referenced with a snapshot of the buffer",
    function()
      local root = h.tmpdir()
      local buf = edit(h.write(root .. "/f.txt", h.lines(3)))
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "edited" })
      local text = require("omp_nvim.context").new({ 1, 2 }):render("@this", root)
      local snapshot = text:match("exact content at (%S+)%)$")
      h.truthy(vim.startswith(text, "@f.txt:1-2 (unsaved buffer"), text)
      h.eq({ "line1", "edited" }, vim.fn.readfile(snapshot))
    end,
  },
  {
    "non-file buffers are inlined in a fence longer than their content",
    function()
      local buf = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_buf_set_name(buf, "NeogitStatus")
      vim.bo[buf].filetype = "diff"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "intro", "+```lua", "+x()", "+```" })
      local text = require("omp_nvim.context").new({ 2, 4 }):render("@this", "/")
      h.eq("NeogitStatus lines 2-4:\n````diff\n+```lua\n+x()\n+```\n````", text)
    end,
  },
  {
    "@diagnostics lists the selected range in line order",
    function()
      local root = h.tmpdir()
      local buf = edit(h.write(root .. "/f.lua", h.lines(6)))
      local ns = vim.api.nvim_create_namespace("omp_nvim_test")
      vim.diagnostic.set(ns, buf, {
        { lnum = 4, col = 2, severity = vim.diagnostic.severity.WARN, message = "later", source = "lint" },
        { lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "outside" },
        { lnum = 2, col = 0, severity = vim.diagnostic.severity.ERROR, message = "first", source = "lsp", code = "E1" },
      })
      local text = require("omp_nvim.context").new({ 2, 5 }):render("@diagnostics", root)
      h.eq("Diagnostics:\n```\nf.lua:3:1: ERROR: first [lsp E1]\nf.lua:5:3: WARN: later [lint]\n```", text)
    end,
  },
  {
    "@quickfix lists valid entries; an empty list fails the whole prompt",
    function()
      local root = h.tmpdir()
      edit(h.write(root .. "/a.txt", { "x" }))
      local ctx = require("omp_nvim.context").new()
      local text, err = ctx:render("fix @quickfix please", root)
      h.eq(nil, text)
      h.eq("@quickfix: quickfix list is empty", err)

      vim.fn.setqflist({}, "r", {
        title = "grep",
        items = {
          { filename = root .. "/a.txt", lnum = 1, col = 2, text = "  match  " },
          { text = "not a location" },
        },
      })
      -- Block values go on their own lines so the closing fence stays valid.
      -- Inline references stay inline.
      h.eq(
        "fix\nQuickfix list (grep):\n```\na.txt:1:2: match\n```\nplease, and @a.txt",
        ctx:render("fix @quickfix please, and @this", root)
      )
      h.eq("Quickfix list (grep):\n```\na.txt:1:2: match\n```", ctx:render("@quickfix", root))
    end,
  },
}
