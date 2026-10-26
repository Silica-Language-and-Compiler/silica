" Vim filetype detection for Silica.

augroup filetypedetect
  au BufRead,BufNewFile *.silica setf silica
augroup END

