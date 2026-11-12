-- Buffers follow external edits (omp's tools, git, ...) without :e and
-- without any omp connection.
local h = require("helpers")

local function open(lines)
  local path = h.write(h.tmpdir() .. "/f.txt", lines)
  vim.cmd.runtime("plugin/omp_nvim.lua")
  vim.cmd.edit(vim.fn.fnameescape(path))
  return path, vim.api.nvim_get_current_buf()
end

---Replace a file the way most tools do: write a temp file, rename over it.
local function replace(path, lines)
  vim.fn.writefile(lines, path .. ".tmp")
  assert(vim.uv.fs_rename(path .. ".tmp", path))
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

return {
  {
    "reloads a buffer as soon as its file changes, in place or replaced",
    function()
      local path, buf = open({ "old" })
      vim.fn.writefile({ "in place" }, path)
      h.wait(function()
        return lines(buf)[1] == "in place"
      end, "in-place write not reloaded")

      replace(path, { "replaced" })
      h.wait(function()
        return lines(buf)[1] == "replaced"
      end, "atomic replace not reloaded")
      h.eq(false, vim.bo[buf].modified)
    end,
  },
  {
    "keeps unsaved edits and says the file changed",
    function()
      local messages = h.capture_notify()
      local path, buf = open({ "old" })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "mine" })
      replace(path, { "theirs" })
      h.wait(function()
        return #messages > 0
      end, "no notice")
      h.truthy(messages[1].msg:find("f.txt changed on disk", 1, true), messages[1].msg)
      h.eq({ "mine" }, lines(buf))
    end,
  },
  {
    "reload = false leaves buffers alone",
    function()
      require("omp_nvim.config").setup({ reload = false })
      local path, buf = open({ "old" })
      replace(path, { "new" })
      vim.wait(300)
      h.eq({ "old" }, lines(buf))
    end,
  },
}
