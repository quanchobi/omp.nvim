local h = require("helpers")

---Open the editor the way a mapping does, then type `keys`.
local function type_into(opts, keys)
  local result
  _G.omp_nvim_test_open = function()
    require("omp_nvim.ui").input(opts, function(text, mode)
      result = { text = text, mode = mode }
    end)
  end
  h.defer(function()
    _G.omp_nvim_test_open = nil
  end)
  h.feed("<Cmd>lua omp_nvim_test_open()<CR>" .. keys)
  return result
end

return {
  {
    "<C-j> inserts a newline and <CR> sends the whole prompt",
    function()
      h.eq({ text = "first\nsecond", mode = "submit" }, type_into({}, "first<C-j>second<CR>"))
    end,
  },
  {
    "the editor grows with its content and keeps the first line visible",
    function()
      local child = h.child()
      child.lua("require('omp_nvim.ui').input({}, function() end)")
      child.input("one<C-j>two<C-j>three")
      h.wait(function()
        return child.lua("return vim.api.nvim_buf_line_count(0)") == 3
      end)
      h.eq({ 3, 1 }, child.lua("return { vim.api.nvim_win_get_height(0), vim.fn.line('w0') }"))
    end,
  },
  {
    "<M-CR> sends with the other mode",
    function()
      h.eq({ text = "draft", mode = "submit" }, type_into({ mode = "hold" }, "draft<M-CR>"))
      h.eq({ text = "draft", mode = "hold" }, type_into({ mode = "hold" }, "draft<CR>"))
    end,
  },
  {
    "prefilled text can be edited in normal mode; q cancels",
    function()
      h.eq(nil, type_into({ default = "@hunk " }, "why?<Esc>"))
      h.eq({ "@hunk why?" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      h.feed("q")
      h.eq(1, #vim.api.nvim_tabpage_list_wins(0))
    end,
  },
}
