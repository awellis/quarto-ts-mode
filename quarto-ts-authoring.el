;;; quarto-ts-authoring.el --- Quarto authoring completion -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrew Ellis

;; Author: Andrew Ellis
;; Keywords: languages, markdown, tools
;; Package-Requires: ((emacs "32.0"))

;;; Commentary:

;; Context-sensitive completion for Quarto cell options and project-wide
;; cross-references.  Citation completion is intentionally left to Citar or
;; another bibliography package.

;;; Code:

(require 'cl-lib)
(require 'quarto-ts-cell)
(require 'subr-x)

(declare-function citar-capf "citar-capf")
(declare-function citar-insert-citation "citar")

(defgroup quarto-ts-authoring nil
  "Quarto-specific authoring assistance."
  :group 'quarto-ts
  :prefix "quarto-ts-authoring-")

(defcustom quarto-ts-authoring-cell-options
  '("label" "eval" "echo" "output" "warning" "error" "include"
    "cache" "freeze" "code-fold" "code-summary" "code-line-numbers"
    "fig-cap" "fig-alt" "fig-align" "fig-width" "fig-height"
    "fig-asp" "fig-dpi" "fig-format" "fig-pos" "fig-scap"
    "fig-subcap" "tbl-cap" "tbl-cap-location" "tbl-column"
    "tbl-colwidths" "tbl-subcap" "classes" "column")
  "Cell-option names offered after a Quarto `#|' prefix."
  :type '(repeat string)
  :group 'quarto-ts-authoring)

(defcustom quarto-ts-authoring-option-values
  '(("eval" . ("true" "false"))
    ("echo" . ("true" "false" "fenced"))
    ("output" . ("true" "false" "asis"))
    ("warning" . ("true" "false"))
    ("error" . ("true" "false"))
    ("include" . ("true" "false"))
    ("cache" . ("true" "false" "refresh"))
    ("freeze" . ("true" "false" "auto"))
    ("code-fold" . ("true" "false" "show"))
    ("code-line-numbers" . ("true" "false")))
  "Known completion values for selected Quarto cell options."
  :type '(alist :key-type string :value-type (repeat string))
  :group 'quarto-ts-authoring)

(defcustom quarto-ts-authoring-crossref-prefixes
  '("fig" "tbl" "sec" "eq" "lst" "thm" "lem" "cor" "prp"
    "cnj" "def" "exm" "exr")
  "Prefixes that identify Quarto cross-references rather than citations."
  :type '(repeat string)
  :group 'quarto-ts-authoring)

(defcustom quarto-ts-authoring-ignored-directories
  '(".git" ".quarto" "_site" "_book" "node_modules" "renv")
  "Directory names excluded from project cross-reference searches."
  :type '(repeat string)
  :group 'quarto-ts-authoring)

(defcustom quarto-ts-authoring-callout-types
  '("note" "warning" "important" "tip" "caution")
  "Callout types offered by `quarto-ts-insert-callout'."
  :type '(repeat string)
  :group 'quarto-ts-authoring)

(defcustom quarto-ts-authoring-shortcodes
  '("meta" "var" "include" "pagebreak" "video" "embed")
  "Shortcode names offered by `quarto-ts-insert-shortcode'."
  :type '(repeat string)
  :group 'quarto-ts-authoring)

(defvar quarto-ts-authoring--label-cache (make-hash-table :test #'equal)
  "Project label cache keyed by project root.")

(defun quarto-ts-authoring--project-root ()
  "Return the current Quarto project root or source directory."
  (when buffer-file-name
    (file-name-as-directory
     (file-truename
      (or (locate-dominating-file buffer-file-name "_quarto.yml")
          (locate-dominating-file buffer-file-name "_quarto.yaml")
          (file-name-directory buffer-file-name))))))

(defun quarto-ts-authoring--ignored-directory-p (directory)
  "Return non-nil when DIRECTORY should be excluded from searches."
  (member (file-name-nondirectory (directory-file-name directory))
          quarto-ts-authoring-ignored-directories))

(defun quarto-ts-authoring--project-files (root)
  "Return Quarto source files below ROOT."
  (directory-files-recursively
   root "\\.qmd\\'" nil
   (lambda (directory)
     (not (quarto-ts-authoring--ignored-directory-p directory)))))

(defun quarto-ts-authoring--extract-labels ()
  "Extract Quarto labels from the current buffer."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let (labels)
        (while (re-search-forward
                "^[[:space:]]*#|[[:space:]]*label[[:space:]]*:[[:space:]]*['\"]?\\([[:alnum:]_.:-]+\\)"
                nil t)
          (push (match-string-no-properties 1) labels))
        (goto-char (point-min))
        (while (re-search-forward
                "[({]#\\([[:alnum:]_.:-]+\\)[})]"
                nil t)
          (push (match-string-no-properties 1) labels))
        (delete-dups labels)))))

(defun quarto-ts-authoring--file-signature (files)
  "Return a modification signature for FILES."
  (mapcar
   (lambda (file)
     (let ((attributes (file-attributes file)))
       (list file
             (file-attribute-modification-time attributes)
             (file-attribute-size attributes))))
   files))

(defun quarto-ts-authoring--disk-labels (root)
  "Return cached labels read from Quarto files below ROOT."
  (let* ((files (quarto-ts-authoring--project-files root))
         (signature (quarto-ts-authoring--file-signature files))
         (cached (gethash root quarto-ts-authoring--label-cache)))
    (if (equal signature (car-safe cached))
        (cdr cached)
      (let (labels)
        (dolist (file files)
          (unless (and buffer-file-name
                       (equal (file-truename file)
                              (file-truename buffer-file-name)))
            (with-temp-buffer
              (insert-file-contents file)
              (setq labels
                    (nconc (quarto-ts-authoring--extract-labels) labels)))))
        (setq labels (sort (delete-dups labels) #'string-lessp))
        (puthash root (cons signature labels)
                 quarto-ts-authoring--label-cache)
        labels))))

(defun quarto-ts-authoring-project-labels ()
  "Return cross-reference labels from the current Quarto project."
  (when-let* ((root (quarto-ts-authoring--project-root)))
    (sort
     (delete-dups
      (append (quarto-ts-authoring--extract-labels)
              (quarto-ts-authoring--disk-labels root)))
     #'string-lessp)))

(defun quarto-ts-authoring-clear-cache ()
  "Clear cached project cross-reference labels."
  (interactive)
  (clrhash quarto-ts-authoring--label-cache))

(defun quarto-ts-authoring--option-value-completion ()
  "Return completion data for a Quarto cell-option value at point."
  (let* ((line-beginning (line-beginning-position))
         (prefix (buffer-substring-no-properties line-beginning (point))))
    (when (string-match
           "^[[:space:]]*#|[[:space:]]*\\([[:alnum:]_-]+\\)[[:space:]]*:[[:space:]]*\\([[:alnum:]_-]*\\)\\'"
           prefix)
      (when-let* ((values
                   (cdr (assoc-string (match-string 1 prefix)
                                      quarto-ts-authoring-option-values t))))
        (list (+ line-beginning (match-beginning 2))
              (+ line-beginning (match-end 2))
              values
              :exclusive 'no)))))

(defun quarto-ts-authoring--option-key-completion ()
  "Return completion data for a Quarto cell-option key at point."
  (let ((position (point))
        (line-beginning (line-beginning-position))
        (line-end (line-end-position)))
    (save-excursion
      (goto-char line-beginning)
      (when (re-search-forward
             "^[[:space:]]*#|[[:space:]]*\\([[:alnum:]_-]*\\)"
             line-end t)
        (let ((beg (match-beginning 1))
              (end (match-end 1)))
          (when (<= beg position end)
            (list beg end quarto-ts-authoring-cell-options
                  :exclusive 'no
                  :annotation-function (lambda (_candidate) " cell option"))))))))

(defun quarto-ts-authoring--cell-option-completion ()
  "Return cell-option completion data when point is on a `#|' line."
  (when (quarto-ts-cell-at-point)
    (or (quarto-ts-authoring--option-value-completion)
        (quarto-ts-authoring--option-key-completion))))

(defun quarto-ts-authoring--crossref-prefix-p (text)
  "Return non-nil when TEXT resembles a Quarto cross-reference key."
  (and (>= (length text) 3)
       (cl-some
        (lambda (prefix)
          (or (string-prefix-p text prefix)
              (string-prefix-p (concat prefix "-") text)))
        quarto-ts-authoring-crossref-prefixes)))

(defun quarto-ts-authoring--crossref-label-p (label)
  "Return non-nil when LABEL has a recognized cross-reference prefix."
  (cl-some
   (lambda (prefix)
     (string-prefix-p (concat prefix "-") label))
   quarto-ts-authoring-crossref-prefixes))

(defun quarto-ts-authoring--crossref-completion ()
  "Return project cross-reference completion data at point."
  (unless (quarto-ts-cell-at-point)
    (let ((end (point)))
      (save-excursion
        (skip-chars-backward "[:alnum:]_.:-")
        (let ((beg (point)))
          (when (and (> beg (point-min))
                     (eq (char-before beg) ?@))
            (let ((prefix (buffer-substring-no-properties beg end)))
              (when (quarto-ts-authoring--crossref-prefix-p prefix)
                (let ((labels
                       (cl-remove-if-not
                        #'quarto-ts-authoring--crossref-label-p
                        (quarto-ts-authoring-project-labels))))
                  (when labels
                    (list beg end labels
                          :exclusive 'no
                          :annotation-function
                          (lambda (_candidate) " cross-reference"))))))))))))

(defun quarto-ts-authoring-completion-at-point ()
  "Complete Quarto cell options or project cross-references at point."
  (or (quarto-ts-authoring--cell-option-completion)
      (quarto-ts-authoring--crossref-completion)))

(defun quarto-ts-insert-citation ()
  "Insert or edit a Pandoc citation using Citar."
  (interactive)
  (if (require 'citar nil t)
      (call-interactively #'citar-insert-citation)
    (user-error "Citar is not installed")))

(defun quarto-ts-insert-callout (type title)
  "Insert a Quarto callout of TYPE with optional TITLE.
When the region is active, wrap its contents in the callout."
  (interactive
   (list (completing-read "Callout type: "
                          quarto-ts-authoring-callout-types nil t nil nil
                          "note")
         (read-string "Title (optional): ")))
  (let ((contents
         (when (use-region-p)
           (prog1 (buffer-substring-no-properties
                   (region-beginning) (region-end))
             (delete-region (region-beginning) (region-end))))))
    (insert (format "::: {.callout-%s}\n" type))
    (unless (string-empty-p title)
      (insert (format "## %s\n\n" title)))
    (let ((body-start (point)))
      (if contents
          (insert contents)
        (insert "\n"))
      (unless (bolp) (insert "\n"))
      (insert ":::")
      (unless contents (goto-char body-start)))))

(defun quarto-ts-insert-shortcode (name arguments)
  "Insert Quarto shortcode NAME with ARGUMENTS."
  (interactive
   (list (completing-read "Shortcode: "
                          quarto-ts-authoring-shortcodes nil nil)
         (read-string "Arguments: ")))
  (insert (format "{{< %s%s >}}"
                  name
                  (if (string-empty-p arguments)
                      ""
                    (concat " " arguments)))))

(defun quarto-ts-authoring-setup ()
  "Install optional citation completion for a Quarto source buffer."
  (when (require 'citar-capf nil t)
    (add-hook 'completion-at-point-functions #'citar-capf t t)))

(provide 'quarto-ts-authoring)
;;; quarto-ts-authoring.el ends here
