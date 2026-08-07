# research Makefile — xelatex + bibtex 编译链
TEX = main.tex
PDF = main.pdf
BIB = references.bib

all: $(PDF)

$(PDF): $(TEX) $(BIB)
	xelatex -interaction=nonstopmode $(TEX)
	bibtex main
	xelatex -interaction=nonstopmode $(TEX)
	xelatex -interaction=nonstopmode $(TEX)

clean:
	rm -f main.aux main.bbl main.blg main.log main.out main.toc main.pdf

.PHONY: all clean
