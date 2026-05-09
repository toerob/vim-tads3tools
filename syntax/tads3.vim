" Vim syntax file for TADS3 (Text Adventure Development System 3)
" Translated from vscode-tads3tools/syntaxes/tads3.tmLanguage.json

if exists("b:current_syntax")
  finish
endif

" ─── Keywords ────────────────────────────────────────────────────────────────

" Type / declaration keywords
syn keyword tads3Type
      \ class dictionary enum function intrinsic local
      \ method operator property propertyset template

" Storage class modifiers
syn keyword tads3StorageClass
      \ extern export modify multimethod replace transient

" Misc keywords
syn keyword tads3Keyword
      \ delegated inherited new replaced object static

" Control flow — each mapped to the most appropriate Vim group
syn keyword tads3Conditional  if else switch case default
syn keyword tads3Repeat       for foreach do while in
syn keyword tads3Statement    break continue return goto
syn keyword tads3Exception    try catch finally throw

" Built-in constants and implicit context identifiers
syn keyword tads3Boolean  nil true
syn keyword tads3Special  self targetobj targetprop definingobj argcount invokee

" ─── Comments ────────────────────────────────────────────────────────────────

syn keyword tads3Todo  contained TODO FIXME XXX HACK NOTE

syn match  tads3LineComment  "//.*$"
      \ contains=tads3Todo,@Spell

syn region tads3BlockComment  start="/\*"  end="\*/"
      \ contains=tads3Todo,@Spell

" ─── Preprocessor ────────────────────────────────────────────────────────────

" Directive keyword on lines that start with #
syn match tads3Preproc
      \ "^\s*#\s*\(charset\|define\|undef\|error\|line\|pragma\|include\|ifdef\|ifndef\|if\b\|elif\|else\|endif\)"

" Path/file after #include, shown as a string
syn match tads3PreprocPath  display
      \ "^\s*#\s*include\s*\zs[\"<][^\">\n]*[\">]"

" ─── Numbers ─────────────────────────────────────────────────────────────────

" Hexadecimal  0xFF
syn match tads3Number  "\b0[Xx][0-9A-Fa-f]\+\b"

" Octal  0777
syn match tads3Number  "\b0[0-7]\+\b"

" Floating-point  1.5   1e10   .5e-3   3.14E+2
syn match tads3Float
      \ "\b\([0-9]\+\(\.[0-9]*\)\?\|\.[0-9]\+\)\([Ee][+-]\?[0-9]\+\)\b"
syn match tads3Float  "\b[0-9]\+\.[0-9]*\b"
syn match tads3Float  "\.[0-9]\+\b"

" Decimal integer (after float so a leading digit isn't stolen)
syn match tads3Number  "\b[0-9]\+\b"

" ─── Strings ─────────────────────────────────────────────────────────────────

" Escape sequences valid inside all string variants
"   \n  \t  \b  \r  \v  \\  \"  \'  \<  \>  \^  (space)
"   \uXXXX   \xXX   \OOO
syn match tads3Escape  contained "\\[\\<>\"' \^vbnrt]"
syn match tads3Escape  contained "\\u[0-9A-Fa-f]\{4}"
syn match tads3Escape  contained "\\x[0-9A-Fa-f]\{2}"
syn match tads3Escape  contained "\\[0-7]\{3}"

" HTML / adv3-style tags embedded in display strings
"   <b>  <\p>  </font>  {a dobj}
syn match tads3HtmlTag  contained "<[A-Za-z\.][^'\"<>\n]*>"
syn match tads3HtmlTag  contained "</[A-Za-z\.]\+>"
syn match tads3HtmlTag  contained "{[A-Za-z0-9/ _-]*}"

" <<expr>>  embedded expression inside a string.
" Highlights TADS3 keywords/values inside the << >> but not nested strings,
" which would corrupt the outer string boundary detection.
syn region tads3Interp  matchgroup=tads3InterpDelim
      \ start="<<"  end=">>"  contained  oneline
      \ contains=
      \   tads3Type,tads3StorageClass,tads3Keyword,
      \   tads3Conditional,tads3Repeat,tads3Statement,tads3Exception,
      \   tads3Boolean,tads3Special,tads3Number,tads3Float

" String regions.
"
" Single and double variants are defined first so that triple variants
" (defined afterward) have higher priority at positions where all three
" start= patterns could match (e.g. the first char of """).
"
" skip=+\\\\.+ steps over any backslash+char pair while searching for
" the closing quote, handling \" \\ \' etc.

syn region tads3String  matchgroup=tads3Quote
      \ start=+"+  skip=+\\\\.+  end=+"+
      \ contains=tads3Escape,tads3Interp,tads3HtmlTag

syn region tads3String  matchgroup=tads3Quote
      \ start=+'+  skip=+\\\\.+  end=+'+
      \ contains=tads3Escape,tads3Interp,tads3HtmlTag

syn region tads3String  matchgroup=tads3Quote
      \ start=+"""+  end=+"""+
      \ contains=tads3Escape,tads3Interp,tads3HtmlTag

syn region tads3String  matchgroup=tads3Quote
      \ start=+'''+  end=+'''+
      \ contains=tads3Escape,tads3Interp,tads3HtmlTag

" ─── Highlight links ─────────────────────────────────────────────────────────

hi def link tads3Type          Type
hi def link tads3StorageClass  StorageClass
hi def link tads3Keyword       Keyword
hi def link tads3Conditional   Conditional
hi def link tads3Repeat        Repeat
hi def link tads3Statement     Statement
hi def link tads3Exception     Exception
hi def link tads3Boolean       Boolean
hi def link tads3Special       Special
hi def link tads3Todo          Todo
hi def link tads3LineComment   Comment
hi def link tads3BlockComment  Comment
hi def link tads3Preproc       PreProc
hi def link tads3PreprocPath   String
hi def link tads3Number        Number
hi def link tads3Float         Float
hi def link tads3Escape        SpecialChar
hi def link tads3HtmlTag       Tag
hi def link tads3Interp        PreProc
hi def link tads3InterpDelim   Delimiter
hi def link tads3Quote         String
hi def link tads3String        String

let b:current_syntax = "tads3"
