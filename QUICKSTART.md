# Quick-start: Vim 8 / Vim 9 + coc.nvim

This covers the minimum steps to get hover, completions, go-to-definition, and
parse-progress messages working in terminal Vim on macOS or Linux using
[coc.nvim](https://github.com/neoclide/coc.nvim).

---

## 1. Prerequisites

| Requirement | Check |
|-------------|-------|
| Vim 8.2 or 9.x (terminal build) | `vim --version \| head -1` |
| Node.js 18 or later | `node --version` |
| [vim-plug](https://github.com/junegunn/vim-plug) installed | `~/.vim/autoload/plug.vim` exists |

---

## 2. Get the language server binary

The plugin can download the correct binary for your platform automatically.
After completing step 3 (plugin install), open Vim and run:

```
:Tads3InstallServer
```

The binary is saved to `~/.local/share/tads3tools/bin/` and is picked up automatically
on restart — no `server_dir` configuration needed.

**Manual alternative:** download the binary for your platform from the
[vscode-tads3tools releases page](https://github.com/toerob/vscode-tads3tools/releases/latest),
place it in `~/.local/share/tads3tools/bin/`, and make it executable:

```sh
mkdir -p ~/.local/share/tads3tools/bin
chmod +x ~/.local/share/tads3tools/bin/vscode-tads3tools-server-*
```

---

## 3. Install the plugins

Add these two lines to the `call plug#begin()` / `call plug#end()` block in your `~/.vimrc`:

```vim
Plug 'neoclide/coc.nvim', {'branch': 'release'}
Plug 'toerob/vim-tads3tools'
```

Run `:PlugInstall` in Vim, then quit and re-open Vim.

---

## 4. Configure coc-settings.json

Open the file (create it if it doesn't exist):

```
~/.vim/coc-settings.json
```

Add the `tads3` entry inside `languageserver`. Replace the `command` path and the
`include` / `lib` paths to match your system:

After running `:Tads3InstallServer` (step 3), use the generated wrapper script as the `command`:

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

> **Two things that are easy to get wrong:**
>
> - `"filetypes"` must be `["tads3"]`, not `["tads"]`. Vim's built-in detection
>   sets `.t` files to the older `tads` type; this plugin overrides that, but only
>   if coc is told to watch for `tads3`.
>
> - The keys inside `"settings": { "tads3": { ... } }` must **not** have a `tads3.`
>   prefix. Write `"include"`, not `"tads3.include"`.

---

## 5. Add the setup call to your vimrc

Paste this **after** `call plug#end()` in `~/.vimrc`. Adjust `storage_path` if you
want the symbol cache somewhere other than the default:

```vim
call plug#begin()
  Plug 'neoclide/coc.nvim', {'branch': 'release'}
  Plug 'toerob/vim-tads3tools'
call plug#end()

call tads3tools#coc#setup({
  \ 'server_id':    'tads3',
  \ 'storage_path': expand('~/.local/share/vim/tads3tools'),
\ })
```

> **Important:** call `tads3tools#coc#setup()` directly after `plug#end()` — not
> inside an `autocmd User CocNvimInit`. Putting it inside CocNvimInit means it runs
> too late: the FileType event for a file opened on the command line (`vim file.t`)
> fires before CocNvimInit, so the auto-parse is never triggered.

---

## 6. Verify it works

1. Open a TADS3 project file: `vim mygame.t`
2. After about 2–3 seconds you should see a message like:

   ```
   [tads3tools] Parsed 71 files in 2387 ms
   ```

3. Move the cursor onto a class name or function and press `K` — you should get a
   hover pop-up from the server.

If you don't see the message after a few seconds, run `:Tads3Parse` manually to
trigger a parse and watch for errors. `:messages` shows the full message history.

---

## 7. Optional: show parse progress in the status line

Add a helper function to your `~/.vimrc`:

```vim
function! Tads3Status() abort
  if !exists('g:tads3tools_state') | return '' | endif
  if !g:tads3tools_state['parsing']  | return '' | endif
  return printf('[tads3 %d/%d]', g:tads3tools_state['tracker'], g:tads3tools_state['total'])
endfunction

set statusline+=%{Tads3Status()}
```

While parsing you'll see `[tads3 12/71]` in the status line, updating file by file.

---

## 8. Keymaps for LSP features

coc.nvim does not add any keymaps by default — you have to add them yourself.
Paste this block into your `~/.vimrc` (outside any function):

```vim
" Only add these mappings in buffers where the LSP is active.
autocmd FileType tads3 call s:tads3_lsp_maps()
function! s:tads3_lsp_maps() abort

  " ── Navigation ───────────────────────────────────────────────────────────
  " Jump to where a symbol is defined.
  nmap <buffer> gd <Plug>(coc-definition)

  " Jump to where a symbol is implemented (class body, not just the declaration).
  nmap <buffer> gi <Plug>(coc-implementation)

  " List every place a symbol is used.
  nmap <buffer> gr <Plug>(coc-references)

  " ── Documentation ────────────────────────────────────────────────────────
  " Show documentation / type info for the symbol under the cursor.
  " Pressing K a second time moves the cursor into the pop-up so you can scroll.
  nnoremap <buffer> K :call CocActionAsync('doHover')<CR>

  " Show the function signature (parameter hints) while typing a call.
  inoremap <buffer> <C-k> <C-r>=CocActionAsync('showSignatureHelp')<CR>

  " ── Rename (NOT SUPPORTED YET) ───────────────────────────────────────────
  " Rename a symbol across the whole project.
  nmap <buffer> <leader>rn <Plug>(coc-rename)

  " ── Code actions ─────────────────────────────────────────────────────────
  " Show available fixes or refactors for the current line or selection.
  nmap <buffer> <leader>ca <Plug>(coc-codeaction-line)
  xmap <buffer> <leader>ca <Plug>(coc-codeaction-selected)

  " ── Diagnostics (errors and warnings) ────────────────────────────────────
  " Jump to the previous / next diagnostic message in the file.
  nmap <buffer> [d <Plug>(coc-diagnostic-prev)
  nmap <buffer> ]d <Plug>(coc-diagnostic-next)

  " Show the full diagnostic message for the current line in a floating window.
  nmap <buffer> <leader>e :call CocActionAsync('diagnosticInfo')<CR>

  " ── Links ────────────────────────────────────────────────────────────────
  " Open the file linked on the current line (e.g. an #include path).
  " Falls back to the full link list if the cursor isn't on a link.
  nmap <buffer> gl :call tads3tools#coc#follow_link()<CR>

endfunction
```

### Completion

coc.nvim shows a pop-up automatically as you type. To confirm a suggestion with
`<Tab>` and dismiss with `<Esc>`, add:

```vim
inoremap <silent><expr> <Tab>
  \ coc#pum#visible() ? coc#pum#next(1) : "\<Tab>"
inoremap <silent><expr> <S-Tab>
  \ coc#pum#visible() ? coc#pum#prev(1) : "\<S-Tab>"
inoremap <silent><expr> <CR>
  \ coc#pum#visible() ? coc#pum#confirm() : "\<CR>"
```

### Searching symbols

These work anywhere (not just in TADS3 files) once the server is running:

| Command | What it does |
|---------|--------------|
| `:CocList symbols` | Search all symbols in the current file |
| `:CocList outline` | Browse the structure of the current file |
| `:CocList -I symbols` | Search symbols across the whole workspace |

---

## Commands

| Command | What it does |
|---------|--------------|
| `:Tads3InstallServer` | Download the server binary for your platform (run once after install) |
| `:Tads3Parse` | Re-parse the whole project (e.g. after adding source files) |
| `:Tads3AbortParse` | Cancel a parse that's taking too long |
| `:Tads3Build` | Compile with `t3make`; errors load into the quickfix list |
| `:Tads3Run` | Launch the compiled game (default interpreter: `frob`) |
| `:Tads3SelectMakefile` | Re-prompt which `.t3m` to use (for projects with multiple makefiles) |
