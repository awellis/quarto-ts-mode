;;; quarto-ts-font-lock.el --- Quarto-specific fontification -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrew Ellis

;; Author: Andrew Ellis
;; Keywords: languages, markdown, tools
;; Package-Requires: ((emacs "32.0"))

;;; Commentary:

;; Quarto-specific semantic faces layered over `markdown-ts-mode'.  Native
;; Markdown, YAML, and embedded-language fontification remain responsible for
;; their own syntax; this module highlights the Quarto structures that join
;; those languages into one document.

;;; Code:

(require 'color)
(require 'face-remap)
(require 'font-lock)
(require 'markdown-ts-mode)
(require 'quarto-ts-cell)
(require 'subr-x)
(require 'treesit)

(defface quarto-ts-fence-face
  '((t :inherit font-lock-preprocessor-face :weight bold))
  "Face used for executable-cell fences."
  :group 'quarto-ts)

(defface quarto-ts-markup-face
  '((t :inherit shadow))
  "Face used for secondary Quarto markup delimiters."
  :group 'quarto-ts)

(defface quarto-ts-cell-language-face
  '((t :inherit font-lock-type-face :weight bold))
  "Face used for executable-cell language names."
  :group 'quarto-ts)

(defface quarto-ts-cell-option-key-face
  '((t :inherit font-lock-property-name-face :weight semi-bold))
  "Face used for Quarto cell-option names."
  :group 'quarto-ts)

(defface quarto-ts-cell-option-value-face
  '((t :inherit font-lock-constant-face))
  "Face used for Quarto cell-option values."
  :group 'quarto-ts)

(defface quarto-ts-crossref-face
  '((t :inherit link :weight semi-bold))
  "Face used for Quarto cross-references."
  :group 'quarto-ts)

(defface quarto-ts-citation-face
  '((t :inherit font-lock-variable-use-face))
  "Face used for citation keys."
  :group 'quarto-ts)

(defface quarto-ts-shortcode-face
  '((t :inherit font-lock-preprocessor-face))
  "Face used for Quarto shortcodes."
  :group 'quarto-ts)

(defface quarto-ts-callout-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face used for Quarto callout declarations."
  :group 'quarto-ts)

(defface quarto-ts-attribute-face
  '((t :inherit font-lock-property-use-face))
  "Face used for Pandoc identifiers, classes, and attributes."
  :group 'quarto-ts)

(defface quarto-ts-table-face
  '((t :inherit fixed-pitch :extend t))
  "Base face used for Markdown and Quarto tables."
  :group 'quarto-ts)

(defface quarto-ts-table-header-face
  '((t :inherit (font-lock-function-name-face fixed-pitch) :weight bold))
  "Face used for table header cells."
  :group 'quarto-ts)

(defface quarto-ts-table-cell-face
  '((t :inherit fixed-pitch))
  "Face used for table body cells."
  :group 'quarto-ts)

(defface quarto-ts-table-delimiter-face
  '((t :inherit (font-lock-comment-delimiter-face fixed-pitch) :weight bold))
  "Face used for table pipes and alignment rows."
  :group 'quarto-ts)

(defface quarto-ts-table-caption-face
  '((t :inherit font-lock-doc-face :slant italic))
  "Face used for Pandoc table captions."
  :group 'quarto-ts)

(defface quarto-ts-math-face
  '((t :inherit font-lock-builtin-face))
  "Face used for LaTeX mathematics in Quarto prose."
  :group 'quarto-ts)

(defcustom quarto-ts-table-background-contrast 7
  "Percentage by which table backgrounds contrast with the default face."
  :type 'integer
  :group 'quarto-ts)

(defcustom quarto-ts-table-header-background-contrast 12
  "Percentage by which table header backgrounds contrast with the default."
  :type 'integer
  :group 'quarto-ts)

(defcustom quarto-ts-font-lock-language-grammars
  '((python . python)
    (julia . julia)
    (ojs . javascript))
  "Tree-sitter grammar names used by configured cell languages."
  :type '(alist :key-type symbol :value-type symbol)
  :group 'quarto-ts)

(defconst quarto-ts-font-lock--citation-regexp
  "\\(?:^\\|[^[:alnum:]_@]\\)\\(@[[:alnum:]_][[:alnum:]_.:/-]*\\)"
  "Regexp matching a Pandoc citation key in prose.")

(defconst quarto-ts-font-lock--crossref-regexp
  "\\(?:^\\|[^[:alnum:]_@]\\)\\(@\\(?:fig\\|tbl\\|sec\\|eq\\|lst\\|thm\\|lem\\|cor\\|prp\\|cnj\\|def\\|exm\\|exr\\)-[[:alnum:]_.:-]+\\)"
  "Regexp matching a Quarto cross-reference in prose.")

(defun quarto-ts-font-lock--match-prose (regexp limit)
  "Search for REGEXP before LIMIT, excluding executable cells."
  (catch 'match
    (while (re-search-forward regexp limit t)
      (let ((match-data (match-data)))
        (unless (quarto-ts-cell-at-point (match-beginning 0))
          (set-match-data match-data)
          (throw 'match t))))))

(defun quarto-ts-font-lock--match-citation (limit)
  "Search for a citation before LIMIT outside executable cells."
  (quarto-ts-font-lock--match-prose
   quarto-ts-font-lock--citation-regexp limit))

(defun quarto-ts-font-lock--match-crossref (limit)
  "Search for a cross-reference before LIMIT outside executable cells."
  (quarto-ts-font-lock--match-prose
   quarto-ts-font-lock--crossref-regexp limit))

(defun quarto-ts-font-lock--markup-delimiter-face (subexpression)
  "Return a subdued face and optionally hide SUBEXPRESSION."
  (when markdown-ts-hide-markup
    (put-text-property (match-beginning subexpression)
                       (match-end subexpression)
                       'invisible 'markdown-ts--markup))
  'quarto-ts-markup-face)

(defun quarto-ts-font-lock--cell-language-face ()
  "Reveal and return the face for the matched cell language name."
  (remove-text-properties (match-beginning 3) (match-end 3)
                          '(invisible nil))
  'quarto-ts-cell-language-face)

(defconst quarto-ts-font-lock-keywords
  '(("^\\([[:space:]]*\\(?:```+\\|~~~+\\)\\)\\({[[:space:]]*\\.?\\([[:alnum:]_+.-]+\\)[^}\n]*}\\)?[[:space:]]*$"
     (1 'quarto-ts-fence-face t)
     (2 'quarto-ts-attribute-face t t)
     (3 (quarto-ts-font-lock--cell-language-face) t t))
    ("^[[:space:]]*\\(#|\\)[[:space:]]*\\([[:alnum:]_-]+\\)\\([[:space:]]*:[[:space:]]*\\)\\(.*\\)$"
     (1 (quarto-ts-font-lock--markup-delimiter-face 1) t)
     (2 'quarto-ts-cell-option-key-face t)
     (3 'quarto-ts-markup-face t)
     (4 'quarto-ts-cell-option-value-face t))
    ("^[[:space:]]*\\(:\\)[[:space:]]+\\(.+\\)$"
     (1 'quarto-ts-fence-face t)
     (2 'quarto-ts-table-caption-face t))
    (quarto-ts-font-lock--match-citation
     (1 'quarto-ts-citation-face keep))
    (quarto-ts-font-lock--match-crossref
     (1 'quarto-ts-crossref-face t))
    ("\\({{<\\)[[:space:]]*\\([^}\n]+?\\)[[:space:]]*\\(>}}\\)"
     (1 (quarto-ts-font-lock--markup-delimiter-face 1) t)
     (2 'quarto-ts-shortcode-face t)
     (3 (quarto-ts-font-lock--markup-delimiter-face 3) t))
    ("{\\(?:#[[:alnum:]_.:-]+\\|\\.[[:alnum:]_.:-]+\\)[^}\n]*}"
     (0 'quarto-ts-attribute-face t))
    ("^[[:space:]]*\\(:::+\\)[[:space:]]*\\({\\.callout-\\)\\([[:alnum:]_-]+\\)\\([^}\n]*\\)\\(}\\)[[:space:]]*$"
     (1 (quarto-ts-font-lock--markup-delimiter-face 1) t)
     (2 (quarto-ts-font-lock--markup-delimiter-face 2) t)
     (3 'quarto-ts-callout-face t)
     (4 'quarto-ts-attribute-face t t)
     (5 (quarto-ts-font-lock--markup-delimiter-face 5) t))
    ("^[[:space:]]*\\(:::+\\)[[:space:]]*$"
     (1 (quarto-ts-font-lock--markup-delimiter-face 1) t)))
  "Additional font-lock keywords for Quarto document structures.")

(defun quarto-ts-font-lock--mode-configuration (mode)
  "Return fresh tree-sitter font-lock configuration harvested from MODE."
  (when (fboundp mode)
    (condition-case nil
        (with-temp-buffer
          (delay-mode-hooks (funcall mode))
          (when-let* ((language (treesit-language-at (point-min)))
                      (settings treesit-font-lock-settings))
            (list :language language
                  :font-lock settings
                  :simple-indent treesit-simple-indent-rules
                  :range treesit-range-settings)))
      (error nil))))

(defun quarto-ts-font-lock--fallback-mode (mode)
  "Return the conventional major-mode counterpart of MODE."
  (let ((name (symbol-name mode)))
    (if (string-match "\\`\\(.+\\)-ts-mode\\'" name)
        (intern (concat (match-string 1 name) "-mode"))
      mode)))

(defun quarto-ts-font-lock--record-conventional-mode (language mode)
  "Use conventional MODE to fontify code blocks for LANGUAGE."
  (let ((fallback (quarto-ts-font-lock--fallback-mode mode)))
    (unless (fboundp fallback)
      (require fallback nil t))
    (when (fboundp fallback)
      (setf (alist-get language markdown-ts--code-block-non-ts-modes)
            fallback))))

(defun quarto-ts-font-lock--prepare-code-languages (language-modes)
  "Prepare native tree-sitter fontification from LANGUAGE-MODES.
LANGUAGE-MODES is an alist mapping fence-language symbols to major modes.
A fresh temporary buffer is used for each tree-sitter mode, avoiding parser
state left in `markdown-ts-mode' work buffers when several guest languages are
configured.  Conventional font-lock is recorded as a fallback when a grammar
or tree-sitter mode is unavailable."
  (dolist (entry language-modes)
    (pcase-let* ((`(,language . ,mode) entry)
                 (grammar
                  (alist-get language
                             quarto-ts-font-lock-language-grammars))
                 (treesit-mode-p
                  (string-suffix-p "-ts-mode" (symbol-name mode))))
      (unless (fboundp mode)
        (require mode nil t))
      (if (and treesit-mode-p grammar (treesit-ready-p grammar t))
          (if-let* ((configuration
                     (quarto-ts-font-lock--mode-configuration mode))
                    (treesit-language
                     (plist-get configuration :language)))
              (progn
                (markdown-ts--configure-current-buffer configuration)
                (setf (alist-get language markdown-ts--code-block-languages)
                      treesit-language))
            (quarto-ts-font-lock--record-conventional-mode language mode))
        (quarto-ts-font-lock--record-conventional-mode language mode)))))

(defun quarto-ts-font-lock--contrasting-background (percentage)
  "Return a theme-aware background changed by PERCENTAGE."
  (when-let* ((background (face-background 'default nil t))
              ((not (member background '(nil "unspecified-bg")))))
    (condition-case nil
        (if (color-dark-p background)
            (color-lighten-name background percentage)
          (color-darken-name background percentage))
      (error nil))))

(defun quarto-ts-font-lock--prepare-table-inline-ranges ()
  "Parse inline Markdown independently inside every pipe-table cell."
  (setq treesit-range-settings
        (append
         treesit-range-settings
         (treesit-range-rules
          :embed 'markdown-inline
          :host 'markdown
          :local t
          '((pipe_table_cell) @markdown-inline)))))

(defun quarto-ts-font-lock--remap-table-faces ()
  "Install buffer-local, theme-aware table face remappings."
  (let ((table-background
         (quarto-ts-font-lock--contrasting-background
          quarto-ts-table-background-contrast))
        (header-background
         (quarto-ts-font-lock--contrasting-background
          quarto-ts-table-header-background-contrast)))
    (if table-background
        (face-remap-add-relative
         'markdown-ts-table 'quarto-ts-table-face
         `(:background ,table-background :extend t))
      (face-remap-add-relative
       'markdown-ts-table 'quarto-ts-table-face))
    (if header-background
        (face-remap-add-relative
         'markdown-ts-table-header 'quarto-ts-table-header-face
         `(:background ,header-background))
      (face-remap-add-relative
       'markdown-ts-table-header 'quarto-ts-table-header-face))
    (face-remap-add-relative
     'markdown-ts-table-cell 'quarto-ts-table-cell-face)
    (face-remap-add-relative
     'markdown-ts-table-delimiter-cell 'quarto-ts-table-delimiter-face)
    (when header-background
      (face-remap-add-relative
       'markdown-ts-in-table
       `(:background ,header-background :extend t)))))

(defun quarto-ts-font-lock-setup (language-modes)
  "Install Quarto fontification and prepare LANGUAGE-MODES."
  (quarto-ts-font-lock--prepare-code-languages language-modes)
  (quarto-ts-font-lock--prepare-table-inline-ranges)
  (quarto-ts-font-lock--remap-table-faces)
  (face-remap-add-relative 'markdown-ts-latex 'quarto-ts-math-face)
  (font-lock-add-keywords nil quarto-ts-font-lock-keywords 'append)
  (font-lock-flush))

(provide 'quarto-ts-font-lock)
;;; quarto-ts-font-lock.el ends here
