$lualatex = 'lualatex -synctex=1 -interaction=nonstopmode -file-line-error %O %S';
$pdf_mode = 4;
$biber = 'biber %O %B';
$bibtex_use = 2;   # use biber workflow (biblatex)