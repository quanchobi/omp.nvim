# omp.nvim

Talk to the [omp](https://omp.sh/) session running next to your editor, from Neovim. Ask about a selection,
the diff hunk under the cursor, staged changes, diagnostics, or the quickfix list. The question goes into the
live omp session you already have open; nothing new is spawned.

Fork of [l3aro/omp.nvim](https://github.com/l3aro/omp.nvim), adding diff/diagnostic context, multi-session
discovery, safe delivery while omp is busy, a multi-line prompt editor, omp profile support, and a Nix flake.
See the [changelog](CHANGELOG.md).

## Features

- Sends prompts into a running omp session (same directory, a parent, or a subdirectory of Neovim's cwd)
- Several omp sessions? Neovim asks which one and remembers your choice (`:OmpSelect` to switch)
- Context placeholders: `@this`, `@buffer`, `@hunk`, `@diff`, `@unstaged`, `@staged`, `@diagnostics`, `@quickfix`
- Diffs include unsaved edits (buffer vs git index)
- Prompts sent while omp is working wait for the current turn instead of interrupting it
- Hold mode: drop the prompt into omp's input box and press Enter there yourself
- Multi-line prompt editor with normal-mode editing
- Files omp changed are reloaded when its turn ends
- Bridge extension installs itself into omp's extension directories, including named profiles

## Requirements

- Neovim 0.11+
- omp
- git (for the diff placeholders)

## Install

<details open>
<summary><a href="https://github.com/folke/lazy.nvim">lazy.nvim</a></summary>

```lua
{
  "quanchobi/omp.nvim",
  opts = {}, -- see Configuration
}
```

</details>

<details>
<summary>vim.pack</summary>

```lua
vim.pack.add({ "https://github.com/quanchobi/omp.nvim" })
require("omp_nvim").setup({})
```

</details>

<details>
<summary>Nix (flake)</summary>

```nix
inputs.omp-nvim.url = "github:quanchobi/omp.nvim";
```

The flake provides:

| Output                         | Use                                                              |
| ------------------------------ | ---------------------------------------------------------------- |
| `nixvimModules.default`        | `plugins.omp-nvim = { enable = true; settings = { ... }; };`     |
| `homeModules.default`          | `programs.omp-nvim.enable = true;` installs the bridge extension |
| `overlays.default`             | adds `pkgs.vimPlugins.omp-nvim`                                  |
| `packages.<system>.default`    | the plugin                                                       |

With Nix managing the bridge, turn off the plugin's own install:

```nix
# nixvim
imports = [ inputs.omp-nvim.nixvimModules.default ];
plugins.omp-nvim = {
  enable = true;
  settings.auto_install = false;
};

# home-manager
imports = [ inputs.omp-nvim.homeModules.default ];
programs.omp-nvim = {
  enable = true;
  profiles = [ "work" ]; # named omp profiles that should load it too
};
```

Even with `auto_install` on, symlinked copies (what home-manager creates) are never overwritten.

</details>

> [!TIP]
> Run `:checkhealth omp_nvim` after setup. It lists install targets, running omp sessions, and which one Neovim
> would talk to from the current directory.

## The bridge extension

omp loads a small bridge (`extension/omp-nvim-bridge.ts`) that accepts prompts from Neovim. The plugin copies
it into every extension directory omp reads, on startup and with `:OmpNvimInstallExtension`:

- the default agent dir: `~/.omp/agent/extensions`, or `$PI_CODING_AGENT_DIR/extensions`, or
  `~/$PI_CONFIG_DIR/agent/extensions`
- every named profile: `~/.omp/profiles/<name>/agent/extensions`

Set `extension_dirs` to replace detection. Restart running omp instances after the bridge is installed or
updated; omp loads extensions at startup.

## Usage

### Asking

`<leader>oa` opens the prompt editor at the bottom of the screen. Its title names the omp session it will
reach. In visual mode the selection is attached automatically unless the prompt already uses a placeholder.

| Key (in the editor)   | Action                                          |
| --------------------- | ----------------------------------------------- |
| `<CR>`                | send (or hold, if opened with `<leader>oA`)     |
| `<M-CR>`              | the other one: hold instead of send, or vice versa |
| `<C-j>` / `<S-CR>`    | newline                                         |
| `<Esc>`               | normal mode; `q` or `<Esc>` there cancels       |
| `<C-c>`               | cancel                                          |

If a placeholder can't resolve (no diff under the cursor, no diagnostics, ...), you get a warning and the
editor reopens with your text.

**Hold** puts the prompt into omp's input box without sending it, so you can add to it there and press Enter
yourself.

### Commands

| Command                    | Sends                                                     |
| -------------------------- | --------------------------------------------------------- |
| `:OmpAsk`                  | opens the prompt editor                                   |
| `:OmpAsk text`             | `text`, with placeholders resolved                        |
| `:5,20OmpAsk [text]`       | lines 5–20 of the current file, with optional instruction |
| `:'<,'>OmpAsk [text]`      | the last visual range                                     |
| `:OmpAsk! ...`             | any of the above, held in omp's input instead of sent     |
| `:OmpSelect`               | choose which omp session to talk to                       |
| `:OmpNvimInstallExtension` | (re)install the bridge                                    |

### Placeholders

| Placeholder    | Becomes                                                                   |
| -------------- | ------------------------------------------------------------------------- |
| `@this`        | the visual range (`@path:5-20`), else the current file                    |
| `@buffer`      | the current file (`@path`)                                                |
| `@hunk`        | the unstaged diff hunk under the cursor                                   |
| `@diff`        | this file's unstaged diff                                                 |
| `@unstaged`    | `git diff` for the whole repository                                       |
| `@staged`      | `git diff --cached` for the whole repository                              |
| `@diagnostics` | diagnostics in the visual range, else the whole buffer                    |
| `@quickfix`    | the current quickfix list                                                 |

- Saved files are sent as references (`@path:5-20`) that omp reads itself. Paths are relative to the omp
  session's directory, or absolute outside it.
- A file with unsaved edits also gets a temp-file snapshot, so omp never reads stale content.
- Buffers that aren't files on disk (Neogit, diffview, scratch buffers) are inlined, so selecting lines in a
  Neogit status or diff view works.
- `@hunk` and `@diff` compare the buffer, unsaved edits included, against the git index: the same unstaged
  changes gitsigns shows. `@staged` and `@unstaged` run git on the repository as saved on disk.
- Diffs and lists are fenced and placed on their own lines.

### Which omp session?

Every running omp advertises itself, and Neovim picks one by its directory relative to `:pwd`:

1. an omp in the same directory
2. the nearest parent directory (omp at the repo root, Neovim in a subdirectory)
3. a subdirectory (Neovim at the root, omp in a subdirectory)

When several tie, for example two omp sessions in one repo, Neovim asks once and remembers the choice until
that omp exits. `:OmpSelect` (`<leader>ot`) switches at any time and also lists unrelated sessions.

### When omp is busy

A prompt sent mid-turn would normally *steer* the running turn. omp.nvim instead queues it as a follow-up
that runs when the turn ends, and tells you. Set `busy = "steer"` to interrupt, or `busy = "aside"` to inject
it at the next step without stopping the current tool calls.

### Keymaps

| Key          | Mode | Action                                      |
| ------------ | ---- | ------------------------------------------- |
| `<leader>oa` | n, x | ask (x: about the selection)                |
| `<leader>oA` | n, x | ask, hold in omp's input                    |
| `<leader>oh` | n    | ask about the hunk under the cursor         |
| `<leader>od` | n    | ask about this file's unstaged changes      |
| `<leader>oD` | n    | ask about all unstaged changes              |
| `<leader>os` | n    | ask about staged changes                    |
| `<leader>oe` | n, x | ask about diagnostics                       |
| `<leader>oq` | n    | ask about the quickfix list                 |
| `<leader>ot` | n    | choose the omp session                      |

The diff/diagnostic keys open the editor prefilled with the placeholder; type your question after it.

## Configuration

Defaults, passed to `setup()` or set as `vim.g.omp_nvim` before the plugin loads:

```lua
require("omp_nvim").setup({
  auto_install = true,   -- install/refresh the bridge on startup
  extension_dirs = nil,  -- list of dirs to install into; nil detects omp's agent dirs and profiles
  keymaps = true,        -- default <leader>o* keymaps
  busy = "followUp",     -- delivery while omp is mid-turn: "followUp" | "steer" | "aside"
  reload = true,         -- :checktime when an omp turn ends
})
```

`vim.g.omp_nvim_no_keymaps = true` also disables the keymaps.

## API

```lua
local omp = require("omp_nvim")

omp.ask()                                  -- prompt editor; attaches the selection in visual mode
omp.ask({ default = "@hunk ", hold = true })
omp.prompt("Review the error handling")    -- verbatim, no placeholders
omp.prompt("Draft", { submit = false })    -- hold in omp's input
omp.send_range(5, 20, "Explain this")      -- file lines 5-20 + instruction
omp.send_selection("Explain this")         -- last visual selection
omp.select()                               -- choose the omp session
```

Status events from the connected session:

```lua
require("omp_nvim.bridge").on_status(function(event, frame)
  -- "ready" | "turn_started" | "turn_ended" | "prompt_accepted" (frame.delivery)
end)
```

## How it works

Each interactive omp loads the bridge, which listens on `~/.omp/run/omp-nvim/<pid>.sock` and describes
itself in `<pid>.json` (directory, session title, protocol version). Subagents and non-interactive omp modes
don't bind. Neovim reads the metadata, picks a session, and sends JSONL prompt frames. The bridge checks
whether omp is mid-turn and delivers through omp's extension API: start a turn, queue a follow-up, steer, or
fill the input box. It removes its files when omp exits. `OMP_NVIM_RUN_DIR` overrides the directory for
both sides.

## Development

```sh
nix develop          # neovim, bun, git, stylua, luacheck
nvim --headless --clean -l tests/run.lua   # Lua tests
bun test tests/bridge.test.ts              # bridge tests
nix flake check      # everything, as CI runs it
```

## License

[MIT](LICENSE) © [l3aro](https://github.com/l3aro), [quanchobi](https://github.com/quanchobi)
