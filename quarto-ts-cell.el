;;; quarto-ts-cell.el --- Quarto executable-cell model -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrew Ellis

;; Author: Andrew Ellis
;; Keywords: languages, markdown, tools
;; Package-Requires: ((emacs "32.0"))

;;; Commentary:

;; Parser-neutral representation and navigation for executable cells in
;; Quarto documents.  The first backend uses Emacs's Markdown tree-sitter
;; grammar; future backends may use a dedicated Quarto grammar.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'treesit)

(cl-defstruct (quarto-ts-cell
               (:constructor quarto-ts-cell-create))
  "An executable cell in a Quarto document."
  language
  body-begin
  body-end
  fence-begin
  fence-end
  label
  options)

(defvar-local quarto-ts-cell-provider #'quarto-ts-cell--markdown-cells
  "Function returning the executable cells in the current buffer.
The function accepts optional region bounds BEG and END.")

(defface quarto-ts-cell-fold-summary
  '((t :inherit shadow :slant italic))
  "Face used for folded Quarto cell summaries."
  :group 'quarto-ts)

(defvar-local quarto-ts-cell--fold-overlays nil
  "Body-hiding overlays for folded cells in the current buffer.")

(defun quarto-ts-cell--normalize-language (text)
  "Return the normalized language symbol represented by TEXT."
  (when text
    (let ((case-fold-search t)
          (text (string-trim text)))
      (when (string-match
             "\\`[{:[:space:]]*\\.?\\([[:alnum:]_+.-]+\\)"
             text)
        (intern (downcase (match-string 1 text)))))))

(defun quarto-ts-cell--parse-options (beg end)
  "Return Quarto cell options found between BEG and END.
The result is an alist whose keys and values are strings."
  (save-excursion
    (save-restriction
      (narrow-to-region beg end)
      (goto-char (point-min))
      (let (options)
        (while (re-search-forward
                "^[[:space:]]*#|[[:space:]]*\\([^:\n]+\\):[[:space:]]*\\(.*\\)$"
                nil t)
          (push (cons (string-trim (match-string-no-properties 1))
                      (string-trim (match-string-no-properties 2)))
                options))
        (nreverse options)))))

(defun quarto-ts-cell--descendant (node type)
  "Return the first descendant of NODE whose type is TYPE."
  (treesit-search-subtree
   node
   (lambda (candidate)
     (string= (treesit-node-type candidate) type))))

(defun quarto-ts-cell--from-markdown-node (node)
  "Construct a `quarto-ts-cell' from Markdown fenced block NODE."
  (when-let* ((body (quarto-ts-cell--descendant node "code_fence_content")))
    (let* ((info (quarto-ts-cell--descendant node "info_string"))
           (language-node
            (and info (quarto-ts-cell--descendant info "language")))
           (language
            (quarto-ts-cell--normalize-language
             (and language-node (treesit-node-text language-node t))))
           (body-begin (treesit-node-start body))
           (body-end (treesit-node-end body))
           (options (quarto-ts-cell--parse-options body-begin body-end)))
      (when language
        (quarto-ts-cell-create
         :language language
         :body-begin body-begin
         :body-end body-end
         :fence-begin (treesit-node-start node)
         :fence-end (treesit-node-end node)
         :label (cdr (assoc "label" options))
         :options options)))))

(defun quarto-ts-cell--markdown-cells (&optional beg end)
  "Return Markdown fenced cells intersecting optional BEG and END."
  (unless (treesit-parser-list nil 'markdown)
    (user-error "The current buffer has no Markdown tree-sitter parser"))
  (let* ((root (treesit-buffer-root-node 'markdown))
         (captures
          (treesit-query-capture root '((fenced_code_block) @cell)))
         cells)
    (dolist (capture captures)
      (when-let* ((cell (quarto-ts-cell--from-markdown-node (cdr capture)))
                  (cell-beg (quarto-ts-cell-fence-begin cell))
                  (cell-end (quarto-ts-cell-fence-end cell))
                  ((or (null beg) (null end)
                       (and (< cell-beg end) (> cell-end beg)))))
        (push cell cells)))
    (nreverse cells)))

(defun quarto-ts-cell-list (&optional beg end)
  "Return executable cells intersecting optional region BEG to END."
  (funcall quarto-ts-cell-provider beg end))

(defun quarto-ts-cell-at-point (&optional position)
  "Return the executable cell containing POSITION or point."
  (let ((position (or position (point))))
    (cl-find-if
     (lambda (cell)
       (and (<= (quarto-ts-cell-fence-begin cell) position)
            (< position (quarto-ts-cell-fence-end cell))))
     (quarto-ts-cell-list))))

(defun quarto-ts-cell-next (&optional count)
  "Move to the next executable cell.
With COUNT, move forward that many cells."
  (interactive "p")
  (let ((count (or count 1)))
    (if (< count 0)
        (quarto-ts-cell-previous (- count))
      (dotimes (_ count)
        (if-let* ((cell
                   (cl-find-if
                    (lambda (candidate)
                      (> (quarto-ts-cell-fence-begin candidate) (point)))
                    (quarto-ts-cell-list))))
            (goto-char (quarto-ts-cell-body-begin cell))
          (user-error "No next Quarto cell"))))))

(defun quarto-ts-cell-previous (&optional count)
  "Move to the previous executable cell.
With COUNT, move backward that many cells."
  (interactive "p")
  (let ((count (or count 1)))
    (if (< count 0)
        (quarto-ts-cell-next (- count))
      (dotimes (_ count)
        (let* ((current (quarto-ts-cell-at-point))
               (before (if current
                           (quarto-ts-cell-fence-begin current)
                         (point))))
          (if-let* ((cell
                     (cl-find-if
                      (lambda (candidate)
                        (< (quarto-ts-cell-fence-begin candidate) before))
                      (reverse (quarto-ts-cell-list)))))
              (goto-char (quarto-ts-cell-body-begin cell))
            (user-error "No previous Quarto cell")))))))

(defun quarto-ts-cell-mark ()
  "Mark the body of the executable cell at point."
  (interactive)
  (if-let* ((cell (quarto-ts-cell-at-point)))
      (progn
        (goto-char (quarto-ts-cell-body-begin cell))
        (push-mark (quarto-ts-cell-body-end cell) nil t))
    (user-error "Point is not in a Quarto cell")))

(defun quarto-ts-cell--fold-overlay (cell)
  "Return the folding overlay associated with CELL, or nil."
  (cl-find-if
   (lambda (overlay)
     (and (overlay-buffer overlay)
          (= (overlay-start overlay) (quarto-ts-cell-body-begin cell))
          (= (overlay-end overlay) (quarto-ts-cell-body-end cell))))
   quarto-ts-cell--fold-overlays))

(defun quarto-ts-cell--delete-fold-overlay (overlay)
  "Delete folding OVERLAY and its summary overlay."
  (when-let* ((summary (overlay-get overlay 'quarto-ts-cell-summary-overlay)))
    (delete-overlay summary))
  (setq quarto-ts-cell--fold-overlays
        (delq overlay quarto-ts-cell--fold-overlays))
  (delete-overlay overlay))

(defun quarto-ts-cell--isearch-open (overlay)
  "Unfold the cell hidden by OVERLAY during an isearch match."
  (quarto-ts-cell--delete-fold-overlay overlay))

(defun quarto-ts-cell--fold-summary (cell)
  "Return a display summary for folded CELL."
  (let* ((language (quarto-ts-cell-language cell))
         (label (quarto-ts-cell-label cell))
         (lines (count-lines (quarto-ts-cell-body-begin cell)
                             (quarto-ts-cell-body-end cell))))
    (propertize
     (format "  … %s%s · %d line%s\n"
             language
             (if label (format ": %s" label) "")
             lines
             (if (= lines 1) "" "s"))
     'face 'quarto-ts-cell-fold-summary)))

(defun quarto-ts-cell-fold (&optional cell)
  "Fold CELL or the executable cell at point."
  (interactive)
  (let ((cell (or cell (quarto-ts-cell-at-point))))
    (unless cell
      (user-error "Point is not in a Quarto cell"))
    (unless (quarto-ts-cell--fold-overlay cell)
      (let* ((beg (quarto-ts-cell-body-begin cell))
             (end (quarto-ts-cell-body-end cell))
             (body (make-overlay beg end nil t nil))
             (summary (make-overlay beg beg nil t nil)))
        (overlay-put body 'invisible 'quarto-ts-cell)
        (overlay-put body 'evaporate t)
        (overlay-put body 'isearch-open-invisible
                     #'quarto-ts-cell--isearch-open)
        (overlay-put body 'quarto-ts-cell-summary-overlay summary)
        (overlay-put summary 'before-string
                     (quarto-ts-cell--fold-summary cell))
        (push body quarto-ts-cell--fold-overlays)))))

(defun quarto-ts-cell-unfold (&optional cell)
  "Unfold CELL or the executable cell at point."
  (interactive)
  (let ((cell (or cell (quarto-ts-cell-at-point))))
    (unless cell
      (user-error "Point is not in a Quarto cell"))
    (when-let* ((overlay (quarto-ts-cell--fold-overlay cell)))
      (quarto-ts-cell--delete-fold-overlay overlay))))

(defun quarto-ts-cell-toggle-fold ()
  "Toggle folding of the executable cell at point."
  (interactive)
  (if-let* ((cell (quarto-ts-cell-at-point)))
      (if (quarto-ts-cell--fold-overlay cell)
          (quarto-ts-cell-unfold cell)
        (quarto-ts-cell-fold cell))
    (user-error "Point is not in a Quarto cell")))

(defun quarto-ts-cell-fold-all ()
  "Fold every executable cell in the current document."
  (interactive)
  (dolist (cell (quarto-ts-cell-list))
    (quarto-ts-cell-fold cell)))

(defun quarto-ts-cell-unfold-all ()
  "Unfold every executable cell in the current document."
  (interactive)
  (dolist (overlay (copy-sequence quarto-ts-cell--fold-overlays))
    (quarto-ts-cell--delete-fold-overlay overlay)))

(define-minor-mode quarto-ts-cell-fold-mode
  "Enable folding of executable Quarto cell bodies."
  :lighter nil
  (if quarto-ts-cell-fold-mode
      (progn
        (add-to-invisibility-spec 'quarto-ts-cell)
        (add-hook 'kill-buffer-hook #'quarto-ts-cell-unfold-all nil t))
    (remove-hook 'kill-buffer-hook #'quarto-ts-cell-unfold-all t)
    (quarto-ts-cell-unfold-all)
    (remove-from-invisibility-spec 'quarto-ts-cell)))

(provide 'quarto-ts-cell)
;;; quarto-ts-cell.el ends here
