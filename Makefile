EMACS ?= emacs

.PHONY: test integration-test compile check clean

test:
	$(EMACS) -Q --batch -L . -L test \
		--eval '(add-to-list '\''treesit-extra-load-path (expand-file-name "tree-sitter" default-directory))' \
		-l test/quarto-ts-cell-test.el \
		-l test/quarto-ts-shadow-test.el \
		-l test/quarto-ts-eglot-test.el \
		-l test/quarto-ts-preview-test.el \
		-l test/quarto-ts-runner-test.el \
		-f ert-run-tests-batch-and-exit

integration-test:
	$(EMACS) -Q --batch -L . -L test \
		--eval '(add-to-list '\''treesit-extra-load-path (expand-file-name "tree-sitter" default-directory))' \
		-l test/quarto-ts-eglot-integration-test.el \
		-f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . \
		-f batch-byte-compile \
		quarto-ts-cell.el quarto-ts-shadow.el quarto-ts-eglot.el \
		quarto-ts-preview.el quarto-ts-runner.el quarto-ts-mode.el

check: compile test

clean:
	rm -f ./*.elc test/*.elc
