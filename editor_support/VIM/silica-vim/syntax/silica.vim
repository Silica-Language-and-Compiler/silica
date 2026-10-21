" Vim syntax file
" Language: Silica
" Maintainer: Silica project
" Latest Revision: 2026-10-07

if exists("b:current_syntax")
  finish
endif

if !has('syntax')
  finish
endif

syn case match

" String and character literals, including escaped characters.
syn region silicaString start='"' skip='\\.' end='"' keepend contains=silicaEscape containedin=ALLBUT,silicaComment
syn region silicaCharacter start="'" skip='\\.' end="'" keepend contains=silicaEscape containedin=ALLBUT,silicaComment
syn match  silicaEscape contained "\\."

" Atom literals such as :ok and :failed.
syn match silicaAtom ":[a-zA-Z_][a-zA-Z0-9_]*" containedin=ALLBUT,silicaComment

" Language keywords and language constants.
syn keyword silicaKeyword actor actor_ref and as atom atomic buf case cast do else end enum fn for from if impl import module not of or proc pub recv ref region return self send spawn spawn_registered spawn_linked trait type use wait_for_exit where containedin=ALLBUT,silicaComment
syn keyword silicaKeywordOther concurrency core_id core_set device_io effect efficiency_cores mailbox mem normal performance_cores containedin=ALLBUT,silicaComment
syn keyword silicaConstant true false underscore containedin=ALLBUT,silicaComment

" Types used in declarations and type annotations.
syn keyword silicaType int8 int16 int32 int64 uint8 uint16 uint32 uint64 float16 float32 float64 bool boolean char string unit atom actor_ref pid dangerous_pid supervisor_ref monitor_ref failure_reason bytes core_id core_set performance_cores efficiency_cores containedin=ALLBUT,silicaComment

" Function names are identifiers immediately followed by an opening parenthesis.
syn match silicaFunction "\<[a-z_][a-zA-Z0-9_]*\>\ze\s*(" containedin=ALLBUT,silicaComment

" Numeric literals.
syn match silicaNumber "\<0[xX][0-9a-fA-F]\+\>" containedin=ALLBUT,silicaComment
syn match silicaNumber "\<0[bB][01]\+\>" containedin=ALLBUT,silicaComment
syn match silicaNumber "\<\d\+\.\d\+[eE][+-]\=\d\+\>" containedin=ALLBUT,silicaComment
syn match silicaNumber "\<\d\+[eE][+-]\=\d\+\>" containedin=ALLBUT,silicaComment
syn match silicaNumber "\<\d\+\.\d\+\>" containedin=ALLBUT,silicaComment
syn match silicaNumber "\<\d\+\>" containedin=ALLBUT,silicaComment

" Arrow operators are kept separate to mirror keyword.operator.arrow.
syn match silicaArrow "<-\|->" containedin=ALLBUT,silicaComment
syn match silicaOperator "::\|+\|-\|\*\|/\|%\|==\|!=\|<=\|>=\|<\|>\|&&\|||\|!\|?\|:\||\|=\|@" containedin=ALLBUT,silicaComment

" Effect expressions: proc[...].
syn region silicaEffect start="\<proc\[" end="\]" keepend contains=silicaDangerous,silicaEffectKeyword,silicaType,silicaOperator,silicaArrow containedin=ALLBUT,silicaComment
syn keyword silicaEffectKeyword contained device_io concurrency
syn match silicaEffectKeyword contained "\<mem(normal)\>"

" Constructs called out as dangerous in the VS Code grammar.
syn keyword silicaDangerous spawn_dangerous dangerous_actor_ref external_danger containedin=ALLBUT,silicaComment

" Bracket matching is useful for the same delimiters declared by VS Code.
syn match silicaDelimiter "[{}()\[\]]" containedin=ALLBUT,silicaComment

" Comments are deliberately defined last so they win over punctuation and
" other same-position matches. Keep them opaque so their contents stay one
" color, including numbers, quotes, and parentheses.
syn match  silicaComment "//.*$" contains=NONE
syn region silicaComment start="{-" end="-}" keepend contains=NONE

" Standard Vim highlight groups preserve the active colorscheme's appearance.
hi def link silicaComment Comment
hi def link silicaDangerous WarningMsg
hi def link silicaKeyword Keyword
hi def link silicaKeywordOther Statement
hi def link silicaConstant Constant
hi def link silicaType Type
hi def link silicaFunction Function
hi def link silicaString String
hi def link silicaCharacter Character
hi def link silicaEscape SpecialChar
hi def link silicaAtom Constant
hi def link silicaNumber Number
hi def link silicaArrow Operator
hi def link silicaOperator Operator
hi def link silicaEffect Special
hi def link silicaEffectKeyword Special
hi def link silicaDelimiter Delimiter

let b:current_syntax = "silica"
