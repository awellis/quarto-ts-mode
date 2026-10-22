;;; quarto-ts-shadow-test.el --- Tests for Quarto shadow buffers -*- lexical-binding: t; -*-

(require 'ert)
(require 'markdown-ts-mode)
(require 'quarto-ts-shadow)

(defconst quarto-ts-shadow-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defmacro quarto-ts-shadow-test-with-fixture (&rest body)
  "Evaluate BODY in a temporary buffer containing the mixed fixture."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (setq buffer-file-name
           (expand-file-name "fixture.qmd" temporary-file-directory))
     (insert-file-contents
      (expand-file-name "fixtures/mixed.qmd"
                        quarto-ts-shadow-test-directory))
     (markdown-ts-mode)
     (quarto-ts-shadow-mode 1)
     (unwind-protect
         (progn ,@body)
       (quarto-ts-shadow-kill-all))))

(ert-deftest quarto-ts-shadow-preserves-source-positions ()
  (quarto-ts-shadow-test-with-fixture
    (let* ((source (buffer-string))
           (shadow (quarto-ts-shadow-buffer 'python))
           (shadow-text (with-current-buffer shadow (buffer-string))))
      (should (= (length source) (length shadow-text)))
      (should
       (equal (cl-loop for index below (length source)
                       when (eq (aref source index) ?\n)
                       collect index)
              (cl-loop for index below (length shadow-text)
                       when (eq (aref shadow-text index) ?\n)
                       collect index))))))

(ert-deftest quarto-ts-shadow-includes-only-selected-language ()
  (quarto-ts-shadow-test-with-fixture
    (let* ((shadow (quarto-ts-shadow-buffer 'python))
           (shadow-text (with-current-buffer shadow (buffer-string))))
      (should (string-match-p "import matplotlib" shadow-text))
      (should-not (string-match-p "mean(1:10)" shadow-text))
      (should-not (string-match-p "using DataFrames" shadow-text)))))

(ert-deftest quarto-ts-shadow-synchronizes-source-edits ()
  (quarto-ts-shadow-test-with-fixture
    (let ((shadow (quarto-ts-shadow-buffer 'python)))
      (goto-char (point-min))
      (search-forward "import matplotlib.pyplot as plt")
      (replace-match "value = 42")
      (quarto-ts-shadow-sync 'python)
      (should
       (with-current-buffer shadow
         (string-match-p "value = 42" (buffer-string)))))))

(provide 'quarto-ts-shadow-test)
;;; quarto-ts-shadow-test.el ends here
