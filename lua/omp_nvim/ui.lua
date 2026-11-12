---Multi-line floating prompt editor.
local M = {}

local MAX_HEIGHT = 12

---@alias omp_nvim.Mode "submit"|"hold"

---Open the prompt editor. Keys:
---  <CR> (insert/normal)  send with the default mode
---  <M-CR>                send with the other mode (submit <-> hold)
---  <C-j> / <S-CR>        newline (insert)
---  <Esc>                 normal mode; q / <Esc> there cancels
---  <C-c>                 cancel
---@param opts { title?: string, default?: string, mode?: omp_nvim.Mode }
---@param cb fun(text: string?, mode: omp_nvim.Mode?) text is nil when cancelled or empty
function M.input(opts, cb)
  local mode = opts.mode or "submit"
  local other = mode == "submit" and "hold" or "submit"
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "omp_prompt"
  local lines = vim.split(opts.default or "", "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local function geometry()
    local height = math.min(MAX_HEIGHT, math.max(1, vim.api.nvim_buf_line_count(buf)))
    return {
      relative = "editor",
      row = math.max(0, vim.o.lines - vim.o.cmdheight - height - 3),
      col = 2,
      width = math.max(20, vim.o.columns - 6),
      height = height,
    }
  end
  local config = vim.tbl_extend("force", geometry(), {
    style = "minimal",
    border = "rounded",
    title = " " .. (opts.title or "omp") .. " ",
    title_pos = "left",
    footer = (" <CR> %s · <M-CR> %s · <C-j> newline · <C-c> cancel "):format(mode, other),
    footer_pos = "right",
  })
  local ok, win = pcall(vim.api.nvim_open_win, buf, true, config)
  if not ok then
    vim.api.nvim_buf_delete(buf, { force = true })
    return cb(nil, nil)
  end
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local done = false
  local function finish(chosen)
    if done then
      return
    end
    done = true
    local text = chosen and vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")) or ""
    vim.cmd.stopinsert()
    pcall(vim.api.nvim_win_close, win, true)
    if text == "" then
      return cb(nil, nil)
    end
    cb(text, chosen)
  end

  local map = function(modes, lhs, rhs)
    vim.keymap.set(modes, lhs, rhs, { buffer = buf, nowait = true })
  end
  map({ "i", "n" }, "<CR>", function()
    finish(mode)
  end)
  map({ "i", "n" }, "<M-CR>", function()
    finish(other)
  end)
  map("i", "<C-j>", "<CR>") -- noremap: a literal newline, not the send mapping
  map("i", "<S-CR>", "<CR>")
  map({ "i", "n" }, "<C-c>", function()
    finish(nil)
  end)
  map("n", "q", function()
    finish(nil)
  end)
  map("n", "<Esc>", function()
    finish(nil)
  end)

  local group = vim.api.nvim_create_augroup("omp_nvim_input_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      local geo = geometry()
      if not pcall(vim.api.nvim_win_set_config, win, geo) then
        return
      end
      if vim.api.nvim_buf_line_count(buf) <= geo.height then
        -- Grown to fit everything: undo the scroll from when it was shorter.
        vim.api.nvim_win_call(win, function()
          vim.fn.winrestview({ topline = 1 })
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufWipeout" }, {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        finish(nil) -- focus moved away or the window was closed externally
      end)
    end,
  })

  vim.api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
  vim.cmd.startinsert({ bang = true })
end

return M
