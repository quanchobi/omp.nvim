local h = require("helpers")

local function committed(lines)
  local repo = h.repo()
  h.write(repo .. "/f.txt", lines)
  h.git(repo, "add", ".")
  h.git(repo, "commit", "-qm", "init")
  vim.cmd.edit(vim.fn.fnameescape(repo .. "/f.txt"))
  return repo, vim.api.nvim_get_current_buf()
end

local function render(prompt, repo, cursor)
  if cursor then
    vim.api.nvim_win_set_cursor(0, { cursor, 0 })
  end
  return require("omp_nvim.context").new():render(prompt, repo)
end

return {
  {
    "@diff shows unsaved buffer edits against the index",
    function()
      local repo, buf = committed(h.lines(5))
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "changed" })
      local text = render("@diff", repo)
      h.eq(
        table.concat({
          "Unstaged changes (editor buffer vs git index):",
          "```diff",
          "diff --git a/f.txt b/f.txt",
          "--- a/f.txt",
          "+++ b/f.txt",
          "@@ -1,5 +1,5 @@",
          " line1",
          "-line2",
          "+changed",
          " line3",
          " line4",
          " line5",
          "```",
        }, "\n"),
        text
      )
    end,
  },
  {
    "@hunk sends only the hunk under the cursor",
    function()
      local repo, buf = committed(h.lines(30))
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "early" })
      vim.api.nvim_buf_set_lines(buf, 24, 25, false, { "late" })

      local text = render("@hunk", repo, 25)
      h.truthy(text:find("+late", 1, true), text)
      h.truthy(not text:find("+early", 1, true), text)
      h.truthy(text:find("@@ -22,7 +22,7 @@", 1, true), text)

      local _, err = render("@hunk", repo, 12)
      h.eq("@hunk: no unstaged change at line 12", err)
    end,
  },
  {
    "untracked files diff against /dev/null",
    function()
      local repo = h.repo()
      vim.cmd.edit(vim.fn.fnameescape(h.write(repo .. "/new.txt", { "hello" })))
      local text = render("@diff", repo)
      h.truthy(text:find("--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+hello", 1, true), text)
    end,
  },
  {
    "@staged and @unstaged mirror git for the whole repository",
    function()
      local repo = committed(h.lines(3))
      h.write(repo .. "/f.txt", { "line1", "staged", "line3" })
      h.git(repo, "add", "f.txt")
      h.write(repo .. "/f.txt", { "line1", "staged", "unstaged" })

      local staged = render("@staged", repo)
      h.truthy(staged:find("+staged", 1, true) and not staged:find("+unstaged", 1, true), staged)
      local unstaged = render("@unstaged", repo)
      h.truthy(unstaged:find("+unstaged", 1, true) and not unstaged:find("+staged", 1, true), unstaged)

      h.git(repo, "add", "f.txt")
      local _, err = render("@unstaged", repo)
      h.truthy(err:find("^@unstaged: no unstaged changes"), err)
    end,
  },
  {
    "diffs outside a repository fail with a reason",
    function()
      vim.cmd.edit(vim.fn.fnameescape(h.write(h.tmpdir() .. "/f.txt", { "x" })))
      local _, err = render("@diff", "/")
      h.truthy(err:find("^@diff: not in a git repository"), err)
    end,
  },
}
