;;; quarto-ts-preview.el --- Quarto preview and render processes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrew Ellis

;; Author: Andrew Ellis
;; Keywords: languages, markdown, tools
;; Package-Requires: ((emacs "32.0"))

;;; Commentary:

;; Project-aware Quarto preview and render process management.  Preview
;; sessions are keyed by Quarto project root or standalone source file, so
;; several documents and projects can be previewed independently.

;;; Code:

(require 'ansi-color)
(require 'browse-url)
(require 'cl-lib)
(require 'subr-x)

(defgroup quarto-ts-preview nil
  "Preview and render Quarto documents."
  :group 'quarto-ts
  :prefix "quarto-ts-preview-")

(defcustom quarto-ts-command "quarto"
  "Quarto executable used for preview and render commands."
  :type 'string
  :group 'quarto-ts-preview)

(defcustom quarto-ts-preview-arguments '("--no-browser")
  "Additional arguments passed to `quarto preview'."
  :type '(repeat string)
  :group 'quarto-ts-preview)

(defcustom quarto-ts-render-arguments nil
  "Additional arguments passed to every `quarto render' command."
  :type '(repeat string)
  :group 'quarto-ts-preview)

(defcustom quarto-ts-preview-auto-browse t
  "When non-nil, open a preview URL when Quarto first reports it."
  :type 'boolean
  :group 'quarto-ts-preview)

(defcustom quarto-ts-preview-display-buffer t
  "When non-nil, display the preview process buffer after starting."
  :type 'boolean
  :group 'quarto-ts-preview)

(defcustom quarto-ts-render-display-buffer t
  "When non-nil, display the render process buffer after starting."
  :type 'boolean
  :group 'quarto-ts-preview)

(defcustom quarto-ts-save-before-command t
  "When non-nil, save modified source buffers before Quarto commands."
  :type 'boolean
  :group 'quarto-ts-preview)

(cl-defstruct (quarto-ts-preview-session
               (:constructor quarto-ts-preview-session-create))
  "A running or completed Quarto preview session."
  key
  root
  target
  source-file
  process
  buffer
  url
  browser-opened-p)

(defvar quarto-ts-preview--sessions (make-hash-table :test #'equal)
  "Preview sessions keyed by project root or standalone source file.")

(defun quarto-ts-preview--source-file ()
  "Return the current Quarto source file or signal a user-facing error."
  (unless buffer-file-name
    (user-error "The current buffer is not visiting a file"))
  (when (file-remote-p buffer-file-name)
    (user-error "Remote Quarto previews are not supported yet"))
  (expand-file-name buffer-file-name))

(defun quarto-ts-preview--project-root (file)
  "Return the Quarto project root containing FILE, or nil."
  (or (locate-dominating-file file "_quarto.yml")
      (locate-dominating-file file "_quarto.yaml")))

(defun quarto-ts-preview--context (&optional file)
  "Return preview context for FILE or the current buffer.
The result is a plist containing `:key', `:root', `:target', `:source-file',
and `:project'."
  (let* ((file (file-truename (or file (quarto-ts-preview--source-file))))
         (project-root (quarto-ts-preview--project-root file)))
    (if project-root
        (let ((root (file-name-as-directory (file-truename project-root))))
          (list :key root
                :root root
                :target nil
                :source-file file
                :project t))
      (let ((root (file-name-directory file)))
        (list :key file
              :root root
              :target (file-name-nondirectory file)
              :source-file file
              :project nil)))))

(defun quarto-ts-preview--session (&optional file)
  "Return the preview session associated with FILE or the current buffer."
  (gethash (plist-get (quarto-ts-preview--context file) :key)
           quarto-ts-preview--sessions))

(defun quarto-ts-preview--buffer-name (kind key)
  "Return a process buffer name for KIND and session KEY."
  (format "*quarto-%s:%s:%s*"
          kind
          (file-name-nondirectory
           (directory-file-name
            (if (file-directory-p key) key (file-name-directory key))))
          (substring (secure-hash 'sha1 key) 0 7)))

(defun quarto-ts-preview--prepare-buffer (name directory)
  "Return an erased process buffer NAME rooted at DIRECTORY."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (setq-local default-directory directory)))
    buffer))

(defun quarto-ts-preview--append-output (process output)
  "Append cleaned OUTPUT from PROCESS to its process buffer."
  (when-let* ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (moving (= (point) (process-mark process))))
          (goto-char (process-mark process))
          (insert (ansi-color-filter-apply output))
          (set-marker (process-mark process) (point))
          (when moving
            (goto-char (process-mark process))))))))

(defun quarto-ts-preview--extract-url (text)
  "Return the most recent Quarto preview URL found in TEXT."
  (let ((start 0)
        url)
    (while (string-match
            "Browse at[[:space:]]+\\(https?://[^][[:space:]<>]+\\)"
            text start)
      (setq url (string-trim-right (match-string 1 text) "[.,;]+")
            start (match-end 0)))
    url))

(defun quarto-ts-preview--process-filter (process output)
  "Handle preview PROCESS OUTPUT and capture its browser URL."
  (quarto-ts-preview--append-output process output)
  (when-let* ((session (process-get process 'quarto-ts-preview-session))
              (buffer (process-buffer process))
              (url
               (with-current-buffer buffer
                 (quarto-ts-preview--extract-url
                  (buffer-substring-no-properties (point-min) (point-max))))))
    (setf (quarto-ts-preview-session-url session) url)
    (when (and quarto-ts-preview-auto-browse
               (not (quarto-ts-preview-session-browser-opened-p session)))
      (setf (quarto-ts-preview-session-browser-opened-p session) t)
      (browse-url url))))

(defun quarto-ts-preview--process-sentinel (process event)
  "Handle preview PROCESS lifecycle EVENT."
  (quarto-ts-preview--append-output process (format "\n[%s] %s" (process-name process) event))
  (when-let* ((session (process-get process 'quarto-ts-preview-session)))
    (unless (process-live-p process)
      (setf (quarto-ts-preview-session-process session) nil))))

(defun quarto-ts-preview--save-source ()
  "Save the current source buffer when configured and modified."
  (when (and quarto-ts-save-before-command
             (buffer-modified-p))
    (save-buffer)))

(defun quarto-ts-preview--command (context)
  "Return the `quarto preview' command for CONTEXT."
  (append (list quarto-ts-command "preview")
          (when-let* ((target (plist-get context :target)))
            (list target))
          quarto-ts-preview-arguments))

(defun quarto-ts-preview-start ()
  "Start or restart the preview session for the current file or project."
  (interactive)
  (quarto-ts-preview--save-source)
  (let* ((context (quarto-ts-preview--context))
         (key (plist-get context :key))
         (root (plist-get context :root))
         (target (plist-get context :target))
         (source-file (plist-get context :source-file))
         (existing (gethash key quarto-ts-preview--sessions))
         (buffer-name (quarto-ts-preview--buffer-name "preview" key))
         (buffer (quarto-ts-preview--prepare-buffer buffer-name root))
         process
         session)
    (when-let* ((old-process
                 (and existing
                      (quarto-ts-preview-session-process existing))))
      (when (process-live-p old-process)
        (delete-process old-process)))
    (setq session
          (quarto-ts-preview-session-create
           :key key
           :root root
           :target target
           :source-file source-file
           :buffer buffer))
    (let ((default-directory root))
      (setq process
            (make-process
             :name (format "quarto-preview-%s"
                           (substring (secure-hash 'sha1 key) 0 7))
             :buffer buffer
             :command (quarto-ts-preview--command context)
             :connection-type 'pipe
             :noquery t
             :filter #'quarto-ts-preview--process-filter
             :sentinel #'quarto-ts-preview--process-sentinel)))
    (setf (quarto-ts-preview-session-process session) process)
    (process-put process 'quarto-ts-preview-session session)
    (puthash key session quarto-ts-preview--sessions)
    (when quarto-ts-preview-display-buffer
      (display-buffer buffer))
    (message "Started Quarto preview in %s" root)
    session))

(defun quarto-ts-preview-stop ()
  "Stop the preview session associated with the current file or project."
  (interactive)
  (if-let* ((context (quarto-ts-preview--context))
            (key (plist-get context :key))
            (session (gethash key quarto-ts-preview--sessions)))
      (progn
        (when-let* ((process (quarto-ts-preview-session-process session)))
          (when (process-live-p process)
            (delete-process process)))
        (remhash key quarto-ts-preview--sessions)
        (message "Stopped Quarto preview"))
    (user-error "No Quarto preview session for this file or project")))

(defun quarto-ts-preview-stop-all ()
  "Stop and forget every Quarto preview session."
  (interactive)
  (maphash
   (lambda (_key session)
     (when-let* ((process (quarto-ts-preview-session-process session)))
       (when (process-live-p process)
         (delete-process process))))
   quarto-ts-preview--sessions)
  (clrhash quarto-ts-preview--sessions)
  (message "Stopped all Quarto previews"))

(defun quarto-ts-preview-browse ()
  "Open the current file or project's preview URL."
  (interactive)
  (if-let* ((session (quarto-ts-preview--session))
            (url (quarto-ts-preview-session-url session)))
      (browse-url url)
    (user-error "The Quarto preview URL is not available yet")))

(defun quarto-ts-preview-live-p ()
  "Return non-nil when the current file has a live preview process."
  (when-let* ((session (quarto-ts-preview--session))
              (process (quarto-ts-preview-session-process session)))
    (process-live-p process)))

(defun quarto-ts-preview-update ()
  "Save the document so its Quarto preview runtime reevaluates it.
Start a preview session when the current file has no live session."
  (interactive)
  (if (quarto-ts-preview-live-p)
      (progn
        (quarto-ts-preview--save-source)
        (message "Updated Quarto preview runtime")
        (quarto-ts-preview--session))
    (quarto-ts-preview-start)))

(defun quarto-ts-preview-refresh ()
  "Save the current document and reopen its preview URL.
Quarto's file watcher performs the actual re-render."
  (interactive)
  (quarto-ts-preview-update)
  (quarto-ts-preview-browse))

(defun quarto-ts-preview-show-log ()
  "Display the process buffer for the current preview session."
  (interactive)
  (if-let* ((session (quarto-ts-preview--session))
            (buffer (quarto-ts-preview-session-buffer session))
            ((buffer-live-p buffer)))
      (pop-to-buffer buffer)
    (user-error "No Quarto preview session for this file or project")))

(defun quarto-ts-render--sentinel (process event)
  "Handle render PROCESS lifecycle EVENT."
  (quarto-ts-preview--append-output process (format "\n[%s] %s" (process-name process) event))
  (when (memq (process-status process) '(exit signal))
    (if (= (process-exit-status process) 0)
        (message "Quarto render completed")
      (message "Quarto render failed; see %s"
               (buffer-name (process-buffer process))))))

(defun quarto-ts-render--start (target root arguments)
  "Start rendering TARGET from ROOT with additional ARGUMENTS."
  (let* ((key (if target (expand-file-name target root) root))
         (buffer
          (quarto-ts-preview--prepare-buffer
           (quarto-ts-preview--buffer-name "render" key) root))
         (command
          (append (list quarto-ts-command "render")
                  (when target (list target))
                  arguments
                  quarto-ts-render-arguments))
         process)
    (let ((default-directory root))
      (setq process
            (make-process
             :name (format "quarto-render-%s"
                           (substring (secure-hash 'sha1 key) 0 7))
             :buffer buffer
             :command command
             :connection-type 'pipe
             :noquery t
             :filter #'quarto-ts-preview--append-output
             :sentinel #'quarto-ts-render--sentinel)))
    (when quarto-ts-render-display-buffer
      (display-buffer buffer))
    process))

(defun quarto-ts-render (&optional format)
  "Render the current Quarto document, optionally to FORMAT."
  (interactive)
  (quarto-ts-preview--save-source)
  (let* ((file (quarto-ts-preview--source-file))
         (context (quarto-ts-preview--context file))
         (root (plist-get context :root))
         (target (file-relative-name file root)))
    (quarto-ts-render--start
     target root (when format (list "--to" format)))))

(defun quarto-ts-render-to (format)
  "Render the current Quarto document to FORMAT."
  (interactive "sRender format: ")
  (quarto-ts-render format))

(defun quarto-ts-render-project (&optional format)
  "Render the current Quarto project, optionally to FORMAT."
  (interactive)
  (quarto-ts-preview--save-source)
  (let* ((file (quarto-ts-preview--source-file))
         (root (or (quarto-ts-preview--project-root file)
                   (user-error "The current file is not in a Quarto project"))))
    (quarto-ts-render--start
     nil (file-name-as-directory (file-truename root))
     (when format (list "--to" format)))))

(provide 'quarto-ts-preview)
;;; quarto-ts-preview.el ends here
