" coc.nvim integration for vim-tads3tools.
"
" The language server is configured in coc-settings.json (see SETUP.md).
" Call tads3tools#coc#setup({}) from your vimrc after plug#end().

" Tracks which project roots have already triggered an initial parse this
" session, so opening a second tads3 file in the same project doesn't
" re-send request/parseDocuments.
let s:parsed_roots = {}

" ─── Public API ───────────────────────────────────────────────────────────────

" Main entry point. Call this from your vimrc after plug#end():
"
"   call tads3tools#coc#setup({
"     \ 'server_id':    'tads3',
"     \ 'storage_path': expand('~/.local/share/vim/tads3tools'),
"   \ })
"
" Setup has two phases so that 'vim file.t' on the command line works:
"
"   Phase 1 (immediate) — state variables, FileType/DirChanged autocmds, and
"   :Tads3* commands are registered right away.  This is necessary because
"   when Vim is invoked as 'vim file.t' the FileType event fires as the file
"   loads — before CocNvimInit ever fires — so if we waited for CocNvimInit
"   for everything, that first FileType event would be missed entirely.
"
"   Phase 2 (deferred) — coc#on_notify wires notification handlers into
"   coc's internal registry.  coc#on_notify itself is safe to call any time
"   after coc.nvim is in &rtp (it just writes to a Vim dict), but we check
"   whether the autoload function is already reachable and fall back to
"   CocNvimInit if not, so the code is robust regardless of load order.
function! tads3tools#coc#setup(opts) abort
  " Store options globally so parse/abort functions can read them without
  " needing them passed as arguments every call.
  let g:tads3tools_coc_opts = {
    \ 'server_id':    get(a:opts, 'server_id',    'tads3'),
    \ 'storage_path': get(a:opts, 'storage_path', expand('~/.local/share/vim/tads3tools')),
  \ }

  " Ensure the wrapper script exists so coc.nvim can always spawn it without
  " an ENOENT error.  When no binary is installed yet the wrapper exits with a
  " clear message rather than failing to spawn entirely.
  let l:bin_dir = expand('~/.local/share/tads3tools/bin')
  let l:wrapper = l:bin_dir . '/tads3-server'
  if !filereadable(l:wrapper)
    call mkdir(l:bin_dir, 'p')
    call writefile([
      \ '#!/bin/sh',
      \ 'dir="$(dirname "$0")"',
      \ 'for bin in "$dir"/vscode-tads3tools-server-*; do',
      \ '  [ -x "$bin" ] && exec "$bin" "$@"',
      \ 'done',
      \ 'echo "[tads3tools] Server binary not found. Run :Tads3InstallServer in Vim." >&2',
      \ 'exit 1',
    \ ], l:wrapper)
    call system('chmod +x ' . shellescape(l:wrapper))
  endif

  " Initialize shared state (same keys as the Neovim M.state table so
  " statusline snippets work identically across both integrations).
  let g:tads3tools_state           = { 'parsing': 0, 'file': '', 'tracker': 0, 'total': 0 }
  let g:tads3tools_using_adv3_lite = 0
  let g:tads3tools_makefile_kvs    = []
  let g:tads3tools_preprocessed    = []

  " Register editor commands (same names as the Neovim integration).
  command! -nargs=0 Tads3Parse      call tads3tools#coc#parse()
  command! -nargs=0 Tads3AbortParse call tads3tools#coc#abort_parse()

  " Phase 1 — register autocmds immediately.
  "
  " augroup wraps a set of autocmds under a named label.  The 'autocmd!'
  " inside the group clears any previously registered autocmds in that group,
  " which prevents duplicates if setup() is called more than once (e.g. after
  " :source ~/.vimrc).
  "
  " timer_start(delay, callback) schedules a one-shot call 1500 ms later.
  " The lambda '{_ -> expr}' is Vim's anonymous-function syntax; _ discards
  " the timer-id argument that Vim passes automatically.  The delay gives
  " coc.nvim time to start its Node.js process before we send a request.
  augroup tads3tools_coc
    autocmd!
    autocmd FileType  tads3 call timer_start(1500, {_ -> tads3tools#coc#s_auto_parse()})
    autocmd DirChanged  *   call timer_start(1500, {_ -> tads3tools#coc#s_auto_parse()})
  augroup END

  " Phase 2 — wire coc#on_notify handlers.
  "
  " coc#on_notify stores the Vim-side callback AND sends a 'registerNotification'
  " message to coc's Node.js process so it knows to route that server
  " notification back to Vim.  coc#rpc#notify silently drops messages when the
  " RPC channel isn't open yet, so calling coc#on_notify too early stores the
  " callback but leaves the Node.js process unaware — notifications never arrive.
  "
  " coc#rpc#ready() returns 1 once the channel is open (i.e. after CocNvimInit).
  " If it's already open (e.g. setup() is called via :source after startup),
  " register immediately; otherwise defer to CocNvimInit.
  if coc#rpc#ready()
    call tads3tools#coc#s_register_notifications()
  else
    augroup tads3tools_coc_notify
      autocmd!
      autocmd User CocNvimInit call tads3tools#coc#s_register_notifications()
    augroup END
  endif
endfunction

" Send request/parseDocuments for the current buffer's project.
" Can also be called via :Tads3Parse.
function! tads3tools#coc#parse() abort
  if !exists('*CocRequestAsync')
    echoerr '[tads3tools] coc.nvim is required. See https://github.com/neoclide/coc.nvim'
    return
  endif

  if empty(tads3tools#s_server_cmd(''))
    let l:choice = confirm('[tads3tools] Server binary not found.', "&Install now\n&Cancel", 1)
    if l:choice == 1
      call tads3tools#install_server()
    endif
    return
  endif

  let l:makefile = tads3tools#s_resolve_makefile(expand('%:p'))
  if empty(l:makefile)
    echom '[tads3tools] No .t3m makefile found'
    return
  endif

  let l:opts         = get(g:, 'tads3tools_coc_opts', {})
  let l:server_id    = get(l:opts, 'server_id',    'tads3')
  let l:storage_path = get(l:opts, 'storage_path', expand('~/.local/share/vim/tads3tools'))

  " Ensure notification handlers are wired before the request goes out.
  " coc#on_notify is idempotent (later calls overwrite the same key), so
  " calling this here is safe even if CocNvimInit already registered them.
  " The critical guarantee: by the time CocRequestAsync runs below, the
  " RPC channel is open and registerNotification reaches Node.js.
  call tads3tools#coc#s_register_notifications()

  " 'p' flag creates all intermediate directories, like mkdir -p.
  call mkdir(l:storage_path, 'p')
  let g:tads3tools_state['parsing'] = 1

  " CocRequestAsync(server_id, method, params) sends an LSP request without
  " blocking the editor. The server will start parsing and send progress
  " notifications back as it goes.
  "
  " filePaths and token are intentionally omitted: the server checks
  " 'filePaths === undefined' to trigger the parse-all code path.
  " Sending v:null serialises to JSON null, which is not === undefined,
  " so the server would skip the branch and crash on null.length.
  call CocRequestAsync(l:server_id, 'request/parseDocuments', {
    \ 'globalStoragePath': l:storage_path,
    \ 'makefileLocation':  l:makefile,
  \ })
endfunction

" Abort an in-progress parse operation.
" CocNotify(server_id, method, params) sends a fire-and-forget LSP
" notification — no response is expected from the server.
function! tads3tools#coc#abort_parse() abort
  let l:server_id = get(get(g:, 'tads3tools_coc_opts', {}), 'server_id', 'tads3')
  call CocNotify(l:server_id, 'symbolparsing/abort', {})
  let g:tads3tools_state['parsing'] = 0
  redrawstatus
endfunction

" Open the document link on the current line, falling back to the full
" CocList links view if the cursor isn't on a link.
" Uses the LSP textDocument/documentLink request directly — the same data
" source that :CocList links uses — so no extra server support is needed.
function! tads3tools#coc#follow_link() abort
  let l:server_id = get(get(g:, 'tads3tools_coc_opts', {}), 'server_id', 'tads3')
  let l:uri = 'file://' . expand('%:p')

  try
    let l:links = CocRequest(l:server_id, 'textDocument/documentLink',
          \ {'textDocument': {'uri': l:uri}})
  catch
    CocList links
    return
  endtry

  if type(l:links) != v:t_list || empty(l:links)
    CocList links
    return
  endif

  let l:lnum = line('.') - 1
  for l:link in l:links
    if l:link['range']['start']['line'] == l:lnum
      let l:target = get(l:link, 'target', '')
      if !empty(l:target)
        let l:path = substitute(l:target, '^file://', '', '')
        execute 'edit ' . fnameescape(l:path)
        return
      endif
    endif
  endfor

  CocList links
endfunction

" ─── Private ──────────────────────────────────────────────────────────────────

" Register server-to-client notification handlers with coc.nvim.
" Extracted so it can be called either immediately (if coc is ready) or
" deferred to CocNvimInit.
"
" Uses CocRegisterNotification (defined in plugin/coc.vim, always available
" after plug#end()) rather than coc#on_notify directly.  coc#on_notify lives
" in autoload/coc.vim which is NOT pre-loaded; exists('*coc#on_notify') would
" return 0 until something else loads that file, causing a silent no-op.
" CocRegisterNotification is a plugin-level wrapper that is always present.
"
" server_id must match the key used in coc-settings.json languageserver block.
function! tads3tools#coc#s_register_notifications() abort
  if !exists('*CocRegisterNotification') | return | endif
  let l:server_id = get(get(g:, 'tads3tools_coc_opts', {}), 'server_id', 'tads3')
  call CocRegisterNotification(l:server_id, 'symbolparsing/processing',       function('tads3tools#coc#s_on_processing'))
  call CocRegisterNotification(l:server_id, 'symbolparsing/success',          function('tads3tools#coc#s_on_file_success'))
  call CocRegisterNotification(l:server_id, 'symbolparsing/allfiles/success', function('tads3tools#coc#s_on_allfiles_success'))
  call CocRegisterNotification(l:server_id, 'symbolparsing/allfiles/failed',  function('tads3tools#coc#s_on_allfiles_failed'))
  call CocRegisterNotification(l:server_id, 'response/preprocessed/list',     function('tads3tools#coc#s_on_preprocessed_list'))
  call CocRegisterNotification(l:server_id, 'response/makefile/keyvaluemap',  function('tads3tools#coc#s_on_makefile_kvmap'))
endfunction

" Called 1500 ms after a FileType or DirChanged event fires.
" Parses each project root at most once per Vim session.
"
" Search order:
"   1. Walk up from the current buffer's path (normal file-open case).
"   2. Fall back to walking up from getcwd() — covers opening Vim as
"      'vim .' or 'vim' from inside a project directory, and :cd into a
"      project root before opening any file.
function! tads3tools#coc#s_auto_parse() abort
  if empty(tads3tools#s_server_cmd(''))
    let l:choice = confirm('[tads3tools] Server binary not found.', "&Install now\n&Cancel", 1)
    if l:choice == 1
      call tads3tools#install_server()
    endif
    return
  endif

  let l:makefile = tads3tools#s_resolve_makefile(expand('%:p'))
  if empty(l:makefile)
    let l:makefile = tads3tools#s_resolve_makefile(getcwd())
  endif
  if empty(l:makefile) | return | endif

  let l:root = fnamemodify(l:makefile, ':h')
  if has_key(s:parsed_roots, l:root) | return | endif
  let s:parsed_roots[l:root] = 1

  call tads3tools#coc#parse()
endfunction

" ─── Notification handlers ────────────────────────────────────────────────────
" coc.nvim passes the notification params directly as the sole argument.

" params: [filePath, tracker, totalFiles, poolSize, inFlightFiles?]
function! tads3tools#coc#s_on_processing(params) abort
  if empty(a:params) | return | endif
  let g:tads3tools_state['parsing']  = 1
  let g:tads3tools_state['file']     = fnamemodify(get(a:params, 0, ''), ':t')
  let g:tads3tools_state['tracker']  = get(a:params, 1, 0)
  let g:tads3tools_state['total']    = get(a:params, 2, 0)
  redrawstatus
endfunction

" params: [filePath, tracker, totalFiles, poolSize, inFlightFiles?]
function! tads3tools#coc#s_on_file_success(params) abort
  if empty(a:params) | return | endif
  let g:tads3tools_state['file']    = fnamemodify(get(a:params, 0, ''), ':t')
  let g:tads3tools_state['tracker'] = get(a:params, 1, 0)
  let g:tads3tools_state['total']   = get(a:params, 2, 0)
  redrawstatus
endfunction

" params: { allFilePaths, elapsedTime }
function! tads3tools#coc#s_on_allfiles_success(params) abort
  let l:elapsed_ms = get(a:params, 'elapsedTime', 0)
  let l:total      = g:tads3tools_state['total']
  let g:tads3tools_state['parsing'] = 0
  let g:tads3tools_state['file']    = ''
  redrawstatus
  echom printf('[tads3tools] Parsed %d files in %d ms', l:total, l:elapsed_ms)
endfunction

" params: { error } or bare array on some server code paths
function! tads3tools#coc#s_on_allfiles_failed(params) abort
  let g:tads3tools_state['parsing'] = 0
  let g:tads3tools_state['file']    = ''
  redrawstatus
  let l:error_message = type(a:params) == v:t_dict
    \ ? get(a:params, 'error', 'unknown error')
    \ : 'unknown error'
  echohl ErrorMsg
  echom '[tads3tools] Parse failed: ' . l:error_message
  echohl None
endfunction

" params: list of preprocessed file paths
function! tads3tools#coc#s_on_preprocessed_list(params) abort
  let g:tads3tools_preprocessed = type(a:params) == v:t_list ? a:params : []
endfunction

" params: { makefileStructure: [{key,value},...], usingAdv3Lite: bool }
function! tads3tools#coc#s_on_makefile_kvmap(params) abort
  let g:tads3tools_using_adv3_lite = get(a:params, 'usingAdv3Lite', 0)
  let g:tads3tools_makefile_kvs    = get(a:params, 'makefileStructure', [])
endfunction
