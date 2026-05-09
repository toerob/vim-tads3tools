# vim-tads3tools setup

Vim/Neovim LSP client for the [vscode-tads3tools](https://github.com/toerob/vscode-tads3tools) language server.

## Requirements

- **Neovim 0.10+** (built-in LSP) or **Vim 8.2+** with [vim-lsp](https://github.com/prabirshrestha/vim-lsp)
- The `vscode-tads3tools` repository cloned locally (for the LSP server binary)
- **Node.js 18+** only if the pre-built binary doesn't work on your platform

## Installation

### Get the server binary

The easiest way is to let the plugin download it for you. After installing the plugin, open Vim/Neovim and run:

```
:Tads3InstallServer
```

This downloads the correct binary for your platform and places it in the default location
(`{stdpath('data')}/tads3tools/bin/` for Neovim, `~/.local/share/tads3tools/bin/` for Vim).
Restart Vim/Neovim afterwards — `server_dir` does not need to be set.

**Manual alternative:** clone the full [vscode-tads3tools](https://github.com/toerob/vscode-tads3tools)
repository and point `server_dir` at its `server/` subdirectory:

```sh
git clone https://github.com/toerob/vscode-tads3tools /path/to/vscode-tads3tools
# server binaries live in /path/to/vscode-tads3tools/server/
```

### lazy.nvim

```lua
{
  'toerob/vim-tads3tools',
  -- lazy = false is required: ftdetect/tads3.vim calls tads3tools#detect_ft to
  -- identify .t/.h files, so the plugin must be on rtp before any buffer loads.
  lazy = false,
  config = function()
    require('tads3tools').setup({
      server_dir = vim.fn.expand('/path/to/vscode-tads3tools/server'),
    })
  end,
}
```

### vim-plug (Neovim)

```vim
Plug 'toerob/vim-tads3tools'
```

Then in your `init.vim`:

```vim
lua << EOF
require('tads3tools').setup({
  server_dir = '/path/to/vscode-tads3tools/server',
})
EOF
```

### Vim 8 / Vim 9 with coc.nvim

Install [coc.nvim](https://github.com/neoclide/coc.nvim) and this plugin:

```vim
Plug 'neoclide/coc.nvim', {'branch': 'release'}
Plug 'toerob/vim-tads3tools'
```

**Step 1** — Add the language server to `~/.vim/coc-settings.json`.

Using the pre-built binary (recommended):

After running `:Tads3InstallServer`, use the generated wrapper script as the `command` — it works on all platforms without needing to hardcode the binary name:

```json
{
  "languageserver": {
    "tads3": {
      "command": "~/.local/share/tads3tools/bin/tads3-server",
      "args": ["--stdio"],
      "filetypes": ["tads3"],
      "settings": {
        "tads3": {
          "include": "/usr/local/share/frobtads/tads3/include/",
          "lib":     "/usr/local/share/frobtads/tads3/lib/"
        }
      }
    }
  }
}
```

Or using Node.js (replace `command`/`args` with `module` + `transport`):

```json
{
  "languageserver": {
    "tads3": {
      "module":    "/path/to/vscode-tads3tools/server/out/server.js",
      "transport": "ipc",
      "filetypes": ["tads3"],
      "settings": {
        "tads3": {
          "include": "/usr/local/share/frobtads/tads3/include/",
          "lib":     "/usr/local/share/frobtads/tads3/lib/"
        }
      }
    }
  }
}
```

**Step 2** — Call `tads3tools#coc#setup()` from your `vimrc`:

```vim
call tads3tools#coc#setup({
  \ 'server_id':    'tads3',
  \ 'storage_path': expand('~/.local/share/vim/tads3tools'),
\ })
```

`server_id` must match the key you used in `coc-settings.json` (default: `'tads3'`).

### Vim 8 / Vim 9 with vim-lsp

First install [vim-lsp](https://github.com/prabirshrestha/vim-lsp) and, optionally,
[asyncomplete.vim](https://github.com/prabirshrestha/asyncomplete.vim) for completion support:

```vim
Plug 'prabirshrestha/async.vim'
Plug 'prabirshrestha/vim-lsp'
Plug 'prabirshrestha/asyncomplete.vim'        " optional, for completions
Plug 'prabirshrestha/asyncomplete-lsp.vim'    " optional, for completions
Plug 'toerob/vim-tads3tools'
```

Then in your `vimrc`:

```vim
call tads3tools#setup({
  \ 'server_dir': '/path/to/vscode-tads3tools/server',
\ })
```

vim-lsp does not set up keymaps automatically. Add these to your `vimrc` (or inside an
`on_attach` autocmd):

```vim
function! s:on_lsp_buffer_enabled() abort
  setlocal omnifunc=lsp#complete
  nmap <buffer> gd <Plug>(lsp-definition)
  nmap <buffer> gr <Plug>(lsp-references)
  nmap <buffer> gi <Plug>(lsp-implementation)
  nmap <buffer> K  <Plug>(lsp-hover)
  nmap <buffer> [d <Plug>(lsp-previous-diagnostic)
  nmap <buffer> ]d <Plug>(lsp-next-diagnostic)
  nmap <buffer> <leader>rn <Plug>(lsp-rename)
endfunction

augroup lsp_install
  autocmd!
  autocmd User lsp_buffer_enabled call s:on_lsp_buffer_enabled()
augroup END
```

## Configuration

All options and their defaults:

```lua
require('tads3tools').setup({
  -- Path to vscode-tads3tools/server (required)
  server_dir = nil,

  -- Server symbol cache location
  storage_path = vim.fn.stdpath('data') .. '/tads3tools',

  -- TADS3 include and library paths (match your frobtads installation)
  settings = {
    tads3 = {
      include                    = '/usr/local/share/frobtads/tads3/include/',
      lib                        = '/usr/local/share/frobtads/tads3/lib/',
      enableLibraryCache         = false,
      enablePreprocessorCodeLens = false,
      maxNumberOfProblems        = 1000,
    },
  },

  -- Filetypes that activate the server
  filetypes = { 'tads3' },

  -- Your own on_attach (runs after tads3tools' own setup)
  on_attach = nil,

  -- Extra LSP capabilities
  capabilities = nil,
})
```

### Vim 8 / Vim 9

```vim
call tads3tools#setup({
  \ 'server_dir':    '/path/to/vscode-tads3tools/server',
  \ 'include':       '/usr/local/share/frobtads/tads3/include/',
  \ 'lib':           '/usr/local/share/frobtads/tads3/lib/',
  \ 'storage_path':  expand('~/.local/share/tads3tools'),
\ })
```

| Key | Default | Description |
|-----|---------|-------------|
| `server_dir` | — | Path to `vscode-tads3tools/server` (**required**) |
| `include` | `/usr/local/share/frobtads/tads3/include/` | TADS3 include path |
| `lib` | `/usr/local/share/frobtads/tads3/lib/` | TADS3 library path |
| `storage_path` | `~/.local/share/nvim/tads3tools` | Server symbol cache directory |

### With nvim-lspconfig

If [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) is installed, `setup()` registers a
`tads3` server entry automatically and calls `lspconfig.tads3.setup(...)` internally — no extra
steps needed.

If you prefer to drive lspconfig yourself:

```lua
require('tads3tools').setup({ server_dir = '...' })

-- or, skip tads3tools' own lspconfig call and do it manually:
local cfg = require('tads3tools').lspconfig_config()
require('lspconfig.configs').tads3 = { default_config = cfg }
require('lspconfig').tads3.setup(cfg)
```

## Statusline integration

### Neovim

```lua
-- In your statusline config (lualine, heirline, etc.):
require('lualine').setup({
  sections = {
    lualine_x = { require('tads3tools').status },
  },
})

-- Or raw Vim statusline:
-- set statusline+=%{v:lua.require('tads3tools').status()}
```

`M.status()` returns `"[tads3 12/48]"` while parsing, `""` otherwise.

The full parse state is available at `require('tads3tools').state`:

| Field | Type | Description |
|-------|------|-------------|
| `parsing` | bool | `true` while a parse is running |
| `file` | string | basename of the file currently being parsed |
| `tracker` | int | files processed so far |
| `total` | int | total files in the parse job |
| `pool_size` | int | number of worker threads the server is using |
| `using_adv3_lite` | bool | `true` if the project uses adv3Lite |
| `makefile_kvs` | table | raw `{key, value}` list from the makefile |
| `preprocessed` | table | paths of all preprocessed source files |

### Vim 8 (vim-lsp)

Parse state is stored in global variables:

| Variable | Description |
|----------|-------------|
| `g:tads3tools_state` | dict with `parsing`, `file`, `tracker`, `total` |
| `g:tads3tools_using_adv3_lite` | `1` if the project uses adv3Lite |
| `g:tads3tools_makefile_kvs` | list of `{key, value}` dicts from the makefile |
| `g:tads3tools_preprocessed` | list of preprocessed file paths |

Example statusline function:

```vim
function! Tads3Status() abort
  if !exists('g:tads3tools_state') | return '' | endif
  if !g:tads3tools_state['parsing'] | return '' | endif
  return printf('[tads3 %d/%d]', g:tads3tools_state['tracker'], g:tads3tools_state['total'])
endfunction
set statusline+=%{Tads3Status()}
```

## How it works

On attach, the plugin sends a `request/parseDocuments` request to the server with
the path to the project's `.t3m` makefile. The server then preprocesses and parses all
source files and populates its symbol table. Standard LSP features (hover, completions,
go-to-definition, references, etc.) become available once parsing completes.

The server is located automatically by platform:

| Platform | Binary |
|----------|--------|
| macOS arm64 | `server/bin/vscode-tads3tools-server-macos-arm64` |
| macOS x64   | `server/bin/vscode-tads3tools-server-macos-x64`   |
| Linux x64   | `server/bin/vscode-tads3tools-server-linux-x64`   |
| Linux arm64 | `server/bin/vscode-tads3tools-server-linux-arm64` |
| Windows x64 | `server/bin/vscode-tads3tools-server-win-x64.exe` |

If the binary isn't executable, run:

```sh
chmod +x /path/to/vscode-tads3tools/server/bin/vscode-tads3tools-server-*
```

The plugin falls back to `node out/server.js --stdio` if no binary is found.

## Commands

| Command | Description |
|---------|-------------|
| `:Tads3InstallServer` | Download the server binary for your platform (run once after install) |
| `:Tads3Parse` | Re-parse the full project |
| `:Tads3AbortParse` | Cancel an in-progress parse |
| `:Tads3Build` | Compile with `t3make`; errors load into the quickfix list |
| `:Tads3Run` | Launch the compiled game (default interpreter: `frob`) |
| `:Tads3SelectMakefile` | Re-prompt which `.t3m` to use (for projects with multiple makefiles) |

## Filetype detection

`.t3m` files → `tads3makefile`  
`.t` and `.h` files → `tads3` (detected by content: `#charset`, `#include`, `gameMain:`, etc.)

If you work with Perl test files in the same editor session and `.t` detection conflicts,
override it per-project in `.vim/ftdetect/tads3.vim`:

```vim
autocmd BufRead,BufNewFile *.t setfiletype tads3
```

## Supported LSP features

The server provides:

- Hover documentation
- Completions
- Go to definition / implementation
- Find references
- Document and workspace symbols
- Code actions
- Code lens (preprocessor)
- Document formatting
- Signature help
- Call hierarchy
- Document links
