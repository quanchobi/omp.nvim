-- Minimal headless test runner: nvim --headless --clean -l tests/run.lua [name-filter]
-- Each tests/*_spec.lua returns a list of { name, fn } pairs.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

-- Isolate from the user's environment.
local tmp = vim.fn.tempname()
vim.env.HOME = tmp .. "/home"
vim.env.OMP_NVIM_RUN_DIR = tmp .. "/run"
vim.env.PI_CONFIG_DIR = nil
vim.env.PI_CODING_AGENT_DIR = nil
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"
vim.env.GIT_AUTHOR_NAME, vim.env.GIT_AUTHOR_EMAIL = "test", "test@example.com"
vim.env.GIT_COMMITTER_NAME, vim.env.GIT_COMMITTER_EMAIL = "test", "test@example.com"
vim.fn.mkdir(vim.env.HOME, "p")

local filter = _G.arg[1]
local passed, failed = 0, 0
local files = vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
table.sort(files)

for _, file in ipairs(files) do
  for _, case in ipairs(dofile(file)) do
    local name = vim.fn.fnamemodify(file, ":t:r") .. ": " .. case[1]
    if not filter or name:find(filter, 1, true) then
      local helpers = require("helpers")
      local ok, err = xpcall(case[2], debug.traceback)
      helpers.reset()
      if ok then
        passed = passed + 1
        io.stdout:write("ok   " .. name .. "\n")
      else
        failed = failed + 1
        io.stdout:write("FAIL " .. name .. "\n" .. tostring(err) .. "\n")
      end
    end
  end
end

io.stdout:write(("\n%d passed, %d failed\n"):format(passed, failed))
vim.fn.delete(tmp, "rf")
os.exit(failed > 0 and 1 or 0)
