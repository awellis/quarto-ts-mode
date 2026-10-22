;;; quarto-ts-panache-test.el --- Tests for Panache integration -*- lexical-binding: t; -*-

(require 'ert)
(require 'quarto-ts-mode)

(ert-deftest quarto-ts-panache-registers-document-server ()
  (with-temp-buffer
    (setq major-mode 'quarto-ts-mode
          eglot-server-programs nil)
    (let ((quarto-ts-panache-server-command '("panache" "lsp")))
      (quarto-ts-panache--configure-server)
      (should
       (equal (alist-get 'quarto-ts-mode eglot-server-programs)
              '("panache" "lsp"))))))

(ert-deftest quarto-ts-panache-auto-starts-when-available ()
  (with-temp-buffer
    (setq major-mode 'quarto-ts-mode)
    (let ((quarto-ts-panache-auto-start t)
          ensured)
      (cl-letf (((symbol-function 'quarto-ts-panache-available-p)
                 (lambda () t))
                ((symbol-function 'eglot-ensure)
                 (lambda () (setq ensured t))))
        (quarto-ts-panache-setup))
      (should ensured)
      (should (memq #'quarto-ts-panache--format-on-save
                    before-save-hook)))))

(ert-deftest quarto-ts-panache-formatting-remains-opt-in ()
  (with-temp-buffer
    (let ((quarto-ts-panache-format-on-save nil)
          formatted)
      (cl-letf (((symbol-function 'eglot-managed-p) (lambda () t))
                ((symbol-function 'eglot-format-buffer)
                 (lambda () (setq formatted t))))
        (quarto-ts-panache--format-on-save))
      (should-not formatted))))

(provide 'quarto-ts-panache-test)
;;; quarto-ts-panache-test.el ends here
