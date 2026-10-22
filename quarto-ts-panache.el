;;; quarto-ts-panache.el --- Panache integration for Quarto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrew Ellis

;; Author: Andrew Ellis
;; Keywords: languages, markdown, tools
;; Package-Requires: ((emacs "32.0"))

;;; Commentary:

;; Manage Panache as the document-level Quarto language server.  Panache owns
;; Markdown and Quarto structure in the source buffer, while language-specific
;; Eglot servers continue to manage executable code through shadow buffers.

;;; Code:

(require 'eglot)

(defgroup quarto-ts-panache nil
  "Panache language-server integration for Quarto."
  :group 'quarto-ts
  :prefix "quarto-ts-panache-")

(defcustom quarto-ts-panache-server-command '("panache" "lsp")
  "Command used to start the Panache language server."
  :type '(repeat string)
  :group 'quarto-ts-panache)

(defcustom quarto-ts-panache-auto-start nil
  "Non-nil means start Panache automatically in `quarto-ts-mode'."
  :type 'boolean
  :safe #'booleanp
  :group 'quarto-ts-panache)

(defcustom quarto-ts-panache-format-on-save nil
  "Non-nil means format Quarto source buffers with Panache before saving.
This is disabled by default because document formatting can make broad edits."
  :type 'boolean
  :safe #'booleanp
  :group 'quarto-ts-panache)

(defun quarto-ts-panache-available-p ()
  "Return non-nil when the configured Panache executable is available."
  (when-let* ((program (car quarto-ts-panache-server-command)))
    (executable-find program)))

(defun quarto-ts-panache--configure-server ()
  "Register Panache as the Eglot server for the current Quarto buffer."
  (setq-local eglot-server-programs (copy-tree eglot-server-programs))
  (setf (alist-get 'quarto-ts-mode eglot-server-programs)
        (copy-sequence quarto-ts-panache-server-command)))

(defun quarto-ts-panache-ensure ()
  "Start or connect Panache for the current Quarto source buffer."
  (interactive)
  (unless (derived-mode-p 'quarto-ts-mode)
    (user-error "Panache integration requires a Quarto source buffer"))
  (unless (quarto-ts-panache-available-p)
    (user-error "Cannot find the Panache executable `%s'"
                (car quarto-ts-panache-server-command)))
  (quarto-ts-panache--configure-server)
  (eglot-ensure)
  (message "Starting Panache for %s" (buffer-name)))

(defun quarto-ts-panache-format-buffer ()
  "Format the current Quarto document with Panache."
  (interactive)
  (unless (eglot-managed-p)
    (user-error "Panache is not managing this Quarto buffer"))
  (eglot-format-buffer))

(defun quarto-ts-panache-code-actions ()
  "Show Panache code actions for the current Quarto document."
  (interactive)
  (unless (eglot-managed-p)
    (user-error "Panache is not managing this Quarto buffer"))
  (call-interactively #'eglot-code-actions))

(defun quarto-ts-panache-reconnect ()
  "Reconnect the current Panache session, or start one when absent."
  (interactive)
  (if-let* ((server (eglot-current-server)))
      (eglot-reconnect server)
    (quarto-ts-panache-ensure)))

(defun quarto-ts-panache--format-on-save ()
  "Format the current buffer when Panache format-on-save is enabled."
  (when (and quarto-ts-panache-format-on-save
             (eglot-managed-p))
    (eglot-format-buffer)))

(defun quarto-ts-panache-setup ()
  "Configure optional Panache support in the current Quarto buffer."
  (quarto-ts-panache--configure-server)
  (add-hook 'before-save-hook #'quarto-ts-panache--format-on-save nil t)
  (when (and quarto-ts-panache-auto-start
             (quarto-ts-panache-available-p))
    (eglot-ensure)))

(provide 'quarto-ts-panache)
;;; quarto-ts-panache.el ends here
