;;; quarto-ts-mode.el --- Tree-sitter mode for Quarto documents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrew Ellis

;; Author: Andrew Ellis
;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0"))
;; Keywords: languages, markdown, tools
;; URL: https://github.com/awellis/quarto-ts-mode

;;; Commentary:

;; An experimental Emacs 32 major mode for Quarto documents.  It builds on
;; `markdown-ts-mode' and adds a Quarto cell model.  Execution, preview, and
;; embedded-language Eglot support will be separate optional components.

;;; Code:

(require 'markdown-ts-mode)
(require 'quarto-ts-cell)

(defgroup quarto-ts nil
  "Editing Quarto documents with tree-sitter."
  :group 'languages
  :prefix "quarto-ts-")

(require 'quarto-ts-shadow)
(require 'quarto-ts-eglot)
(require 'quarto-ts-preview)
(require 'quarto-ts-runner)

(defcustom quarto-ts-code-block-modes
  '((r . ess-r-mode)
    (python . python-ts-mode)
    (julia . julia-ts-mode)
    (ojs . js-ts-mode))
  "Alist mapping Quarto cell languages to Emacs major modes."
  :type '(alist :key-type symbol :value-type function)
  :group 'quarto-ts)

(defun quarto-ts--install-code-block-modes ()
  "Register Quarto cell language aliases with `markdown-ts-mode'."
  (dolist (entry quarto-ts-code-block-modes)
    (pcase-let ((`(,language . ,mode) entry))
      (dolist (alias (list language
                           (intern (format "{%s}" language))
                           (intern (format ".%s" language))))
        (setf (alist-get alias markdown-ts-code-block-modes)
              (list mode))))))

(quarto-ts--install-code-block-modes)

(defvar-keymap quarto-ts-preview-command-map
  "p" #'quarto-ts-preview-start
  "s" #'quarto-ts-preview-stop
  "b" #'quarto-ts-preview-browse
  "r" #'quarto-ts-preview-refresh
  "l" #'quarto-ts-preview-show-log
  "x" #'quarto-ts-render
  "f" #'quarto-ts-render-to
  "P" #'quarto-ts-render-project)

(defvar-keymap quarto-ts-mode-map
  :parent markdown-ts-mode-map
  "C-c C-q n" #'quarto-ts-cell-next
  "C-c C-q p" #'quarto-ts-cell-previous
  "C-c C-q m" #'quarto-ts-cell-mark
  "C-c C-q s" #'quarto-ts-shadow-open
  "C-c C-q e" #'quarto-ts-eglot-ensure
  "C-c C-q c" #'quarto-ts-runner-run-cell
  "C-c C-q RET" #'quarto-ts-runner-run-cell-and-next
  "C-c C-q l" #'quarto-ts-runner-run-line
  "C-c C-q r" #'quarto-ts-runner-run-region
  "C-c C-q a" #'quarto-ts-runner-run-cells-above
  "C-c C-q b" #'quarto-ts-runner-run-all-cells
  "C-c C-q z" #'quarto-ts-runner-open-repl
  "C-c C-q v" quarto-ts-preview-command-map)

;;;###autoload
(define-derived-mode quarto-ts-mode markdown-ts-mode "Quarto"
  "Major mode for editing Quarto Markdown documents."
  (setq-local comment-start "<!-- "
              comment-end " -->")
  (quarto-ts--install-code-block-modes)
  (quarto-ts-shadow-mode 1))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.qmd\\'" . quarto-ts-mode))

(provide 'quarto-ts-mode)
;;; quarto-ts-mode.el ends here
