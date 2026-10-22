;;; quarto-ts-eglot-test.el --- Tests for Quarto Eglot mapping -*- lexical-binding: t; -*-

(require 'ert)
(require 'flymake)
(require 'markdown-ts-mode)
(require 'quarto-ts-eglot)

(defconst quarto-ts-eglot-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(ert-deftest quarto-ts-eglot-configures-julia-language-server ()
  (with-temp-buffer
    (setq-local major-mode 'julia-mode
                eglot-server-programs nil)
    (quarto-ts-eglot--configure-server 'julia)
    (should
     (equal (alist-get 'julia-mode eglot-server-programs)
            '("julia" "--startup-file=no" "--history-file=no"
              "-e" "using LanguageServer; runserver()")))))

(ert-deftest quarto-ts-eglot-maps-diagnostic-positions-identically ()
  (let ((source (generate-new-buffer " *quarto-source-test*"))
        (shadow (generate-new-buffer " *quarto-shadow-test*")))
    (unwind-protect
        (progn
          (with-current-buffer source
            (insert "prose\nprint(missing_name)\n"))
          (let ((diagnostic
                 (with-current-buffer shadow
                   (insert "     \nprint(missing_name)\n")
                   (flymake-make-diagnostic
                    shadow 13 25 :error "Undefined name"))))
            (let ((mapped
                   (cl-letf (((symbol-function
                               'quarto-ts-eglot--source-cell-range-p)
                              (lambda (&rest _) t)))
                     (quarto-ts-eglot--map-diagnostic
                      source 'python diagnostic))))
              (should (eq (flymake-diagnostic-buffer mapped) source))
              (should (= (flymake-diagnostic-beg mapped) 13))
              (should (= (flymake-diagnostic-end mapped) 25))
              (should (eq (flymake-diagnostic-type mapped) :error))
              (should (equal (flymake-diagnostic-text mapped)
                             (flymake-diagnostic-text diagnostic))))))
      (kill-buffer source)
      (kill-buffer shadow))))

(ert-deftest quarto-ts-eglot-forwards-completion-table-in-shadow-buffer ()
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "completion-fixture.qmd" temporary-file-directory))
    (insert-file-contents
     (expand-file-name "fixtures/mixed.qmd" quarto-ts-eglot-test-directory))
    (markdown-ts-mode)
    (quarto-ts-shadow-mode 1)
    (unwind-protect
        (progn
          (goto-char (point-min))
          (search-forward "matplotlib")
          (let ((shadow (quarto-ts-shadow-buffer 'python))
                table-buffer
                annotation-buffer)
            (cl-letf (((symbol-function 'eglot-managed-p)
                       (lambda () t))
                      ((symbol-function 'eglot-completion-at-point)
                       (lambda ()
                         (list
                          (- (point) 3)
                          (point)
                          (lambda (_pattern _predicate action)
                            (setq table-buffer (current-buffer))
                            (when (eq action t) '("matplotlib")))
                          :annotation-function
                          (lambda (_candidate)
                            (setq annotation-buffer (current-buffer))
                            " module")
                          :exit-function #'ignore))))
              (let* ((completion (quarto-ts-eglot-completion-at-point))
                     (table (nth 2 completion))
                     (properties (nthcdr 3 completion))
                     (annotation (plist-get properties
                                           :annotation-function)))
                (should completion)
                (should (equal (funcall table "" nil t)
                               '("matplotlib")))
                (should (eq table-buffer shadow))
                (should (equal (funcall annotation "matplotlib")
                               " module"))
                (should (eq annotation-buffer shadow))
                (should (functionp (plist-get properties
                                              :exit-function)))))))
      (quarto-ts-shadow-kill-all))))

(ert-deftest quarto-ts-eglot-copies-completion-edits-from-cell-only ()
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "completion-edit-fixture.qmd"
                            temporary-file-directory))
    (insert-file-contents
     (expand-file-name "fixtures/mixed.qmd" quarto-ts-eglot-test-directory))
    (markdown-ts-mode)
    (quarto-ts-shadow-mode 1)
    (unwind-protect
        (progn
          (goto-char (point-min))
          (search-forward "matplotlib")
          (let ((source (current-buffer))
                (shadow (quarto-ts-shadow-buffer 'python))
                exit-buffer)
            (cl-letf (((symbol-function 'eglot-managed-p)
                       (lambda () t))
                      ((symbol-function 'eglot-completion-at-point)
                       (lambda ()
                         (list
                          (- (point) 3)
                          (point)
                          '("matplotlib")
                          :exit-function
                          (lambda (_candidate status)
                            (setq exit-buffer (current-buffer))
                            (when (eq status 'finished)
                              (insert ".extra")
                              (let ((return-point (copy-marker (point) t)))
                                (goto-char (point-min))
                                (insert "OUTSIDE-CELL")
                                (goto-char return-point)
                                (set-marker return-point nil))))))))
              (let* ((completion (quarto-ts-eglot-completion-at-point))
                     (exit-function
                      (plist-get (nthcdr 3 completion) :exit-function)))
                (funcall exit-function "matplotlib" 'finished)
                (should (eq exit-buffer shadow))
                (with-current-buffer source
                  (should (string-match-p
                           "matplotlib\\.extra\\.pyplot" (buffer-string)))
                  (should-not (string-match-p
                               "OUTSIDE-CELL" (buffer-string))))
                (with-current-buffer shadow
                  (should-not (string-match-p
                               "OUTSIDE-CELL" (buffer-string))))))))
      (quarto-ts-shadow-kill-all))))

(ert-deftest quarto-ts-eglot-maps-rename-edits-back-from-shadow-buffer ()
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "rename-fixture.qmd" temporary-file-directory))
    (insert-file-contents
     (expand-file-name "fixtures/mixed.qmd" quarto-ts-eglot-test-directory))
    (markdown-ts-mode)
    (quarto-ts-shadow-mode 1)
    (unwind-protect
        (progn
          (quarto-ts-shadow-buffer 'python)
          (goto-char (point-min))
          (search-forward "matplotlib")
          (let ((source (current-buffer))
                rename-buffer)
            (cl-letf (((symbol-function 'eglot-managed-p)
                       (lambda () t))
                      ((symbol-function 'eglot-rename)
                       (lambda (new-name)
                         (setq rename-buffer (current-buffer))
                         (save-excursion
                           (goto-char (point-min))
                           (insert "OUTSIDE-CELL")
                           (while (search-forward "matplotlib" nil t)
                             (replace-match new-name t t))))))
              (quarto-ts-eglot-rename "plotting")
              (should-not (eq rename-buffer source))
              (should (string-match-p "import plotting" (buffer-string)))
              (should-not (string-match-p "OUTSIDE-CELL"
                                          (buffer-string))))))
      (quarto-ts-shadow-kill-all))))

(ert-deftest quarto-ts-eglot-forwards-hover-in-shadow-buffer ()
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "hover-fixture.qmd" temporary-file-directory))
    (insert-file-contents
     (expand-file-name "fixtures/mixed.qmd" quarto-ts-eglot-test-directory))
    (markdown-ts-mode)
    (quarto-ts-shadow-mode 1)
    (unwind-protect
        (progn
          (goto-char (point-min))
          (search-forward "matplotlib")
          (let ((shadow (quarto-ts-shadow-buffer 'python))
                hover-buffer
                result)
            (cl-letf (((symbol-function 'eglot-managed-p)
                       (lambda () t))
                      ((symbol-function 'eglot-hover-eldoc-function)
                       (lambda (callback &rest _)
                         (setq hover-buffer (current-buffer))
                         (funcall callback "Python hover"))))
              (quarto-ts-eglot-hover-eldoc-function
               (lambda (documentation &rest _)
                 (setq result documentation)))
              (should (eq hover-buffer shadow))
              (should (equal result "Python hover")))))
      (quarto-ts-shadow-kill-all))))

(ert-deftest quarto-ts-eglot-maps-xrefs-to-quarto-source ()
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "xref-fixture.qmd" temporary-file-directory))
    (insert-file-contents
     (expand-file-name "fixtures/mixed.qmd" quarto-ts-eglot-test-directory))
    (markdown-ts-mode)
    (quarto-ts-shadow-mode 1)
    (unwind-protect
        (progn
          (goto-char (point-min))
          (search-forward "matplotlib")
          (let ((source (current-buffer))
                (shadow (quarto-ts-shadow-buffer 'python))
                backend-buffer)
            (cl-letf (((symbol-function 'eglot-managed-p)
                       (lambda () t)))
              (let* ((shadow-file (buffer-local-value 'buffer-file-name shadow))
                     (mapped
                      (quarto-ts-eglot--call-xref
                       (lambda (backend identifier)
                         (setq backend-buffer (current-buffer))
                         (should (eq backend 'eglot))
                         (should (equal identifier "matplotlib"))
                         (list
                          (xref-make-match
                           "import matplotlib.pyplot as plt"
                           (xref-make-file-location shadow-file 18 7)
                           10)))
                       "matplotlib"))
                     (item (car mapped))
                     (location (xref-item-location item)))
                (should (eq backend-buffer shadow))
                (should (xref-match-item-p item))
                (should (= (xref-match-length item) 10))
                (should (xref-file-location-p location))
                (should (equal (xref-file-location-file location)
                               (buffer-file-name source)))
                (should (= (xref-file-location-line location) 18))
                (should (= (xref-file-location-column location) 7))))))
      (quarto-ts-shadow-kill-all))))

(provide 'quarto-ts-eglot-test)
;;; quarto-ts-eglot-test.el ends here
