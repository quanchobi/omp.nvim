---omp.nvim public API: send editor context into a running omp session.
local M = {}

local bridge = require("omp_nvim.bridge")
local config = require("omp_nvim.config")
local Context = require("omp_nvim.context")
local ui = require("omp_nvim.ui")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "omp.nvim" })
end

-- Feedback for deliveries that did not simply start a turn.
local DELIVERY_MESSAGE = {
  editor = "added to omp's input; press Enter there to send",
  followUp = "omp is busy; queued to run after the current turn",
  steer = "omp is busy; sent as a steer",
  aside = "omp is busy; injected at the next step",
}

---Configure omp.nvim. Optional: defaults apply without calling it.
---@param opts? omp_nvim.Config
function M.setup(opts)
  config.setup(opts)
  M.apply_keymaps()
end

local function deliver(inst, text, opts, cb)
  bridge.prompt(inst, text, opts, function(ok, info)
    if not ok then
      notify(info or "omp rejected the prompt", vim.log.levels.WARN)
    elseif DELIVERY_MESSAGE[info] then
      notify(DELIVERY_MESSAGE[info])
    end
    if cb then
      cb(ok, info)
    end
  end)
end

---Run `fn(instance)` against the resolved omp, reporting failures.
local function with_target(fn)
  bridge.resolve(function(inst, err)
    if inst then
      fn(inst)
    elseif err then
      notify(err, vim.log.levels.WARN)
    end
  end)
end

---Inject a prompt verbatim (no placeholder resolution).
---@param text string
---@param opts? { submit?: boolean, busy?: "followUp"|"steer"|"aside" } submit=false fills omp's input instead
---@param cb? fun(ok: boolean, info: string?)
function M.prompt(text, opts, cb)
  with_target(function(inst)
    deliver(inst, text, opts, cb)
  end)
end

---Resolve placeholders against `inst` and send. A selection/range without
---any placeholder gets `@this` appended. Returns false when rendering failed.
---@return boolean
local function send(ctx, inst, text, hold)
  local prompt = text
  if prompt == "" then
    prompt = "@this"
  elseif ctx.range and not Context.has_placeholder(prompt) then
    prompt = prompt .. "\n\n@this"
  end
  local rendered, err = ctx:render(prompt, inst.cwd)
  if not rendered then
    notify(err or "cannot resolve placeholders", vim.log.levels.WARN)
    return false
  end
  deliver(inst, rendered, { submit = not hold })
  return true
end

---Send a context snapshot with an instruction, without the editor.
---@param ctx omp_nvim.Context
---@param text string instruction; may contain placeholders
---@param opts? { hold?: boolean }
function M.send_context(ctx, text, opts)
  with_target(function(inst)
    send(ctx, inst, text, opts and opts.hold)
  end)
end

---Send file lines [from, to] with an optional instruction.
---@param from integer
---@param to integer
---@param extra? string
---@param opts? { hold?: boolean }
function M.send_range(from, to, extra, opts)
  M.send_context(Context.new({ math.min(from, to), math.max(from, to) }), extra or "", opts)
end

---Send the last visual selection ('< to '>) with an optional instruction.
---@param extra? string
---@param opts? { hold?: boolean }
function M.send_selection(extra, opts)
  local from, to = vim.fn.line("'<"), vim.fn.line("'>")
  if from == 0 or to == 0 then
    return notify("no selection", vim.log.levels.WARN)
  end
  M.send_range(from, to, extra, opts)
end

---Open the prompt editor for a captured context. When placeholders cannot
---resolve, the editor reopens with the text so nothing is lost.
---@param ctx omp_nvim.Context
---@param opts? { hold?: boolean, default?: string }
function M.ask_context(ctx, opts)
  opts = opts or {}
  with_target(function(inst)
    local function open(default)
      ui.input(
        { title = "omp · " .. bridge.label(inst), default = default, mode = opts.hold and "hold" or "submit" },
        function(text, mode)
          if text and not send(ctx, inst, text, mode == "hold") then
            open(text)
          end
        end
      )
    end
    open(opts.default)
  end)
end

---Interactive ask about the current selection/buffer. Call from visual mode
---to attach the selection.
---@param opts? { hold?: boolean, default?: string } default prefills the editor (e.g. "@hunk ")
function M.ask(opts)
  M.ask_context(Context.new(), opts)
end

---Choose which omp session to talk to (persists until that omp exits).
function M.select()
  bridge.select(function(inst)
    if inst then
      notify("talking to " .. bridge.label(inst))
    end
  end)
end

---Install or refresh the bridge extension in omp's extension directories.
function M.install_extension()
  require("omp_nvim.install").install_and_notify()
end

local function asker(default, hold)
  return function()
    M.ask({ default = default, hold = hold })
  end
end

M.KEYMAPS = {
  { "n", "<leader>oa", asker(nil), "omp: ask" },
  { "x", "<leader>oa", asker(nil), "omp: ask about selection" },
  { { "n", "x" }, "<leader>oA", asker(nil, true), "omp: ask, hold in omp's input" },
  { "n", "<leader>oh", asker("@hunk "), "omp: ask about the hunk under the cursor" },
  { "n", "<leader>od", asker("@diff "), "omp: ask about this file's unstaged changes" },
  { "n", "<leader>oD", asker("@unstaged "), "omp: ask about all unstaged changes" },
  { "n", "<leader>os", asker("@staged "), "omp: ask about staged changes" },
  { { "n", "x" }, "<leader>oe", asker("@diagnostics "), "omp: ask about diagnostics" },
  { "n", "<leader>oq", asker("@quickfix "), "omp: ask about the quickfix list" },
  { "n", "<leader>ot", M.select, "omp: choose session" },
}

local mapped = false

---Create or remove the default keymaps to match `config.keymaps`.
function M.apply_keymaps()
  if config.options.keymaps == mapped then
    return
  end
  for _, map in ipairs(M.KEYMAPS) do
    if config.options.keymaps then
      vim.keymap.set(map[1], map[2], map[3], { desc = map[4] })
    else
      pcall(vim.keymap.del, map[1], map[2])
    end
  end
  mapped = config.options.keymaps
end

return M
