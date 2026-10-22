;;; quarto-ts-authoring-test.el --- Tests for Quarto authoring -*- lexical-binding: t; -*-

(require 'ert)
(require 'quarto-ts-mode)

(defconst quarto-ts-authoring-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(ert-deftest quarto-ts-authoring-completes-cell-option-keys ()
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "authoring-fixture.qmd" temporary-file-directory))
    (insert-file-contents
     (expand-file-name "fixtures/mixed.qmd"
                       quarto-ts-authoring-test-directory))
    (quarto-ts-mode)
    (unwind-protect
        (progn
          (goto-char (point-min))
          (search-forward "#| label")
          (let* ((completion
                  (quarto-ts-authoring-completion-at-point))
                 (beg (nth 0 completion))
                 (end (nth 1 completion))
                 (candidates (nth 2 completion)))
            (should (equal (buffer-substring-no-properties beg end)
                           "label"))
            (should (member "fig-cap" candidates))
            (should (member "code-fold" candidates))))
      (quarto-ts-shadow-kill-all))))

(ert-deftest quarto-ts-authoring-completes-cell-option-values ()
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "authoring-fixture.qmd" temporary-file-directory))
    (insert-file-contents
     (expand-file-name "fixtures/mixed.qmd"
                       quarto-ts-authoring-test-directory))
    (quarto-ts-mode)
    (unwind-protect
        (progn
          (goto-char (point-min))
          (search-forward "#| echo: false")
          (let* ((completion
                  (quarto-ts-authoring-completion-at-point))
                 (candidates (nth 2 completion)))
            (should (equal candidates '("true" "false" "fenced")))))
      (quarto-ts-shadow-kill-all))))

(ert-deftest quarto-ts-authoring-completes-project-cross-references ()
  (let ((directory (make-temp-file "quarto-ts-authoring-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "_quarto.yml" directory)
            (insert "project:\n  type: website\n"))
          (with-temp-file (expand-file-name "chapter.qmd" directory)
            (insert "# Other section {#sec-other}\n\n"
                    "```{python}\n"
                    "#| label: fig-other\n"
                    "1 + 1\n"
                    "```\n"))
          (with-temp-buffer
            (setq buffer-file-name (expand-file-name "index.qmd" directory))
            (insert "# Main {#sec-main}\n\nSee @fig-")
            (quarto-ts-mode)
            (unwind-protect
                (let* ((completion
                        (quarto-ts-authoring-completion-at-point))
                       (beg (nth 0 completion))
                       (end (nth 1 completion))
                       (candidates (nth 2 completion)))
                  (should (equal (buffer-substring-no-properties beg end)
                                 "fig-"))
                  (should (member "fig-other" candidates))
                  (should (member "sec-main" candidates))
                  (should (member "sec-other" candidates)))
              (quarto-ts-shadow-kill-all))))
      (quarto-ts-authoring-clear-cache)
      (delete-directory directory t))))

(ert-deftest quarto-ts-authoring-inserts-callouts-and-shortcodes ()
  (with-temp-buffer
    (insert "selected text")
    (set-mark (point-min))
    (activate-mark)
    (quarto-ts-insert-callout "tip" "Remember")
    (should (equal (buffer-string)
                   "::: {.callout-tip}\n## Remember\n\nselected text\n:::"))
    (goto-char (point-max))
    (insert "\n")
    (quarto-ts-insert-shortcode "meta" "title")
    (should (string-suffix-p "{{< meta title >}}" (buffer-string)))))

(ert-deftest quarto-ts-authoring-leaves-citations-to-other-packages ()
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "citation.qmd" temporary-file-directory))
    (insert "See @smith2024")
    (quarto-ts-mode)
    (unwind-protect
        (should-not (quarto-ts-authoring-completion-at-point))
      (quarto-ts-shadow-kill-all))))

(provide 'quarto-ts-authoring-test)
;;; quarto-ts-authoring-test.el ends here
