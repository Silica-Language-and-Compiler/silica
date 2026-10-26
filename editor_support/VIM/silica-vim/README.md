# Silica Vim support

This bundle provides Vim syntax highlighting and filetype detection for
`.silica` files. It mirrors the grammar in the Silica VS Code extension.

## Installation

Extract the contents of this archive into the user's Vim directory:

```sh
unzip silica-vim.zip -d ~/.vim
```

Then make sure the user's `~/.vimrc` contains:

```vim
syntax on
filetype plugin indent on
```

No Silica-specific absolute paths are required. Vim will automatically find
the `syntax/` and `ftdetect/` directories under `~/.vim`.

The syntax file links semantic categories to standard Vim highlight groups,
so the active colorscheme controls the actual colors.
