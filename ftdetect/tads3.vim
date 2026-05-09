" TADS3 makefile
autocmd BufRead,BufNewFile *.t3m setfiletype tads3makefile

" TADS3 source and header files — detected by content to avoid conflict with
" Perl test files (.t) and C/C++ headers (.h)
autocmd BufRead,BufNewFile *.t call tads3tools#detect_ft()
autocmd BufRead,BufNewFile *.h call tads3tools#detect_ft()
