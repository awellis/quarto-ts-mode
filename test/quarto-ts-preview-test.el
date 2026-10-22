;;; quarto-ts-preview-test.el --- Tests for Quarto process management -*- lexical-binding: t; -*-

(require 'ert)
(require 'quarto-ts-preview)

(ert-deftest quarto-ts-preview-detects-project-context ()
  (let* ((directory (make-temp-file "quarto-ts-project-" t))
         (nested (expand-file-name "chapters" directory))
         (file (expand-file-name "chapter.qmd" nested)))
    (unwind-protect
        (progn
          (make-directory nested)
          (with-temp-file (expand-file-name "_quarto.yml" directory)
            (insert "project:\n  type: website\n"))
          (with-temp-file file
            (insert "# Chapter\n"))
          (let ((context (quarto-ts-preview--context file)))
            (should (plist-get context :project))
            (should-not (plist-get context :target))
            (should
             (equal (plist-get context :root)
                    (file-name-as-directory (file-truename directory))))))
      (delete-directory directory t))))

(ert-deftest quarto-ts-preview-detects-standalone-context ()
  (let* ((directory (make-temp-file "quarto-ts-standalone-" t))
         (file (expand-file-name "document.qmd" directory)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# Document\n"))
          (let ((context (quarto-ts-preview--context file)))
            (should-not (plist-get context :project))
            (should (equal (plist-get context :key) (file-truename file)))
            (should (equal (plist-get context :target) "document.qmd"))))
      (delete-directory directory t))))

(ert-deftest quarto-ts-preview-builds-argument-list-without-shell ()
  (let ((quarto-ts-command "/usr/local/bin/quarto")
        (quarto-ts-preview-arguments '("--no-browser" "--port" "4567")))
    (should
     (equal
      (quarto-ts-preview--command
       '(:target "document.qmd" :root "/tmp/"))
      '("/usr/local/bin/quarto" "preview" "document.qmd"
        "--no-browser" "--port" "4567")))
    (should
     (equal
      (quarto-ts-preview--command '(:target nil :root "/tmp/project/"))
      '("/usr/local/bin/quarto" "preview"
        "--no-browser" "--port" "4567")))))

(ert-deftest quarto-ts-preview-extracts-most-recent-url ()
  (should
   (equal
    (quarto-ts-preview--extract-url
     "Preparing...\nBrowse at http://127.0.0.1:4321/\n")
    "http://127.0.0.1:4321/"))
  (should
   (equal
    (quarto-ts-preview--extract-url
     "Browse at http://127.0.0.1:1111/\nBrowse at https://localhost:2222/book/\n")
    "https://localhost:2222/book/")))

(provide 'quarto-ts-preview-test)
;;; quarto-ts-preview-test.el ends here
