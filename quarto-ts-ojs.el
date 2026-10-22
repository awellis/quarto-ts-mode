;;; quarto-ts-ojs.el --- Observable JavaScript support for Quarto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrew Ellis

;; Author: Andrew Ellis
;; Keywords: languages, markdown, tools
;; Package-Requires: ((emacs "32.0"))

;;; Commentary:

;; Translate Observable JavaScript cells into JavaScript suitable for a
;; TypeScript language server.  The translation retains a position map so
;; diagnostics and language features can be routed back to the Quarto source.
;; OJS execution remains in Quarto's browser runtime through live preview.

;;; Code:

(require 'cl-lib)
(require 'js)
(require 'quarto-ts-cell)
(require 'subr-x)

(defgroup quarto-ts-ojs nil
  "Observable JavaScript support for Quarto."
  :group 'quarto-ts
  :prefix "quarto-ts-ojs-")

(defcustom quarto-ts-ojs-global-declarations
  '("DOM" "FileAttachment" "Generators" "Inputs" "Mutable" "Plot"
    "Promises" "Requirement" "SQLite" "arrow" "d3" "dot" "html"
    "htl" "invalidation" "md" "now" "require" "resolve" "svg" "tex"
    "transpose" "visibility" "width")
  "Observable and Quarto globals declared in OJS shadow buffers."
  :type '(repeat string)
  :group 'quarto-ts-ojs)

(defun quarto-ts-ojs--identifier-regexp ()
  "Return a regexp matching a JavaScript identifier."
  "[[:alpha:]_$][[:alnum:]_$]*")

(defun quarto-ts-ojs--code-start (code)
  "Return the zero-based start of executable OJS in CODE.
Leading blank lines and Quarto `//|' option lines are skipped."
  (with-temp-buffer
    (insert code)
    (goto-char (point-min))
    (while (and (< (point) (point-max))
                (or (looking-at-p "[[:space:]]*$")
                    (looking-at-p "[[:space:]]*//|")))
      (forward-line 1))
    (1- (point))))

(defun quarto-ts-ojs--trimmed-end (code start)
  "Return the zero-based non-whitespace end of CODE after START."
  (let ((end (length code)))
    (while (and (> end start)
                (memq (aref code (1- end)) '(?\s ?\t ?\n ?\r)))
      (cl-decf end))
    end))

(defun quarto-ts-ojs--keyword-edits (code absolute-begin)
  "Return edits removing OJS reference keywords from CODE.
ABSOLUTE-BEGIN is the source-buffer position of CODE's first character."
  (let (edits)
    (with-temp-buffer
      (insert code)
      (js-mode)
      (syntax-propertize (point-max))
      (goto-char (point-min))
      (while (re-search-forward
              (concat "\\_<\\(?:viewof\\|mutable\\|initial\\)\\_>"
                      "[[:space:]]+")
              nil t)
        (let ((beg (match-beginning 0))
              (end (match-end 0)))
          (unless (nth 8 (syntax-ppss beg))
            (push (list (+ absolute-begin (1- beg))
                        (+ absolute-begin (1- end))
                        "")
                  edits))
          (goto-char end))))
    (nreverse edits)))

(defun quarto-ts-ojs--import-spec (code start end absolute-begin)
  "Return an OJS import translation spec for CODE between START and END.
ABSOLUTE-BEGIN is the source-buffer position of CODE's first character."
  (let ((text (substring code start end)) bindings)
    (when (string-match
           (concat "\\`import[[:space:]]+{\\([^}]+\\)}"
                   "\\(?:[[:space:]]+with[[:space:]]+{[^}]*}\\)?"
                   "[[:space:]]+from[[:space:]]+[^;]+;?\\'")
           text)
      (let* ((contents-beg (match-beginning 1))
             (contents (match-string 1 text))
             (cursor 0)
             (identifier (quarto-ts-ojs--identifier-regexp)))
        (while (< cursor (length contents))
          (let* ((comma (or (string-match "," contents cursor)
                            (length contents)))
                 (specifier (substring contents cursor comma))
                 name-beg name-end name)
            (if (string-match
                 (concat "\\_<as\\_>[[:space:]]*\\(" identifier "\\)"
                         "[[:space:]]*\\'")
                 specifier)
                (setq name-beg (+ contents-beg cursor (match-beginning 1))
                      name-end (+ contents-beg cursor (match-end 1))
                      name (match-string 1 specifier))
              (when (string-match
                     (concat "\\`[[:space:]]*"
                             "\\(?:\\(?:viewof\\|mutable\\)[[:space:]]+\\)?"
                             "\\(" identifier "\\)")
                     specifier)
                (setq name-beg (+ contents-beg cursor (match-beginning 1))
                      name-end (+ contents-beg cursor (match-end 1))
                      name (match-string 1 specifier))))
            (when name
              (push (list name name-beg name-end) bindings))
            (setq cursor (if (< comma (length contents))
                             (1+ comma)
                           (length contents)))))
        (setq bindings (nreverse bindings))
        (let ((cursor 0)
              (first t)
              edits)
          (dolist (binding bindings)
            (pcase-let ((`(,_name ,name-beg ,name-end) binding))
              (push (list (+ absolute-begin start cursor)
                          (+ absolute-begin start name-beg)
                          (if first "var " ", "))
                    edits)
              (setq cursor name-end
                    first nil)))
          (push (list (+ absolute-begin start cursor)
                      (+ absolute-begin end)
                      (if bindings ";" ""))
                edits)
          (list :edits (nreverse edits)
                ;; The translated import already declares these names.
                :names nil))))))

(defun quarto-ts-ojs--wrapper (block-p async-p generator-p)
  "Return wrapper strings for an OJS body.
BLOCK-P, ASYNC-P, and GENERATOR-P describe the parsed cell body."
  (cond
   (generator-p
    (if block-p
        (cons (if async-p "(async function* () " "(function* () ") ")()")
      (cons (if async-p
                "(async function* () { return ("
              "(function* () { return (")
            "); })()")))
   (async-p
    (if block-p
        (cons "(async () => " ")()")
      (cons "(async () => (" "))()")))
   (block-p (cons "(() => " ")()"))
   (t nil)))

(defun quarto-ts-ojs--cell-spec (source cell)
  "Return translation edits and declared names for OJS CELL in SOURCE."
  (let* ((absolute-begin (quarto-ts-cell-body-begin cell))
         (absolute-end (quarto-ts-cell-body-end cell))
         (code (substring source (1- absolute-begin) (1- absolute-end)))
         (start (quarto-ts-ojs--code-start code))
         (end (quarto-ts-ojs--trimmed-end code start))
         (identifier (quarto-ts-ojs--identifier-regexp))
         (case-fold-search nil)
         edits names)
    (when (< start end)
      (if-let* ((import (quarto-ts-ojs--import-spec
                         code start end absolute-begin)))
          (setq edits (plist-get import :edits)
                names (plist-get import :names))
        (let* ((prefix (substring code start end))
               (named-regexp
                (concat "\\`\\(?:\\(?:viewof\\|mutable\\)[[:space:]]+\\)?"
                        "\\(" identifier "\\)[[:space:]]*=[[:space:]]*"))
               (named-p (string-match named-regexp prefix))
               (body-start (+ start (if named-p (match-end 0) 0)))
               (name (and named-p (match-string 1 prefix)))
               (block-p (and (< body-start end)
                             (= (aref code body-start) ?{)
                             (= (aref code (1- end)) ?})))
               (async-p (string-match-p "\\bawait\\b" prefix))
               (generator-p (string-match-p "\\byield\\b" prefix))
               (wrapper (quarto-ts-ojs--wrapper
                         block-p async-p generator-p)))
          (when name (push name names))
          (setq edits (quarto-ts-ojs--keyword-edits code absolute-begin))
          (when wrapper
            (push (list (+ absolute-begin body-start)
                        (+ absolute-begin body-start)
                        (car wrapper))
                  edits)
            (push (list (+ absolute-begin end)
                        (+ absolute-begin end)
                        (cdr wrapper))
                  edits)))))
    (list :edits edits :names names)))

(defun quarto-ts-ojs--appendix (names)
  "Return JavaScript declarations for OJS cell NAMES and built-in globals."
  (let* ((builtins (sort (delete-dups
                          (copy-sequence quarto-ts-ojs-global-declarations))
                         #'string-lessp))
         (names (sort (cl-set-difference (delete-dups names) builtins
                                         :test #'equal)
                      #'string-lessp))
         (generic-builtins
          (cl-set-difference builtins '("FileAttachment" "Inputs" "Plot")
                             :test #'equal)))
    (concat
     "\n\n/* Quarto OJS language-service declarations. */\n"
     "/** @type {{plot: Function, dot: Function, line: Function, barX: Function, barY: Function, rectX: Function, rectY: Function, binX: Function, binY: Function, ruleX: Function, ruleY: Function, text: Function, cell: Function, frame: Function}} */ var Plot;\n"
     "/** @type {{range: Function, checkbox: Function, radio: Function, select: Function, table: Function, text: Function, textarea: Function, search: Function, toggle: Function, button: Function, form: Function}} */ var Inputs;\n"
     "/** @type {(name: string) => any} */ var FileAttachment;\n"
     (when generic-builtins
       (concat "/** @type {any} */ var "
               (string-join generic-builtins ", ") ";\n"))
     (when names
       (concat "var " (string-join names ", ") ";\n")))))

(defun quarto-ts-ojs-shadow-spec (source cells)
  "Return an OJS shadow translation specification.
SOURCE is the complete Quarto source string and CELLS are its parsed cells.
The result contains source-coordinate edits and a JavaScript appendix."
  (let ((edits (list (list 1 1 "// @ts-check\n")))
        names)
    (dolist (cell cells)
      (when (eq (quarto-ts-cell-language cell) 'ojs)
        (let ((spec (quarto-ts-ojs--cell-spec source cell)))
          (setq edits (append (plist-get spec :edits) edits)
                names (append (plist-get spec :names) names)))))
    (list :edits (sort edits (lambda (left right) (< (car left) (car right))))
          :appendix (quarto-ts-ojs--appendix names))))

(provide 'quarto-ts-ojs)
;;; quarto-ts-ojs.el ends here
