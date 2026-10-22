;;; quarto-ts-cell-test.el --- Tests for Quarto cells -*- lexical-binding: t; -*-

(require 'ert)
(require 'quarto-ts-cell)

(defconst quarto-ts-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(ert-deftest quarto-ts-cell-normalizes-language-tags ()
  (dolist (case '(("python" . python)
                  ("{python}" . python)
                  ("{.python}" . python)
                  ("{r, echo=FALSE}" . r)
                  (" OJS " . ojs)))
    (should (eq (quarto-ts-cell--normalize-language (car case))
                (cdr case)))))

(ert-deftest quarto-ts-cell-parses-options ()
  (with-temp-buffer
    (insert "#| label: fig-example\n#| echo: false\nplot(1:10)\n")
    (should
     (equal (quarto-ts-cell--parse-options (point-min) (point-max))
            '(("label" . "fig-example")
              ("echo" . "false"))))))

(ert-deftest quarto-ts-cell-extracts-markdown-fences ()
  (skip-unless (and (treesit-available-p)
                    (treesit-language-available-p 'markdown)
                    (treesit-language-available-p 'markdown-inline)))
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "fixtures/mixed.qmd" quarto-ts-test-directory))
    (markdown-ts-mode)
    (let ((cells (quarto-ts-cell-list)))
      (should (= (length cells) 3))
      (should (equal (mapcar #'quarto-ts-cell-language cells)
                     '(r python julia)))
      (should (equal (quarto-ts-cell-label (nth 1 cells))
                     "fig-python")))))

(ert-deftest quarto-ts-cell-folds-and-unfolds-body ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "fixtures/mixed.qmd" quarto-ts-test-directory))
    (markdown-ts-mode)
    (quarto-ts-cell-fold-mode 1)
    (goto-char (point-min))
    (search-forward "import matplotlib")
    (let* ((cell (quarto-ts-cell-at-point))
           (body-begin (quarto-ts-cell-body-begin cell)))
      (quarto-ts-cell-fold cell)
      (should (eq (get-char-property body-begin 'invisible)
                  'quarto-ts-cell))
      (should (= (length quarto-ts-cell--fold-overlays) 1))
      (let* ((body-overlay (car quarto-ts-cell--fold-overlays))
             (summary (overlay-get
                       body-overlay 'quarto-ts-cell-summary-overlay)))
        (should (string-match-p
                 "python: fig-python"
                 (overlay-get summary 'before-string))))
      (quarto-ts-cell-unfold cell)
      (should-not quarto-ts-cell--fold-overlays)
      (should-not (get-char-property body-begin 'invisible)))))

(ert-deftest quarto-ts-cell-folds-and-unfolds-all-cells ()
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "fixtures/mixed.qmd" quarto-ts-test-directory))
    (markdown-ts-mode)
    (quarto-ts-cell-fold-mode 1)
    (quarto-ts-cell-fold-all)
    (should (= (length quarto-ts-cell--fold-overlays) 3))
    (quarto-ts-cell-unfold-all)
    (should-not quarto-ts-cell--fold-overlays)))

(provide 'quarto-ts-cell-test)
;;; quarto-ts-cell-test.el ends here
