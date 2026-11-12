local M = {}

local cleanups = {}

function M.defer(fn)
  cleanups[#cleanups + 1] = fn
end

---Undo per-test state: cleanups, buffers, loaded plugin modules.
function M.reset()
  for i = #cleanups, 1, -1 do
    pcall(cleanups[i])
  end
  cleanups = {}
  vim.cmd("silent! %bwipeout!")
  vim.fn.setqflist({}, "r")
  for name in pairs(package.loaded) do
    if name:match("^omp_nvim") then
      package.loaded[name] = nil
    end
  end
  vim.g.loaded_omp_nvim = nil
  vim.g.omp_nvim = nil
  vim.fn.delete(vim.env.OMP_NVIM_RUN_DIR, "rf")
end

function M.eq(want, got, msg)
  if not vim.deep_equal(want, got) then
    error(("%sexpected %s, got %s"):format(msg and (msg .. ": ") or "", vim.inspect(want), vim.inspect(got)), 2)
  end
end

function M.truthy(value, msg)
  if not value then
    error(msg or "expected a truthy value", 2)
  end
  return value
end

---A fresh real directory (symlinks resolved).
function M.tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  M.defer(function()
    vim.fn.delete(dir, "rf")
  end)
  return vim.uv.fs_realpath(dir)
end

function M.write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
  return path
end

function M.git(dir, ...)
  local res = vim.system({ "git", ... }, { cwd = dir, text = true }):wait()
  assert(res.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. (res.stderr or ""))
  return res.stdout
end

function M.repo()
  local dir = M.tmpdir()
  M.git(dir, "init", "-q")
  return dir
end

function M.lines(n, fmt)
  local out = {}
  for i = 1, n do
    out[i] = (fmt or "line%d"):format(i)
  end
  return out
end

function M.cd(dir)
  local prev = vim.fn.getcwd()
  vim.cmd.cd(dir)
  M.defer(function()
    vim.cmd.cd(prev)
  end)
end

function M.wait(fn, msg)
  M.truthy(vim.wait(2000, fn, 10), msg or "timed out waiting")
end

---Stand-in for an omp bridge: a live process (pid), a socket answering the
---JSONL protocol, and the metadata file nvim discovers.
---@param cwd string
---@param opts? { delivery?: string, session?: string, version?: integer, drop?: boolean, started?: integer }
function M.fake_omp(cwd, opts)
  opts = opts or {}
  local proc = vim.system({ "sleep", "60" })
  M.defer(function()
    proc:kill(9)
  end)
  local run = vim.env.OMP_NVIM_RUN_DIR
  vim.fn.mkdir(run, "p")
  local socket = ("%s/%d.sock"):format(run, proc.pid)
  local fake = { pid = proc.pid, cwd = cwd, socket = socket, frames = {} }

  local server = assert(vim.uv.new_pipe(false))
  assert(server:bind(socket))
  server:listen(8, function()
    local client = assert(vim.uv.new_pipe(false))
    server:accept(client)
    client:write('{"type":"status","event":"ready"}\n')
    local buf = ""
    client:read_start(function(_, data)
      if not data then
        return client:close()
      end
      buf = buf .. data
      while buf:find("\n") do
        local line
        line, buf = buf:match("^(.-)\n(.*)$")
        local frame = vim.json.decode(line)
        table.insert(fake.frames, frame)
        if opts.drop then
          return client:close()
        end
        client:write(vim.json.encode({
          type = "status",
          event = "prompt_accepted",
          delivery = opts.delivery or (frame.submit and "prompt" or "editor"),
        }) .. "\n")
      end
    end)
  end)
  M.defer(function()
    server:close()
    vim.fn.delete(socket)
  end)

  vim.fn.writefile({
    vim.json.encode({
      version = opts.version or 2,
      pid = proc.pid,
      cwd = cwd,
      socket = socket,
      started = opts.started or 0,
      session = opts.session,
    }),
  }, ("%s/%d.json"):format(run, proc.pid))
  return fake
end

---Capture vim.notify messages for the rest of the test.
function M.capture_notify()
  local messages = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    messages[#messages + 1] = { msg = msg, level = level }
  end
  M.defer(function()
    vim.notify = orig
  end)
  return messages
end

---Type keys as if from the user (mappings apply) and run them now.
function M.feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

---A separate Neovim driven over RPC: `input()` goes through the real input
---loop (insert-mode autocmds like TextChangedI fire), unlike feedkeys in -l.
function M.child()
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  local chan = vim.fn.jobstart(
    { vim.v.progpath, "--embed", "--headless", "--clean", "--cmd", "set rtp^=" .. root },
    { rpc = true }
  )
  M.defer(function()
    vim.fn.jobstop(chan)
  end)
  return {
    input = function(keys)
      vim.rpcrequest(chan, "nvim_input", keys)
    end,
    lua = function(code, ...)
      return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
    end,
  }
end

return M
