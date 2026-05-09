-- M is the module table returned at the bottom of this file.
-- Callers access public functions as require('tads3tools').setup(), etc.
local M = {}

-- ─── Defaults ──────────────────────────────────────────────────────────────

local defaults = {
  -- Required: path to the vscode-tads3tools/server directory.
  -- The plugin looks for pre-built binaries inside server/bin/ and falls back
  -- to running server/out/server.js with Node.js.
  server_dir = nil,

  -- Writable directory used by the server to cache parsed symbol data.
  -- vim.fn.stdpath('data') returns the Neovim data directory (~/.local/share/nvim).
  storage_path = vim.fn.stdpath('data') .. '/tads3tools',

  -- Workspace settings forwarded to the server via workspace/configuration.
  settings = {
    tads3 = {
      include                    = '/usr/local/share/frobtads/tads3/include/',
      lib                        = '/usr/local/share/frobtads/tads3/lib/',
      enableLibraryCache         = false,
      enablePreprocessorCodeLens = false,
      maxNumberOfProblems        = 1000,
    },
  },

  -- Filetypes that activate the LSP client.
  filetypes = { 'tads3' },

  -- Optional callback invoked after the LSP attaches to a buffer.
  -- Runs after tads3tools' own on_attach so the client is fully ready.
  on_attach = nil,

  -- Optional extra LSP client capabilities merged over the defaults.
  capabilities = nil,
}

-- Active config, populated by M.setup().
local config = {}

-- Per-session cache: root_dir → user-selected makefile path.
local selected_makefiles = {}

-- ─── Observable parse state (readable from statuslines / autocmds) ─────────

-- M.state is a live table updated by server notifications.
-- Fields:
--   parsing         (bool)   — true while a parse is in progress
--   file            (string) — basename of the file currently being parsed
--   tracker         (int)    — number of files processed so far
--   total           (int)    — total number of files in the parse job
--   pool_size       (int)    — number of worker threads the server is using
--   using_adv3_lite (bool)   — true if the project uses the adv3Lite library
--   makefile_kvs    (table)  — raw {key,value} list from the makefile
--   preprocessed    (table)  — list of all preprocessed file paths
M.state = {
  parsing         = false,
  file            = '',
  tracker         = 0,
  total           = 0,
  pool_size       = 0,
  using_adv3_lite = false,
  makefile_kvs    = {},
  preprocessed    = {},
}

-- Convenience function suitable for statuslines:
--   %{v:lua.require('tads3tools').status()}
-- Returns e.g. "[tads3 12/48]" while parsing, "" otherwise.
function M.status()
  if not M.state.parsing then return '' end
  if M.state.total == 0 then return '[tads3 …]' end
  return string.format('[tads3 %d/%d]', M.state.tracker, M.state.total)
end

-- ─── Server detection ──────────────────────────────────────────────────────

-- Returns the command list used to launch the LSP server, e.g.
-- { '/path/to/server-binary', '--stdio' } or { 'node', 'server.js', '--stdio' }.
-- Returns nil if no suitable binary or Node.js fallback can be found.
-- Returns { system_name, architecture, platform_suffix, binary_extension } for
-- the current platform, or nil if the platform is unsupported.
local function platform_info()
  local uv    = vim.uv or vim.loop
  local uname = uv.os_uname()
  local system_name  = uname.sysname
  local architecture = uname.machine

  local platform_suffix, binary_extension
  if system_name == 'Darwin' then
    platform_suffix  = architecture == 'arm64' and 'macos-arm64' or 'macos-x64'
    binary_extension = ''
  elseif system_name == 'Linux' then
    local is_arm     = architecture == 'aarch64' or architecture == 'arm64'
    platform_suffix  = is_arm and 'linux-arm64' or 'linux-x64'
    binary_extension = ''
  elseif system_name:match('[Ww]indows') or system_name:match('MINGW') or system_name:match('CYGWIN') then
    platform_suffix  = architecture:lower():match('arm') and 'win-arm64' or 'win-x64'
    binary_extension = '.exe'
  else
    return nil
  end

  return system_name, platform_suffix, binary_extension
end

local function server_cmd(server_dir)
  -- When no server_dir is given, try the default :Tads3InstallServer location.
  local dir = server_dir or (vim.fn.stdpath('data') .. '/tads3tools')

  local system_name, platform_suffix, binary_extension = platform_info()

  if platform_suffix then
    local binary_path = dir
      .. '/bin/vscode-tads3tools-server-'
      .. platform_suffix
      .. binary_extension
    -- vim.fn.executable returns 1 if the path exists and is executable, 0 otherwise.
    if vim.fn.executable(binary_path) == 1 then
      return { binary_path, '--stdio' }
    end
  end

  -- Fallback: run the compiled JavaScript entry point via Node.js.
  -- Disabled: use :Tads3InstallServer to get the pre-built binary instead.
  -- local server_js_path = dir .. '/out/server.js'
  -- if vim.fn.filereadable(server_js_path) == 1 and vim.fn.executable('node') == 1 then
  --   return { 'node', server_js_path, '--stdio' }
  -- end

  return nil
end

-- ─── Project helpers ───────────────────────────────────────────────────────

-- Walks up the directory tree from fname looking for a directory that contains
-- a *.t3m makefile (the primary TADS3 project marker), then falls back to a
-- .git root if no makefile directory is found.
local function find_root(fname)
  return vim.fs.root(fname, function(name, _path)
    return name:match('%.t3m$') ~= nil
  end) or vim.fs.root(fname, '.git')
end

-- Returns all *.t3m files under root_dir, sorted shortest-path-first.
local function all_makefiles(root_dir)
  local paths = vim.fn.glob(root_dir .. '/**/*.t3m', false, true)
  table.sort(paths, function(a, b) return #a < #b end)
  return paths
end

-- Async: resolve the makefile for root_dir, prompting with vim.ui.select when
-- there are multiple candidates.  Caches the choice for the session so the
-- prompt only appears once per project root.
-- callback(path) receives the chosen path, or nil if nothing found / cancelled.
local function resolve_makefile(root_dir, callback)
  if selected_makefiles[root_dir] then
    callback(selected_makefiles[root_dir])
    return
  end

  local paths = all_makefiles(root_dir)
  if #paths == 0 then
    callback(nil)
    return
  end

  if #paths == 1 then
    selected_makefiles[root_dir] = paths[1]
    callback(paths[1])
    return
  end

  vim.ui.select(paths, {
    prompt = 'Select TADS3 makefile:',
    format_item = function(p) return vim.fn.fnamemodify(p, ':.') end,
  }, function(choice)
    if choice then
      selected_makefiles[root_dir] = choice
    end
    callback(choice)
  end)
end

-- Convenience: resolve for the current buffer's project root.
local function resolve_makefile_for_buf(callback)
  local buf_path = vim.api.nvim_buf_get_name(0)
  local root = find_root(buf_path) or vim.fn.getcwd()
  resolve_makefile(root, callback)
end

-- Parse the -o <file> line from a .t3m makefile and return an absolute path.
local function find_output_file(makefile_path)
  local dir = vim.fn.fnamemodify(makefile_path, ':h')
  for line in io.lines(makefile_path) do
    local name = line:match('^%s*%-o%s+(%S+)')
    if name then
      return name:sub(1, 1) == '/' and name or (dir .. '/' .. name)
    end
  end
  return nil
end

-- ─── Notification handlers ─────────────────────────────────────────────────
-- Each handler matches the signature Neovim's LSP layer expects:
--   function(err, result, ctx, config)
-- For custom server notifications err is always nil and result holds the params.

-- The server sends array params via JSON-RPC positional notation:
--   "params": [[filePath, tracker, totalFiles, poolSize, inFlightFiles?]]
-- The outer array is the JSON-RPC positional wrapper; the inner array is the
-- actual data.  coc.nvim unwraps one level before calling Vimscript handlers;
-- Neovim's LSP layer passes the raw params, so result[1] is the inner table.
local function unwrap(result)
  return (type(result) == 'table' and type(result[1]) == 'table') and result[1] or result
end

-- Called for each file as it starts being parsed.
local function on_processing(_err, result, _ctx, _cfg)
  if not result then return end
  local p = unwrap(result)
  M.state.parsing   = true
  -- vim.fn.fnamemodify with ':t' strips the directory part, returning only the filename.
  M.state.file      = vim.fn.fnamemodify(p[1] or '', ':t')
  M.state.tracker   = p[2] or 0
  M.state.total     = p[3] or 0
  M.state.pool_size = p[4] or 1
  vim.cmd('redrawstatus')
end

-- Called when a single file has been parsed successfully.
local function on_file_success(_err, result, _ctx, _cfg)
  if not result then return end
  local p = unwrap(result)
  M.state.file      = vim.fn.fnamemodify(p[1] or '', ':t')
  M.state.tracker   = p[2] or 0
  M.state.total     = p[3] or 0
  M.state.pool_size = p[4] or 1
  vim.cmd('redrawstatus')
end

-- Called when all files in the parse job have been processed successfully.
-- result: { allFilePaths, elapsedTime }
local function on_allfiles_success(_err, result, _ctx, _cfg)
  M.state.parsing = false
  M.state.file    = ''
  vim.cmd('redrawstatus')
  local elapsed_ms = result and result.elapsedTime or 0
  vim.notify(
    string.format('[tads3tools] Parsed %d files in %d ms', M.state.total, elapsed_ms),
    vim.log.levels.INFO
  )
end

-- Called when parsing fails (preprocessing error, missing compiler, etc.).
-- result: { error } or a bare array of file paths on some server code paths.
local function on_allfiles_failed(_err, result, _ctx, _cfg)
  M.state.parsing = false
  M.state.file    = ''
  vim.cmd('redrawstatus')
  local error_message
  if type(result) == 'table' and result.error then
    error_message = result.error
  elseif type(result) == 'string' then
    error_message = result
  else
    error_message = 'unknown error'
  end
  vim.notify('[tads3tools] Parse failed: ' .. error_message, vim.log.levels.ERROR)
end

-- Called after preprocessing completes; result is a list of preprocessed file paths.
local function on_preprocessed_list(_err, result, _ctx, _cfg)
  if type(result) == 'table' then
    M.state.preprocessed = result
  end
end

-- Called once per parse job with the parsed makefile contents.
-- result: { makefileStructure: [{key,value},...], usingAdv3Lite: bool }
local function on_makefile_kvmap(_err, result, _ctx, _cfg)
  if not result then return end
  M.state.using_adv3_lite = result.usingAdv3Lite or false
  M.state.makefile_kvs    = result.makefileStructure or {}
end

-- Handler table passed to vim.lsp.start / lspconfig.setup as `handlers`.
-- Keys are LSP method names; values are the handler functions above.
local notification_handlers = {
  ['symbolparsing/processing']       = on_processing,
  ['symbolparsing/success']          = on_file_success,
  ['symbolparsing/allfiles/success'] = on_allfiles_success,
  ['symbolparsing/allfiles/failed']  = on_allfiles_failed,
  ['response/preprocessed/list']     = on_preprocessed_list,
  ['response/makefile/keyvaluemap']  = on_makefile_kvmap,
  -- The remaining server notifications are VS Code-specific (map/NPC visualiser,
  -- quote extractor, preprocessed-file viewer). Register silent no-op handlers so
  -- Neovim does not log "no handler found" warnings for them.
  ['response/mapsymbols']            = function() end,
  ['response/npcsymbols']            = function() end,
  ['response/foundsymbol']           = function() end,
  ['response/connectrooms']          = function() end,
  ['response/extractQuotes']         = function() end,
  ['response/preprocessed/file']     = function() end,
  ['response/analyzeText/findNouns'] = function() end,
}

-- ─── Parse request ─────────────────────────────────────────────────────────

local function send_parse_request(client, bufnr, makefile)
  -- 'p' flag makes mkdir create all intermediate directories, like `mkdir -p`.
  vim.fn.mkdir(config.storage_path, 'p')
  M.state.parsing = true

  -- filePaths and token are omitted: the server checks `filePaths === undefined`
  -- to trigger the parse-all path.  vim.NIL serialises to JSON null, which is
  -- not === undefined, causing a null.length crash on the server side.
  client.request('request/parseDocuments', {
    globalStoragePath = config.storage_path,
    makefileLocation  = makefile,
  }, function(err)
    if err then
      M.state.parsing = false
      vim.notify('[tads3tools] Parse failed: ' .. (err.message or tostring(err)), vim.log.levels.ERROR)
    end
  end, bufnr)
end

-- ─── LSP lifecycle ─────────────────────────────────────────────────────────

local function on_attach(client, bufnr)
  resolve_makefile(client.config.root_dir, function(makefile)
    if not makefile then
      vim.notify('[tads3tools] No .t3m makefile found in ' .. client.config.root_dir, vim.log.levels.WARN)
      return
    end
    send_parse_request(client, bufnr, makefile)
  end)
  if config.on_attach then
    config.on_attach(client, bufnr)
  end
end

-- ─── Public API ────────────────────────────────────────────────────────────

-- Trigger a full project re-parse (e.g. after adding source files or changing
-- the makefile).
function M.parse()
  local clients = vim.lsp.get_clients({ name = 'tads3' })
  if #clients == 0 then
    vim.notify('[tads3tools] No active tads3 LSP client', vim.log.levels.WARN)
    return
  end
  local client = clients[1]
  resolve_makefile(client.config.root_dir, function(makefile)
    if not makefile then
      vim.notify('[tads3tools] No .t3m makefile found', vim.log.levels.WARN)
      return
    end
    send_parse_request(client, vim.api.nvim_get_current_buf(), makefile)
  end)
end

-- Abort an in-progress parse operation.
function M.abort_parse()
  -- ipairs iterates a sequential table from index 1 upwards, stopping at the
  -- first nil.  Used here instead of pairs because get_clients returns an array.
  for _, client in ipairs(vim.lsp.get_clients({ name = 'tads3' })) do
    client.notify('symbolparsing/abort', {})
  end
  M.state.parsing = false
  vim.cmd('redrawstatus')
end

-- Compile the project with t3make, loading errors into the quickfix list.
function M.build()
  resolve_makefile_for_buf(function(makefile)
    if not makefile then
      vim.notify('[tads3tools] No .t3m makefile found', vim.log.levels.WARN)
      return
    end
    if vim.fn.executable('t3make') == 0 then
      vim.notify('[tads3tools] t3make not found in PATH', vim.log.levels.WARN)
      return
    end

    local dir        = vim.fn.fnamemodify(makefile, ':h')
    local saved_prg  = vim.o.makeprg
    local saved_efm  = vim.o.errorformat

    vim.o.makeprg    = 'cd ' .. vim.fn.shellescape(dir) .. ' && t3make'
    -- t3make emits errors in two formats:
    --   file.t(42): error T3001: message   (compiler stage)
    --   file.t, line 42: error: message    (preprocessor stage)
    vim.o.errorformat = '%f(%l): %m,%f\\, line %l: %m'

    local ok, err = pcall(vim.cmd, 'make!')

    vim.o.makeprg    = saved_prg
    vim.o.errorformat = saved_efm

    if not ok then
      vim.notify('[tads3tools] make! failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
    vim.cmd('cwindow')
  end)
end

-- Launch the compiled game through the interpreter.
-- Override the default with: vim.g.tads3tools_interpreter = 'qtads'
function M.run()
  resolve_makefile_for_buf(function(makefile)
    if not makefile then
      vim.notify('[tads3tools] No .t3m makefile found', vim.log.levels.WARN)
      return
    end

    local output = find_output_file(makefile)
    if not output then
      vim.notify('[tads3tools] No -o output line found in ' .. vim.fn.fnamemodify(makefile, ':t'), vim.log.levels.WARN)
      return
    end

    if vim.fn.filereadable(output) == 0 then
      vim.notify('[tads3tools] ' .. vim.fn.fnamemodify(output, ':t') .. ' not found — run :Tads3Build first', vim.log.levels.WARN)
      return
    end

    local interpreter = vim.g.tads3tools_interpreter or 'frob'
    vim.cmd('!' .. vim.fn.shellescape(interpreter) .. ' ' .. vim.fn.shellescape(output))
  end)
end

-- Clear the cached makefile choice and re-prompt.
-- Run :Tads3Parse afterwards to re-parse with the new selection.
function M.select_makefile()
  local buf_path = vim.api.nvim_buf_get_name(0)
  local root = find_root(buf_path) or vim.fn.getcwd()
  selected_makefiles[root] = nil
  resolve_makefile(root, function(makefile)
    if makefile then
      vim.notify(
        '[tads3tools] Using ' .. vim.fn.fnamemodify(makefile, ':.') .. ' — run :Tads3Parse to re-parse',
        vim.log.levels.INFO
      )
    end
  end)
end

-- Returns an lspconfig-compatible server spec for users who manage lspconfig
-- themselves:
--   require('lspconfig').tads3.setup(require('tads3tools').lspconfig_config())
function M.lspconfig_config()
  return {
    cmd          = server_cmd(config.server_dir),
    filetypes    = config.filetypes,
    root_dir     = find_root,
    settings     = config.settings,
    handlers     = notification_handlers,
    on_attach    = on_attach,
    capabilities = config.capabilities,
  }
end

-- Downloads the server binary for the current platform from the latest
-- vscode-tads3tools GitHub release into {stdpath('data')}/tads3tools/bin/.
-- After installation, restart Neovim — server_dir does not need to be set.
function M.install_server()
  local system_name, platform_suffix, binary_extension = platform_info()
  if not platform_suffix then
    vim.notify('[tads3tools] Unsupported platform.', vim.log.levels.ERROR)
    return
  end

  local binary_name = 'vscode-tads3tools-server-' .. platform_suffix .. binary_extension
  local bin_dir     = vim.fn.stdpath('data') .. '/tads3tools/bin'
  local dest        = bin_dir .. '/' .. binary_name
  local url         = 'https://github.com/toerob/vscode-tads3tools/releases/latest/download/' .. binary_name

  vim.fn.mkdir(bin_dir, 'p')
  vim.notify('[tads3tools] Downloading ' .. binary_name .. ' …', vim.log.levels.INFO)

  vim.fn.jobstart({ 'curl', '-fsSL', '-o', dest, url }, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          vim.notify(
            '[tads3tools] Download failed (curl exit ' .. code .. '). Check your internet connection.',
            vim.log.levels.ERROR
          )
          return
        end
        if system_name ~= 'Windows_NT' then
          vim.fn.system({ 'chmod', '+x', dest })
        end
        -- Write a platform-independent wrapper script so coc.nvim (or any other
        -- client that uses a shell command) can use a stable path regardless of
        -- which platform binary is installed.
        local wrapper = bin_dir .. '/tads3-server'
        local f = io.open(wrapper, 'w')
        if f then
          f:write('#!/bin/sh\ndir="$(dirname "$0")"\nfor bin in "$dir"/vscode-tads3tools-server-*; do\n  [ -x "$bin" ] && exec "$bin" "$@"\ndone\necho "[tads3tools] No server binary found in $dir" >&2\nexit 1\n')
          f:close()
          vim.fn.system({ 'chmod', '+x', wrapper })
        end
        vim.notify(
          '[tads3tools] Installed ' .. binary_name .. ' to ' .. bin_dir .. '\n'
            .. 'coc.nvim command: ' .. wrapper .. '\n'
            .. 'Restart Neovim to start the language server.',
          vim.log.levels.INFO
        )
      end)
    end,
  })
end

local _locations_patched = false

function M.setup(opts)
  -- vim.tbl_deep_extend('force', ...) merges tables recursively; 'force' means
  -- keys in later arguments overwrite keys in earlier ones.
  config = vim.tbl_deep_extend('force', defaults, opts or {})

  -- The server sends bare paths (e.g. /usr/local/share/frobtads/...) instead of
  -- file:// URIs. Neovim 0.11+ validates URI schemes strictly. Monkey-patch
  -- locations_to_items once so every location-returning method (definition,
  -- references, implementation, …) gets the fix without touching per-request
  -- callbacks, which bypass the handlers table in Neovim 0.11.
  if not _locations_patched then
    local _orig_lti = vim.lsp.util.locations_to_items
    vim.lsp.util.locations_to_items = function(locations, offset_encoding)
      for _, loc in ipairs(locations or {}) do
        if loc.uri and not loc.uri:match('^%a[%a%d+%-%.]*://') then
          loc.uri = 'file://' .. loc.uri
        end
        if loc.targetUri and not loc.targetUri:match('^%a[%a%d+%-%.]*://') then
          loc.targetUri = 'file://' .. loc.targetUri
        end
      end
      return _orig_lti(locations, offset_encoding)
    end
    _locations_patched = true
  end

  -- vim.fn.expand resolves shell-style paths such as '~' and environment
  -- variables to absolute paths that the OS can use directly.
  if config.server_dir then
    config.server_dir = vim.fn.expand(config.server_dir)
  end

  local server_command = server_cmd(config.server_dir)
  if not server_command then
    vim.notify(
      '[tads3tools] LSP server binary not found.\n'
        .. 'Run :Tads3InstallServer to download it automatically, or\n'
        .. 'set `server_dir` in setup() to an existing vscode-tads3tools/server directory.\n'
        .. 'Example:\n'
        .. '  require("tads3tools").setup({\n'
        .. '    server_dir = "/path/to/vscode-tads3tools/server",\n'
        .. '  })',
      vim.log.levels.ERROR
    )
    return
  end

  -- pcall (protected call) calls require() without raising an error if the
  -- module is not installed.  Returns true + the module, or false + an error.
  local has_lspconfig, lspconfig = pcall(require, 'lspconfig')
  if has_lspconfig then
    -- Register a custom server entry under the name 'tads3' if not already done.
    local lsp_configs = require('lspconfig.configs')
    if not lsp_configs.tads3 then
      lsp_configs.tads3 = {
        default_config = {
          cmd       = server_command,
          filetypes = config.filetypes,
          root_dir  = require('lspconfig.util').root_pattern('*.t3m', '.git'),
          settings  = config.settings,
        },
        docs = { description = 'TADS3 Language Server (vscode-tads3tools)' },
      }
    end
    lspconfig.tads3.setup({
      settings     = config.settings,
      handlers     = notification_handlers,
      on_attach    = on_attach,
      capabilities = config.capabilities,
    })
    return
  end

  -- No lspconfig available — fall back to Neovim's built-in vim.lsp.start.
  -- nvim_create_augroup creates (or clears) a named autocmd group so that
  -- re-running setup() does not register duplicate autocmds.
  -- nvim_create_autocmd registers the callback to fire on FileType events for
  -- the configured filetypes, starting the LSP client for each matching buffer.
  vim.api.nvim_create_autocmd('FileType', {
    group   = vim.api.nvim_create_augroup('tads3tools', { clear = true }),
    pattern = config.filetypes,
    callback = function(args)
      -- vim.fn.getcwd() is the fallback when no project root can be determined
      -- (e.g. a lone file opened outside any git/t3m tree).
      local root_dir = find_root(args.file) or vim.fn.getcwd()
      vim.lsp.start({
        name         = 'tads3',
        cmd          = server_command,
        root_dir     = root_dir,
        settings     = config.settings,
        handlers     = notification_handlers,
        on_attach    = on_attach,
        capabilities = config.capabilities,
      })
    end,
  })
end

return M
