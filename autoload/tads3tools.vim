" Content-based filetype detection for .t and .h files.
" Called from ftdetect/tads3.vim so the check runs after the buffer is loaded.
function! tads3tools#detect_ft() abort
  for l:line in getline(1, 15)
    if l:line =~# '#charset\|#include\s*[<"]\|gameMain\s*:\|versionInfo\s*:\|^\s*class\s\+\w\+\s*:'
      " Use 'set filetype=' rather than 'setfiletype' because Vim's built-in
      " filetype.vim already sets .t files to 'tads' (the older TADS2 type),
      " and setfiletype is a no-op once filetype is set.  Since content
      " matching confirms this is a TADS3 file, force the correct value.
      set filetype=tads3
      return
    endif
  endfor
endfunction

" ─── vim-lsp integration (Vim 8 / Neovim without built-in LSP) ────────────

" Call this from your vimrc after the plugin is loaded:
"
"   call tads3tools#setup({
"     \ 'server_dir': expand('~/path/to/vscode-tads3tools/server'),
"     \ 'include':    '/usr/local/share/frobtads/tads3/include/',
"     \ 'lib':        '/usr/local/share/frobtads/tads3/lib/',
"   \ })
"
function! tads3tools#setup(opts) abort
  if !exists('*lsp#register_server')
    echoerr '[tads3tools] vim-lsp is required for Vim 8 support. See https://github.com/prabirshrestha/vim-lsp'
    return
  endif

  let l:server_dir = get(a:opts, 'server_dir', '')
  let l:cmd        = tads3tools#s_server_cmd(l:server_dir)
  if empty(l:cmd)
    echoerr '[tads3tools] Server not found. Set server_dir to vscode-tads3tools/server.'
    return
  endif

  " Shared state (readable from statuslines via g:tads3tools_state)
  let g:tads3tools_state = { 'parsing': 0, 'file': '', 'tracker': 0, 'total': 0 }
  let g:tads3tools_using_adv3_lite = 0
  let g:tads3tools_makefile_kvs    = []
  let g:tads3tools_preprocessed    = []

  " Expose settings for use in the on_server_init hook
  let g:tads3tools_storage_path = get(a:opts, 'storage_path',
    \ expand(stdpath('data') . '/tads3tools'))
  let g:tads3tools_settings = {
    \ 'tads3': {
    \   'include':                    get(a:opts, 'include', '/usr/local/share/frobtads/tads3/include/'),
    \   'lib':                        get(a:opts, 'lib',     '/usr/local/share/frobtads/tads3/lib/'),
    \   'enableLibraryCache':         v:false,
    \   'enablePreprocessorCodeLens': v:false,
    \   'maxNumberOfProblems':        1000,
    \ }
  \ }

  call lsp#register_server({
    \ 'name':     'tads3',
    \ 'cmd':      {_server_info -> l:cmd},
    \ 'root_uri': {_server_info ->
    \   lsp#utils#path_to_uri(
    \     lsp#utils#find_nearest_parent_file_directory(
    \       lsp#utils#get_buffer_path(), ['*.t3m', '.git']
    \     )
    \   )
    \ },
    \ 'allowlist':          ['tads3'],
    \ 'initialization_options': {},
    \ 'workspace_config':   g:tads3tools_settings,
    \ })

  augroup tads3tools_lsp
    autocmd!
    autocmd User lsp_server_init   call tads3tools#s_on_server_init()
  augroup END

  " Register handlers for server-to-client notifications
  call lsp#register_notification_handler('symbolparsing/processing',       function('tads3tools#s_on_processing'))
  call lsp#register_notification_handler('symbolparsing/success',          function('tads3tools#s_on_file_success'))
  call lsp#register_notification_handler('symbolparsing/allfiles/success', function('tads3tools#s_on_allfiles_success'))
  call lsp#register_notification_handler('symbolparsing/allfiles/failed',  function('tads3tools#s_on_allfiles_failed'))
  call lsp#register_notification_handler('response/preprocessed/list',     function('tads3tools#s_on_preprocessed_list'))
  call lsp#register_notification_handler('response/makefile/keyvaluemap',  function('tads3tools#s_on_makefile_kvmap'))
endfunction

function! tads3tools#s_on_server_init() abort
  " Send the initial parse request so the server builds its symbol table
  let l:makefile = tads3tools#s_resolve_makefile(lsp#utils#get_buffer_path())
  if empty(l:makefile)
    echom '[tads3tools] No .t3m makefile found — skipping initial parse'
    return
  endif

  call mkdir(g:tads3tools_storage_path, 'p')
  let g:tads3tools_state = { 'parsing': 1, 'file': '', 'tracker': 0, 'total': 0 }

  call lsp#send_request('tads3', {
    \ 'method':  'request/parseDocuments',
    \ 'params':  {
    \   'globalStoragePath': g:tads3tools_storage_path,
    \   'makefileLocation':  l:makefile,
    \   'filePaths':         v:null,
    \   'token':             v:null,
    \ },
    \ })
endfunction

" ─── Server notification handlers ────────────────────────────────────────────
" params: [filePath, tracker, totalFiles, poolSize, inFlightFiles?]
function! tads3tools#s_on_processing(data) abort
  let l:p = get(a:data, 'response', {})
  let l:params = get(l:p, 'params', [])
  if empty(l:params) | return | endif
  let g:tads3tools_state['parsing']  = 1
  let g:tads3tools_state['file']     = fnamemodify(l:params[0], ':t')
  let g:tads3tools_state['tracker']  = get(l:params, 1, 0)
  let g:tads3tools_state['total']    = get(l:params, 2, 0)
  redrawstatus
endfunction

function! tads3tools#s_on_file_success(data) abort
  let l:p = get(a:data, 'response', {})
  let l:params = get(l:p, 'params', [])
  if empty(l:params) | return | endif
  let g:tads3tools_state['file']    = fnamemodify(l:params[0], ':t')
  let g:tads3tools_state['tracker'] = get(l:params, 1, 0)
  let g:tads3tools_state['total']   = get(l:params, 2, 0)
  redrawstatus
endfunction

" params: { allFilePaths, elapsedTime }
function! tads3tools#s_on_allfiles_success(data) abort
  let l:p      = get(a:data, 'response', {})
  let l:params = get(l:p, 'params', {})
  let l:ms     = get(l:params, 'elapsedTime', 0)
  let l:total  = g:tads3tools_state['total']
  let g:tads3tools_state['parsing'] = 0
  let g:tads3tools_state['file']    = ''
  redrawstatus
  echom printf('[tads3tools] Parsed %d files in %d ms', l:total, l:ms)
endfunction

" params: { error } or bare array
function! tads3tools#s_on_allfiles_failed(data) abort
  let l:p      = get(a:data, 'response', {})
  let l:params = get(l:p, 'params', {})
  let g:tads3tools_state['parsing'] = 0
  let g:tads3tools_state['file']    = ''
  redrawstatus
  let l:msg = type(l:params) == v:t_dict
    \ ? get(l:params, 'error', 'unknown error')
    \ : 'unknown error'
  echohl ErrorMsg
  echom '[tads3tools] Parse failed: ' . l:msg
  echohl None
endfunction

" params: list of preprocessed file paths
function! tads3tools#s_on_preprocessed_list(data) abort
  let l:p = get(a:data, 'response', {})
  let g:tads3tools_preprocessed = get(l:p, 'params', [])
endfunction

" params: { makefileStructure: [{key,value},...], usingAdv3Lite: bool }
function! tads3tools#s_on_makefile_kvmap(data) abort
  let l:p      = get(a:data, 'response', {})
  let l:params = get(l:p, 'params', {})
  let g:tads3tools_using_adv3_lite = get(l:params, 'usingAdv3Lite', 0)
  let g:tads3tools_makefile_kvs    = get(l:params, 'makefileStructure', [])
endfunction

" Re-parse the project manually
function! tads3tools#parse() abort
  let l:makefile = tads3tools#s_resolve_makefile(lsp#utils#get_buffer_path())
  if empty(l:makefile)
    echom '[tads3tools] No .t3m makefile found'
    return
  endif
  call lsp#send_request('tads3', {
    \ 'method':  'request/parseDocuments',
    \ 'params':  {
    \   'globalStoragePath': g:tads3tools_storage_path,
    \   'makefileLocation':  l:makefile,
    \   'filePaths':         v:null,
    \   'token':             v:null,
    \ },
    \ 'on_notification': function('tads3tools#s_on_parse_response'),
    \ })
endfunction

function! tads3tools#abort_parse() abort
  call lsp#notify('tads3', {
    \ 'method': 'symbolparsing/abort',
    \ 'params': {},
    \ })
endfunction

" ─── Build and run ──────────────────────────────────────────────────────────

" Interpreter used by :Tads3Run.  Override in your vimrc if needed, e.g.:
"   let g:tads3tools_interpreter = 'qtads'
if !exists('g:tads3tools_interpreter')
  let g:tads3tools_interpreter = 'frob'
endif

" Parse the -o <file> line from a .t3m makefile and return an absolute path.
function! tads3tools#s_find_output_file(makefile) abort
  let l:dir = fnamemodify(a:makefile, ':h')
  for l:line in readfile(a:makefile)
    let l:name = matchstr(l:line, '^\s*-o\s\+\zs\S\+')
    if !empty(l:name)
      return l:name =~# '^/' ? l:name : l:dir . '/' . l:name
    endif
  endfor
  return ''
endfunction

" Run t3make from the project directory and load compiler errors into the
" quickfix list (:copen / ]q / [q to navigate them).
function! tads3tools#build() abort
  let l:makefile = tads3tools#s_resolve_makefile(expand('%:p'))
  if empty(l:makefile)
    echom '[tads3tools] No .t3m makefile found'
    return
  endif
  if !executable('t3make')
    echom '[tads3tools] t3make not found in PATH'
    return
  endif

  let l:dir           = fnamemodify(l:makefile, ':h')
  let l:saved_makeprg = &g:makeprg
  let l:saved_efm     = &g:errorformat

  let &g:makeprg = 'cd ' . shellescape(l:dir) . ' && t3make'
  " t3make emits errors in two formats:
  "   file.t(42): error T3001: message   (compiler stage)
  "   file.t, line 42: error: message    (preprocessor stage)
  let &g:errorformat = '%f(%l):\ %m,'.
        \ '%f\,\ line\ %l:\ %m'

  try
    make!
  finally
    let &g:makeprg     = l:saved_makeprg
    let &g:errorformat = l:saved_efm
  endtry
  cwindow
endfunction

" Launch the compiled game through the interpreter.
" Reads the output filename directly from the -o line in the .t3m makefile.
function! tads3tools#run() abort
  let l:makefile = tads3tools#s_resolve_makefile(expand('%:p'))
  if empty(l:makefile)
    echom '[tads3tools] No .t3m makefile found'
    return
  endif

  let l:output = tads3tools#s_find_output_file(l:makefile)
  if empty(l:output)
    echom '[tads3tools] No -o output line found in ' . fnamemodify(l:makefile, ':t')
    return
  endif

  if !filereadable(l:output)
    echom '[tads3tools] ' . fnamemodify(l:output, ':t') . ' not found — run :Tads3Build first'
    return
  endif

  execute '!' . shellescape(g:tads3tools_interpreter) . ' ' . shellescape(l:output)
endfunction

" ─── Helpers ───────────────────────────────────────────────────────────────

" Per-session cache: project root → chosen makefile path.
let s:makefile_sel = {}

" Walk up from from_path to find the project root (first directory that contains
" a *.t3m file), then return all *.t3m files in that tree, sorted shortest first.
function! tads3tools#s_find_makefiles(from_path) abort
  let l:start = isdirectory(a:from_path) ? a:from_path : fnamemodify(a:from_path, ':h')
  let l:search = l:start
  while l:search !=# fnamemodify(l:search, ':h')
    if !empty(glob(l:search . '/*.t3m', 0, 1))
      let l:all = glob(l:search . '/**/*.t3m', 0, 1)
      if empty(l:all)
        let l:all = glob(l:search . '/*.t3m', 0, 1)
      endif
      return sort(copy(l:all), {a, b -> len(a) - len(b)})
    endif
    let l:search = fnamemodify(l:search, ':h')
  endwhile
  return []
endfunction

" Return the makefile to use for from_path, prompting with inputlist() when
" multiple candidates exist.  Caches the choice per project root for the session.
function! tads3tools#s_resolve_makefile(from_path) abort
  let l:paths = tads3tools#s_find_makefiles(a:from_path)
  if empty(l:paths) | return '' | endif

  let l:root = fnamemodify(l:paths[0], ':h')
  if has_key(s:makefile_sel, l:root)
    return s:makefile_sel[l:root]
  endif

  if len(l:paths) == 1
    let s:makefile_sel[l:root] = l:paths[0]
    return l:paths[0]
  endif

  let l:menu = ['Select TADS3 makefile:']
  for l:i in range(len(l:paths))
    call add(l:menu, printf('%d. %s', l:i + 1, fnamemodify(l:paths[l:i], ':.')))
  endfor
  let l:choice = inputlist(l:menu)
  if l:choice < 1 || l:choice > len(l:paths)
    return ''
  endif
  let s:makefile_sel[l:root] = l:paths[l:choice - 1]
  return s:makefile_sel[l:root]
endfunction

" Clear the cached choice and re-prompt. Run :Tads3Parse afterwards to
" re-parse with the new selection.
function! tads3tools#select_makefile() abort
  let l:paths = tads3tools#s_find_makefiles(expand('%:p'))
  if empty(l:paths)
    echom '[tads3tools] No .t3m makefile found'
    return
  endif
  let l:root = fnamemodify(l:paths[0], ':h')
  if has_key(s:makefile_sel, l:root)
    unlet s:makefile_sel[l:root]
  endif
  let l:chosen = tads3tools#s_resolve_makefile(expand('%:p'))
  if !empty(l:chosen)
    echom '[tads3tools] Using ' . fnamemodify(l:chosen, ':.') . ' — run :Tads3Parse to re-parse'
  endif
endfunction

function! tads3tools#s_server_cmd(server_dir) abort
  " When no server_dir is given, try the default :Tads3InstallServer location.
  let l:dir = !empty(a:server_dir) ? a:server_dir : expand('~/.local/share/tads3tools')

  let l:sys  = system('uname -s')
  let l:arch = system('uname -m')

  if l:sys =~# 'Darwin'
    let l:plat = (l:arch =~# 'arm64') ? 'macos-arm64' : 'macos-x64'
    let l:ext  = ''
  elseif l:sys =~# 'Linux'
    let l:plat = (l:arch =~# 'aarch64\|arm64') ? 'linux-arm64' : 'linux-x64'
    let l:ext  = ''
  elseif l:sys =~# '[Ww]indows\|MINGW\|CYGWIN'
    let l:plat = (l:arch =~# '[Aa][Rr][Mm]') ? 'win-arm64' : 'win-x64'
    let l:ext  = '.exe'
  else
    let l:plat = ''
    let l:ext  = ''
  endif

  if !empty(l:plat)
    let l:bin = l:dir . '/bin/vscode-tads3tools-server-' . l:plat . l:ext
    if executable(l:bin)
      return [l:bin, '--stdio']
    endif
  endif

  " Fallback to Node.js.
  " Disabled: use :Tads3InstallServer to get the pre-built binary instead.
  " let l:js = l:dir . '/out/server.js'
  " if filereadable(l:js) && executable('node')
  "   return ['node', l:js, '--stdio']
  " endif

  return []
endfunction

function! tads3tools#install_server() abort
  let l:sys  = system('uname -s')
  let l:arch = system('uname -m')

  if l:sys =~# 'Darwin'
    let l:plat = (l:arch =~# 'arm64') ? 'macos-arm64' : 'macos-x64'
    let l:ext  = ''
  elseif l:sys =~# 'Linux'
    let l:plat = (l:arch =~# 'aarch64\|arm64') ? 'linux-arm64' : 'linux-x64'
    let l:ext  = ''
  elseif l:sys =~# '[Ww]indows\|MINGW\|CYGWIN'
    let l:plat = (l:arch =~# '[Aa][Rr][Mm]') ? 'win-arm64' : 'win-x64'
    let l:ext  = '.exe'
  else
    echoerr '[tads3tools] Unsupported platform: ' . l:sys
    return
  endif

  let l:name    = 'vscode-tads3tools-server-' . l:plat . l:ext
  let l:bin_dir = expand('~/.local/share/tads3tools/bin')
  let l:dest    = l:bin_dir . '/' . l:name
  let l:url     = 'https://github.com/toerob/vscode-tads3tools/releases/latest/download/' . l:name

  call mkdir(l:bin_dir, 'p')
  redraw | echomsg '[tads3tools] Downloading ' . l:name . ' …'

  call system('curl -fsSL -o ' . shellescape(l:dest) . ' ' . shellescape(l:url))
  if v:shell_error != 0
    echoerr '[tads3tools] Download failed (curl exit ' . v:shell_error . '). Check your internet connection.'
    return
  endif
  if l:sys !~# '[Ww]indows\|MINGW\|CYGWIN'
    call system('chmod +x ' . shellescape(l:dest))
  endif
  " Write a platform-independent wrapper script for coc.nvim.
  let l:wrapper = l:bin_dir . '/tads3-server'
  call writefile([
    \ '#!/bin/sh',
    \ 'dir="$(dirname "$0")"',
    \ 'for bin in "$dir"/vscode-tads3tools-server-*; do',
    \ '  [ -x "$bin" ] && exec "$bin" "$@"',
    \ 'done',
    \ 'echo "[tads3tools] No server binary found in $dir" >&2',
    \ 'exit 1',
  \ ], l:wrapper)
  call system('chmod +x ' . shellescape(l:wrapper))
  echomsg '[tads3tools] Installed to ' . l:dest
  echomsg '[tads3tools] coc.nvim command: ' . l:wrapper
  echomsg '[tads3tools] Restart Vim to start the language server.'
endfunction
