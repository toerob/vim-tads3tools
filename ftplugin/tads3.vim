if exists('b:did_ftplugin')
  finish
endif
let b:did_ftplugin = 1

setlocal commentstring=//%s
setlocal comments=s1:/*,mb:*,ex:*/,://
setlocal expandtab
setlocal tabstop=4
setlocal shiftwidth=4
setlocal softtabstop=4

let b:undo_ftplugin = 'setlocal commentstring< comments< expandtab< tabstop< shiftwidth< softtabstop<'
