---Reload buffers whose files change on disk: omp's edits (including
---subagents'), git checkouts, anything. Needs no omp connection.
---
---Every directory holding a loaded file buffer gets one fs watcher (watching
---the directory, not the file, also catches tools that write a temp file and
---rename it over the original). Events are debounced, then each affected
---buffer is reloaded with :checktime, which honors 'autoread' (on by default).
---Buffers with unsaved edits are never reloaded; you get a notice instead,
---and Neovim's write check still guards against overwriting the newer file.
local M = {}

local config = require("omp_nvim.config")

local DEBOUNCE_MS = 50
local RETRY_MS = 500

---@type table<string, { handle: uv.uv_fs_event_t, bufs: table<integer, true> }>
local dirs = {}
local watched = {} ---@type table<integer, string> buffer -> real path it is watched as
local pending = {} ---@type table<integer, true> buffers whose file changed
local notified = {} ---@type table<integer, true> modified buffers already told about a change
local timer = assert(vim.uv.new_timer())

local function unwatch(buf)
  local path = watched[buf]
  if not path then
    return
  end
  watched[buf] = nil
  local dir = vim.fs.dirname(path)
  local entry = dirs[dir]
  if entry then
    entry.bufs[buf] = nil
    if next(entry.bufs) == nil then
      entry.handle:close()
      dirs[dir] = nil
    end
  end
end

local function flush()
  local bufs = vim.tbl_keys(pending)
  pending = {}
  if not config.options.reload then
    return
  end
  for _, buf in ipairs(bufs) do
    if vim.api.nvim_buf_is_loaded(buf) then
      if not vim.bo[buf].modified then
        -- Fails under textlock (e.g. mid-completion); try again shortly.
        if not pcall(vim.cmd, "checktime " .. buf) then
          pending[buf] = true
        end
      elseif not notified[buf] then
        notified[buf] = true
        vim.notify(
          vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
            .. " changed on disk; kept your unsaved edits (:e! loads the new version)",
          vim.log.levels.WARN,
          { title = "omp.nvim" }
        )
      end
    end
  end
  if next(pending) then
    timer:start(RETRY_MS, 0, vim.schedule_wrap(flush))
  end
end

---Watcher callback (fast event context: no API calls).
local function on_event(dir, err, filename)
  local entry = dirs[dir]
  if not entry then
    return
  end
  if err then
    -- Directory removed or unwatchable: drop it; BufEnter re-arms.
    for buf in pairs(entry.bufs) do
      watched[buf] = nil
    end
    entry.handle:close()
    dirs[dir] = nil
    return
  end
  local changed = filename and (dir == "/" and "/" or dir .. "/") .. filename
  for buf in pairs(entry.bufs) do
    if not changed or watched[buf] == changed then
      pending[buf] = true
    end
  end
  if next(pending) then
    timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(flush))
  end
end

---Start (or move) the watcher for a buffer's file.
---@param buf integer
function M.watch(buf)
  if not config.options.reload or not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" then
    return unwatch(buf)
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local dir = name ~= "" and vim.uv.fs_realpath(vim.fs.dirname(name))
  if not dir then
    return unwatch(buf)
  end
  -- Symlinked files are watched where their target lives.
  local path = vim.uv.fs_realpath(name) or vim.fs.joinpath(dir, vim.fs.basename(name))
  if watched[buf] == path then
    return
  end
  unwatch(buf)
  dir = vim.fs.dirname(path)
  local entry = dirs[dir]
  if not entry then
    local handle = assert(vim.uv.new_fs_event())
    local ok = handle:start(dir, {}, function(err, filename)
      on_event(dir, err, filename)
    end)
    if not ok then
      handle:close() -- unsupported filesystem; the turn-end check still applies
      return
    end
    entry = { handle = handle, bufs = {} }
    dirs[dir] = entry
  end
  entry.bufs[buf] = true
  watched[buf] = path
end

---:checktime every unmodified file buffer (fallback for unwatchable files).
function M.check_all()
  if not config.options.reload then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and not vim.bo[buf].modified then
      pcall(vim.cmd, "checktime " .. buf)
    end
  end
end

---Watch every loaded buffer now and every file buffer from here on.
function M.start()
  local group = vim.api.nvim_create_augroup("omp_nvim_reload", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "BufFilePost", "BufEnter" }, {
    group = group,
    callback = function(args)
      if args.event ~= "BufEnter" then
        notified[args.buf] = nil -- buffer now matches disk again
      end
      M.watch(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    callback = function(args)
      unwatch(args.buf)
      pending[args.buf], notified[args.buf] = nil, nil
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    M.watch(buf)
  end
end

return M
