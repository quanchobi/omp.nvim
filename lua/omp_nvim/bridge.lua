---Discovery of running omp instances and the socket transport to their bridges.
---
---Every bridge advertises itself as <run>/<pid>.json ({ version, pid, cwd,
---socket, session }). Instances are matched to nvim's cwd: same directory
---first, then the nearest ancestor (omp at the repo root, nvim in a subdir),
---then descendants (nvim at the root, omp in a subdir). Ties prompt a picker;
---the choice sticks until that omp exits or :OmpSelect picks another.
local M = {}

M.PROTOCOL = 2
local MAX_INLINE_BYTES = 900000

---@class omp_nvim.Instance
---@field pid integer
---@field cwd string
---@field socket string
---@field session string?
---@field started integer
---@field version integer
---@field rank integer? set by candidates(); lower is a closer match

function M.run_dir()
  local dir = vim.env.OMP_NVIM_RUN_DIR
  if dir and dir ~= "" then
    return dir
  end
  return vim.fs.joinpath(assert(vim.uv.os_homedir()), ".omp", "run", "omp-nvim")
end

local function alive(pid)
  local ok, _, name = vim.uv.kill(pid, 0)
  return ok == 0 or name == "EPERM"
end

local function realpath(path)
  return vim.uv.fs_realpath(path) or path
end

---Every live bridge, including ones speaking another protocol version
---(flagged `outdated`; they need their omp restarted).
---@return (omp_nvim.Instance|{ outdated: boolean })[]
function M.list_all()
  local dir = M.run_dir()
  local out = {}
  if not vim.uv.fs_stat(dir) then
    return out
  end
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("^%d+%.json$") then
      local ok, meta = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(vim.fs.joinpath(dir, name)), "\n"))
      end)
      if ok and type(meta) == "table" and type(meta.pid) == "number" and alive(meta.pid) then
        local stat = type(meta.socket) == "string" and vim.uv.fs_stat(meta.socket)
        if stat and stat.type == "socket" then
          meta.session = meta.session ~= vim.NIL and meta.session or nil
          meta.outdated = meta.version ~= M.PROTOCOL
          out[#out + 1] = meta
        end
      end
    end
  end
  return out
end

---@return omp_nvim.Instance[]
function M.list()
  return vim.tbl_filter(function(inst)
    return not inst.outdated
  end, M.list_all())
end

---Closeness of an omp cwd to the anchor directory, or nil when unrelated.
---@return integer?
local function rank(anchor, cwd)
  if cwd == anchor then
    return 0
  end
  local function depth(path)
    return select(2, path:gsub("/[^/]", ""))
  end
  local prefix = cwd == "/" and "/" or cwd .. "/"
  if vim.startswith(anchor, prefix) then
    return depth(anchor) - depth(cwd) -- ancestor: nearest first
  end
  if vim.startswith(cwd, anchor == "/" and "/" or anchor .. "/") then
    return 1000 + depth(cwd) - depth(anchor) -- descendant: after every ancestor
  end
end

---Instances related to `anchor` (default: nvim's cwd), closest first.
---@param anchor? string
---@return omp_nvim.Instance[]
function M.candidates(anchor)
  anchor = realpath(anchor or vim.fn.getcwd())
  local out = {}
  for _, inst in ipairs(M.list()) do
    inst.rank = rank(anchor, inst.cwd)
    if inst.rank then
      out[#out + 1] = inst
    end
  end
  table.sort(out, function(a, b)
    if a.rank ~= b.rank then
      return a.rank < b.rank
    end
    return a.started > b.started
  end)
  return out
end

---@param inst omp_nvim.Instance
---@return string
function M.label(inst)
  return ("%s — %s (started %s, pid %d)"):format(
    inst.session or "untitled",
    vim.fn.fnamemodify(inst.cwd, ":~"),
    os.date("%H:%M", math.floor(inst.started / 1000)),
    inst.pid
  )
end

local selected ---@type integer? pid chosen by the picker

---Pick among instances; remembers the choice.
---@param list omp_nvim.Instance[]
---@param cb fun(inst: omp_nvim.Instance?)
function M.pick(list, cb)
  vim.ui.select(list, { prompt = "omp session", format_item = M.label }, function(choice)
    if choice then
      selected = choice.pid
    end
    cb(choice)
  end)
end

---Resolve the omp to talk to. Calls back with (instance) or (nil, err);
---(nil, nil) means the user dismissed the picker.
---@param cb fun(inst: omp_nvim.Instance?, err: string?)
function M.resolve(cb)
  local list = M.candidates()
  for _, inst in ipairs(list) do
    if inst.pid == selected then
      return cb(inst)
    end
  end
  if #list == 0 then
    local elsewhere = #M.list()
    if elsewhere > 0 then
      return cb(nil, ("no omp for %s; %d running elsewhere (:OmpSelect)"):format(vim.fn.getcwd(), elsewhere))
    end
    return cb(nil, "no running omp found (is the bridge loaded? see :checkhealth omp_nvim)")
  end
  local best = vim.tbl_filter(function(inst)
    return inst.rank == list[1].rank
  end, list)
  if #best == 1 then
    return cb(best[1])
  end
  M.pick(best, cb)
end

---Interactive selection over every live omp, related ones first.
---@param cb? fun(inst: omp_nvim.Instance?)
function M.select(cb)
  local list = M.candidates()
  local seen = {}
  for _, inst in ipairs(list) do
    seen[inst.pid] = true
  end
  for _, inst in ipairs(M.list()) do
    if not seen[inst.pid] then
      list[#list + 1] = inst
    end
  end
  if #list == 0 then
    vim.notify("no running omp found", vim.log.levels.WARN, { title = "omp.nvim" })
    return
  end
  M.pick(list, cb or function() end)
end

-- Transport --------------------------------------------------------------

---@class omp_nvim.Conn
---@field pipe uv.uv_pipe_t
---@field socket string
---@field pid integer
---@field buf string
---@field connected boolean
---@field queue string[] frames written once connected
---@field pending fun(ok: boolean, info: string?)[] prompt callbacks awaiting an ack, FIFO

local conn ---@type omp_nvim.Conn?
local status_handlers = {} ---@type table<fun(event: string, frame: table), true>

---Register a handler for bridge status events: "ready" | "turn_started" |
---"turn_ended" | "prompt_accepted" (frame.delivery says how).
---@param cb fun(event: string, frame: table)
function M.on_status(cb)
  status_handlers[cb] = true
end

local function close(c, err)
  if conn == c then
    conn = nil
  end
  pcall(c.pipe.close, c.pipe)
  local pending = c.pending
  c.pending = {}
  vim.schedule(function()
    for _, cb in ipairs(pending) do
      cb(false, err or "omp closed the connection")
    end
  end)
end

local function on_frame(c, frame)
  if frame.type == "status" then
    if frame.event == "prompt_accepted" then
      local cb = table.remove(c.pending, 1)
      if cb then
        cb(true, frame.delivery)
      end
    end
    for handler in pairs(status_handlers) do
      pcall(handler, frame.event, frame)
    end
  elseif frame.type == "error" then
    local cb = table.remove(c.pending, 1)
    if cb then
      cb(false, frame.message)
    end
  end
end

local function on_read(c, err, data)
  if err or not data then
    return close(c, err)
  end
  c.buf = c.buf .. data
  local lines = vim.split(c.buf, "\n", { plain = true })
  c.buf = table.remove(lines)
  vim.schedule(function()
    for _, line in ipairs(lines) do
      local ok, frame = pcall(vim.json.decode, line)
      if ok and type(frame) == "table" then
        on_frame(c, frame)
      end
    end
  end)
end

---@param inst omp_nvim.Instance
---@return omp_nvim.Conn
local function connect(inst)
  if conn and conn.socket == inst.socket and not conn.pipe:is_closing() then
    return conn
  end
  if conn then
    close(conn)
  end
  local c = {
    pipe = assert(vim.uv.new_pipe(false)),
    socket = inst.socket,
    pid = inst.pid,
    buf = "",
    connected = false,
    queue = {},
    pending = {},
  }
  conn = c
  c.pipe:connect(inst.socket, function(err)
    if err then
      return close(c, ("cannot reach omp (pid %d): %s"):format(inst.pid, err))
    end
    c.connected = true
    c.pipe:read_start(function(read_err, data)
      on_read(c, read_err, data)
    end)
    for _, line in ipairs(c.queue) do
      c.pipe:write(line)
    end
    c.queue = {}
  end)
  return c
end

---Send a prompt to an instance.
---@param inst omp_nvim.Instance
---@param text string
---@param opts? { submit?: boolean, busy?: string }
---@param cb? fun(ok: boolean, info: string?) info: delivery on success, error otherwise
function M.prompt(inst, text, opts, cb)
  opts = opts or {}
  if #text > MAX_INLINE_BYTES then
    local file = vim.fn.tempname() .. ".md"
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), file)
    text = "The prompt is in " .. file
  end
  local c = connect(inst)
  c.pending[#c.pending + 1] = cb or function() end
  local line = vim.json.encode({
    type = "prompt",
    text = text,
    submit = opts.submit ~= false,
    busy = opts.busy or require("omp_nvim.config").options.busy,
  }) .. "\n"
  if c.connected then
    c.pipe:write(line)
  else
    c.queue[#c.queue + 1] = line
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("omp_nvim_bridge", { clear = true }),
  callback = function()
    if conn then
      pcall(conn.pipe.close, conn.pipe)
      conn = nil
    end
  end,
})

return M
