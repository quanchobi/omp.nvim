---:checkhealth omp_nvim
local M = {}

function M.check()
  local health = vim.health
  health.start("omp.nvim")

  if vim.fn.has("nvim-0.11") == 0 then
    health.error("nvim 0.11+ required")
    return
  end
  health.ok("nvim >= 0.11")
  if vim.fn.executable("git") == 1 then
    health.ok("git found (@hunk, @diff, @staged, @unstaged)")
  else
    health.warn("git not found: diff placeholders are unavailable")
  end

  health.start("bridge extension")
  local install = require("omp_nvim.install")
  for _, dir in ipairs(install.targets()) do
    local state, path = install.state(dir)
    if state == "current" then
      health.ok("up to date: " .. path)
    elseif state == "managed" then
      health.warn("differs from this plugin's bridge and is a symlink (Nix/home-manager?); update it there: " .. path)
    elseif state == "outdated" then
      health.warn("outdated: " .. path, "Run :OmpNvimInstallExtension, then restart omp")
    else
      health.warn("missing: " .. path, "Run :OmpNvimInstallExtension, then restart omp")
    end
  end

  health.start("running omp sessions")
  local bridge = require("omp_nvim.bridge")
  local all = bridge.list_all()
  if #all == 0 then
    health.warn("none found in " .. bridge.run_dir(), "Start omp (or restart it after installing the bridge)")
    return
  end
  for _, inst in ipairs(all) do
    if inst.outdated then
      health.warn(("%s speaks protocol %s; restart that omp"):format(bridge.label(inst), tostring(inst.version)))
    else
      health.ok(bridge.label(inst))
    end
  end
  local candidates = bridge.candidates()
  if #candidates == 0 then
    health.warn("none related to " .. vim.fn.getcwd(), "Use :OmpSelect to talk to one anyway")
  else
    health.info(("%d candidate(s) for %s; best: %s"):format(#candidates, vim.fn.getcwd(), bridge.label(candidates[1])))
  end
end

return M
