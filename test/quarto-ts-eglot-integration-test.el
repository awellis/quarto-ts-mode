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

(ert-deftest quarto-ts-eglot-starts-r-language-server-in-shadow-buffer ()
  (skip-unless
   (and (executable-find "R")
        (locate-library "ess-r-mode")
        (= 0 (call-process
              "R" nil nil nil "--slave" "-e"
              (concat "quit(status=if (requireNamespace("
                      "'languageserver', quietly=TRUE)) 0 else 1)")))))
  (require 'ess-r-mode)
  (let* ((fixture
          (expand-file-name "fixtures/mixed.qmd"
                            quarto-ts-eglot-integration-test-directory))
         (source (find-file-noselect fixture))
         shadow
         server)
    (unwind-protect
        (with-current-buffer source
          (quarto-ts-mode)
          (goto-char (point-min))
          (search-forward "mean(1:10)")
          (setq shadow (quarto-ts-shadow-buffer 'r))
          (quarto-ts-eglot-ensure 'r)
          (let ((deadline (+ (float-time) 30)))
            (while (and (< (float-time) deadline) (null server))
              (accept-process-output nil 0.2)
              (setq server
                    (with-current-buffer shadow (eglot-current-server)))))
          (should server)
          (should (eq (buffer-local-value 'major-mode shadow)
                      'ess-r-mode))
          (should (jsonrpc-running-p server)))
      (when server
        (ignore-errors (eglot-shutdown server)))
      (when (buffer-live-p source)
        (with-current-buffer source
          (set-buffer-modified-p nil)
          (quarto-ts-shadow-kill-all))
        (kill-buffer source)))))

(ert-deftest quarto-ts-eglot-starts-julia-language-server-in-shadow-buffer ()
  (skip-unless
   (and (executable-find "julia")
        (locate-library "julia-mode")
        (= 0 (call-process
              "julia" nil nil nil "--startup-file=no" "-e"
              "using LanguageServer"))))
  (require 'julia-mode)
  (let* ((fixture
          (expand-file-name "fixtures/mixed.qmd"
                            quarto-ts-eglot-integration-test-directory))
         (source (find-file-noselect fixture))
         shadow
         server)
    (unwind-protect
        (with-current-buffer source
          (quarto-ts-mode)
          (goto-char (point-min))
          (search-forward "DataFrame(x = 1:3)")
          (setq shadow (quarto-ts-shadow-buffer 'julia))
          (quarto-ts-eglot-ensure 'julia)
          (let ((deadline (+ (float-time) 90)))
            (while (and (< (float-time) deadline) (null server))
              (accept-process-output nil 0.2)
              (setq server
                    (with-current-buffer shadow (eglot-current-server)))))
          (should server)
          (should (eq (buffer-local-value 'major-mode shadow)
                      'julia-mode))
          (should (jsonrpc-running-p server)))
      (when server
        (ignore-errors (eglot-shutdown server)))
      (when (buffer-live-p source)
        (with-current-buffer source
          (set-buffer-modified-p nil)
          (quarto-ts-shadow-kill-all))
        (kill-buffer source)))))

(ert-deftest quarto-ts-eglot-supports-ojs-through-typescript-language-server ()
  (skip-unless (executable-find "typescript-language-server"))
  (let* ((fixture
          (expand-file-name "fixtures/ojs.qmd"
                            quarto-ts-eglot-integration-test-directory))
         (source (find-file-noselect fixture))
         shadow
         server
         reported)
    (unwind-protect
        (with-current-buffer source
          (quarto-ts-mode)
          (goto-char (point-max))
          (insert "\n```{ojs}\nbroken = unknownOjsName + 1\n```\n")
          (goto-char (point-min))
          (search-forward "viewof threshold")
          (setq shadow (quarto-ts-shadow-buffer 'ojs))
          (quarto-ts-eglot-ensure 'ojs)
          (let ((deadline (+ (float-time) 30)))
            (while (and (< (float-time) deadline) (null server))
              (accept-process-output nil 0.2)
              (setq server
                    (with-current-buffer shadow (eglot-current-server)))))
          (should server)
          (should (jsonrpc-running-p server))
          (goto-char (point-min))
          (search-forward "Promise.")
          (let ((completion (quarto-ts-eglot-completion-at-point)))
            (should completion)
            (should (functionp (nth 2 completion))))
          (quarto-ts-eglot-flymake-backend
           (lambda (diagnostics &rest _)
             (when diagnostics
               (setq reported diagnostics))))
          (let ((deadline (+ (float-time) 15)))
            (while
                (and (< (float-time) deadline)
                     (not
                      (cl-find-if
                       (lambda (diagnostic)
                         (string-match-p
                          "unknownOjsName"
                          (flymake-diagnostic-text diagnostic)))
                       reported)))
              (accept-process-output nil 0.2)))
          (let ((invalid
                 (cl-find-if
                  (lambda (diagnostic)
                    (string-match-p
                     "unknownOjsName"
                     (flymake-diagnostic-text diagnostic)))
                  reported)))
            (should invalid)
            (should (eq (flymake-diagnostic-buffer invalid) source)))
          (goto-char (point-min))
          (search-forward "viewof threshold")
          (let ((eglot-confirm-server-edits nil))
            (quarto-ts-eglot-rename "cutoff"))
          (should (string-match-p "viewof cutoff" (buffer-string)))
          (should (string-match-p "const minimum = cutoff" (buffer-string)))
          (should-not (string-match-p "viewof threshold" (buffer-string)))
          (goto-char (point-min))
          (search-forward "viewof cutoff")
          (let ((references
                 (xref-backend-references 'quarto-ts-eglot "cutoff")))
            (should (>= (length references) 2))
            (dolist (reference references)
              (should
               (equal (file-truename
                       (xref-file-location-file
                        (xref-item-location reference)))
                      (file-truename fixture)))))
          (goto-char (point-min))
          (search-forward "data = [{value")
          (quarto-ts-eglot-format-cell)
          (should (string-match-p "data = \\[" (buffer-string))))
      (when server
        (ignore-errors (eglot-shutdown server)))
      (when (buffer-live-p source)
        (with-current-buffer source
          (set-buffer-modified-p nil)
          (quarto-ts-shadow-kill-all))
        (kill-buffer source)))))

(ert-deftest quarto-ts-panache-coexists-with-ojs-language-server ()
  (skip-unless
   (and (executable-find "panache")
        (executable-find "typescript-language-server")))
  (let* ((fixture
          (expand-file-name "fixtures/ojs.qmd"
                            quarto-ts-eglot-integration-test-directory))
         (source (find-file-noselect fixture))
         panache-server
         shadow
         ojs-server)
    (unwind-protect
        (with-current-buffer source
          (quarto-ts-mode)
          (goto-char (point-max))
          (insert "\nSee @fig-controls.\n")
          (quarto-ts-panache-ensure)
          ;; `eglot-ensure' connects from `post-command-hook'.
          (run-hooks 'post-command-hook)
          (let ((deadline (+ (float-time) 30)))
            (while (and (< (float-time) deadline) (null panache-server))
              (accept-process-output nil 0.2)
              (setq panache-server (eglot-current-server))))
          (should panache-server)
          (should (jsonrpc-running-p panache-server))
          (goto-char (point-min))
          (search-forward "@fig-controls")
          (backward-char)
          (let* ((identifier (xref-backend-identifier-at-point 'eglot))
                 (definitions
                  (xref-backend-definitions 'eglot identifier)))
            (should identifier)
            (should definitions))
          (goto-char (point-min))
          (search-forward "viewof threshold")
          (setq shadow (quarto-ts-shadow-buffer 'ojs))
          (quarto-ts-eglot-ensure 'ojs)
          (let ((deadline (+ (float-time) 30)))
            (while (and (< (float-time) deadline) (null ojs-server))
              (accept-process-output nil 0.2)
              (setq ojs-server
                    (with-current-buffer shadow (eglot-current-server)))))
          (should ojs-server)
          (should (jsonrpc-running-p ojs-server))
          (should-not (eq panache-server ojs-server))
          (should (eq (xref-find-backend) 'quarto-ts-eglot))
          (goto-char (point-min))
          (search-forward "@fig-controls")
          (backward-char)
          (should (eq (xref-find-backend) 'eglot)))
      (when ojs-server
        (ignore-errors (eglot-shutdown ojs-server)))
      (when panache-server
        (ignore-errors (eglot-shutdown panache-server)))
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

(ert-deftest quarto-ts-font-lock-uses-distinct-python-and-julia-parsers ()
  (skip-unless
   (and (treesit-ready-p 'python t)
        (treesit-ready-p 'julia t)
        (locate-library "julia-ts-mode")))
  (require 'julia-ts-mode)
  (let* ((fixture
          (expand-file-name "fixtures/mixed.qmd"
                            quarto-ts-eglot-integration-test-directory))
         (source (find-file-noselect fixture)))
    (unwind-protect
        (with-current-buffer source
          (quarto-ts-mode)
          (font-lock-ensure)
          (should (eq (alist-get 'python markdown-ts--code-block-languages)
                      'python))
          (should (eq (alist-get 'julia markdown-ts--code-block-languages)
                      'julia))
          (goto-char (point-min))
          (search-forward "import")
          (backward-word)
          (should (eq (treesit-language-at (point)) 'python))
          (should (eq (get-text-property (point) 'face)
                      'font-lock-keyword-face))
          (search-forward "using")
          (backward-word)
          (should (eq (treesit-language-at (point)) 'julia))
          (should (eq (get-text-property (point) 'face)
                      'font-lock-keyword-face)))
      (when (buffer-live-p source)
        (with-current-buffer source
          (quarto-ts-shadow-kill-all))
        (kill-buffer source)))))

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

(ert-deftest quarto-ts-runner-starts-quarto-runtime-for-ojs ()
  (skip-unless (executable-find "quarto"))
  (let* ((directory (make-temp-file "quarto-ts-ojs-preview-" t))
         (file (expand-file-name "observable.qmd" directory))
         buffer
         session
         process)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (concat "---\ntitle: OJS runtime\nformat: html\n---\n\n"
                            "```{ojs}\nvalue = 1\n```\n")))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert "\nOJS preview update\n")
            (let ((quarto-ts-preview-auto-browse nil)
                  (quarto-ts-preview-display-buffer nil)
                  (quarto-ts-preview-arguments '("--no-browser")))
              (quarto-ts-runner-ojs-send nil nil)
              (setq session (quarto-ts-preview--session)
                    process (quarto-ts-preview-session-process session))))
          (let ((deadline (+ (float-time) 30)))
            (while (and (< (float-time) deadline)
                        (process-live-p process)
                        (null (quarto-ts-preview-session-url session)))
              (accept-process-output process 0.2)))
          (should (process-live-p process))
          (should (string-prefix-p
                   "http" (quarto-ts-preview-session-url session)))
          (should (with-temp-buffer
                    (insert-file-contents file)
                    (string-match-p "OJS preview update" (buffer-string))))
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

(ert-deftest quarto-ts-runner-sends-code-to-ess-process ()
  (skip-unless (and (executable-find "R")
                    (locate-library "ess-inf")
                    (locate-library "ess-r-mode")))
  (require 'ess-inf)
  (require 'ess-r-mode)
  (let (process output process-buffer)
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name
                (expand-file-name "runner-ess-integration.qmd"
                                  temporary-file-directory))
          (setq process (quarto-ts-runner--ess-process)
                process-buffer (process-buffer process))
          (quarto-ts-runner-ess-send
           "quarto_ts_runner_value <- 6 * 7" nil)
          (ess-wait-for-process process)
          (setq output (get-buffer-create " *quarto-ess-test-output*"))
          (ess-command "cat(quarto_ts_runner_value, '\\n')\n"
                       output nil nil nil process)
          (should
           (string-match-p "42"
                           (with-current-buffer output (buffer-string)))))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p process-buffer)
        (kill-buffer process-buffer))
      (when (buffer-live-p output)
        (kill-buffer output)))))

(ert-deftest quarto-ts-runner-sends-code-to-julia-repl ()
  (skip-unless (and (executable-find "julia")
                    (locate-library "julia-repl")))
  (require 'julia-repl)
  (let ((julia-repl-pop-to-buffer nil)
        (julia-repl-switches "--startup-file=no --history-file=no")
        inferior
        process)
    (unwind-protect
        (with-temp-buffer
          (setq buffer-file-name
                (expand-file-name "runner-julia-integration.qmd"
                                  temporary-file-directory))
          (setq inferior (julia-repl-inferior-buffer)
                process (get-buffer-process inferior))
          (let ((deadline (+ (float-time) 30)))
            (while (and (< (float-time) deadline)
                        (process-live-p process)
                        (not (with-current-buffer inferior
                               (save-excursion
                                 (goto-char (point-min))
                                 (search-forward "julia>" nil t)))))
              (accept-process-output process 0.2)))
          (quarto-ts-runner-julia-send "println(6 * 7)" nil)
          (let ((deadline (+ (float-time) 30)))
            (while (and (< (float-time) deadline)
                        (process-live-p process)
                        (not (with-current-buffer inferior
                               (save-excursion
                                 (goto-char (point-min))
                                 (re-search-forward "[\r\n]42[\r\n]" nil t)))))
              (accept-process-output process 0.2)))
          (should
           (with-current-buffer inferior
             (save-excursion
               (goto-char (point-min))
               (re-search-forward "[\r\n]42[\r\n]" nil t)))))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p inferior)
        (kill-buffer inferior)))))

(provide 'quarto-ts-eglot-integration-test)
;;; quarto-ts-eglot-integration-test.el ends here
