---Installs the bundled bridge extension into omp's extension directories.
local M = {}

M.FILENAME = "omp-nvim-bridge.ts"

---@return string path of the bridge shipped with this plugin
function M.bundled()
  local src = debug.getinfo(1, "S").source:sub(2) -- <root>/lua/omp_nvim/install.lua
  return vim.fs.joinpath(vim.fn.fnamemodify(src, ":h:h:h"), "extension", M.FILENAME)
end

---Extension directories omp loads from: the default agent dir (honoring
---PI_CONFIG_DIR / PI_CODING_AGENT_DIR) plus every existing named profile.
---`extension_dirs` in the config replaces detection entirely.
---@return string[]
function M.targets()
  local configured = require("omp_nvim.config").options.extension_dirs
  if configured then
    return vim.tbl_map(vim.fs.normalize, configured)
  end
  local home = assert(vim.uv.os_homedir())
  local root = vim.env.PI_CONFIG_DIR
  if not root or root == "" then
    root = vim.fs.joinpath(home, ".omp")
  elseif root:sub(1, 1) ~= "/" then
    root = vim.fs.joinpath(home, root) -- omp resolves PI_CONFIG_DIR under $HOME
  end
  local agent = vim.env.PI_CODING_AGENT_DIR
  local dirs = {
    vim.fs.joinpath(agent and agent ~= "" and vim.fs.normalize(agent) or vim.fs.joinpath(root, "agent"), "extensions"),
  }
  local profiles = vim.fs.joinpath(root, "profiles")
  if vim.uv.fs_stat(profiles) then
    for name, kind in vim.fs.dir(profiles) do
      if kind == "directory" then
        dirs[#dirs + 1] = vim.fs.joinpath(profiles, name, "agent", "extensions")
      end
    end
  end
  return dirs
end

local function read(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

---@alias omp_nvim.InstallState "current"|"outdated"|"missing"|"managed"

---State of the bridge in one extension directory. "managed" means the file
---is a symlink owned by something else (e.g. home-manager) whose content
---differs from the bundled bridge; it is never overwritten.
---@param dir string
---@param want? string bundled content
---@return omp_nvim.InstallState state
---@return string path
function M.state(dir, want)
  want = want or read(M.bundled())
  local path = vim.fs.joinpath(dir, M.FILENAME)
  local lstat = vim.uv.fs_lstat(path)
  if not lstat then
    return "missing", path
  end
  if read(path) == want then
    return "current", path
  end
  return lstat.type == "link" and "managed" or "outdated", path
end

---Install or refresh the bridge in every target. Idempotent; symlinks are left alone.
---@return { path: string, state: omp_nvim.InstallState, written: boolean, err: string? }[]
function M.install()
  local want = read(M.bundled())
  if not want then
    error("omp.nvim: bundled bridge missing at " .. M.bundled())
  end
  local results = {}
  for _, dir in ipairs(M.targets()) do
    local state, path = M.state(dir, want)
    local result = { path = path, state = state, written = false }
    if state == "missing" or state == "outdated" then
      local ok, err = pcall(function()
        vim.fn.mkdir(dir, "p")
        local tmp = path .. ".tmp"
        local fd = assert(io.open(tmp, "wb"))
        fd:write(want)
        fd:close()
        assert(vim.uv.fs_rename(tmp, path))
      end)
      result.written, result.err = ok, not ok and tostring(err) or nil
    end
    results[#results + 1] = result
  end
  return results
end

---Install and report: notifies about written files and failures only.
function M.install_and_notify()
  local ok, results = pcall(M.install)
  if not ok then
    vim.notify(results, vim.log.levels.ERROR, { title = "omp.nvim" })
    return
  end
  for _, r in ipairs(results) do
    if r.written then
      vim.notify(
        "bridge installed to " .. r.path .. " (restart running omp instances to load it)",
        vim.log.levels.INFO,
        { title = "omp.nvim" }
      )
    elseif r.err then
      vim.notify("cannot install bridge to " .. r.path .. ": " .. r.err, vim.log.levels.WARN, { title = "omp.nvim" })
    end
  end
end

return M
