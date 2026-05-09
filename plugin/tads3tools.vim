if exists('g:loaded_tads3tools')
  finish
endif
let g:loaded_tads3tools = 1

" Neovim built-in LSP path (lua module) — users call require('tads3tools').setup()
" Vim 8 + vim-lsp path   — users call tads3tools#setup() from their vimrc
" Vim 8 + coc.nvim path  — Tads3Parse/Tads3AbortParse registered by tads3tools#coc#setup()

if has('nvim-0.10')
  command! -nargs=0 Tads3Parse           lua require('tads3tools').parse()
  command! -nargs=0 Tads3AbortParse      lua require('tads3tools').abort_parse()
  command! -nargs=0 Tads3Build           lua require('tads3tools').build()
  command! -nargs=0 Tads3Run             lua require('tads3tools').run()
  command! -nargs=0 Tads3SelectMakefile  lua require('tads3tools').select_makefile()
  command! -nargs=0 Tads3InstallServer   lua require('tads3tools').install_server()
elseif exists('*lsp#register_server') || exists('*lsp#enable')
  command! -nargs=0 Tads3Parse           call tads3tools#parse()
  command! -nargs=0 Tads3AbortParse      call tads3tools#abort_parse()
  command! -nargs=0 Tads3Build           call tads3tools#build()
  command! -nargs=0 Tads3Run             call tads3tools#run()
  command! -nargs=0 Tads3SelectMakefile  call tads3tools#select_makefile()
  command! -nargs=0 Tads3InstallServer   call tads3tools#install_server()
else
  " coc.nvim: Tads3Parse / Tads3AbortParse are registered by tads3tools#coc#setup().
  command! -nargs=0 Tads3Build           call tads3tools#build()
  command! -nargs=0 Tads3Run             call tads3tools#run()
  command! -nargs=0 Tads3SelectMakefile  call tads3tools#select_makefile()
  command! -nargs=0 Tads3InstallServer   call tads3tools#install_server()
endif
