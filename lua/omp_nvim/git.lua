---Git diffs for @hunk / @diff / @staged / @unstaged.
---
---@diff and @hunk compare the *buffer* (including unsaved edits) against the
---git index, i.e. the unstaged changes as you see them in the editor.
---@staged and @unstaged run git on the whole repository (disk content).
local M = {}

local diff = vim.text and vim.text.diff or vim.diff

---@return string? stdout
---@return string? err
local function git(args, cwd)
  local ok, proc = pcall(vim.system, vim.list_extend({ "git", "--no-pager" }, args), { cwd = cwd, text = true })
  if not ok then
    return nil, "git is not available: " .. tostring(proc)
  end
  local res = proc:wait()
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or "")
  end
  return res.stdout
end

---@param dir string
---@return string? root
function M.root(dir)
  local out = git({ "rev-parse", "--show-toplevel" }, dir)
  return out and vim.trim(out) or nil
end

---Repository containing the buffer's file, else nvim's cwd.
---@param buf integer
---@return string? root
---@return string? err
function M.root_for(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local dir = vim.bo[buf].buftype == "" and name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
  if not vim.uv.fs_stat(dir) then
    dir = vim.fn.getcwd()
  end
  local root = M.root(dir)
  if not root then
    return nil, "not in a git repository: " .. dir
  end
  return root
end

---Unified diff of a buffer against the git index, with git-style headers.
---@param buf integer
---@return string? diff
---@return string? err
function M.buffer_diff(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= "" or name == "" then
    return nil, "not a file buffer"
  end
  local path = vim.uv.fs_realpath(name) or vim.fs.normalize(name)
  local root, err = M.root_for(buf)
  if not root then
    return nil, err
  end
  root = vim.uv.fs_realpath(root) or root
  local rel = path:sub(#root + 2)

  local old = git({ "show", ":" .. rel }, root)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local new = table.concat(lines, "\n")
  if not (#lines == 1 and lines[1] == "") and (vim.bo[buf].eol or vim.bo[buf].fixeol) then
    new = new .. "\n"
  end
  if old and vim.bo[buf].fileformat == "dos" then
    old = old:gsub("\r\n", "\n")
  end

  local body = diff(old or "", new, { ctxlen = 3 }) --[[@as string]]
  if body == "" then
    return nil, "no unstaged changes in " .. rel
  end
  local header = old and ("diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n"):format(rel, rel, rel, rel)
    or ("diff --git a/%s b/%s\nnew file (untracked)\n--- /dev/null\n+++ b/%s\n"):format(rel, rel, rel)
  return header .. body
end

---The hunk of buffer_diff() covering `lnum` (1-based), with headers.
---@param buf integer
---@param lnum integer
---@return string? diff
---@return string? err
function M.hunk(buf, lnum)
  local full, err = M.buffer_diff(buf)
  if not full then
    return nil, err
  end
  local header, rest = full:match("^(.-\n%+%+%+ [^\n]*\n)(.*)$")
  if rest:sub(-1) ~= "\n" then
    rest = rest .. "\n"
  end
  -- Diff body lines start with ' ', '+', '-' or '\'; only hunk headers start with '@'.
  for chunk in (rest .. "@@"):gmatch("(@@.-\n)%f[@]") do
    local start, count = chunk:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
    start, count = math.max(tonumber(start) or 0, 1), tonumber(count) or 1
    if lnum >= start and lnum <= start + math.max(count, 1) - 1 then
      return header .. chunk
    end
  end
  return nil, ("no unstaged change at line %d"):format(lnum)
end

---@param staged boolean
---@param buf integer anchors the repository
---@return string? diff
---@return string? err
function M.repo_diff(staged, buf)
  local root, err = M.root_for(buf)
  if not root then
    return nil, err
  end
  local args = { "diff", "--no-color", "--no-ext-diff" }
  if staged then
    args[#args + 1] = "--cached"
  end
  local out, git_err = git(args, root)
  if not out then
    return nil, git_err
  end
  if out == "" then
    return nil, ("no %s changes in %s"):format(staged and "staged" or "unstaged", vim.fn.fnamemodify(root, ":~"))
  end
  return out
end

return M
