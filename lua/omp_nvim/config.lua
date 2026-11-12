---Configuration, merged from defaults, vim.g.omp_nvim and setup().
local M = {}

---@class omp_nvim.Config
---@field auto_install boolean Install/refresh the bridge extension into omp's extension dirs.
---@field extension_dirs string[]? Install targets; nil auto-detects omp's agent dirs (incl. profiles).
---@field keymaps boolean Create the default <leader>o* keymaps.
---@field busy "followUp"|"steer"|"aside" Delivery while omp is mid-turn (default: queue after the turn).
---@field reload boolean Reload buffers when their files change on disk (unsaved buffers are kept).
---@field inline_max_lines integer @this/@buffer up to this many lines are sent as text, longer as a reference.
local defaults = {
  auto_install = true,
  extension_dirs = nil,
  keymaps = true,
  busy = "followUp",
  reload = true,
  inline_max_lines = 500,
}

local BUSY = { followUp = true, steer = true, aside = true }

---@type omp_nvim.Config
M.options = vim.deepcopy(defaults)

---True once setup() ran (explicitly or from the plugin script).
M.configured = false

---@param opts? table
function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(defaults), vim.g.omp_nvim or {}, opts or {})
  if vim.g.omp_nvim_no_keymaps then
    merged.keymaps = false
  end
  vim.validate("auto_install", merged.auto_install, "boolean")
  vim.validate("extension_dirs", merged.extension_dirs, "table", true)
  vim.validate("keymaps", merged.keymaps, "boolean")
  vim.validate("reload", merged.reload, "boolean")
  if type(merged.inline_max_lines) ~= "number" or merged.inline_max_lines < 0 then
    error(("omp.nvim: inline_max_lines must be a number >= 0 (got %s)"):format(vim.inspect(merged.inline_max_lines)))
  end
  if not BUSY[merged.busy] then
    error(("omp.nvim: busy must be followUp, steer or aside (got %s)"):format(vim.inspect(merged.busy)))
  end
  M.options = merged
  M.configured = true
end

return M
