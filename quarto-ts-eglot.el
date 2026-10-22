;;; quarto-ts-eglot.el --- Eglot support for Quarto shadow buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrew Ellis

;; Author: Andrew Ellis
;; Keywords: languages, markdown, tools
;; Package-Requires: ((emacs "32.0"))

;;; Commentary:

;; Eglot integration for Quarto using persistent per-language shadow buffers.
;; Diagnostics, completion, hover, signature help, and xrefs are forwarded to
;; the Quarto source while ordinary language servers manage synthetic files.

;;; Code:

(require 'eglot)
(require 'flymake)
(require 'markdown-ts-mode)
(require 'quarto-ts-shadow)
(require 'xref)

(defvar-local quarto-ts-eglot--diagnostics nil
  "Alist of mapped Flymake diagnostics keyed by embedded language.")

(defun quarto-ts-eglot--map-diagnostic (source diagnostic)
  "Map shadow-buffer DIAGNOSTIC into SOURCE using identical positions."
  (let ((beg (flymake-diagnostic-beg diagnostic))
        (end (flymake-diagnostic-end diagnostic))
        (type (flymake-diagnostic-type diagnostic))
        (info (list (flymake-diagnostic-origin diagnostic)
                    (flymake-diagnostic-code diagnostic)
                    (flymake-diagnostic-message diagnostic)))
        (data (flymake-diagnostic-data diagnostic)))
    (with-current-buffer source
      (flymake-make-diagnostic source beg end type info data))))

(defun quarto-ts-eglot--combined-diagnostics ()
  "Return all currently cached embedded-language diagnostics."
  (apply #'append (mapcar #'cdr quarto-ts-eglot--diagnostics)))

(defun quarto-ts-eglot--call-in-buffer (buffer function)
  "Return a function that calls FUNCTION with BUFFER current."
  (lambda (&rest args)
    (with-current-buffer buffer
      (apply function args))))

(defun quarto-ts-eglot--cell-markers (source shadow language)
  "Return source and SHADOW marker sets for LANGUAGE cells in SOURCE."
  (with-current-buffer source
    (cl-loop for cell in (quarto-ts-cell-list)
             when (eq language (quarto-ts-cell-language cell))
             collect
             (let ((beg (quarto-ts-cell-body-begin cell))
                   (end (quarto-ts-cell-body-end cell)))
               (list (copy-marker beg)
                     (copy-marker end t)
                     (with-current-buffer shadow (copy-marker beg))
                     (with-current-buffer shadow (copy-marker end t)))))))

(defun quarto-ts-eglot--release-markers (marker-sets)
  "Detach every marker in MARKER-SETS."
  (dolist (markers marker-sets)
    (dolist (marker markers)
      (set-marker marker nil))))

(defun quarto-ts-eglot--copy-shadow-cells (source shadow marker-sets)
  "Copy cell bodies from SHADOW into SOURCE using MARKER-SETS."
  (with-current-buffer source
    (atomic-change-group
      (dolist (markers (reverse marker-sets))
        (pcase-let ((`(,source-beg ,source-end ,shadow-beg ,shadow-end)
                     markers))
          (let ((contents
                 (with-current-buffer shadow
                   (buffer-substring-no-properties shadow-beg shadow-end))))
            (goto-char source-beg)
            (delete-region source-beg source-end)
            (insert contents)))))))

(defun quarto-ts-eglot--completion-exit-function
    (source shadow language exit-function)
  "Run EXIT-FUNCTION in SHADOW and copy LANGUAGE cell edits to SOURCE."
  (lambda (&rest arguments)
    (when (and (buffer-live-p source) (buffer-live-p shadow))
      (with-current-buffer source
        (quarto-ts-shadow-sync language)
        (let ((source-point (point))
              (marker-sets
               (quarto-ts-eglot--cell-markers source shadow language))
              point-in-cell)
          (unwind-protect
              (progn
                (with-current-buffer shadow
                  (goto-char source-point)
                  (apply exit-function arguments)
                  (let ((shadow-point (point)))
                    (dolist (markers marker-sets)
                      (pcase-let ((`(,source-beg ,_source-end
                                     ,shadow-beg ,shadow-end)
                                   markers))
                        (when (and (<= shadow-beg shadow-point)
                                   (<= shadow-point shadow-end))
                          (setq point-in-cell
                                (cons source-beg
                                      (- shadow-point shadow-beg))))))))
                (quarto-ts-eglot--copy-shadow-cells
                 source shadow marker-sets)
                (with-current-buffer source
                  (goto-char
                   (min (if point-in-cell
                            (+ (marker-position (car point-in-cell))
                               (cdr point-in-cell))
                          source-point)
                        (point-max)))
                  ;; Remove any language-server edits made outside executable
                  ;; cell bodies and restore exact source/shadow alignment.
                  (quarto-ts-shadow-sync language)))
            (quarto-ts-eglot--release-markers marker-sets)))))))

(defun quarto-ts-eglot--completion-properties
    (properties source shadow language)
  "Wrap completion PROPERTIES for SOURCE, SHADOW, and LANGUAGE."
  (cl-loop for (key value) on properties by #'cddr
           append
           (list key
                 (cond
                  ((and (eq key :exit-function) (functionp value))
                   (quarto-ts-eglot--completion-exit-function
                    source shadow language value))
                  ((functionp value)
                   (quarto-ts-eglot--call-in-buffer shadow value))
                  (t value)))))

(defun quarto-ts-eglot--shadow-context-at-point ()
  "Return (LANGUAGE SHADOW POSITION) for an Eglot-managed cell at point."
  (when-let* ((cell (quarto-ts-cell-at-point))
              (language (quarto-ts-cell-language cell))
              (shadow (alist-get language quarto-ts-shadow--buffers))
              ((buffer-live-p shadow))
              ((with-current-buffer shadow (eglot-managed-p))))
    (quarto-ts-shadow-sync language)
    (list language shadow (point))))

(defun quarto-ts-eglot-completion-at-point ()
  "Return embedded-language Eglot completion at point, when available."
  (let ((source (current-buffer)))
    (when-let* ((context (quarto-ts-eglot--shadow-context-at-point))
                (language (nth 0 context))
                (shadow (nth 1 context))
                (source-point (nth 2 context)))
      (with-current-buffer shadow
        (goto-char source-point)
        (when-let* ((completion (eglot-completion-at-point))
                    (beg (nth 0 completion))
                    (end (nth 1 completion))
                    (table (nth 2 completion)))
          (append
           (list beg end
                 (if (functionp table)
                     (quarto-ts-eglot--call-in-buffer shadow table)
                   table))
           (quarto-ts-eglot--completion-properties
            (nthcdr 3 completion) source shadow language)))))))

(defun quarto-ts-eglot-hover-eldoc-function (callback &rest ignored)
  "Forward Eglot hover documentation to CALLBACK for the cell at point.
IGNORED contains extra arguments supplied by ElDoc."
  (when-let* ((context (quarto-ts-eglot--shadow-context-at-point))
              (shadow (nth 1 context))
              (source-point (nth 2 context)))
    (with-current-buffer shadow
      (goto-char source-point)
      (apply #'eglot-hover-eldoc-function callback ignored))))

(defun quarto-ts-eglot-signature-eldoc-function (callback &rest ignored)
  "Forward Eglot signature help to CALLBACK for the cell at point.
IGNORED contains extra arguments supplied by ElDoc."
  (when-let* ((context (quarto-ts-eglot--shadow-context-at-point))
              (shadow (nth 1 context))
              (source-point (nth 2 context)))
    (with-current-buffer shadow
      (goto-char source-point)
      (apply #'eglot-signature-eldoc-function callback ignored))))

(defun quarto-ts-eglot--source-for-shadow-file (file)
  "Return the source buffer represented by synthetic shadow FILE."
  (cl-loop for buffer in (buffer-list)
           when (and (buffer-live-p buffer)
                     (buffer-local-value 'quarto-ts-shadow-source-buffer buffer)
                     (equal
                      (file-truename
                       (buffer-local-value 'buffer-file-name buffer))
                      (file-truename file)))
           return (buffer-local-value 'quarto-ts-shadow-source-buffer buffer)))

(defun quarto-ts-eglot--map-xref-location (location)
  "Map a shadow-buffer xref LOCATION back to its Quarto source."
  (if (xref-file-location-p location)
      (let* ((file (xref-file-location-file location))
             (source (quarto-ts-eglot--source-for-shadow-file file)))
        (if (not (buffer-live-p source))
            location
          (let ((line (xref-file-location-line location))
                (column (xref-file-location-column location)))
            (if-let* ((source-file (buffer-file-name source)))
                (xref-make-file-location source-file line column)
              (with-current-buffer source
                (save-excursion
                  (goto-char (point-min))
                  (forward-line (1- line))
                  (move-to-column column)
                  (xref-make-buffer-location source (point))))))))
    location))

(defun quarto-ts-eglot--map-xref-item (item)
  "Map xref ITEM from a shadow buffer into its Quarto source."
  (let ((summary (xref-item-summary item))
        (location
         (quarto-ts-eglot--map-xref-location (xref-item-location item))))
    (if (xref-match-item-p item)
        (xref-make-match summary location (xref-match-length item))
      (xref-make summary location))))

(defun quarto-ts-eglot--call-xref (function &rest arguments)
  "Call Eglot xref FUNCTION with ARGUMENTS in the cell shadow buffer."
  (when-let* ((context (quarto-ts-eglot--shadow-context-at-point))
              (shadow (nth 1 context))
              (source-point (nth 2 context)))
    (with-current-buffer shadow
      (goto-char source-point)
      (mapcar #'quarto-ts-eglot--map-xref-item
              (apply function 'eglot arguments)))))

(defun quarto-ts-eglot-xref-backend ()
  "Return the Quarto Eglot xref backend when point is in a managed cell."
  (when (quarto-ts-eglot--shadow-context-at-point)
    'quarto-ts-eglot))

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql quarto-ts-eglot)))
  "Return Eglot's identifier for the embedded language at point."
  (when-let* ((context (quarto-ts-eglot--shadow-context-at-point))
              (shadow (nth 1 context))
              (source-point (nth 2 context)))
    (with-current-buffer shadow
      (goto-char source-point)
      (xref-backend-identifier-at-point 'eglot))))

(cl-defmethod xref-backend-definitions ((_backend (eql quarto-ts-eglot)) identifier)
  "Return mapped embedded-language definitions for IDENTIFIER."
  (quarto-ts-eglot--call-xref #'xref-backend-definitions identifier))

(cl-defmethod xref-backend-references ((_backend (eql quarto-ts-eglot)) identifier)
  "Return mapped embedded-language references for IDENTIFIER."
  (quarto-ts-eglot--call-xref #'xref-backend-references identifier))

(cl-defmethod xref-backend-apropos ((_backend (eql quarto-ts-eglot)) pattern)
  "Return mapped embedded-language symbols matching PATTERN."
  (quarto-ts-eglot--call-xref #'xref-backend-apropos pattern))

(cl-defmethod xref-backend-xref-kinds ((_backend (eql quarto-ts-eglot)))
  "Return xref kinds supported by the embedded language server."
  (when-let* ((context (quarto-ts-eglot--shadow-context-at-point))
              (shadow (nth 1 context))
              (source-point (nth 2 context)))
    (with-current-buffer shadow
      (goto-char source-point)
      (xref-backend-xref-kinds 'eglot))))

(cl-defmethod xref-backend-xrefs-by-kind
  ((_backend (eql quarto-ts-eglot)) identifier kind)
  "Return mapped xrefs for IDENTIFIER of KIND."
  (quarto-ts-eglot--call-xref
   #'xref-backend-xrefs-by-kind identifier kind))

(defun quarto-ts-eglot-flymake-backend (report-fn &rest _args)
  "Report diagnostics from Eglot-managed language shadow buffers.
REPORT-FN follows the protocol of `flymake-diagnostic-functions'."
  (let ((source (current-buffer))
        connected)
    (dolist (entry quarto-ts-shadow--buffers)
      (pcase-let ((`(,language . ,shadow) entry))
        (when (and (buffer-live-p shadow)
                   (with-current-buffer shadow (eglot-managed-p)))
          (setq connected t)
          (with-current-buffer shadow
            (eglot-flymake-backend
             (lambda (diagnostics &rest _report-args)
               (when (buffer-live-p source)
                 (let ((mapped
                        (mapcar
                         (lambda (diagnostic)
                           (quarto-ts-eglot--map-diagnostic source diagnostic))
                         diagnostics)))
                   (with-current-buffer source
                     (setf (alist-get language quarto-ts-eglot--diagnostics)
                           mapped)
                     (funcall report-fn
                              (quarto-ts-eglot--combined-diagnostics)))))))))))
    (unless connected
      (setq quarto-ts-eglot--diagnostics nil)
      (funcall report-fn nil))))

(defun quarto-ts-eglot-ensure (language)
  "Create LANGUAGE's shadow buffer and ensure that Eglot manages it."
  (interactive
   (list
    (intern
     (completing-read
      "Language: "
      (delete-dups
       (mapcar (lambda (cell)
                 (symbol-name (quarto-ts-cell-language cell)))
               (quarto-ts-cell-list)))
      nil t))))
  (let ((source (current-buffer))
        (shadow (quarto-ts-shadow-buffer language)))
    (with-current-buffer shadow
      (unless (eglot-current-server)
        (let ((current-prefix-arg nil))
          (call-interactively #'eglot)))
      ;; Diagnostics are displayed in the source document, not in this
      ;; implementation buffer.  This also prevents Eglot's shadow Flymake
      ;; callback from replacing the forwarding callback below.
      (flymake-mode -1))
    (unless (memq #'quarto-ts-eglot-flymake-backend
                  flymake-diagnostic-functions)
      (add-hook 'flymake-diagnostic-functions
                #'quarto-ts-eglot-flymake-backend nil t))
    (unless (memq #'quarto-ts-eglot-completion-at-point
                  completion-at-point-functions)
      (add-hook 'completion-at-point-functions
                #'quarto-ts-eglot-completion-at-point nil t))
    (add-hook 'eldoc-documentation-functions
              #'quarto-ts-eglot-hover-eldoc-function t t)
    (add-hook 'eldoc-documentation-functions
              #'quarto-ts-eglot-signature-eldoc-function t t)
    (unless (memq #'quarto-ts-eglot-xref-backend xref-backend-functions)
      (add-hook 'xref-backend-functions
                #'quarto-ts-eglot-xref-backend nil t))
    (eldoc-mode 1)
    ;; `markdown-ts-mode' otherwise redirects these commands into short-lived
    ;; work buffers that cannot share the persistent Eglot session.
    (setq-local markdown-ts-code-block-commands
                (remove 'completion-at-point
                        markdown-ts-code-block-commands))
    (setq-local markdown-ts-code-block-thing-commands
                (remove 'xref-find-definitions
                        markdown-ts-code-block-thing-commands))
    (flymake-mode 1)
    (flymake-start t)
    (message "Eglot is managing %s in %s"
             language (buffer-name shadow))
    source))

(provide 'quarto-ts-eglot)
;;; quarto-ts-eglot.el ends here
