;;; quarto-ts-yaml.el --- Quarto YAML intelligence -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrew Ellis

;; Author: Andrew Ellis
;; Keywords: languages, markdown, tools
;; Package-Requires: ((emacs "32.0"))

;;; Commentary:

;; Schema-aware completion, documentation, project-value discovery, and YAML
;; Language Server integration for Quarto project files and document front
;; matter.  The schema reader consumes the definitions distributed with the
;; installed Quarto CLI rather than maintaining a separate option list.

;;; Code:

(require 'cl-lib)
(require 'eglot)
(require 'json)
(require 'subr-x)
(require 'yaml-ts-mode)

(defgroup quarto-ts-yaml nil
  "Quarto YAML editing and validation."
  :group 'quarto-ts
  :prefix "quarto-ts-yaml-")

(defcustom quarto-ts-yaml-schema-definitions-file nil
  "Quarto's `all-schema-definitions.json' file.
When nil, discover it from `quarto --paths'."
  :type '(choice (const nil) file)
  :group 'quarto-ts-yaml)

(defcustom quarto-ts-yaml-language-server-command
  '("yaml-language-server" "--stdio")
  "Command used to start YAML Language Server."
  :type '(repeat string)
  :group 'quarto-ts-yaml)

(defcustom quarto-ts-yaml-auto-eglot t
  "Non-nil means start Eglot automatically in Quarto project YAML files."
  :type 'boolean
  :group 'quarto-ts-yaml)

(defvar quarto-ts-yaml--definitions nil
  "Cached Quarto schema definitions.")

(defvar quarto-ts-yaml--definitions-file nil
  "File from which `quarto-ts-yaml--definitions' was loaded.")


(defun quarto-ts-yaml--quarto-share-path ()
  "Return the Quarto share directory, or nil."
  (when (executable-find "quarto")
    (condition-case nil
        (cadr (process-lines "quarto" "--paths"))
      (error nil))))

(defun quarto-ts-yaml--schema-file ()
  "Return the installed Quarto schema-definitions file."
  (or quarto-ts-yaml-schema-definitions-file
      (when-let* ((share (quarto-ts-yaml--quarto-share-path)))
        (expand-file-name "editor/tools/yaml/all-schema-definitions.json"
                          share))))

(defun quarto-ts-yaml--json-schemas-file ()
  "Return Quarto's compact JSON-schema bundle."
  (when-let* ((share (quarto-ts-yaml--quarto-share-path)))
    (expand-file-name "schema/json-schemas.json" share)))

(defun quarto-ts-yaml--definitions ()
  "Return Quarto's schema-definition hash table."
  (let ((file (quarto-ts-yaml--schema-file)))
    (unless (and file (file-readable-p file))
      (user-error "Cannot find Quarto YAML schema definitions"))
    (unless (and quarto-ts-yaml--definitions
                 (equal file quarto-ts-yaml--definitions-file))
      (with-temp-buffer
        (insert-file-contents file)
        (setq quarto-ts-yaml--definitions
              (json-parse-buffer :object-type 'hash-table
                                 :array-type 'list
                                 :null-object nil
                                 :false-object :json-false)
              quarto-ts-yaml--definitions-file file)))
    quarto-ts-yaml--definitions))

(defun quarto-ts-yaml--get (object key)
  "Return KEY from hash-table OBJECT."
  (and (hash-table-p object) (gethash key object)))

(defun quarto-ts-yaml--definition (name)
  "Return schema definition NAME."
  (gethash name (quarto-ts-yaml--definitions)))

(defun quarto-ts-yaml--hidden-p (schema)
  "Return non-nil when SCHEMA is marked hidden."
  (eq (quarto-ts-yaml--get
       (quarto-ts-yaml--get schema "tags") "hidden") t))

(defun quarto-ts-yaml--branches (schema)
  "Return schemas composed into SCHEMA."
  (append (quarto-ts-yaml--get schema "allOf")
          (quarto-ts-yaml--get schema "anyOf")))

(defun quarto-ts-yaml--resolve-ref (schema)
  "Resolve a direct custom reference in SCHEMA."
  (if (equal (quarto-ts-yaml--get schema "type") "ref")
      (or (quarto-ts-yaml--definition
           (quarto-ts-yaml--get schema "$ref"))
          schema)
    schema))

(defun quarto-ts-yaml--merge-properties (target source)
  "Merge hash-table SOURCE into TARGET and return TARGET."
  (when (hash-table-p source)
    (maphash (lambda (key value) (puthash key value target)) source))
  target)

(defun quarto-ts-yaml--properties (schema &optional seen)
  "Return all object properties composed into SCHEMA.
SEEN prevents recursive schema references."
  (let* ((schema (quarto-ts-yaml--resolve-ref schema))
         (identity (or (quarto-ts-yaml--get schema "$id") schema))
         (seen (or seen (make-hash-table :test #'equal)))
         (result (make-hash-table :test #'equal)))
    (unless (gethash identity seen)
      (puthash identity t seen)
      (quarto-ts-yaml--merge-properties
       result (quarto-ts-yaml--get schema "properties"))
      (dolist (branch (quarto-ts-yaml--branches schema))
        (quarto-ts-yaml--merge-properties
         result (quarto-ts-yaml--properties branch seen))))
    result))

(defun quarto-ts-yaml--array-item-schema (schema)
  "Return the item schema for array SCHEMA, when available."
  (let* ((schema (quarto-ts-yaml--resolve-ref schema))
         (item (quarto-ts-yaml--get schema "arrayOf")))
    (cond ((hash-table-p item) item)
          ((and (stringp item) (quarto-ts-yaml--definition item))
           (quarto-ts-yaml--definition item))
          (t nil))))

(defun quarto-ts-yaml--property-schema (schema key)
  "Return the schema for KEY below SCHEMA."
  (let ((property (gethash key (quarto-ts-yaml--properties schema))))
    (or property
        (let ((item (quarto-ts-yaml--array-item-schema schema)))
          (and item
               (gethash key (quarto-ts-yaml--properties item)))))))

(defun quarto-ts-yaml--schema-at-path (root path)
  "Resolve PATH of YAML keys below ROOT schema."
  (let ((schema (quarto-ts-yaml--definition root)))
    (dolist (key path schema)
      (setq schema
            (or (quarto-ts-yaml--property-schema schema key)
                schema))
      (when-let* ((item (quarto-ts-yaml--array-item-schema schema)))
        (setq schema item)))))

(defun quarto-ts-yaml--collect-values (schema &optional seen)
  "Return completion values recursively composed into SCHEMA.
SEEN prevents recursive schema references."
  (let* ((schema (quarto-ts-yaml--resolve-ref schema))
         (identity (or (quarto-ts-yaml--get schema "$id") schema))
         (seen (or seen (make-hash-table :test #'equal)))
         values)
    (unless (or (gethash identity seen)
                (quarto-ts-yaml--hidden-p schema))
      (puthash identity t seen)
      (setq values
            (append (quarto-ts-yaml--get schema "completions")
                    (quarto-ts-yaml--get schema "enum")))
      (dolist (branch (quarto-ts-yaml--branches schema))
        (setq values
              (nconc (quarto-ts-yaml--collect-values branch seen) values)))
      (when-let* ((item (quarto-ts-yaml--array-item-schema schema)))
        (setq values
              (nconc (quarto-ts-yaml--collect-values item seen) values))))
    (delete-dups (mapcar (lambda (value) (format "%s" value)) values))))

(defun quarto-ts-yaml--description (schema)
  "Return useful documentation from SCHEMA."
  (let* ((schema (quarto-ts-yaml--resolve-ref schema))
         (documentation (quarto-ts-yaml--get schema "documentation"))
         (description (quarto-ts-yaml--get schema "description")))
    (cond ((and (stringp documentation)
                (not (string-empty-p documentation)))
           documentation)
          ((stringp description) description)
          ((hash-table-p description)
           (or (gethash "long" description)
               (gethash "short" description)))
          (t nil))))

(defun quarto-ts-yaml--front-matter-region ()
  "Return the YAML front-matter bounds in a Quarto document."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at-p "---[[:space:]]*$")
      (forward-line 1)
      (let ((beg (point)))
        (when (re-search-forward "^---[[:space:]]*$" nil t)
          (cons beg (line-beginning-position)))))))

(defun quarto-ts-yaml--region ()
  "Return the YAML bounds and root schema for the current buffer."
  (cond ((derived-mode-p 'quarto-ts-project-mode)
         (list (point-min) (point-max) "project-config"))
        ((derived-mode-p 'quarto-ts-mode)
         (when-let* ((bounds (quarto-ts-yaml--front-matter-region))
                     ((<= (car bounds) (point) (cdr bounds))))
           (list (car bounds) (cdr bounds) "front-matter")))))

(defun quarto-ts-yaml--indentation ()
  "Return indentation of the current line."
  (save-excursion
    (back-to-indentation)
    (current-column)))

(defun quarto-ts-yaml--parent-path (begin)
  "Return the YAML parent-key path from BEGIN to the current line."
  (let ((target (line-beginning-position))
        (target-indent (quarto-ts-yaml--indentation))
        stack)
    (save-excursion
      (goto-char begin)
      (while (< (point) target)
        (unless (looking-at-p "[[:space:]]*\\(?:#\\|$\\)")
          (when (looking-at
                 "^\\([[:space:]]*\\)\\(?:-[[:space:]]+\\)?\\([[:alnum:]_.-]+\\)[[:space:]]*:")
            (let ((indent (length (match-string 1)))
                  (key (match-string-no-properties 2)))
              (while (and stack (>= (caar stack) indent))
                (pop stack))
              (push (cons indent key) stack))))
        (forward-line 1)))
    (while (and stack (>= (caar stack) target-indent))
      (pop stack))
    (mapcar #'cdr (reverse stack))))

(defun quarto-ts-yaml--current-key ()
  "Return the YAML key on the current line, if any."
  (save-excursion
    (beginning-of-line)
    (when (looking-at
           "^[[:space:]]*\\(?:-[[:space:]]+\\)?\\([[:alnum:]_.-]+\\)[[:space:]]*:")
      (match-string-no-properties 1))))

(defun quarto-ts-yaml--project-root ()
  "Return the current Quarto project root."
  (when buffer-file-name
    (file-name-as-directory
     (file-truename
      (or (locate-dominating-file buffer-file-name "_quarto.yml")
          (locate-dominating-file buffer-file-name "_quarto.yaml")
          (file-name-directory buffer-file-name))))))

(defun quarto-ts-yaml--project-profiles (root)
  "Return Quarto profile names found below ROOT."
  (mapcar
   (lambda (file)
     (string-remove-prefix
      "_quarto-"
      (file-name-sans-extension (file-name-nondirectory file))))
   (directory-files root t "\\`_quarto-[^.]+\\.ya?ml\\'")))

(defun quarto-ts-yaml--project-filters (root)
  "Return project-local Lua filters below ROOT."
  (mapcar (lambda (file) (file-relative-name file root))
          (directory-files-recursively root "\\.lua\\'" nil
                                       (lambda (directory)
                                         (not (string-match-p
                                               "/\\(?:_site\\|\\.git\\)/"
                                               directory))))))

(defun quarto-ts-yaml--project-extensions (root)
  "Return installed Quarto extension names below ROOT."
  (let ((directory (expand-file-name "_extensions" root)) values)
    (when (file-directory-p directory)
      (dolist (file (directory-files-recursively
                     directory "_extension\\.ya?ml\\'"))
        (push (file-relative-name (file-name-directory file) directory)
              values)))
    (mapcar #'directory-file-name values)))

(defun quarto-ts-yaml--project-values (key)
  "Return project-aware completion values for YAML KEY."
  (when-let* ((root (quarto-ts-yaml--project-root)))
    (pcase key
      ((or "profile" "profiles") (quarto-ts-yaml--project-profiles root))
      ((or "filter" "filters") (quarto-ts-yaml--project-filters root))
      ((or "extension" "extensions")
       (quarto-ts-yaml--project-extensions root))
      ((or "format" "formats")
       (quarto-ts-yaml--project-extensions root)))))

(defun quarto-ts-yaml--key-completion (begin root)
  "Return key completion data using BEGIN and ROOT schema."
  (let ((line-end (line-end-position))
        (position (point)))
    (save-excursion
      (beginning-of-line)
      (when (re-search-forward
             "^[[:space:]]*\\([[:alnum:]_.-]*\\)" line-end t)
        (let ((beg (match-beginning 1))
              (end (match-end 1)))
          (when (<= beg position end)
            (let* ((path (quarto-ts-yaml--parent-path begin))
                   (schema (quarto-ts-yaml--schema-at-path root path))
                   keys)
              (maphash
               (lambda (key value)
                 (unless (quarto-ts-yaml--hidden-p value) (push key keys)))
               (quarto-ts-yaml--properties schema))
              (list beg end (sort (delete-dups keys) #'string-lessp)
                    :exclusive 'no
                    :annotation-function (lambda (_candidate) " Quarto")))))))))

(defun quarto-ts-yaml--value-completion (begin root)
  "Return scalar or list value completion using BEGIN and ROOT schema."
  (let* ((line-begin (line-beginning-position))
         (prefix (buffer-substring-no-properties line-begin (point)))
         key beg end schema values)
    (cond
     ((string-match
       "^[[:space:]]*\\([[:alnum:]_.-]+\\)[[:space:]]*:[[:space:]]*\\([^][{},[:space:]]*\\)\\'"
       prefix)
      (setq key (match-string 1 prefix)
            beg (+ line-begin (match-beginning 2))
            end (+ line-begin (match-end 2))))
     ((string-match
       "^[[:space:]]*-[[:space:]]*\\([^][{},[:space:]]*\\)\\'" prefix)
      (setq key (car (last (quarto-ts-yaml--parent-path begin)))
            beg (+ line-begin (match-beginning 1))
            end (+ line-begin (match-end 1)))))
    (when key
      (let* ((path (quarto-ts-yaml--parent-path begin))
             (parent (quarto-ts-yaml--schema-at-path root path)))
        (setq schema (or (quarto-ts-yaml--property-schema parent key) parent)
              values (append (quarto-ts-yaml--collect-values schema)
                             (quarto-ts-yaml--project-values key))))
      (when values
        (list beg end (sort (delete-dups values) #'string-lessp)
              :exclusive 'no
              :annotation-function (lambda (_candidate) " Quarto value"))))))

(defun quarto-ts-yaml-completion-at-point ()
  "Complete Quarto YAML keys and values at point."
  (when-let* ((region (quarto-ts-yaml--region)))
    (or (quarto-ts-yaml--value-completion (nth 0 region) (nth 2 region))
        (quarto-ts-yaml--key-completion (nth 0 region) (nth 2 region)))))

(defun quarto-ts-yaml--schema-at-point ()
  "Return the option schema and key at point."
  (when-let* ((region (quarto-ts-yaml--region))
              (key (quarto-ts-yaml--current-key)))
    (let* ((path (quarto-ts-yaml--parent-path (nth 0 region)))
           (parent (quarto-ts-yaml--schema-at-path (nth 2 region) path)))
      (cons key (quarto-ts-yaml--property-schema parent key)))))

(defun quarto-ts-yaml-eldoc-function (callback &rest _ignored)
  "Send Quarto YAML option documentation to CALLBACK."
  (when-let* ((entry (quarto-ts-yaml--schema-at-point))
              (description (quarto-ts-yaml--description (cdr entry))))
    (funcall callback (format "%s: %s" (car entry) description))))

(defun quarto-ts-yaml-describe-option ()
  "Display documentation for the Quarto YAML option at point."
  (interactive)
  (if-let* ((entry (quarto-ts-yaml--schema-at-point))
            (description (quarto-ts-yaml--description (cdr entry))))
      (with-help-window "*Quarto YAML Help*"
        (princ (format "%s\n\n%s\n" (car entry) description)))
    (user-error "No documented Quarto YAML option at point")))

(defun quarto-ts-yaml--normalize-json-schema (value)
  "Convert Quarto's compact JSON schema VALUE to standard JSON Schema."
  (cond
   ((hash-table-p value)
    (let ((result (make-hash-table :test #'equal))
          (object (gethash "object" value)))
      (if (hash-table-p object)
          (progn
            (puthash "type" "object" result)
            (maphash
             (lambda (key child)
               (puthash key (quarto-ts-yaml--normalize-json-schema child)
                        result))
             object))
        (maphash
         (lambda (key child)
           (puthash key (quarto-ts-yaml--normalize-json-schema child)
                    result))
         value))
      result))
   ((listp value)
    (vconcat (mapcar #'quarto-ts-yaml--normalize-json-schema value)))
   (t value)))

(defun quarto-ts-yaml-json-schema-file ()
  "Generate and return a JSON Schema for Quarto project files."
  (let* ((source (quarto-ts-yaml--json-schemas-file))
         (directory (expand-file-name "quarto-ts-mode" user-emacs-directory))
         (target (expand-file-name "quarto-project.schema.json" directory)))
    (unless (and source (file-readable-p source))
      (user-error "Cannot find Quarto's JSON schema bundle"))
    (when (or (not (file-exists-p target))
              (file-newer-than-file-p source target))
      (make-directory directory t)
      (with-temp-buffer
        (insert-file-contents source)
        (let* ((document
                (json-parse-buffer :object-type 'hash-table
                                   :array-type 'list
                                   :null-object nil
                                   :false-object :json-false))
               (normalized
                (quarto-ts-yaml--normalize-json-schema document))
               (coding-system-for-write 'utf-8-unix))
          (puthash "$ref" "#/$defs/ProjectConfig" normalized)
          (with-temp-file target
            (insert (json-serialize normalized :null-object nil
                                    :false-object :json-false))))))
    target))

(defun quarto-ts-yaml-eglot-ensure ()
  "Start YAML Language Server with the generated Quarto schema."
  (interactive)
  (unless (executable-find (car quarto-ts-yaml-language-server-command))
    (user-error "Install yaml-language-server to validate Quarto YAML"))
  (let* ((schema (quarto-ts-yaml-json-schema-file))
         (schemas (make-hash-table :test #'equal)))
    (puthash schema ["**/_quarto.yml" "**/_quarto.yaml"] schemas)
    (setq-local eglot-server-programs (copy-tree eglot-server-programs)
                eglot-workspace-configuration
                `(:yaml (:validate t :hover t :completion t
                         :schemas ,schemas)))
    (setf (alist-get 'quarto-ts-project-mode eglot-server-programs)
          quarto-ts-yaml-language-server-command)
    (eglot-ensure)))

(defun quarto-ts-yaml-setup ()
  "Install Quarto YAML completion and documentation in the current buffer."
  (add-hook 'completion-at-point-functions
            #'quarto-ts-yaml-completion-at-point nil t)
  (add-hook 'eldoc-documentation-functions
            #'quarto-ts-yaml-eldoc-function t t)
  (eldoc-mode 1))

(defvar-keymap quarto-ts-project-mode-map
  :parent yaml-ts-mode-map
  "C-c C-q d" #'quarto-ts-yaml-describe-option
  "C-c C-q e" #'quarto-ts-yaml-eglot-ensure)

;;;###autoload
(define-derived-mode quarto-ts-project-mode yaml-ts-mode "Quarto-YAML"
  "Major mode for Quarto project configuration files."
  (quarto-ts-yaml-setup)
  (when (and quarto-ts-yaml-auto-eglot
             (executable-find (car quarto-ts-yaml-language-server-command)))
    (quarto-ts-yaml-eglot-ensure)))

;;;###autoload
(add-to-list 'auto-mode-alist
             '("_quarto\\.ya?ml\\'" . quarto-ts-project-mode))

(provide 'quarto-ts-yaml)
;;; quarto-ts-yaml.el ends here
