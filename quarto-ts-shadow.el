;;; quarto-ts-shadow.el --- Language shadow buffers for Quarto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrew Ellis

;; Author: Andrew Ellis
;; Keywords: languages, markdown, tools
;; Package-Requires: ((emacs "32.0"))

;;; Commentary:

;; Maintain persistent per-language buffers for a Quarto source buffer.  Each
;; shadow buffer normally has the same length and line structure as its source.
;; Cell bodies for one language are copied and all other source characters are
;; blanked.  Observable JavaScript is translated to valid JavaScript with an
;; explicit bidirectional position map.

;;; Code:

(require 'cl-lib)
(require 'quarto-ts-cell)
(require 'quarto-ts-ojs)
(require 'subr-x)

(defgroup quarto-ts-shadow nil
  "Persistent embedded-language buffers for Quarto."
  :group 'quarto-ts
  :prefix "quarto-ts-shadow-")

(defcustom quarto-ts-shadow-language-modes
  '((r . ess-r-mode)
    (python . python-mode)
    (julia . julia-mode)
    (ojs . js-mode))
  "Alist mapping cell languages to shadow-buffer major modes."
  :type '(alist :key-type symbol :value-type function)
  :group 'quarto-ts-shadow)

(defcustom quarto-ts-shadow-language-extensions
  '((r . "R")
    (python . "py")
    (julia . "jl")
    (ojs . "js"))
  "Alist mapping cell languages to synthetic file extensions."
  :type '(alist :key-type symbol :value-type string)
  :group 'quarto-ts-shadow)

(defcustom quarto-ts-shadow-sync-delay 0.15
  "Idle delay in seconds before synchronizing shadow buffers."
  :type 'number
  :group 'quarto-ts-shadow)

(defvar-local quarto-ts-shadow--buffers nil
  "Alist mapping languages to shadow buffers for the current source.")

(defvar-local quarto-ts-shadow--sync-timer nil
  "Pending shadow-buffer synchronization timer.")

(defvar-local quarto-ts-shadow-source-buffer nil
  "Source Quarto buffer associated with the current shadow buffer.")

(defvar-local quarto-ts-shadow-language nil
  "Embedded language represented by the current shadow buffer.")

(defvar-local quarto-ts-shadow-position-map nil
  "Position map for a transformed shadow buffer, or nil for identity mapping.")

(cl-defstruct (quarto-ts-shadow-edit
               (:constructor quarto-ts-shadow-edit-create))
  "One replacement relating source and transformed shadow positions."
  source-beg source-end shadow-beg shadow-end)

(cl-defstruct (quarto-ts-shadow-map
               (:constructor quarto-ts-shadow-map-create))
  "Bidirectional position mapping for a transformed shadow buffer."
  edits source-max shadow-source-max)

(defun quarto-ts-shadow--blank-source (source)
  "Replace every non-newline character in SOURCE with a space."
  (replace-regexp-in-string "[^\n]" " " source t t))

(defun quarto-ts-shadow--apply-edits (contents edits)
  "Apply source-coordinate EDITS to CONTENTS and return text plus a map."
  (let ((source-cursor 1)
        (shadow-cursor 1)
        (source-max (1+ (length contents)))
        parts mapped-edits)
    (dolist (edit edits)
      (pcase-let ((`(,beg ,end ,replacement) edit))
        (unless (and (<= source-cursor beg) (<= beg end source-max))
          (error "Invalid or overlapping Quarto shadow edit: %S" edit))
        (let* ((unchanged (substring contents (1- source-cursor) (1- beg)))
               (shadow-beg (+ shadow-cursor (length unchanged)))
               (shadow-end (+ shadow-beg (length replacement))))
          (push unchanged parts)
          (push replacement parts)
          (push (quarto-ts-shadow-edit-create
                 :source-beg beg :source-end end
                 :shadow-beg shadow-beg :shadow-end shadow-end)
                mapped-edits)
          (setq source-cursor end
                shadow-cursor shadow-end))))
    (push (substring contents (1- source-cursor)) parts)
    (let ((result (apply #'concat (nreverse parts))))
      (cons result
            (quarto-ts-shadow-map-create
             :edits (nreverse mapped-edits)
             :source-max source-max
             :shadow-source-max (1+ (length result)))))))

(defun quarto-ts-shadow--contents (language)
  "Return a plist containing shadow contents and position map for LANGUAGE."
  (let ((source (buffer-substring-no-properties (point-min) (point-max)))
        (cells (quarto-ts-cell-list)))
    (with-temp-buffer
      (insert (quarto-ts-shadow--blank-source source))
      (dolist (cell cells)
        (when (eq language (quarto-ts-cell-language cell))
          (let ((beg (quarto-ts-cell-body-begin cell))
                (end (quarto-ts-cell-body-end cell)))
            (goto-char beg)
            (delete-region beg end)
            (insert (substring source (1- beg) (1- end))))))
      (let ((contents (buffer-string)))
        (if (eq language 'ojs)
            (let* ((spec (quarto-ts-ojs-shadow-spec source cells))
                   (translated
                    (quarto-ts-shadow--apply-edits
                     contents (plist-get spec :edits))))
              (list :contents (concat (car translated)
                                      (plist-get spec :appendix))
                    :map (cdr translated)))
          (list :contents contents :map nil))))))

(defun quarto-ts-shadow-source-to-shadow-position (shadow position)
  "Map source POSITION into SHADOW buffer coordinates."
  (with-current-buffer shadow
    (if (not quarto-ts-shadow-position-map)
        position
      (let ((map quarto-ts-shadow-position-map)
            (delta 0))
        (catch 'mapped
          (dolist (edit (quarto-ts-shadow-map-edits map))
            (let ((source-beg (quarto-ts-shadow-edit-source-beg edit))
                  (source-end (quarto-ts-shadow-edit-source-end edit))
                  (shadow-beg (quarto-ts-shadow-edit-shadow-beg edit))
                  (shadow-end (quarto-ts-shadow-edit-shadow-end edit)))
              (cond
               ((< position source-beg)
                (throw 'mapped (+ position delta)))
               ((and (< source-beg source-end) (< position source-end))
                (throw 'mapped
                       (+ shadow-beg
                          (min (- position source-beg)
                               (- shadow-end shadow-beg))))))
              (setq delta (- shadow-end source-end))))
          (min (+ position delta)
               (quarto-ts-shadow-map-shadow-source-max map)))))))

(defun quarto-ts-shadow-shadow-to-source-position (shadow position)
  "Map POSITION in SHADOW back into source-buffer coordinates."
  (with-current-buffer shadow
    (if (not quarto-ts-shadow-position-map)
        position
      (let ((map quarto-ts-shadow-position-map)
            (delta 0))
        (if (>= position (quarto-ts-shadow-map-shadow-source-max map))
            (quarto-ts-shadow-map-source-max map)
          (catch 'mapped
            (dolist (edit (quarto-ts-shadow-map-edits map))
              (let ((source-beg (quarto-ts-shadow-edit-source-beg edit))
                    (source-end (quarto-ts-shadow-edit-source-end edit))
                    (shadow-beg (quarto-ts-shadow-edit-shadow-beg edit))
                    (shadow-end (quarto-ts-shadow-edit-shadow-end edit)))
                (cond
                 ((< position shadow-beg)
                  (throw 'mapped (- position delta)))
                 ((< position shadow-end)
                  (throw 'mapped
                         (+ source-beg
                            (min (- position shadow-beg)
                                 (- source-end source-beg))))))
                (setq delta (- shadow-end source-end))))
            (- position delta)))))))

(defun quarto-ts-shadow--buffer-name (language)
  "Return the shadow-buffer name for LANGUAGE and the current source."
  (format " *quarto:%s:%s*"
          (buffer-name)
          language))

(defun quarto-ts-shadow--file-name (language)
  "Return a synthetic file name for LANGUAGE in the current source."
  (let* ((source-name (or buffer-file-name
                          (expand-file-name (buffer-name) default-directory)))
         (directory (file-name-directory source-name))
         (base (file-name-nondirectory source-name))
         (extension (or (alist-get language quarto-ts-shadow-language-extensions)
                        (symbol-name language))))
    (expand-file-name
     (format "%s.quarto-shadow.%s" base extension)
     directory)))

(defun quarto-ts-shadow--major-mode (language)
  "Return the configured major-mode function for LANGUAGE."
  (or (alist-get language quarto-ts-shadow-language-modes)
      (user-error "No shadow-buffer major mode configured for %s" language)))

(defun quarto-ts-shadow--create (language)
  "Create and return a shadow buffer for LANGUAGE."
  (let* ((source (current-buffer))
         (mode (quarto-ts-shadow--major-mode language))
         (file-name (quarto-ts-shadow--file-name language))
         (directory default-directory)
         (buffer (generate-new-buffer (quarto-ts-shadow--buffer-name language))))
    (unless (fboundp mode)
      (kill-buffer buffer)
      (user-error "Shadow-buffer mode `%s' is unavailable" mode))
    (with-current-buffer buffer
      (setq-local buffer-file-name file-name
                  buffer-offer-save nil
                  default-directory directory)
      (funcall mode)
      ;; Major-mode initialization kills ordinary buffer-local variables, so
      ;; restore all shadow metadata after activating the language mode.
      (setq-local quarto-ts-shadow-source-buffer source
                  quarto-ts-shadow-language language
                  buffer-file-name file-name
                  buffer-offer-save nil
                  default-directory directory)
      (add-hook 'kill-buffer-hook #'quarto-ts-shadow--forget-current nil t))
    (push (cons language buffer) quarto-ts-shadow--buffers)
    buffer))

(defun quarto-ts-shadow-buffer (language)
  "Return the persistent shadow buffer for LANGUAGE, creating it if needed."
  (let ((buffer (alist-get language quarto-ts-shadow--buffers)))
    (unless (buffer-live-p buffer)
      (setq buffer (quarto-ts-shadow--create language))
      (setf (alist-get language quarto-ts-shadow--buffers) buffer))
    (quarto-ts-shadow-sync language)
    buffer))

(defun quarto-ts-shadow-sync (&optional language)
  "Synchronize shadow buffers with the current source buffer.
When LANGUAGE is non-nil, synchronize only that language."
  (interactive)
  (let ((source (current-buffer)))
    (dolist (entry quarto-ts-shadow--buffers)
      (pcase-let ((`(,entry-language . ,buffer) entry))
        (when (and (buffer-live-p buffer)
                   (or (null language) (eq language entry-language)))
          (let* ((spec (quarto-ts-shadow--contents entry-language))
                 (contents (plist-get spec :contents))
                 (position-map (plist-get spec :map)))
            (with-current-buffer buffer
              (setq quarto-ts-shadow-position-map position-map)
              (unless (equal contents
                             (buffer-substring-no-properties
                              (point-min) (point-max)))
                (let ((inhibit-read-only t)
                      (point-position (point)))
                  (erase-buffer)
                  (insert contents)
                  (goto-char (min point-position (point-max)))
                  (set-buffer-modified-p nil))))))))
    source))

(defun quarto-ts-shadow--schedule-sync (&rest _)
  "Schedule synchronization of the current source's shadow buffers."
  (when (timerp quarto-ts-shadow--sync-timer)
    (cancel-timer quarto-ts-shadow--sync-timer))
  (let ((source (current-buffer)))
    (setq quarto-ts-shadow--sync-timer
          (run-with-idle-timer
           quarto-ts-shadow-sync-delay nil
           (lambda ()
             (when (buffer-live-p source)
               (with-current-buffer source
                 (setq quarto-ts-shadow--sync-timer nil)
                 (quarto-ts-shadow-sync))))))))

(defun quarto-ts-shadow--forget-current ()
  "Remove the current shadow buffer from its source's registry."
  (when (buffer-live-p quarto-ts-shadow-source-buffer)
    (let ((shadow (current-buffer))
          (language quarto-ts-shadow-language))
      (with-current-buffer quarto-ts-shadow-source-buffer
        (when (eq (alist-get language quarto-ts-shadow--buffers) shadow)
          (setf (alist-get language quarto-ts-shadow--buffers nil 'remove)
                nil))))))

(defun quarto-ts-shadow-kill-all ()
  "Kill every shadow buffer belonging to the current source buffer."
  (interactive)
  (when (timerp quarto-ts-shadow--sync-timer)
    (cancel-timer quarto-ts-shadow--sync-timer)
    (setq quarto-ts-shadow--sync-timer nil))
  (let ((buffers (mapcar #'cdr quarto-ts-shadow--buffers)))
    (setq quarto-ts-shadow--buffers nil)
    (dolist (buffer buffers)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun quarto-ts-shadow-open (language)
  "Open the persistent shadow buffer for LANGUAGE."
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
  (pop-to-buffer (quarto-ts-shadow-buffer language)))

(define-minor-mode quarto-ts-shadow-mode
  "Maintain persistent embedded-language buffers for this Quarto document."
  :lighter nil
  (if quarto-ts-shadow-mode
      (progn
        (add-hook 'after-change-functions #'quarto-ts-shadow--schedule-sync nil t)
        (add-hook 'kill-buffer-hook #'quarto-ts-shadow-kill-all nil t))
    (remove-hook 'after-change-functions #'quarto-ts-shadow--schedule-sync t)
    (remove-hook 'kill-buffer-hook #'quarto-ts-shadow-kill-all t)
    (quarto-ts-shadow-kill-all)))

(provide 'quarto-ts-shadow)
;;; quarto-ts-shadow.el ends here
