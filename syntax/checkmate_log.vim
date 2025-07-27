if exists("b:current_syntax")
  finish
endif

" Date and time at the start of lines
syntax match checkmateLogDate /^\d\{4}-\d\{2}-\d\{2} \d\{2}:\d\{2}:\d\{2}/ nextgroup=checkmateLogLevel skipwhite

" Log levels
syntax match checkmateLogTrace /\[TRACE\]/
syntax match checkmateLogDebug /\[DEBUG\]/
syntax match checkmateLogInfo /\[INFO\]/
syntax match checkmateLogWarn /\[WARN\]/
syntax match checkmateLogError /\[ERROR\]/

" Source location [file:line]
syntax match checkmateLogSource /\[[^\]]\+:\d\+\]/

" Numbers
syntax match checkmateLogNumber /\<\d\+\>/ contained
syntax match checkmateLogNumber /\<\d\+\.\d\+\>/ contained
syntax match checkmateLogNumber /\<0x\x\+\>/ contained

" Strings
syntax region checkmateLogString start=/"/ skip=/\\"/ end=/"/ oneline contained
syntax region checkmateLogString start=/'/ skip=/\\'/ end=/'/ oneline contained

" File paths (common extensions)
syntax match checkmateLogPath /[~/]\S*\.\(lua\|vim\|log\|txt\|json\|yaml\|toml\)/ contained

" Lua/Vim table output from vim.inspect
syntax region checkmateLogTable start=/{/ end=/}/ contains=checkmateLogTableKey,checkmateLogString,checkmateLogNumber,checkmateLogTable
syntax match checkmateLogTableKey /\<\w\+\>\ze\s*=/ contained

" Error-related keywords (case insensitive)
syntax match checkmateLogErrorWord /\c\<error\|failed\|failure\|fail\|exception\|critical\|fatal\>/

" Success-related keywords
syntax match checkmateLogSuccessWord /\c\<successfully\|successful\|success\|succeed\|ok\|passed\|pass\|completed\|complete\>/

" Common syntax
syntax keyword checkmateLogKeyword nil true false function table string number boolean

" File size units
syntax match checkmateLogSize /\d\+\s*\(mb\|kb\|gb\|bytes\?\)/

" Define default highlighting - links to standard highlight groups
" This ensures it works with any colorscheme
highlight default link checkmateLogDate Comment
highlight default link checkmateLogTrace Comment
highlight default link checkmateLogDebug Normal
highlight default link checkmateLogInfo Type
highlight default link checkmateLogWarn WarningMsg
highlight default link checkmateLogError ErrorMsg
highlight default link checkmateLogSource Identifier
highlight default link checkmateLogNumber Number
highlight default link checkmateLogString String
highlight default link checkmateLogPath Directory
highlight default link checkmateLogTable Structure
highlight default link checkmateLogTableKey Identifier
highlight default link checkmateLogErrorWord ErrorMsg
highlight default link checkmateLogSuccessWord DiagnosticOk
highlight default link checkmateLogKeyword Keyword
highlight default link checkmateLogSize Number

" Set syntax sync - important for log files that might be large
syntax sync minlines=50

let b:current_syntax = "checkmate_log"
