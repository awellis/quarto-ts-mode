;;; quarto-ts-mode.el --- Tree-sitter mode for Quarto documents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrew Ellis

;; Author: Andrew Ellis
;; Version: 0.1.0
;; Package-Requires: ((emacs "32.0"))
;; Keywords: languages, markdown, tools
;; URL: https://github.com/awellis/quarto-ts-mode

;;; Commentary:

;; An experimental Emacs 32 major mode for Quarto documents.  It builds on
;; `markdown-ts-mode' and adds Quarto cells, execution, preview management,
;; folding, and embedded-language Eglot support.

;;; Code:

(require 'easymenu)
(require 'markdown-ts-mode)
(require 'quarto-ts-cell)

(defgroup quarto-ts nil
  "Editing Quarto documents with tree-sitter."
  :group 'languages
  :prefix "quarto-ts-")

(require 'quarto-ts-shadow)
(require 'quarto-ts-eglot)
(require 'quarto-ts-panache)
(require 'quarto-ts-authoring)
(require 'quarto-ts-font-lock)
(require 'quarto-ts-yaml)
(require 'quarto-ts-preview)
(require 'quarto-ts-runner)

(defcustom quarto-ts-hide-markup t
  "Non-nil means hide Markdown delimiters in Quarto buffers.
The underlying text is unchanged and delimiters can be revealed with
`quarto-ts-toggle-hide-markup'."
  :type 'boolean
  :safe #'booleanp
  :group 'quarto-ts)

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

(defun quarto-ts--imenu-cell-node-p (node)
  "Return non-nil when NODE is an executable-cell info string."
  (and (string= (treesit-node-type node) "info_string")
       (when-let* ((language-node
                    (treesit-search-subtree node "language")))
         (quarto-ts-cell--normalize-language
          (treesit-node-text language-node t)))))

(defun quarto-ts--imenu-cell-name (node)
  "Return an Imenu name for the executable cell represented by NODE."
  (when-let* ((cell (quarto-ts-cell-at-point (treesit-node-start node)))
              (language (quarto-ts-cell-language cell)))
    (if-let* ((label (quarto-ts-cell-label cell)))
        (format "%s: %s" language label)
      (format "%s cell at line %d"
              language
              (line-number-at-pos (quarto-ts-cell-fence-begin cell))))))

(defun quarto-ts--install-imenu-cells ()
  "Add labelled and unlabelled executable cells to Imenu."
  (add-to-list
   'treesit-simple-imenu-settings
   `("Cells" ,#'quarto-ts--imenu-cell-node-p
     nil ,#'quarto-ts--imenu-cell-name)
   t))

(defvar-keymap quarto-ts-insert-command-map
  "c" #'quarto-ts-insert-citation
  "a" #'quarto-ts-insert-callout
  "s" #'quarto-ts-insert-shortcode)

(defvar-keymap quarto-ts-eglot-command-map
  "r" #'quarto-ts-eglot-rename
  "f" #'quarto-ts-eglot-format-cell
  "a" #'quarto-ts-eglot-code-actions)

(defvar-keymap quarto-ts-panache-command-map
  "e" #'quarto-ts-panache-ensure
  "f" #'quarto-ts-panache-format-buffer
  "a" #'quarto-ts-panache-code-actions
  "r" #'quarto-ts-panache-reconnect)

(defvar-keymap quarto-ts-preview-command-map
  "p" #'quarto-ts-preview-start
  "s" #'quarto-ts-preview-stop
  "b" #'quarto-ts-preview-browse
  "r" #'quarto-ts-preview-refresh
  "l" #'quarto-ts-preview-show-log
  "x" #'quarto-ts-render
  "f" #'quarto-ts-render-to
  "P" #'quarto-ts-render-project)

(defun quarto-ts-toggle-hide-markup ()
  "Toggle AUCTeX-like hiding of Markdown markup delimiters."
  (interactive)
  (setq-local quarto-ts-hide-markup (not markdown-ts-hide-markup)
              markdown-ts-hide-markup quarto-ts-hide-markup)
  (markdown-ts--set-hide-markup markdown-ts-hide-markup)
  (message "Quarto markup is %s"
           (if markdown-ts-hide-markup "hidden" "visible")))

(defvar-keymap quarto-ts-mode-map
  :parent markdown-ts-mode-map
  "C-c C-q n" #'quarto-ts-cell-next
  "C-c C-q p" #'quarto-ts-cell-previous
  "C-c C-q m" #'quarto-ts-cell-mark
  "C-c C-q f" #'quarto-ts-cell-toggle-fold
  "C-c C-q F" #'quarto-ts-cell-fold-all
  "C-c C-q u" #'quarto-ts-cell-unfold-all
  "C-c C-q h" #'quarto-ts-toggle-hide-markup
  "C-c C-q s" #'quarto-ts-shadow-open
  "C-c C-q e" #'quarto-ts-eglot-ensure
  "C-c C-q c" #'quarto-ts-runner-run-cell
  "C-c C-q RET" #'quarto-ts-runner-run-cell-and-next
  "C-c C-q l" #'quarto-ts-runner-run-line
  "C-c C-q r" #'quarto-ts-runner-run-region
  "C-c C-q a" #'quarto-ts-runner-run-cells-above
  "C-c C-q b" #'quarto-ts-runner-run-all-cells
  "C-c C-q z" #'quarto-ts-runner-open-repl
  "C-c C-q d" #'quarto-ts-yaml-describe-option
  "C-c C-q i" quarto-ts-insert-command-map
  "C-c C-q g" quarto-ts-eglot-command-map
  "C-c C-q w" quarto-ts-panache-command-map
  "C-c C-q v" quarto-ts-preview-command-map)

;; `defvar-keymap' preserves an existing map when this development file is
;; reloaded, so install newly introduced bindings explicitly as well.
(keymap-set quarto-ts-mode-map "C-c C-q h"
            #'quarto-ts-toggle-hide-markup)
(keymap-set quarto-ts-mode-map "C-c C-q d"
            #'quarto-ts-yaml-describe-option)
(keymap-set quarto-ts-mode-map "C-c C-q i"
            quarto-ts-insert-command-map)
(keymap-set quarto-ts-mode-map "C-c C-q g"
            quarto-ts-eglot-command-map)
(keymap-set quarto-ts-mode-map "C-c C-q w"
            quarto-ts-panache-command-map)
;; Reuse Doom/Markdown's existing localleader toggle binding while dispatching
;; to the tree-sitter presentation implementation in Quarto buffers.
(define-key quarto-ts-mode-map [remap markdown-toggle-markup-hiding]
            #'quarto-ts-toggle-hide-markup)

(easy-menu-define quarto-ts-menu quarto-ts-mode-map
  "Menu for editing and running Quarto documents."
  '("Quarto"
    ("Execute"
     ["Run Selection" quarto-ts-runner-run-region :active (use-region-p)]
     ["Run Line" quarto-ts-runner-run-line]
     ["Run Cell" quarto-ts-runner-run-cell]
     ["Run Cell and Advance" quarto-ts-runner-run-cell-and-next]
     "---"
     ["Run Cells Above" quarto-ts-runner-run-cells-above]
     ["Run All Cells" quarto-ts-runner-run-all-cells]
     "---"
     ["Open REPL" quarto-ts-runner-open-repl])
    ("Cells"
     ["Next Cell" quarto-ts-cell-next]
     ["Previous Cell" quarto-ts-cell-previous]
     ["Mark Cell" quarto-ts-cell-mark]
     "---"
     ["Toggle Cell Fold" quarto-ts-cell-toggle-fold]
     ["Fold All Cells" quarto-ts-cell-fold-all]
     ["Unfold All Cells" quarto-ts-cell-unfold-all])
    ("Embedded Language"
     ["Start Language Server" quarto-ts-eglot-ensure]
     ["Open Language Shadow" quarto-ts-shadow-open]
     "---"
     ["Rename Symbol" quarto-ts-eglot-rename]
     ["Format Cell" quarto-ts-eglot-format-cell]
     ["Code Actions" quarto-ts-eglot-code-actions])
    ("Document Language"
     ["Start Panache" quarto-ts-panache-ensure]
     ["Reconnect Panache" quarto-ts-panache-reconnect]
     "---"
     ["Format Document" quarto-ts-panache-format-buffer]
     ["Code Actions" quarto-ts-panache-code-actions])
    ("Authoring"
     ["Insert Citation" quarto-ts-insert-citation]
     ["Insert Callout" quarto-ts-insert-callout]
     ["Insert Shortcode" quarto-ts-insert-shortcode]
     "---"
     ["Describe YAML Option" quarto-ts-yaml-describe-option])
    ("Preview and Render"
     ["Start Preview" quarto-ts-preview-start]
     ["Stop Preview" quarto-ts-preview-stop
      :active (quarto-ts-preview-live-p)]
     ["Open Preview" quarto-ts-preview-browse
      :active (quarto-ts-preview-live-p)]
     ["Refresh Preview" quarto-ts-preview-refresh
      :active (quarto-ts-preview-live-p)]
     ["Show Preview Log" quarto-ts-preview-show-log]
     "---"
     ["Render Document" quarto-ts-render]
     ["Render Document To..." quarto-ts-render-to]
     ["Render Project" quarto-ts-render-project])
    "---"
    ["Toggle Markup Visibility" quarto-ts-toggle-hide-markup]))

(defun quarto-ts--comment-setup ()
  "Select the comment syntax appropriate at point."
  (if (quarto-ts-yaml--region)
      (setq-local comment-start "# "
                  comment-end ""
                  comment-start-skip "#+[ \t]*"
                  comment-end-skip nil
                  comment-continue "# "
                  comment-use-syntax nil)
    (setq-local comment-start "<!-- "
                comment-end " -->"
                comment-start-skip "<!--[ \t]*"
                comment-end-skip "[ \t]*-->"
                comment-continue nil
                comment-use-syntax nil)))

;;;###autoload
(define-derived-mode quarto-ts-mode markdown-ts-mode "Quarto"
  "Major mode for editing Quarto Markdown documents."
  (setq-local comment-setup-function #'quarto-ts--comment-setup)
  (quarto-ts--comment-setup)
  (quarto-ts--install-code-block-modes)
  (setq-local markdown-ts-hide-markup quarto-ts-hide-markup)
  (quarto-ts-font-lock-setup quarto-ts-code-block-modes)
  (markdown-ts--set-hide-markup markdown-ts-hide-markup)
  (quarto-ts--install-imenu-cells)
  (setq-local markdown-ts-code-block-commands
              (remq 'completion-at-point
                    markdown-ts-code-block-commands))
  (add-hook 'completion-at-point-functions
            #'quarto-ts-authoring-completion-at-point nil t)
  (quarto-ts-authoring-setup)
  (quarto-ts-yaml-setup)
  (quarto-ts-panache-setup)
  (quarto-ts-cell-fold-mode 1)
  (quarto-ts-shadow-mode 1))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.qmd\\'" . quarto-ts-mode))

(provide 'quarto-ts-mode)
;;; quarto-ts-mode.el ends here
