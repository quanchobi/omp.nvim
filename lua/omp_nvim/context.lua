---Editor context snapshot and @placeholder resolution for omp prompts.
---
---State (buffer, cursor, visual range) is captured before any UI opens.
---Placeholders resolve against the *target* omp's cwd, so file references are
---relative to where omp runs, not where nvim runs.
---
---  @this        visual range (or current file)
---  @buffer      current file
---  @hunk        unstaged diff hunk under the cursor (buffer vs index)
---  @diff        unstaged diff of the current file (buffer vs index)
---  @unstaged    `git diff` of the repository
---  @staged      `git diff --cached` of the repository
---  @diagnostics diagnostics in the visual range, else the whole buffer
---  @quickfix    current quickfix list
---
---@this/@buffer send the buffer's text (unsaved edits included), fenced under
---a path header. Ranges longer than `inline_max_lines` are sent as a reference
---(`@path:5-20`) for omp to read instead, with a temp-file snapshot when the
---buffer has unsaved edits.
local Context = {}
Context.__index = Context

local git = require("omp_nvim.git")

---@class omp_nvim.Range
---@field from integer[] { line, col } 1-based; col inclusive 1-based
---@field to integer[] { line, col }
---@field kind "char" | "line" | "block"

---Fence `text` with a backtick run longer than any inside it.
---@param text string
---@param lang? string
---@return string
function Context.fence(text, lang)
  local longest = 2
  for run in text:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  local fence = ("`"):rep(longest + 1)
  return ("%s%s\n%s%s%s"):format(fence, lang or "", text, text:sub(-1) == "\n" and "" or "\n", fence)
end

---Capture the current visual selection (exits visual mode) or nil.
---@param buf integer
---@return omp_nvim.Range?
local function selection(buf)
  local mode = vim.fn.mode()
  local kind = (mode == "V" and "line") or (mode == "v" and "char") or (mode == "\22" and "block")
  if not kind then
    return nil
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
  local from = vim.api.nvim_buf_get_mark(buf, "<")
  local to = vim.api.nvim_buf_get_mark(buf, ">")
  if from[1] > to[1] or (from[1] == to[1] and from[2] > to[2]) then
    from, to = to, from
  end
  return { from = { from[1], from[2] + 1 }, to = { to[1], to[2] + 1 }, kind = kind }
end

---Snapshot the current editor state. Call while still in visual mode to
---capture the selection.
---@param range? { [1]: integer, [2]: integer } explicit line range (e.g. from :5,20OmpAsk)
---@return omp_nvim.Context
function Context.new(range)
  local self = setmetatable({}, Context)
  self.win = vim.api.nvim_get_current_win()
  self.buf = vim.api.nvim_win_get_buf(self.win)
  self.cursor = vim.api.nvim_win_get_cursor(self.win)
  if range then
    self.range = { from = { range[1], 1 }, to = { range[2], vim.v.maxcol }, kind = "line" }
  else
    self.range = selection(self.buf)
  end
  return self
end

---True when the buffer is a regular file on disk (not a plugin/scratch buffer).
local function is_file(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= "" or name == "" then
    return false
  end
  local stat = vim.uv.fs_stat(name)
  return stat ~= nil and stat.type == "file"
end

---Path as omp at `base` should see it: relative inside base, absolute outside.
---@param path string
---@param base? string
---@return string
function Context.display_path(path, base)
  path = vim.uv.fs_realpath(path) or vim.fs.normalize(path)
  if base and (vim.startswith(path, base .. "/") or base == "/") then
    return path:sub(#base + (base == "/" and 1 or 2))
  end
  return path
end

local function snapshot(buf, from, to)
  local file = vim.fn.tempname()
  vim.fn.writefile(vim.api.nvim_buf_get_lines(buf, from - 1, to, false), file)
  return file
end

---Buffer lines [from, to] as fenced text under a path header, or as a
---reference when the range exceeds `inline_max_lines`.
---@param buf integer
---@param from integer
---@param to integer
---@param base? string target omp cwd
---@param whole? boolean the range is the whole buffer (no line numbers)
---@return string
function Context.reference(buf, from, to, base, whole)
  local name = vim.api.nvim_buf_get_name(buf)
  local file = is_file(buf)
  local unsaved = file and vim.bo[buf].modified
  local label = file and Context.display_path(name, base)
    or (name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]")

  if not file or to - from + 1 <= require("omp_nvim.config").options.inline_max_lines then
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, from - 1, to, false), "\n")
    local where = whole and label or ("%s lines %d-%d"):format(label, from, to)
    return ("%s%s:\n%s"):format(where, unsaved and " (unsaved edits)" or "", Context.fence(text, vim.bo[buf].filetype))
  end

  local ref = whole and ("@" .. label) or ("@%s:%d-%d"):format(label, from, to)
  if not unsaved then
    return ref
  end
  return ("%s (unsaved buffer — exact content at %s)"):format(ref, snapshot(buf, from, to))
end

local SEVERITY = { "ERROR", "WARN", "INFO", "HINT" }

---@param base? string
---@return string? text
---@return string? err
function Context:diagnostics(base)
  local diags = vim.diagnostic.get(self.buf)
  if self.range then
    diags = vim.tbl_filter(function(d)
      return d.lnum + 1 >= self.range.from[1] and d.lnum + 1 <= self.range.to[1]
    end, diags)
  end
  local name = vim.api.nvim_buf_get_name(self.buf)
  local file = is_file(self.buf) and Context.display_path(name, base) or vim.fn.fnamemodify(name, ":t")
  if #diags == 0 then
    return nil, "no diagnostics in " .. (file ~= "" and file or "this buffer")
  end
  table.sort(diags, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return a.col < b.col
  end)
  local lines = {}
  for _, d in ipairs(diags) do
    local source = d.source and (" [%s%s]"):format(d.source, d.code and (" " .. d.code) or "") or ""
    local message = d.message:gsub("\n", "\n  ")
    lines[#lines + 1] = ("%s:%d:%d: %s: %s%s"):format(
      file,
      d.lnum + 1,
      d.col + 1,
      SEVERITY[d.severity] or "?",
      message,
      source
    )
  end
  return "Diagnostics:\n" .. Context.fence(table.concat(lines, "\n"))
end

---@param base? string
---@return string? text
---@return string? err
function Context.quickfix(base)
  local qf = vim.fn.getqflist({ items = 1, title = 1 })
  local lines = {}
  for _, item in ipairs(qf.items) do
    if item.valid == 1 then
      local name = item.bufnr > 0 and vim.api.nvim_buf_get_name(item.bufnr) or ""
      local file = name ~= "" and Context.display_path(name, base) or "?"
      lines[#lines + 1] = ("%s:%d:%d: %s"):format(file, item.lnum, item.col, vim.trim(item.text))
    end
  end
  if #lines == 0 then
    return nil, "quickfix list is empty"
  end
  local title = qf.title ~= "" and (" (" .. qf.title .. ")") or ""
  return ("Quickfix list%s:\n%s"):format(title, Context.fence(table.concat(lines, "\n")))
end

local function labeled_diff(label, text, err)
  if not text then
    return nil, err
  end
  return label .. ":\n" .. Context.fence(text, "diff")
end

---@type table<string, fun(self: omp_nvim.Context, base: string?): string?, string?>
local PLACEHOLDERS = {
  this = function(self, base)
    if self.range then
      return Context.reference(self.buf, self.range.from[1], self.range.to[1], base)
    end
    return Context.reference(self.buf, 1, vim.api.nvim_buf_line_count(self.buf), base, true)
  end,
  buffer = function(self, base)
    return Context.reference(self.buf, 1, vim.api.nvim_buf_line_count(self.buf), base, true)
  end,
  hunk = function(self)
    return labeled_diff("Unstaged hunk (editor buffer vs git index)", git.hunk(self.buf, self.cursor[1]))
  end,
  diff = function(self)
    return labeled_diff("Unstaged changes (editor buffer vs git index)", git.buffer_diff(self.buf))
  end,
  unstaged = function(self)
    return labeled_diff("Unstaged changes (git diff)", git.repo_diff(false, self.buf))
  end,
  staged = function(self)
    return labeled_diff("Staged changes (git diff --cached)", git.repo_diff(true, self.buf))
  end,
  diagnostics = Context.diagnostics,
  quickfix = function(_, base)
    return Context.quickfix(base)
  end,
}

-- `@name` not preceded by a word character or `@`, ending at a non-word character.
local PATTERN = "%f[%w_@]@(%a+)%f[^%w_]"

---True if `prompt` uses a known placeholder.
---@param prompt string
---@return boolean
function Context.has_placeholder(prompt)
  for name in prompt:gmatch(PATTERN) do
    if PLACEHOLDERS[name] then
      return true
    end
  end
  return false
end

---Resolve placeholders against the target omp's cwd. Unknown `@words` are
---left untouched; a placeholder that cannot resolve (no diff, no
---diagnostics, ...) fails the whole render so nothing half-baked is sent.
---Multi-line values (diffs, lists, inlined buffers) are placed on their own
---lines so their code fences stay valid Markdown.
---@param prompt string
---@param base? string target omp cwd
---@return string? text
---@return string? err
function Context:render(prompt, base)
  local out, pos, cache = "", 1, {}
  while true do
    local s, e, name = prompt:find(PATTERN, pos)
    if not s then
      break
    end
    out = out .. prompt:sub(pos, s - 1)
    local resolve = PLACEHOLDERS[name]
    if not resolve then
      out = out .. prompt:sub(s, e)
    else
      if cache[name] == nil then
        local value, err = resolve(self, base)
        if not value then
          return nil, ("@%s: %s"):format(name, err or "unavailable")
        end
        cache[name] = value
      end
      local value = cache[name]
      if value:find("\n", 1, true) then
        out = out:gsub("[ \t]+$", "")
        if out ~= "" and out:sub(-1) ~= "\n" then
          out = out .. "\n"
        end
        e = e + #prompt:match("^[ \t]*", e + 1)
        out = out .. value .. ((e < #prompt and prompt:sub(e + 1, e + 1) ~= "\n") and "\n" or "")
      else
        out = out .. value
      end
    end
    pos = e + 1
  end
  return out .. prompt:sub(pos)
end

return Context
