local h = require("helpers")

local function with_env(vars)
  local saved = {}
  for k, v in pairs(vars) do
    saved[k] = vim.env[k] or false
    vim.env[k] = v
  end
  h.defer(function()
    for k, v in pairs(saved) do
      vim.env[k] = v or nil
    end
  end)
end

return {
  {
    "targets the default agent dir and every existing profile",
    function()
      local home = h.tmpdir()
      with_env({ HOME = home })
      vim.fn.mkdir(home .. "/.omp/profiles/work/agent", "p")
      h.eq({
        home .. "/.omp/agent/extensions",
        home .. "/.omp/profiles/work/agent/extensions",
      }, require("omp_nvim.install").targets())
    end,
  },
  {
    "honors PI_CONFIG_DIR (relative to HOME) and PI_CODING_AGENT_DIR",
    function()
      local home = h.tmpdir()
      with_env({ HOME = home, PI_CONFIG_DIR = ".config/omp", PI_CODING_AGENT_DIR = home .. "/agent" })
      vim.fn.mkdir(home .. "/.config/omp/profiles/p/agent", "p")
      h.eq({
        home .. "/agent/extensions",
        home .. "/.config/omp/profiles/p/agent/extensions",
      }, require("omp_nvim.install").targets())
    end,
  },
  {
    "extension_dirs replaces detection",
    function()
      require("omp_nvim.config").setup({ extension_dirs = { "/x/ext" } })
      h.eq({ "/x/ext" }, require("omp_nvim.install").targets())
    end,
  },
  {
    "installs missing and outdated copies, never overwrites symlinks",
    function()
      local root = h.tmpdir()
      local install = require("omp_nvim.install")
      require("omp_nvim.config").setup({ extension_dirs = { root .. "/a", root .. "/b", root .. "/c" } })
      h.write(root .. "/b/" .. install.FILENAME, { "old" })
      local foreign = h.write(root .. "/foreign.ts", { "managed elsewhere" })
      vim.fn.mkdir(root .. "/c", "p")
      assert(vim.uv.fs_symlink(foreign, root .. "/c/" .. install.FILENAME))

      local written = vim.tbl_map(function(r)
        return { r.state, r.written }
      end, install.install())
      h.eq({ { "missing", true }, { "outdated", true }, { "managed", false } }, written)
      h.eq("current", (install.state(root .. "/a")))
      h.eq("current", (install.state(root .. "/b")))
      h.eq({ "managed elsewhere" }, vim.fn.readfile(foreign))

      h.eq(
        { false, false, false },
        vim.tbl_map(function(r)
          return r.written
        end, install.install())
      )
    end,
  },
}
