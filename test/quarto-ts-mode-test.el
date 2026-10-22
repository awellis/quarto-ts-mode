;;; quarto-ts-mode-test.el --- Tests for the Quarto major mode -*- lexical-binding: t; -*-

(require 'ert)
(require 'quarto-ts-mode)

(defconst quarto-ts-mode-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(ert-deftest quarto-ts-mode-binds-authoring-and-eglot-commands ()
  (should (eq (keymap-lookup quarto-ts-mode-map "C-c C-q h")
              #'quarto-ts-toggle-hide-markup))
  (should (eq (keymap-lookup quarto-ts-mode-map "C-c C-q i c")
              #'quarto-ts-insert-citation))
  (should (eq (keymap-lookup quarto-ts-mode-map "C-c C-q i a")
              #'quarto-ts-insert-callout))
  (should (eq (keymap-lookup quarto-ts-mode-map "C-c C-q g r")
              #'quarto-ts-eglot-rename))
  (should (eq (keymap-lookup quarto-ts-mode-map "C-c C-q g f")
              #'quarto-ts-eglot-format-cell)))

(ert-deftest quarto-ts-mode-adds-cells-to-imenu ()
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "mode-fixture.qmd" temporary-file-directory))
    (insert-file-contents
     (expand-file-name "fixtures/mixed.qmd" quarto-ts-mode-test-directory))
    (quarto-ts-mode)
    (unwind-protect
        (let* ((root (treesit-buffer-root-node 'markdown))
               (nodes
                (mapcar #'cdr
                        (treesit-query-capture
                         root '((info_string) @info))))
               (names
                (delq nil (mapcar #'quarto-ts--imenu-cell-name nodes))))
          (should (assoc "Cells" treesit-simple-imenu-settings))
          (should (member "r: tbl-r" names))
          (should (member "python: fig-python" names))
          (should
           (cl-find-if
            (lambda (name) (string-prefix-p "julia cell at line" name))
            names)))
      (quarto-ts-shadow-kill-all))))

(provide 'quarto-ts-mode-test)
;;; quarto-ts-mode-test.el ends here
