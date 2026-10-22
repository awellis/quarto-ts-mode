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

(defcustom quarto-ts-eglot-language-server-programs
  '((julia . ("julia" "--startup-file=no" "--history-file=no"
              "-e" "using LanguageServer; runserver()"))
    (ojs . ("typescript-language-server" "--stdio")))
  "Language-server commands not supplied by Eglot itself.
Each entry maps an embedded language symbol to a process argument list."
  :type '(alist :key-type symbol :value-type (repeat string))
  :group 'quarto-ts)

(defcustom quarto-ts-eglot-typescript-server-path nil
  "Path to the TypeScript `tsserver' used for OJS language services.
When nil, use the `tsserver' executable found via variable `exec-path'."
  :type '(choice (const :tag "Automatic" nil) file)
  :group 'quarto-ts)

(defvar-local quarto-ts-eglot--diagnostics nil
  "Alist of mapped Flymake diagnostics keyed by embedded language.")

(defun quarto-ts-eglot--configure-server (language)
  "Configure an explicit Eglot server command for LANGUAGE when needed."
  (when-let* ((command
               (alist-get language quarto-ts-eglot-language-server-programs)))
    (setq-local eglot-server-programs (copy-tree eglot-server-programs))
    (let ((contact
           (if-let* (((eq language 'ojs))
                     (tsserver
                      (or quarto-ts-eglot-typescript-server-path
                          (executable-find "tsserver"))))
               (append command
                       (list :initializationOptions
                             `(:tsserver (:path ,tsserver))))
             command)))
      (setf (alist-get major-mode eglot-server-programs) contact))))

(defun quarto-ts-eglot--shadow-managed-mode-changed ()
  "Update source diagnostics when shadow-buffer Eglot state changes."
  (when (eglot-managed-p)
    ;; Diagnostics belong in the Quarto source rather than the implementation
    ;; buffer.  Eglot may enable Flymake after its asynchronous connection.
    (flymake-mode -1)
    (when (buffer-live-p quarto-ts-shadow-source-buffer)
      (with-current-buffer quarto-ts-shadow-source-buffer
        (when flymake-mode
          (flymake-start t))))))

(defun quarto-ts-eglot--source-cell-range-p (source language beg end)
  "Return non-nil when BEG through END belongs to a LANGUAGE cell in SOURCE."
  (with-current-buffer source
    (cl-some
     (lambda (cell)
       (and (eq language (quarto-ts-cell-language cell))
            (<= (quarto-ts-cell-body-begin cell) beg)
            (<= end (quarto-ts-cell-body-end cell))))
     (quarto-ts-cell-list))))

(defun quarto-ts-eglot--map-diagnostic (source language diagnostic)
  "Map shadow DIAGNOSTIC for LANGUAGE into SOURCE coordinates."
  (let* ((shadow (current-buffer))
         (beg (quarto-ts-shadow-shadow-to-source-position
               shadow (flymake-diagnostic-beg diagnostic)))
         (end (quarto-ts-shadow-shadow-to-source-position
               shadow (flymake-diagnostic-end diagnostic)))
         (type (flymake-diagnostic-type diagnostic))
        (info (list (flymake-diagnostic-origin diagnostic)
                    (flymake-diagnostic-code diagnostic)
                    (flymake-diagnostic-message diagnostic)))
         (data (flymake-diagnostic-data diagnostic)))
    (when (quarto-ts-eglot--source-cell-range-p source language beg end)
      (with-current-buffer source
        (flymake-make-diagnostic source beg end type info data)))))

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
               (list
                (copy-marker beg)
                (copy-marker end t)
                (with-current-buffer shadow
                  (copy-marker
                   (quarto-ts-shadow-source-to-shadow-position shadow beg)))
                (with-current-buffer shadow
                  (copy-marker
                   (quarto-ts-shadow-source-to-shadow-position shadow end)
                   t)))))))

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
        (let* ((source-point (point))
               (shadow-point
                (quarto-ts-shadow-source-to-shadow-position
                 shadow source-point)))
          (if (eq language 'ojs)
              (progn
                ;; Completion itself is inserted in the source buffer.  Run
                ;; the language-server exit hook in translated JavaScript,
                ;; then discard generated-only auxiliary edits by resyncing.
                (with-current-buffer shadow
                  (goto-char shadow-point)
                  (apply exit-function arguments))
                (quarto-ts-shadow-sync language))
            (let ((marker-sets
                   (quarto-ts-eglot--cell-markers source shadow language))
                  point-in-cell)
              (unwind-protect
                  (progn
                    (with-current-buffer shadow
                      (goto-char shadow-point)
                      (apply exit-function arguments)
                      (let ((new-shadow-point (point)))
                        (dolist (markers marker-sets)
                          (pcase-let ((`(,source-beg ,_source-end
                                         ,shadow-beg ,shadow-end)
                                       markers))
                            (when (and (<= shadow-beg new-shadow-point)
                                       (<= new-shadow-point shadow-end))
                              (setq point-in-cell
                                    (cons source-beg
                                          (- new-shadow-point shadow-beg))))))))
                    (quarto-ts-eglot--copy-shadow-cells
                     source shadow marker-sets)
                    (with-current-buffer source
                      (goto-char
                       (min (if point-in-cell
                                (+ (marker-position (car point-in-cell))
                                   (cdr point-in-cell))
                              source-point)
                            (point-max)))
                      ;; Remove edits to synthetic prose and restore alignment.
                      (quarto-ts-shadow-sync language)))
                (quarto-ts-eglot--release-markers marker-sets)))))))))

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
    (list language shadow
          (quarto-ts-shadow-source-to-shadow-position shadow (point)))))

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
           (list (quarto-ts-shadow-shadow-to-source-position shadow beg)
                 (quarto-ts-shadow-shadow-to-source-position shadow end)
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

(defun quarto-ts-eglot--shadow-for-file (file)
  "Return the live Quarto shadow buffer represented by FILE."
  (cl-loop for buffer in (buffer-list)
           when (and (buffer-live-p buffer)
                     (buffer-local-value 'quarto-ts-shadow-source-buffer buffer)
                     (equal
                      (file-truename
                       (buffer-local-value 'buffer-file-name buffer))
                      (file-truename file)))
           return buffer))

(defun quarto-ts-eglot--source-for-shadow-file (file)
  "Return the source buffer represented by synthetic shadow FILE."
  (when-let* ((shadow (quarto-ts-eglot--shadow-for-file file)))
    (buffer-local-value 'quarto-ts-shadow-source-buffer shadow)))

(defun quarto-ts-eglot--map-xref-location (location)
  "Map a shadow-buffer xref LOCATION back to its Quarto source."
  (if (xref-file-location-p location)
      (let* ((file (xref-file-location-file location))
             (shadow (quarto-ts-eglot--shadow-for-file file))
             (source (and shadow
                          (buffer-local-value
                           'quarto-ts-shadow-source-buffer shadow))))
        (if (not (buffer-live-p source))
            location
          (let* ((shadow-position
                  (with-current-buffer shadow
                    (save-excursion
                      (goto-char (point-min))
                      (forward-line (1- (xref-file-location-line location)))
                      (move-to-column (xref-file-location-column location))
                      (point))))
                 (source-position
                  (quarto-ts-shadow-shadow-to-source-position
                   shadow shadow-position)))
            (with-current-buffer source
              (save-excursion
                (goto-char source-position)
                (if-let* ((source-file (buffer-file-name source)))
                    (xref-make-file-location
                     source-file (line-number-at-pos) (current-column))
                  (xref-make-buffer-location source source-position)))))))
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
                        (delq
                         nil
                         (mapcar
                          (lambda (diagnostic)
                            (quarto-ts-eglot--map-diagnostic
                             source language diagnostic))
                          diagnostics))))
                   (with-current-buffer source
                     (setf (alist-get language quarto-ts-eglot--diagnostics)
                           mapped)
                     (funcall report-fn
                              (quarto-ts-eglot--combined-diagnostics)))))))))))
    (unless connected
      (setq quarto-ts-eglot--diagnostics nil)
      (funcall report-fn nil))))

(defun quarto-ts-eglot--workspace-edits-for-file (workspace-edit file)
  "Return text edits in WORKSPACE-EDIT that target FILE."
  (let (result)
    (when-let* ((changes (plist-get workspace-edit :changes)))
      (cond
       ((hash-table-p changes)
        (maphash
         (lambda (uri edits)
           (when (equal (file-truename (eglot-uri-to-path uri))
                        (file-truename file))
             (setq result (append (append edits nil) result))))
         changes))
       ((and (listp changes) (keywordp (car changes)))
        (while changes
          (let ((uri (string-remove-prefix ":" (symbol-name (pop changes))))
                (edits (pop changes)))
            (when (equal (file-truename (eglot-uri-to-path uri))
                         (file-truename file))
              (setq result (append (append edits nil) result))))))
       ((listp changes)
        (dolist (entry changes)
          (when (and (consp entry)
                     (equal (file-truename (eglot-uri-to-path (car entry)))
                            (file-truename file)))
            (setq result (append (append (cdr entry) nil) result)))))))
    (dolist (change (append (plist-get workspace-edit :documentChanges) nil))
      (unless (plist-get change :kind)
        (when-let* ((document (plist-get change :textDocument))
                    (uri (plist-get document :uri))
                    ((equal (file-truename (eglot-uri-to-path uri))
                            (file-truename file))))
          (setq result
                (append (append (plist-get change :edits) nil) result)))))
    result))

(defun quarto-ts-eglot--mapped-workspace-edits
    (source shadow language workspace-edit)
  "Map safe LANGUAGE edits in WORKSPACE-EDIT from SHADOW to SOURCE."
  (let (mapped)
    (with-current-buffer shadow
      (dolist (edit (quarto-ts-eglot--workspace-edits-for-file
                     workspace-edit buffer-file-name))
        (when-let* ((range (or (plist-get edit :range)
                              (plist-get edit :replace)))
                    (region (eglot-range-region range))
                    (shadow-beg (car region))
                    (shadow-end (cdr region))
                    (source-beg
                     (quarto-ts-shadow-shadow-to-source-position
                      shadow shadow-beg))
                    (source-end
                     (quarto-ts-shadow-shadow-to-source-position
                      shadow shadow-end))
                    ;; Reject edits that touch generated wrapper text.
                    ((= (quarto-ts-shadow-source-to-shadow-position
                         shadow source-beg)
                        shadow-beg))
                    ((= (quarto-ts-shadow-source-to-shadow-position
                         shadow source-end)
                        shadow-end))
                    ((quarto-ts-eglot--source-cell-range-p
                      source language source-beg source-end)))
          (push (list source-beg source-end (plist-get edit :newText))
                mapped))))
    mapped))

(defun quarto-ts-eglot--apply-source-text-edits (source edits)
  "Apply source-coordinate EDITS to SOURCE from the end backwards."
  (with-current-buffer source
    (atomic-change-group
      (dolist (edit (sort edits (lambda (left right) (> (car left) (car right)))))
        (pcase-let ((`(,beg ,end ,replacement) edit))
          (goto-char beg)
          (delete-region beg end)
          (insert replacement))))))

(defun quarto-ts-eglot--rename-ojs (source shadow source-point new-name)
  "Rename an OJS symbol in SOURCE at SOURCE-POINT to NEW-NAME through SHADOW."
  (with-current-buffer shadow
    (goto-char (quarto-ts-shadow-source-to-shadow-position shadow source-point))
    (let* ((server (eglot--current-server-or-lose))
           (workspace-edit
            (eglot--request
             server :textDocument/rename
             `(,@(eglot--TextDocumentPositionParams) :newName ,new-name)))
           (mapped
            (quarto-ts-eglot--mapped-workspace-edits
             source shadow 'ojs workspace-edit)))
      (eglot--apply-workspace-edit server workspace-edit this-command)
      (quarto-ts-eglot--apply-source-text-edits source mapped)
      (with-current-buffer source
        (quarto-ts-shadow-sync 'ojs)))))

(defun quarto-ts-eglot--format-ojs-cell (source shadow source-beg source-end)
  "Format an OJS cell range through SHADOW and apply safe edits to SOURCE."
  (with-current-buffer shadow
    (let* ((shadow-beg
            (quarto-ts-shadow-source-to-shadow-position shadow source-beg))
           (shadow-end
            (quarto-ts-shadow-source-to-shadow-position shadow source-end))
           (edits
            (eglot--request
             (eglot--current-server-or-lose)
             :textDocument/rangeFormatting
             `(:textDocument ,(eglot--TextDocumentIdentifier)
               :range ,(eglot-region-range shadow-beg shadow-end)
               :options (:tabSize ,tab-width
                         :insertSpaces ,(if indent-tabs-mode :json-false t)))))
           (changes (make-hash-table :test #'equal))
           workspace-edit
           mapped)
      (puthash (eglot-path-to-uri buffer-file-name) edits changes)
      (setq workspace-edit (list :changes changes)
            mapped (quarto-ts-eglot--mapped-workspace-edits
                    source shadow 'ojs workspace-edit))
      (quarto-ts-eglot--apply-source-text-edits source mapped)
      (with-current-buffer source
        (quarto-ts-shadow-sync 'ojs)))))

(defun quarto-ts-eglot--apply-shadow-edit (function)
  "Call FUNCTION in the managed shadow buffer and copy cell edits back."
  (let ((source (current-buffer)))
    (if-let* ((context (quarto-ts-eglot--shadow-context-at-point))
              (language (nth 0 context))
              (shadow (nth 1 context))
              (source-point (nth 2 context)))
        (progn
          (when (eq language 'ojs)
            (user-error "Use an OJS-specific mapped Eglot command"))
          (let ((marker-sets
                 (quarto-ts-eglot--cell-markers source shadow language)))
          (unwind-protect
              (progn
                (with-current-buffer shadow
                  (goto-char source-point)
                  (funcall function))
                (quarto-ts-eglot--copy-shadow-cells
                 source shadow marker-sets)
                (with-current-buffer source
                  (quarto-ts-shadow-sync language)))
              (quarto-ts-eglot--release-markers marker-sets))))
      (user-error "Point is not in an Eglot-managed Quarto cell"))))

(defun quarto-ts-eglot-rename (new-name)
  "Rename the embedded-language symbol at point to NEW-NAME."
  (interactive "sRename to: ")
  (let ((source (current-buffer))
        (source-point (point)))
    (if-let* ((context (quarto-ts-eglot--shadow-context-at-point))
              (language (nth 0 context))
              (shadow (nth 1 context)))
        (if (eq language 'ojs)
            (quarto-ts-eglot--rename-ojs
             source shadow source-point new-name)
          (quarto-ts-eglot--apply-shadow-edit
           (lambda () (eglot-rename new-name))))
      (user-error "Point is not in an Eglot-managed Quarto cell"))))

(defun quarto-ts-eglot-format-cell ()
  "Format the executable cell at point through Eglot."
  (interactive)
  (if-let* ((cell (quarto-ts-cell-at-point)))
      (let ((language (quarto-ts-cell-language cell))
            (beg (quarto-ts-cell-body-begin cell))
            (end (quarto-ts-cell-body-end cell)))
        (if (eq language 'ojs)
            (if-let* ((shadow (quarto-ts-shadow-buffer 'ojs)))
                (quarto-ts-eglot--format-ojs-cell
                 (current-buffer) shadow beg end)
              (user-error "No OJS shadow buffer is available"))
          (quarto-ts-eglot--apply-shadow-edit
           (lambda () (eglot-format beg end)))))
    (user-error "Point is not in a Quarto cell")))

(defun quarto-ts-eglot-code-actions ()
  "Run embedded-language Eglot code actions and map edits back."
  (interactive)
  (if-let* ((cell (quarto-ts-cell-at-point)))
      (if (eq (quarto-ts-cell-language cell) 'ojs)
          (user-error "OJS code actions are unavailable for translated cells")
        (quarto-ts-eglot--apply-shadow-edit
         (lambda () (call-interactively #'eglot-code-actions))))
    (user-error "Point is not in a Quarto cell")))

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
      (quarto-ts-eglot--configure-server language)
      (add-hook 'eglot-managed-mode-hook
                #'quarto-ts-eglot--shadow-managed-mode-changed nil t)
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
