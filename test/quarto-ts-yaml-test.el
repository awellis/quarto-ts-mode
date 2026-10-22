;;; quarto-ts-yaml-test.el --- Tests for Quarto YAML support -*- lexical-binding: t; -*-

(require 'ert)
(require 'quarto-ts-yaml)

(ert-deftest quarto-ts-yaml-completes-project-keys-and-values ()
  (let ((directory (make-temp-file "quarto-ts-yaml-" t))
        (quarto-ts-yaml-auto-eglot nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "_quarto-dev.yml" directory)
            (insert "format: html\n"))
          (with-temp-file (expand-file-name "custom.lua" directory)
            (insert "return {}\n"))
          (make-directory (expand-file-name "_extensions/acme/demo" directory) t)
          (with-temp-file
              (expand-file-name "_extensions/acme/demo/_extension.yml" directory)
            (insert "title: Demo\n"))
          (with-temp-buffer
            (setq buffer-file-name (expand-file-name "_quarto.yml" directory))
            (insert "pro")
            (setq major-mode 'quarto-ts-project-mode)
            (quarto-ts-yaml-setup)
            (let ((completion (quarto-ts-yaml-completion-at-point)))
              (should (member "project" (nth 2 completion)))
              (should (member "profile" (nth 2 completion))))
            (erase-buffer)
            (insert "profile: d")
            (let ((completion (quarto-ts-yaml-completion-at-point)))
              (should (member "dev" (nth 2 completion))))
            (erase-buffer)
            (insert "filters:\n  - cus")
            (let ((completion (quarto-ts-yaml-completion-at-point)))
              (should (member "custom.lua" (nth 2 completion))))
            (erase-buffer)
            (insert "extensions:\n  - ac")
            (let ((completion (quarto-ts-yaml-completion-at-point)))
              (should (member "acme/demo" (nth 2 completion))))))
      (delete-directory directory t))))

(ert-deftest quarto-ts-yaml-completes-front-matter-and-documents-options ()
  (let ((quarto-ts-yaml-auto-eglot nil))
    (with-temp-buffer
      (setq buffer-file-name
            (expand-file-name "yaml-front-matter.qmd" temporary-file-directory))
      (insert "---\nformat: ht\n---\n\n# Document\n")
      (require 'quarto-ts-mode)
      (quarto-ts-mode)
      (goto-char (point-min))
      (search-forward "ht")
      (let ((completion (quarto-ts-yaml-completion-at-point)))
        (should (member "html" (nth 2 completion))))
      (beginning-of-line)
      (let ((entry (quarto-ts-yaml--schema-at-point)))
        (should (equal (car entry) "format"))
        (should (quarto-ts-yaml--description (cdr entry)))))))

(ert-deftest quarto-ts-yaml-configures-eglot-validation ()
  (let ((user-emacs-directory (make-temp-file "quarto-ts-eglot-yaml-" t))
        called)
    (unwind-protect
        (with-temp-buffer
          (setq major-mode 'quarto-ts-project-mode)
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (_command) "/tmp/yaml-language-server"))
                    ((symbol-function 'eglot-ensure)
                     (lambda () (setq called t))))
            (quarto-ts-yaml-eglot-ensure)
            (should called)
            (should
             (equal (alist-get 'quarto-ts-project-mode eglot-server-programs)
                    quarto-ts-yaml-language-server-command))
            (should (plist-get eglot-workspace-configuration :yaml))))
      (delete-directory user-emacs-directory t))))

(ert-deftest quarto-ts-yaml-generates-language-server-schema ()
  (let ((user-emacs-directory (make-temp-file "quarto-ts-schema-" t)))
    (unwind-protect
        (let ((schema (quarto-ts-yaml-json-schema-file)))
          (should (file-exists-p schema))
          (with-temp-buffer
            (insert-file-contents schema)
            (let ((document (json-parse-buffer :object-type 'hash-table)))
              (should (equal (gethash "$ref" document)
                             "#/$defs/ProjectConfig"))
              (should (hash-table-p (gethash "$defs" document))))))
      (delete-directory user-emacs-directory t))))

(provide 'quarto-ts-yaml-test)
;;; quarto-ts-yaml-test.el ends here
