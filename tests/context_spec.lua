local h = require("helpers")

local function edit(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

return {
  {
    "placeholders need word boundaries and unknown @words stay as written",
    function()
      require("omp_nvim.config").setup({ inline_max_lines = 0 }) -- keep @this a one-line reference
      local root = h.tmpdir()
      edit(h.write(root .. "/f.txt", { "x" }))
      local ctx = require("omp_nvim.context").new()
      h.eq("mail a@this, @thisx, @foo and @f.txt", ctx:render("mail a@this, @thisx, @foo and @this", root))
    end,
  },
  {
    "selections are sent as text under a path relative to the target omp's cwd",
    function()
      local root = h.tmpdir()
      local file = h.write(root .. "/sub/f.lua", h.lines(5))
      edit(file)
      local ctx = require("omp_nvim.context").new({ 2, 3 })
      h.eq("sub/f.lua lines 2-3:\n```lua\nline2\nline3\n```", ctx:render("@this", root))
      h.eq("f.lua lines 2-3:\n```lua\nline2\nline3\n```", ctx:render("@this", root .. "/sub"))
      h.eq(file .. " lines 2-3:\n```lua\nline2\nline3\n```", ctx:render("@this", h.tmpdir()))
      h.eq("sub/f.lua:\n```lua\nline1\nline2\nline3\nline4\nline5\n```", ctx:render("@buffer", root))
    end,
  },
  {
    "unsaved edits are sent as the buffer's text, marked unsaved",
    function()
      local root = h.tmpdir()
      local buf = edit(h.write(root .. "/f.lua", h.lines(3)))
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "edited" })
      local text = require("omp_nvim.context").new({ 1, 2 }):render("@this", root)
      h.eq("f.lua lines 1-2 (unsaved edits):\n```lua\nline1\nedited\n```", text)
    end,
  },
  {
    "ranges over inline_max_lines become references; unsaved ones get a snapshot",
    function()
      require("omp_nvim.config").setup({ inline_max_lines = 2 })
      local root = h.tmpdir()
      local buf = edit(h.write(root .. "/sub/f.lua", h.lines(5)))
      h.truthy(require("omp_nvim.context").new({ 2, 3 }):render("@this", root):find("^sub/f.lua lines 2%-3:\n"))
      h.eq("@sub/f.lua:2-4", require("omp_nvim.context").new({ 2, 4 }):render("@this", root))
      h.eq("@sub/f.lua", require("omp_nvim.context").new():render("@buffer", root))

      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "edited" })
      local text = require("omp_nvim.context").new({ 1, 3 }):render("@this", root)
      h.truthy(vim.startswith(text, "@sub/f.lua:1-3 (unsaved buffer"), text)
      h.eq({ "line1", "edited", "line3" }, vim.fn.readfile(text:match("exact content at (%S+)%)$")))
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
      -- Block values go on their own lines so every fence stays valid Markdown.
      h.eq(
        "fix\nQuickfix list (grep):\n```\na.txt:1:2: match\n```\nplease, and\na.txt:\n```text\nx\n```",
        ctx:render("fix @quickfix please, and @this", root)
      )
      h.eq("Quickfix list (grep):\n```\na.txt:1:2: match\n```", ctx:render("@quickfix", root))
    end,
  },
}
