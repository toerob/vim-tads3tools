# vim-tads3tools

Vim/Neovim LSP client for the [vscode-tads3tools](https://github.com/toerob/vscode-tads3tools)
TADS3 language server. Provides hover, completions, go-to-definition, find references, and
parse-progress feedback for TADS3 projects.

## Documentation

- **[SETUP.md](SETUP.md)** — Full installation and configuration reference for all three
  supported setups: Neovim 0.10+ (built-in LSP), Vim 8/9 + coc.nvim, and Vim 8/9 + vim-lsp.

- **[QUICKSTART.md](QUICKSTART.md)** — Step-by-step guide for getting started quickly with
  Vim 8/9 and coc.nvim, including LSP keymaps and statusline integration.

- **[example-vimrc-config](example-vimrc-config)** — A working `~/.vimrc` showing the
  coc.nvim setup with keymaps, Vista integration, and colorscheme settings.

- **[example-nvim-config](example-nvim-config)** — The equivalent `~/.config/nvim/init.lua`
  for Neovim: lazy.nvim, built-in LSP, nvim-cmp completions, aerial.nvim symbols sidebar.

## Quick install (Neovim, lazy.nvim)

```lua
{
  'toerob/vim-tads3tools',
  lazy = false,
  config = function()
    require('tads3tools').setup()
  end,
}
```

Then run `:Tads3InstallServer` once to download the server binary. Restart Neovim and open a `.t` file.

## Quick install (Vim 8/9, coc.nvim)

```vim
Plug 'neoclide/coc.nvim', {'branch': 'release'}
Plug 'toerob/vim-tads3tools'
```

Run `:Tads3InstallServer` once after installing. See [QUICKSTART.md](QUICKSTART.md) for the full coc-settings.json and vimrc setup.

## Commands

| Command | Description |
|---------|-------------|
| `:Tads3InstallServer` | Download the server binary for your platform (run once after install) |
| `:Tads3Parse` | Re-parse the full project |
| `:Tads3AbortParse` | Cancel an in-progress parse |
| `:Tads3Build` | Compile with `t3make`; errors load into the quickfix list |
| `:Tads3Run` | Launch the compiled game (default interpreter: `frob`) |
| `:Tads3SelectMakefile` | Choose which `.t3m` to use (for projects with multiple makefiles) |

## Requirements

- **Neovim 0.10+** or **Vim 8.2+**
- The [vscode-tads3tools](https://github.com/toerob/vscode-tads3tools) repository cloned locally
- **Node.js 18+** (only if the pre-built server binary is unavailable for your platform)
