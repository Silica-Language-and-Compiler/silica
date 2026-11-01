// Apple ld expects C entry _main; Silica asm emits `main` without underscore.
.text
.global _main
.global main
_main = main
