;;; quarto-ts-font-lock-test.el --- Tests for Quarto fontification -*- lexical-binding: t; -*-

(require 'ert)
(require 'quarto-ts-mode)

(defconst quarto-ts-font-lock-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun quarto-ts-font-lock-test--face-p (position face)
  "Return non-nil when the face at POSITION includes FACE."
  (let ((value (get-text-property position 'face)))
    (or (eq value face)
        (and (listp value) (memq face value)))))

(ert-deftest quarto-ts-font-lock-highlights-quarto-structures ()
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "font-lock-fixture.qmd" temporary-file-directory))
    (insert-file-contents
     (expand-file-name "fixtures/mixed.qmd"
                       quarto-ts-font-lock-test-directory))
    (goto-char (point-max))
    (insert "\nSee @fig-result and @smith2024.\n\n"
            "A heading {#sec-details}\n\n"
            "{{< meta title >}}\n\n"
            "::: {.callout-note}\nImportant.\n:::\n\n"
            "```{python}\n@decorator\ndef example():\n    pass\n```\n\n"
            "| Measure | Value |\n"
            "|:--------|------:|\n"
            "| [Mean](target.qmd) | **42** |\n"
            ": Summary table {#tbl-summary}\n")
    (quarto-ts-mode)
    (unwind-protect
        (progn
          (font-lock-ensure)
          (goto-char (point-min))
          (search-forward "```{python}")
          (search-backward "python")
          (should
           (quarto-ts-font-lock-test--face-p
            (point) 'quarto-ts-cell-language-face))
          (goto-char (point-min))
          (search-forward "#| label")
          (search-backward "#|")
          (should (eq (get-text-property (point) 'invisible)
                      'markdown-ts--markup))
          (search-forward "label")
          (search-backward "label")
          (should
           (quarto-ts-font-lock-test--face-p
            (point) 'quarto-ts-cell-option-key-face))
          (search-forward "fig-python")
          (search-backward "fig-python")
          (should
           (quarto-ts-font-lock-test--face-p
            (point) 'quarto-ts-cell-option-value-face))
          (search-forward "@fig-result")
          (search-backward "@fig-result")
          (should
           (quarto-ts-font-lock-test--face-p
            (point) 'quarto-ts-crossref-face))
          (search-forward "@smith2024")
          (search-backward "@smith2024")
          (should
           (quarto-ts-font-lock-test--face-p
            (point) 'quarto-ts-citation-face))
          (search-forward "{#sec-details}")
          (search-backward "{#sec-details}")
          (should
           (quarto-ts-font-lock-test--face-p
            (point) 'quarto-ts-attribute-face))
          (search-forward "{{< meta title >}}")
          (search-backward "{{<")
          (should (eq (get-text-property (point) 'invisible)
                      'markdown-ts--markup))
          (search-forward "meta title")
          (search-backward "meta title")
          (should
           (quarto-ts-font-lock-test--face-p
            (point) 'quarto-ts-shortcode-face))
          (search-forward "{.callout-note}")
          (beginning-of-line)
          (should (eq (get-text-property (point) 'invisible)
                      'markdown-ts--markup))
          (search-forward "note")
          (search-backward "note")
          (should
           (quarto-ts-font-lock-test--face-p
            (point) 'quarto-ts-callout-face))
          (search-forward "@decorator")
          (search-backward "@decorator")
          (should-not
           (quarto-ts-font-lock-test--face-p
            (point) 'quarto-ts-citation-face))
          (search-forward "Measure")
          (search-backward "Measure")
          (should
           (quarto-ts-font-lock-test--face-p
            (point) 'markdown-ts-table-header))
          (search-forward "Mean")
          (search-backward "Mean")
          (should
           (quarto-ts-font-lock-test--face-p
            (point) 'markdown-ts-table-cell))
          (should
           (quarto-ts-font-lock-test--face-p
            (point) 'markdown-ts-link))
          (should (eq (treesit-language-at (point)) 'markdown-inline))
          (search-forward "**42**")
          (search-backward "42")
          (should
           (quarto-ts-font-lock-test--face-p
            (point) 'markdown-ts-bold))
          (search-forward "Summary table")
          (search-backward "Summary table")
          (should
           (quarto-ts-font-lock-test--face-p
            (point) 'quarto-ts-table-caption-face))
          (should (assq 'markdown-ts-table-header face-remapping-alist))
          (should (assq 'markdown-ts-table-delimiter-cell
                        face-remapping-alist)))
      (quarto-ts-shadow-kill-all))))

(ert-deftest quarto-ts-font-lock-hides-and-reveals-markup ()
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "presentation-fixture.qmd"
                            temporary-file-directory))
    (insert "# Heading\n\n"
            "Read [the notes](notes.qmd) with **care** and $x + y$.\n\n"
            "```{python}\nprint('visible')\n```\n")
    (quarto-ts-mode)
    (unwind-protect
        (progn
          (font-lock-ensure)
          (goto-char (point-min))
          (should (eq (get-text-property (point) 'invisible)
                      'markdown-ts--markup))
          (search-forward "notes.qmd")
          (search-backward "notes.qmd")
          (should (eq (get-text-property (point) 'invisible)
                      'markdown-ts--markup))
          (search-forward "**care**")
          (search-backward "**care**")
          (should (eq (get-text-property (point) 'invisible)
                      'markdown-ts--markup))
          (search-forward "$x + y$")
          (search-backward "$x + y$")
          (should (eq (get-text-property (point) 'invisible)
                      'markdown-ts--markup))
          (should (assq 'markdown-ts-latex face-remapping-alist))
          (search-forward "```{python}")
          (search-backward "```")
          (should (eq (get-text-property (point) 'invisible)
                      'markdown-ts--markup))
          (search-forward "python")
          (search-backward "python")
          (should-not (get-text-property (point) 'invisible))
          (quarto-ts-toggle-hide-markup)
          (font-lock-ensure)
          (goto-char (point-min))
          (should-not (get-text-property (point) 'invisible)))
      (quarto-ts-shadow-kill-all))))

(provide 'quarto-ts-font-lock-test)
;;; quarto-ts-font-lock-test.el ends here
