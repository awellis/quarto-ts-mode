;;; quarto-ts-runner-test.el --- Tests for Quarto cell execution -*- lexical-binding: t; -*-

(require 'ert)
(require 'markdown-ts-mode)
(require 'quarto-ts-runner)

(defconst quarto-ts-runner-test-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defmacro quarto-ts-runner-test-with-fixture (&rest body)
  "Evaluate BODY in a temporary buffer containing the mixed fixture."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (setq buffer-file-name
           (expand-file-name "runner-fixture.qmd" temporary-file-directory))
     (insert-file-contents
      (expand-file-name "fixtures/mixed.qmd"
                        quarto-ts-runner-test-directory))
     (markdown-ts-mode)
     ,@body))

(ert-deftest quarto-ts-runner-runs-current-cell ()
  (quarto-ts-runner-test-with-fixture
    (goto-char (point-min))
    (search-forward "import matplotlib")
    (let (sent)
      (cl-letf (((symbol-function 'quarto-ts-runner-test-send)
                 (lambda (code cell)
                   (push (list (quarto-ts-cell-language cell) code) sent))))
        (let ((quarto-ts-runner-backends
               '((python . quarto-ts-runner-test-send))))
          (quarto-ts-runner-run-cell)))
      (should (= (length sent) 1))
      (should (eq (caar sent) 'python))
      (should (string-match-p "import matplotlib" (cadar sent)))
      (should-not (string-match-p "using DataFrames" (cadar sent))))))

(ert-deftest quarto-ts-runner-runs-mixed-language-cells-above ()
  (quarto-ts-runner-test-with-fixture
    (goto-char (point-min))
    (search-forward "using DataFrames")
    (let (languages)
      (cl-letf (((symbol-function 'quarto-ts-runner-test-send)
                 (lambda (_code cell)
                   (push (quarto-ts-cell-language cell) languages))))
        (let ((quarto-ts-runner-backends
               '((r . quarto-ts-runner-test-send)
                 (python . quarto-ts-runner-test-send)
                 (julia . quarto-ts-runner-test-send))))
          (quarto-ts-runner-run-cells-above)))
      (should (equal (nreverse languages) '(r python))))))

(ert-deftest quarto-ts-runner-skips-eval-false-cells ()
  (quarto-ts-runner-test-with-fixture
    (goto-char (point-min))
    (search-forward "mean(1:10)")
    (beginning-of-line)
    (insert "#| eval: false\n")
    (let (languages)
      (cl-letf (((symbol-function 'quarto-ts-runner-test-send)
                 (lambda (_code cell)
                   (push (quarto-ts-cell-language cell) languages))))
        (let ((quarto-ts-runner-backends
               '((r . quarto-ts-runner-test-send)
                 (python . quarto-ts-runner-test-send)
                 (julia . quarto-ts-runner-test-send))))
          (should (= (quarto-ts-runner-run-all-cells) 2))))
      (should (equal (nreverse languages) '(python julia))))))

(ert-deftest quarto-ts-runner-runs-ojs-in-quarto-preview-runtime ()
  (with-temp-buffer
    (setq buffer-file-name
          (expand-file-name "ojs-runner.qmd" temporary-file-directory))
    (insert-file-contents
     (expand-file-name "fixtures/ojs.qmd" quarto-ts-runner-test-directory))
    (markdown-ts-mode)
    (goto-char (point-min))
    (search-forward "viewof threshold")
    (let (updated)
      (cl-letf (((symbol-function 'quarto-ts-preview-update)
                 (lambda () (setq updated t))))
        (quarto-ts-runner-run-cell))
      (should updated))))

(ert-deftest quarto-ts-runner-restricts-region-to-cell-body ()
  (quarto-ts-runner-test-with-fixture
    (goto-char (point-min))
    (let ((beg (progn (search-forward "# Python") (line-beginning-position)))
          (end (progn (search-forward "import matplotlib.pyplot as plt")
                      (line-end-position)))
          sent-code)
      (cl-letf (((symbol-function 'quarto-ts-runner-test-send)
                 (lambda (code _cell)
                   (setq sent-code code))))
        (let ((quarto-ts-runner-backends
               '((python . quarto-ts-runner-test-send))))
          (quarto-ts-runner-run-region beg end)))
      (should (string-match-p "import matplotlib" sent-code))
      (should-not (string-match-p "# Python" sent-code))
      (should-not (string-match-p "```" sent-code)))))

(provide 'quarto-ts-runner-test)
;;; quarto-ts-runner-test.el ends here
