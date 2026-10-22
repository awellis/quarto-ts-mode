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

(provide 'quarto-ts-cell-test)
;;; quarto-ts-cell-test.el ends here
