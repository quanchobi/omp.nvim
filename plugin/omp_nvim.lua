-- omp.nvim entry: commands, default keymaps, turn-end reload, bridge install.
if vim.g.loaded_omp_nvim then
  return
end
vim.g.loaded_omp_nvim = true

local omp = require("omp_nvim")
local config = require("omp_nvim.config")

if not config.configured then
  config.setup()
end
omp.apply_keymaps()

-- :OmpAsk[!] [instruction] — ! fills omp's input instead of sending.
--   :OmpAsk              open the prompt editor
--   :OmpAsk text         send text (placeholders resolved)
--   :5,20OmpAsk [text]   send lines 5-20 of this file with an optional instruction
vim.api.nvim_create_user_command("OmpAsk", function(args)
  local ctx = require("omp_nvim.context").new(args.range > 0 and { args.line1, args.line2 } or nil)
  if args.args ~= "" or args.range > 0 then
    omp.send_context(ctx, args.args, { hold = args.bang })
  else
    omp.ask_context(ctx, { hold = args.bang })
  end
end, { range = true, nargs = "*", bang = true, desc = "Ask the omp session for this directory" })

vim.api.nvim_create_user_command("OmpSelect", omp.select, { desc = "Choose the omp session to talk to" })

vim.api.nvim_create_user_command("OmpNvimInstallExtension", omp.install_extension, {
  desc = "Install the omp.nvim bridge into omp's extension directories",
})

require("omp_nvim.bridge").on_status(function(event)
  if event == "turn_ended" and config.options.reload then
    pcall(vim.cmd.checktime) -- reload files omp changed; buffers with local edits are protected
  end
end)

-- Deferred so setup() from init.lua or a plugin manager's opts can disable it.
local function install()
  if config.options.auto_install then
    omp.install_extension()
  end
end
if vim.v.vim_did_enter == 1 then
  vim.schedule(install)
else
  vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = install })
end
