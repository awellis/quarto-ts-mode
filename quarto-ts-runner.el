;;; quarto-ts-runner.el --- Execute Quarto cells in language REPLs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrew Ellis

;; Author: Andrew Ellis
;; Keywords: languages, markdown, tools
;; Package-Requires: ((emacs "32.0"))

;;; Commentary:

;; Language-neutral cell execution for `quarto-ts-mode'.  This module locates
;; cells and delegates code strings to optional ESS, Python, and Julia REPL
;; adapters.  Observable JavaScript runs in Quarto's reactive browser preview
;; rather than being incorrectly evaluated as standalone JavaScript.

;;; Code:

(require 'cl-lib)
(require 'quarto-ts-cell)
(require 'quarto-ts-preview)
(require 'subr-x)

(declare-function ess-force-buffer-current "ess-inf")
(declare-function ess-send-string "ess-inf")
(declare-function python-shell-calculate-command "python")
(declare-function python-shell-get-process "python")
(declare-function python-shell-send-string "python")
(declare-function run-python "python")
(declare-function julia-repl "julia-repl")
(declare-function julia-repl--send-string "julia-repl")

(defvar ess-ask-for-ess-directory)
(defvar python-shell--first-prompt-received)
(defvar python-shell-dedicated)

(defgroup quarto-ts-runner nil
  "Execute Quarto cells in language-specific REPLs."
  :group 'quarto-ts
  :prefix "quarto-ts-runner-")

(defcustom quarto-ts-runner-backends
  '((r . quarto-ts-runner-ess-send)
    (python . quarto-ts-runner-python-send)
    (julia . quarto-ts-runner-julia-send)
    (ojs . quarto-ts-runner-ojs-send))
  "Alist mapping cell languages to code-sending functions.
Each function receives CODE and the corresponding `quarto-ts-cell' object."
  :type '(alist :key-type symbol :value-type function)
  :group 'quarto-ts-runner)

(defcustom quarto-ts-runner-open-functions
  '((r . quarto-ts-runner-ess-open)
    (python . quarto-ts-runner-python-open)
    (julia . quarto-ts-runner-julia-open)
    (ojs . quarto-ts-runner-ojs-open))
  "Alist mapping cell languages to functions that display their REPL."
  :type '(alist :key-type symbol :value-type function)
  :group 'quarto-ts-runner)

(defcustom quarto-ts-runner-respect-eval-option t
  "When non-nil, do not execute cells whose `eval' option is false."
  :type 'boolean
  :group 'quarto-ts-runner)

(defcustom quarto-ts-runner-python-startup-timeout 10
  "Seconds to wait for a newly started Python shell to initialize."
  :type 'number
  :group 'quarto-ts-runner)

(defcustom quarto-ts-runner-ess-visibly 'nowait
  "Value passed as VISIBLY when sending Quarto code through ESS."
  :type '(choice (const :tag "Invisible" nil)
                 (const :tag "Show without waiting" nowait)
                 (const :tag "Show and wait" t))
  :group 'quarto-ts-runner)

(defun quarto-ts-runner--cell-evaluated-p (cell)
  "Return non-nil when CELL should be evaluated."
  (or (not quarto-ts-runner-respect-eval-option)
      (let ((value (cdr (assoc-string "eval"
                                      (quarto-ts-cell-options cell) t))))
        (not (and value
                  (member (downcase (string-trim value))
                          '("false" "no" "off" "0")))))))

(defun quarto-ts-runner--cell-code (cell &optional beg end)
  "Return CELL code, optionally restricted to BEG and END."
  (let ((beg (max (or beg (quarto-ts-cell-body-begin cell))
                  (quarto-ts-cell-body-begin cell)))
        (end (min (or end (quarto-ts-cell-body-end cell))
                  (quarto-ts-cell-body-end cell))))
    (when (< beg end)
      (buffer-substring-no-properties beg end))))

(defun quarto-ts-runner-send-cell (cell &optional beg end)
  "Send CELL to its configured backend.
When BEG and END are non-nil, send only their intersection with CELL."
  (if (not (quarto-ts-runner--cell-evaluated-p cell))
      (progn
        (message "Skipping Quarto cell with eval: false")
        nil)
    (let* ((language (quarto-ts-cell-language cell))
           (backend (alist-get language quarto-ts-runner-backends))
           (code (quarto-ts-runner--cell-code cell beg end)))
      (unless backend
        (user-error "No Quarto runner configured for `%s'" language))
      (when (and code (not (string-empty-p (string-trim code))))
        (funcall backend code cell)
        t))))

(defun quarto-ts-runner-run-cell ()
  "Run the executable cell at point."
  (interactive)
  (if-let* ((cell (quarto-ts-cell-at-point)))
      (quarto-ts-runner-send-cell cell)
    (user-error "Point is not in a Quarto cell")))

(defun quarto-ts-runner-run-cell-and-next ()
  "Run the executable cell at point and move to the next cell."
  (interactive)
  (quarto-ts-runner-run-cell)
  (condition-case nil
      (quarto-ts-cell-next)
    (user-error nil)))

(defun quarto-ts-runner-run-line ()
  "Run the current line when it belongs to an executable cell."
  (interactive)
  (if-let* ((cell (quarto-ts-cell-at-point)))
      (quarto-ts-runner-send-cell
       cell (line-beginning-position) (line-beginning-position 2))
    (user-error "Point is not in a Quarto cell")))

(defun quarto-ts-runner-run-region (beg end)
  "Run executable code intersecting the region from BEG to END."
  (interactive "r")
  (let ((cells (quarto-ts-cell-list beg end))
        sent)
    (dolist (cell cells)
      (when (quarto-ts-runner-send-cell cell beg end)
        (setq sent t)))
    (unless sent
      (user-error "The region contains no executable Quarto code"))))

(defun quarto-ts-runner--run-cells (cells)
  "Run CELLS in document order and return the number sent."
  (let ((count 0))
    (dolist (cell cells)
      (when (quarto-ts-runner-send-cell cell)
        (cl-incf count)))
    (message "Sent %d Quarto cell%s" count (if (= count 1) "" "s"))
    count))

(defun quarto-ts-runner-run-cells-above ()
  "Run every executable cell above the current cell or point."
  (interactive)
  (let* ((current (quarto-ts-cell-at-point))
         (limit (if current
                    (quarto-ts-cell-fence-begin current)
                  (point)))
         (cells
          (cl-remove-if-not
           (lambda (cell)
             (< (quarto-ts-cell-fence-begin cell) limit))
           (quarto-ts-cell-list))))
    (quarto-ts-runner--run-cells cells)))

(defun quarto-ts-runner-run-all-cells ()
  "Run every executable cell in the current Quarto document."
  (interactive)
  (quarto-ts-runner--run-cells (quarto-ts-cell-list)))

(defun quarto-ts-runner--read-language ()
  "Read an embedded language present in the current document."
  (intern
   (completing-read
    "Language REPL: "
    (delete-dups
     (mapcar (lambda (cell)
               (symbol-name (quarto-ts-cell-language cell)))
             (quarto-ts-cell-list)))
    nil t)))

(defun quarto-ts-runner-open-repl (language)
  "Open the configured REPL for LANGUAGE."
  (interactive
   (list (or (when-let* ((cell (quarto-ts-cell-at-point)))
               (quarto-ts-cell-language cell))
             (quarto-ts-runner--read-language))))
  (if-let* ((open-function
             (alist-get language quarto-ts-runner-open-functions)))
      (funcall open-function)
    (user-error "No Quarto REPL opener configured for `%s'" language)))

(defun quarto-ts-runner--ess-process ()
  "Return an R ESS process, starting or selecting one when necessary."
  (unless (and (require 'ess-inf nil t)
               (require 'ess-r-mode nil t))
    (user-error "ESS is not installed"))
  (setq-local ess-language "S"
              ess-dialect "R")
  (let ((ess-ask-for-ess-directory nil))
    (get-buffer-process
     (ess-force-buffer-current "R process to use: "))))

(defun quarto-ts-runner-ess-send (code _cell)
  "Send CODE from a Quarto cell to an R ESS process."
  (let ((process (quarto-ts-runner--ess-process)))
    (ess-send-string process code quarto-ts-runner-ess-visibly
                     "Sent Quarto R cell")))

(defun quarto-ts-runner-ess-open ()
  "Display the R ESS process used by the current Quarto document."
  (pop-to-buffer (process-buffer (quarto-ts-runner--ess-process))))

(defun quarto-ts-runner--python-process ()
  "Return an initialized Python process, starting one when necessary."
  (require 'python)
  (let* ((process
          (or (python-shell-get-process)
              (run-python (python-shell-calculate-command)
                          python-shell-dedicated nil)))
         (deadline (+ (float-time) quarto-ts-runner-python-startup-timeout)))
    (while (and (process-live-p process)
                (not (buffer-local-value
                      'python-shell--first-prompt-received
                      (process-buffer process)))
                (< (float-time) deadline))
      (accept-process-output process 0.1))
    (unless (and (process-live-p process)
                 (buffer-local-value
                  'python-shell--first-prompt-received
                  (process-buffer process)))
      (user-error "Python shell did not initialize within %.1f seconds"
                  quarto-ts-runner-python-startup-timeout))
    process))

(defun quarto-ts-runner-python-send (code _cell)
  "Send CODE from a Quarto cell to an inferior Python process."
  (python-shell-send-string code (quarto-ts-runner--python-process) t))

(defun quarto-ts-runner-python-open ()
  "Display the Python process used by the current Quarto document."
  (pop-to-buffer (process-buffer (quarto-ts-runner--python-process))))

(defun quarto-ts-runner--require-julia-repl ()
  "Load `julia-repl' or signal a user-facing error."
  (unless (require 'julia-repl nil t)
    (user-error "The julia-repl package is not installed")))

(defun quarto-ts-runner-julia-send (code _cell)
  "Send CODE from a Quarto cell to `julia-repl'."
  (quarto-ts-runner--require-julia-repl)
  ;; julia-repl has no public string-sending API.  Keeping this adapter in one
  ;; function limits reliance on its private primitive.
  (julia-repl--send-string code))

(defun quarto-ts-runner-julia-open ()
  "Display the Julia REPL used by the current Quarto document."
  (quarto-ts-runner--require-julia-repl)
  (julia-repl))

(defun quarto-ts-runner-ojs-send (_code _cell)
  "Reevaluate OJS through the current document's Quarto preview runtime."
  (quarto-ts-preview-update)
  (message "Reevaluating the Quarto OJS reactive graph"))

(defun quarto-ts-runner-ojs-open ()
  "Open or start the Quarto browser runtime used for OJS."
  (if (quarto-ts-preview-live-p)
      (condition-case nil
          (quarto-ts-preview-browse)
        (user-error (quarto-ts-preview-show-log)))
    (quarto-ts-preview-start)))

(provide 'quarto-ts-runner)
;;; quarto-ts-runner.el ends here
