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

(ert-deftest quarto-ts-shadow-translates-ojs-and-maps-positions ()
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "ojs-fixture.qmd" temporary-file-directory))
    (insert-file-contents
     (expand-file-name "fixtures/ojs.qmd" quarto-ts-shadow-test-directory))
    (markdown-ts-mode)
    (quarto-ts-shadow-mode 1)
    (unwind-protect
        (let ((shadow (quarto-ts-shadow-buffer 'ojs)))
          (should
           (with-current-buffer shadow
             (and (string-match-p "threshold = Inputs.range" (buffer-string))
                  (string-match-p "filtered = (() => {" (buffer-string))
                  (string-match-p "asyncData = (async () =>" (buffer-string))
                  (string-match-p "sequence = (function\\*" (buffer-string))
                  (string-match-p "var remoteChart;" (buffer-string)))))
          (goto-char (point-min))
          (search-forward "viewof ")
          (let* ((source-position (point))
                 (shadow-position
                  (quarto-ts-shadow-source-to-shadow-position
                   shadow source-position)))
            (should (eq (with-current-buffer shadow
                          (char-after shadow-position))
                        ?t))
            (should
             (= (quarto-ts-shadow-shadow-to-source-position
                 shadow shadow-position)
                source-position)))
          (goto-char (point-min))
          (search-forward "remoteChart")
          (backward-word)
          (let* ((source-position (point))
                 (shadow-position
                  (quarto-ts-shadow-source-to-shadow-position
                   shadow source-position)))
            (should
             (equal (with-current-buffer shadow
                      (buffer-substring shadow-position
                                        (+ shadow-position 11)))
                    "remoteChart"))
            (should
             (= (quarto-ts-shadow-shadow-to-source-position
                 shadow shadow-position)
                source-position))))
      (quarto-ts-shadow-kill-all))))

(ert-deftest quarto-ts-shadow-handles-option-only-ojs-cells ()
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "ojs-options.qmd" temporary-file-directory))
    (insert "```{ojs}\n//| label: empty-ojs\n```\n")
    (markdown-ts-mode)
    (quarto-ts-shadow-mode 1)
    (unwind-protect
        (should (buffer-live-p (quarto-ts-shadow-buffer 'ojs)))
      (quarto-ts-shadow-kill-all))))

(ert-deftest quarto-ts-shadow-generates-valid-javascript-for-ojs ()
  (skip-unless (executable-find "node"))
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "ojs-validity.qmd" temporary-file-directory))
    (insert-file-contents
     (expand-file-name "fixtures/ojs.qmd" quarto-ts-shadow-test-directory))
    (markdown-ts-mode)
    (quarto-ts-shadow-mode 1)
    (unwind-protect
        (let* ((shadow (quarto-ts-shadow-buffer 'ojs))
               (file (make-temp-file "quarto-ts-ojs-" nil ".js")))
          (unwind-protect
              (progn
                (with-current-buffer shadow
                  (write-region (point-min) (point-max) file nil 'silent))
                (should (= (call-process "node" nil nil nil "--check" file)
                           0)))
            (delete-file file)))
      (quarto-ts-shadow-kill-all))))

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
