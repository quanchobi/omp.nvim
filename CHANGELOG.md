# Changelog

## [0.3.0] - 2026-11-12

### Features

- Buffers reload as soon as their files change on disk, mid-turn included, instead of only when an omp turn ends. Neovim watches the directory of each open file, so it needs no omp connection and also catches subagent edits, `git checkout`, and tools that replace files by renaming
- A buffer with unsaved edits is never reloaded; you get a notice instead, and Neovim's own write check still guards the newer file

### Bug Fixes

- Files omp changed were not reloaded until Neovim had sent a prompt to that omp, because the turn-end event only reaches connected clients

## [0.2.0] - 2026-11-12

First release of the [quanchobi/omp.nvim](https://github.com/quanchobi/omp.nvim) fork.

### Breaking Changes

- New bridge protocol (v2). Reinstall the bridge (`:OmpNvimInstallExtension`, or it happens on startup) and restart running omp instances; `:checkhealth omp_nvim` lists instances still on the old bridge
- `require("omp_nvim").prompt()` now resolves the target session asynchronously; it takes an optional callback instead of returning `ok, err`
- `input_dialog()` is replaced by the multi-line editor in `omp_nvim.ui`; `send_selection()` no longer takes a mode argument

### Features

- Diff context: `@hunk` (hunk under the cursor), `@diff` (this file), `@unstaged`, and `@staged`. `@hunk`/`@diff` compare the buffer, including unsaved edits, against the git index
- Diagnostics and quickfix context: `@diagnostics` (selection or whole buffer) and `@quickfix`
- Selections in non-file buffers (Neogit, diffview, scratch) are inlined instead of sent as unreadable paths
- Session discovery: every omp gets its own bridge, so several can share a directory. Neovim matches the same directory, then the nearest ancestor, then descendants, and asks when several tie; `:OmpSelect` / `<leader>ot` switches sessions
- File references are relative to the target omp's directory, not Neovim's
- Prompts sent while omp is mid-turn are queued as follow-ups instead of steering the running turn (`busy = "steer" | "aside"` to change); Neovim reports how a prompt was delivered
- Multi-line prompt editor: `<C-j>` newline, `<M-CR>` toggles send/hold, normal-mode editing; reopens with your text when a placeholder cannot resolve
- `:OmpAsk!` holds the prompt in omp's input
- Bridge installs into omp profiles and honors `PI_CONFIG_DIR` / `PI_CODING_AGENT_DIR`; `extension_dirs` overrides; symlinked (Nix/home-manager) copies are never overwritten
- `setup()` options: `auto_install`, `extension_dirs`, `keymaps`, `busy`, `reload`
- Nix flake: package, overlay, nixvim module, and home-manager module for the bridge
- New default keymaps: `<leader>oh`, `<leader>od`, `<leader>oD`, `<leader>os`, `<leader>oe`, `<leader>oq`, `<leader>ot`

### Bug Fixes

- The bridge no longer binds for subagent sessions or non-interactive omp modes

## [0.1.0] - 2026-08-08

### Features

- Bridge extension (auto-installed into `~/.omp/agent/extensions/`) that connects nvim to the omp instance running in the current directory over a per-directory Unix socket
- `:OmpAsk` with floating input dialog, line/whole-file/visual ranges, and `@this` / `@buffer` context references
- Hold mode: fill omp's input editor without submitting, press Enter there to run
- Default `<leader>oa` / `<leader>oA` keymaps (opt out with `vim.g.omp_nvim_no_keymaps`)
- Files omp changes are reloaded automatically when a turn ends (`checktime`)
- `:checkhealth omp_nvim`

### Bug Fixes

- `@this` without a selection sends the whole buffer instead of nothing
