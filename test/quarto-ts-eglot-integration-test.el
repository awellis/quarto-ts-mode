;;; quarto-ts-eglot-integration-test.el --- Ruff integration test -*- lexical-binding: t; -*-

(require 'ert)
(require 'quarto-ts-mode)

(defconst quarto-ts-eglot-integration-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(ert-deftest quarto-ts-eglot-forwards-ruff-diagnostics-to-source ()
  (skip-unless (executable-find "ruff"))
  (let* ((fixture
          (expand-file-name "fixtures/mixed.qmd"
                            quarto-ts-eglot-integration-test-directory))
         (source (find-file-noselect fixture))
         (eglot-server-programs
          (cons '((python-mode) . ("ruff" "server"))
                eglot-server-programs))
         shadow
         server
         reported)
    (unwind-protect
        (progn
          (with-current-buffer source
            (quarto-ts-mode)
            (goto-char (point-min))
            (search-forward "import matplotlib.pyplot as plt")
            (end-of-line)
            (insert "\nprint(undefined_quarto_name)")
            (setq shadow (quarto-ts-shadow-buffer 'python))
            (quarto-ts-eglot-ensure 'python)
            (quarto-ts-eglot-flymake-backend
             (lambda (diagnostics &rest _)
               (when diagnostics
                 (setq reported diagnostics)))))
          (setq server (with-current-buffer shadow (eglot-current-server)))
          (let ((deadline (+ (float-time) 15)))
            (while (and (< (float-time) deadline) (null reported))
              (accept-process-output nil 0.2)))
          (should reported)
          (let ((undefined
                 (cl-find-if
                  (lambda (diagnostic)
                    (equal (flymake-diagnostic-code diagnostic) "F821"))
                  reported)))
            (should undefined)
            (should (eq (flymake-diagnostic-buffer undefined) source))
            (with-current-buffer source
              (should
               (equal (buffer-substring-no-properties
                       (flymake-diagnostic-beg undefined)
                       (flymake-diagnostic-end undefined))
                      "undefined_quarto_name")))))
      (when server
        (ignore-errors (eglot-shutdown server)))
      (when (buffer-live-p source)
        (with-current-buffer source
          (set-buffer-modified-p nil)
          (quarto-ts-shadow-kill-all))
        (kill-buffer source)))))

(ert-deftest quarto-ts-runner-sends-code-to-python-process ()
  (skip-unless (executable-find "python3"))
  (let ((python-shell-interpreter (executable-find "python3"))
        (python-shell-dedicated 'buffer)
        process)
    (with-temp-buffer
      (setq buffer-file-name
            (expand-file-name "runner-integration.qmd"
                              temporary-file-directory))
      (unwind-protect
          (progn
            (setq process (quarto-ts-runner--python-process))
            (quarto-ts-runner-python-send
             "quarto_ts_runner_value = 6 * 7" nil)
            (python-shell-accept-process-output process)
            (should
             (string-match-p
              "42"
              (python-shell-send-string-no-output
               "print(quarto_ts_runner_value)" process))))
        (when (process-live-p process)
          (delete-process process))
        (when-let* ((buffer (and process (process-buffer process))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest quarto-ts-preview-starts-and-captures-url ()
  (skip-unless (executable-find "quarto"))
  (let* ((directory (make-temp-file "quarto-ts-preview-" t))
         (file (expand-file-name "preview.qmd" directory))
         (buffer nil)
         session
         process)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "---\ntitle: Preview test\nformat: html\n---\n\n# Preview\n"))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (let ((quarto-ts-preview-auto-browse nil)
                  (quarto-ts-preview-display-buffer nil)
                  (quarto-ts-preview-arguments '("--no-browser")))
              (setq session (quarto-ts-preview-start)
                    process (quarto-ts-preview-session-process session))))
          (let ((deadline (+ (float-time) 30)))
            (while (and (< (float-time) deadline)
                        (process-live-p process)
                        (null (quarto-ts-preview-session-url session)))
              (accept-process-output process 0.2)))
          (should (process-live-p process))
          (should (string-prefix-p
                   "http" (quarto-ts-preview-session-url session)))
          (with-current-buffer buffer
            (quarto-ts-preview-stop)))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (remhash (file-truename file) quarto-ts-preview--sessions)
      (delete-directory directory t))))

(ert-deftest quarto-ts-render-produces-html-output ()
  (skip-unless (executable-find "quarto"))
  (let* ((directory (make-temp-file "quarto-ts-render-" t))
         (file (expand-file-name "render.qmd" directory))
         (output (expand-file-name "render.html" directory))
         buffer
         process)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "---\ntitle: Render test\nformat: html\n---\n\n# Render\n"))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (let ((quarto-ts-render-display-buffer nil))
              (setq process (quarto-ts-render))))
          (let ((deadline (+ (float-time) 30)))
            (while (and (< (float-time) deadline)
                        (process-live-p process))
              (accept-process-output process 0.2)))
          (should (eq (process-status process) 'exit))
          (should (= (process-exit-status process) 0))
          (should (file-exists-p output)))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory directory t))))

(provide 'quarto-ts-eglot-integration-test)
;;; quarto-ts-eglot-integration-test.el ends here
