EMACS ?= emacs
ESS_LISP ?=
JULIA_REPL_LISP ?=
JULIA_MODE_LISP ?=
JULIA_TS_MODE_LISP ?=
S_LISP ?=
TREE_SITTER_PATH ?=

ELISP_FILES = quarto-ts-cell.el quarto-ts-ojs.el quarto-ts-shadow.el quarto-ts-eglot.el \
	quarto-ts-panache.el quarto-ts-authoring.el quarto-ts-font-lock.el quarto-ts-yaml.el \
	quarto-ts-preview.el quarto-ts-runner.el quarto-ts-mode.el

OPTIONAL_LOAD_PATHS = $(if $(ESS_LISP),-L $(ESS_LISP)) \
	$(if $(JULIA_REPL_LISP),-L $(JULIA_REPL_LISP)) \
	$(if $(JULIA_MODE_LISP),-L $(JULIA_MODE_LISP)) \
	$(if $(JULIA_TS_MODE_LISP),-L $(JULIA_TS_MODE_LISP)) \
	$(if $(S_LISP),-L $(S_LISP))

OPTIONAL_TREE_SITTER_PATH = $(if $(TREE_SITTER_PATH),\
	--eval '(add-to-list '\''treesit-extra-load-path "$(TREE_SITTER_PATH)")')

.PHONY: test integration-test compile check checkdoc whitespace clean

test:
	$(EMACS) -Q --batch -L . -L test \
		--eval '(add-to-list '\''treesit-extra-load-path (expand-file-name "tree-sitter" default-directory))' \
		-l test/quarto-ts-cell-test.el \
		-l test/quarto-ts-shadow-test.el \
		-l test/quarto-ts-eglot-test.el \
		-l test/quarto-ts-panache-test.el \
		-l test/quarto-ts-preview-test.el \
		-l test/quarto-ts-runner-test.el \
		-l test/quarto-ts-mode-test.el \
		-l test/quarto-ts-authoring-test.el \
		-l test/quarto-ts-font-lock-test.el \
		-l test/quarto-ts-yaml-test.el \
		-f ert-run-tests-batch-and-exit

integration-test:
	$(EMACS) -Q --batch -L . -L test $(OPTIONAL_LOAD_PATHS) \
		--eval '(add-to-list '\''treesit-extra-load-path (expand-file-name "tree-sitter" default-directory))' \
		$(OPTIONAL_TREE_SITTER_PATH) \
		-l test/quarto-ts-eglot-integration-test.el \
		-f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . \
		-f batch-byte-compile $(ELISP_FILES)

checkdoc:
	@for file in $(ELISP_FILES); do \
		$(EMACS) -Q --batch -L . --eval \
		  "(progn (require 'checkdoc) (checkdoc-file \"$$file\"))"; \
	done

whitespace:
	@if rg -n '[[:blank:]]+$$' --glob '*.el' --glob '*.md' .; then \
		echo "Trailing whitespace found"; exit 1; \
	fi

check: compile test checkdoc whitespace

clean:
	rm -f ./*.elc test/*.elc
