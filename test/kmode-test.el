;;; kmode-test.el --- Tests for kmode-emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; These tests deliberately build tiny synthetic kernel trees.  They should
;; never need a Linux checkout, a compiler toolchain, or network access.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'flymake)
(require 'subr-x)
(require 'kmode-core)

(declare-function kmode-build--current-directory-target "kmode-build")
(declare-function kmode-build--current-object-target "kmode-build")
(declare-function kmode-build--start "kmode-build")
(declare-function kmode-build--target "kmode-build")
(declare-function kmode-build-make-arguments "kmode-build")
(declare-function kmode-build-process-environment "kmode-build")
(declare-function kmode-build-sparse "kmode-build")
(declare-function kmode--dashboard-context "kmode-ui")
(declare-function kmode--include-candidates "kmode-navigate")
(declare-function kmode-lore--cache-file "kmode-lore")
(declare-function kmode-lore--cache-key "kmode-lore")
(declare-function kmode-lore--cache-read "kmode-lore")
(declare-function kmode-lore--cache-write "kmode-lore" (results))
(declare-function kmode-lore--context-query "kmode-lore" (symbol relative))
(declare-function kmode-lore--file-query "kmode-lore" (relative))
(declare-function kmode-lore--identifier-at-point "kmode-lore")
(declare-function kmode-lore--make-result "kmode-lore" (&rest slots))
(declare-function kmode-lore--origin-links "kmode-lore")
(declare-function kmode-lore--parse-atom "kmode-lore" (start end scope))
(declare-function kmode-lore--quote-term "kmode-lore" (value))
(declare-function kmode-lore--request "kmode-lore" (&optional force))
(declare-function kmode-lore--search-url "kmode-lore" (query offset order))
(declare-function kmode-lore--start-search "kmode-lore" (query scope &optional force))
(declare-function kmode-lore--status-header "kmode-lore")
(declare-function kmode-lore--status-with-results "kmode-lore" (source results))
(declare-function kmode-lore--symbol-query "kmode-lore" (symbol))
(declare-function kmode-lore--trusted-origin-url "kmode-lore" (value))
(declare-function kmode-lore--validate-query "kmode-lore" (query))
(declare-function kmode-lore-clear-cache "kmode-lore")
(declare-function kmode-lore--validate-symbol "kmode-lore" (symbol))
(declare-function kmode-lore-context-at-point "kmode-lore")
(declare-function kmode-lore-search-directory "kmode-lore")
(declare-function kmode-lore-why "kmode-lore")
(declare-function kmode-lore-result-author "kmode-lore" (result))
(declare-function kmode-lore-result-date "kmode-lore" (result))
(declare-function kmode-lore-result-message-id "kmode-lore" (result))
(declare-function kmode-lore-result-scope "kmode-lore" (result))
(declare-function kmode-lore-result-subject "kmode-lore" (result))
(declare-function kmode-lore-result-url "kmode-lore" (result))
(declare-function kmode-lore-results-mode "kmode-lore")
(declare-function kmode--search-lines-with-rg "kmode-navigate")
(declare-function kmode-impact--run-button "kmode-impact")
(declare-function kmode-kselftest-collections "kmode-test")
(declare-function kmode-kunit-arguments "kmode-test")
(declare-function kmode-kunit-resolve-build-directory "kmode-test")
(declare-function kmode-review--validate-range "kmode-review")
(declare-function kmode--write-git-diff "kmode-review")
(declare-function kmode--config-at-point "kmode-navigate")
(declare-function kmode-find-callers "kmode-navigate")
(declare-function kmode-find-function-callers "kmode-navigate")
(declare-function kmode-find-usages "kmode-navigate")
(declare-function kmode-find-definition "kmode-navigate")
(declare-function kmode-find-kbuild "kmode-navigate")
(declare-function kmode--kernel-identifier-at-point "kmode-navigate")
(declare-function kmode--line-include "kmode-navigate")
(declare-function kmode-navigation-back "kmode-navigate")
(declare-function kmode--select-usages-backend "kmode-navigate")
(declare-function kmode--search-kconfig-fallback "kmode-navigate")
(declare-function kmode-toggle-header-source "kmode-navigate")
(declare-function kmode-kconfig--source-at-point "kmode-kconfig")
(declare-function kmode-kconfig--source-statement-at-point "kmode-kconfig")
(declare-function kmode-kconfig-calculate-indent "kmode-kconfig")
(declare-function kmode-kconfig-follow-source "kmode-kconfig")
(declare-function kmode-kconfig-indent-line "kmode-kconfig")
(declare-function kmode-kconfig-mode "kmode-kconfig")
(declare-function kmode-qemu-arguments "kmode-debug")
(declare-function kmode-qemu-runtime-resources "kmode-debug")
(declare-function kmode-vng--assert-config-safe "kmode-virtme")
(declare-function kmode-vng--confirm-host-access "kmode-virtme")
(declare-function kmode-vng--default-debug-value "kmode-virtme")
(declare-function kmode-vng--global-runtime-p "kmode-virtme")
(declare-function kmode-vng--prepare-runtime "kmode-virtme")
(declare-function kmode-vng--start-runtime "kmode-virtme")
(declare-function kmode-vng-architecture "kmode-virtme")
(declare-function kmode-vng-build-and-run "kmode-virtme")
(declare-function kmode-vng-command-arguments "kmode-virtme")
(declare-function kmode-vng-config-safe-p "kmode-virtme")
(declare-function kmode-vng-processes "kmode-virtme")
(declare-function kmode-vng-stop "kmode-virtme")
(declare-function kmode-dashboard "kmode-ui")
(declare-function kmode-dashboard-mode "kmode-ui")
(declare-function kmode-dashboard-refresh "kmode-ui")
(declare-function kmode-dispatch "kmode-ui")
(declare-function kmode-command-root "kmode-core")
(declare-function kmode-global-mode "kmode-emacs")
(declare-function kmode--cscope-inverted-index-p "kmode-navigate")
(declare-function kmode-mode "kmode-emacs")
(declare-function kmode-project-find "kmode-emacs")
(declare-function kmode-refresh-tags-table "kmode-emacs")
(declare-function kmode--refresh-tags-file-buffer "kmode-emacs" (file))
(declare-function kmode-build--tags-finished "kmode-build")
(declare-function kmode-build--cscope-finished "kmode-build")
(declare-function kmode-build-cscope "kmode-build")
(declare-function tags-table-mode "etags" ())
(declare-function kmode-build-tags "kmode-build")
(declare-function kmode--call-xcscope "kmode-navigate")
(declare-function kmode--protect-xcscope-result-rerun
                  "kmode-navigate" (buffer start state &optional exact))
(declare-function kmode--xcscope-rerun
                  "kmode-navigate" (state search))
(declare-function kmode-cscope-available-p "kmode-navigate")
(declare-function kmode-cscope-find-callees "kmode-navigate")
(declare-function kmode-cscope-find-callers "kmode-navigate")
(declare-function kmode-cscope-find-definition "kmode-navigate")
(declare-function kmode-cscope-find-includers "kmode-navigate")
(declare-function kmode-cscope-find-symbol "kmode-navigate")
(declare-function kmode-cscope-find-text "kmode-navigate")
(declare-function kmode-eglot-ensure "kmode-navigate")
(declare-function kmode-checkpatch-flymake "kmode-flymake")
(declare-function kmode-checkpatch-flymake--cancel "kmode-flymake")
(declare-function kmode-checkpatch-flymake--parse-output "kmode-flymake")
(declare-function kmode-checkpatch-flymake--source-extension "kmode-flymake")
(declare-function kmode-checkpatch-flymake-mode "kmode-flymake")

(defvar kmode-test--enable-subr-trampolines)
(defvaralias
  'kmode-test--enable-subr-trampolines
  (if (boundp 'native-comp-enable-subr-trampolines)
      'native-comp-enable-subr-trampolines
    'comp-enable-subr-trampolines)
  "Compatibility alias for Emacs's subr-trampoline control variable.")
(defvar kmode--last-root)
(defvar kmode-default-root)
(defvar kmode--saved-locals)
(defvar kmode-apply-kernel-c-style)
(defvar kmode-build-default-target)
(defvar kmode-build-sanitized-environment-variables)
(defvar kmode-build-trusted-path-directories)
(defvar kmode-build-sparse-level)
(defvar kmode-dashboard-root)
(defvar kmode-dashboard-origin)
(defvar kmode-impact-context)
(defvar kmode-impact-origin)
(defvar kmode-impact-root)
(defvar kmode-lore--fetched-at)
(defvar kmode-lore--offset)
(defvar kmode-lore--order)
(defvar kmode-lore--query)
(defvar kmode-lore--request-buffer)
(defvar kmode-lore--results)
(defvar kmode-lore--scope)
(defvar kmode-lore--status)
(defvar kmode-lore--timeout-timer)
(defvar kmode-lore-base-url)
(defvar kmode-lore-cache-directory)
(defvar kmode-lore-cache-ttl)
(defvar kmode-lore-default-date-range)
(defvar kmode-lore-max-query-length)
(defvar kmode-lore-request-timeout)
(defvar kmode-lore-result-limit)
(defvar kmode-lore-results-mode-map)
(defvar kmode-lore-map)
(defvar kmode-lore-user-agent)
(defvar kmode-global-mode)
(defvar kmode-global-mode-map)
(defvar kmode-command-map)
(defvar kmode-mode)
(defvar kmode-kunit-build-directory)
(defvar kmode-set-compile-command)
(defvar kmode-navigation-map)
(defvar kmode-vng-confirm-host-access)
(defvar kmode-vng-home-directory)
(defvar kmode-vng-map)
(defvar kmode-vng-program)
(defvar kmode-vng-trust-default-options)
(defvar kmode-auto-activate-tags)
(defvar kmode-clangd-arguments)
(defvar kmode-cscope-map)
(defvar kmode-kernel-fill-column)
(defvar kmode-usages-backend)
(defvar kmode-usages-text-files)
(defvar kmode-require-final-newline)
(defvar kmode-show-trailing-whitespace)
(defvar kmode-checkpatch-flymake--output-buffer)
(defvar kmode-checkpatch-flymake--process)
(defvar kmode-checkpatch-flymake--report-function)
(defvar kmode-checkpatch-flymake--request)
(defvar kmode-checkpatch-flymake--started-flymake)
(defvar kmode-checkpatch-flymake--temporary-file)
(defvar kmode-checkpatch-flymake-mode)
(defvar c-label-minimum-indentation)
(defvar c-offsets-alist)
(defvar cscope-database-file)
(defvar cscope-database-regexps)
(defvar cscope-index-file)
(defvar cscope-initial-directory)
(defvar cscope-option-disable-compression)
(defvar cscope-option-do-not-update-database)
(defvar cscope-option-include-directories)
(defvar cscope-option-kernel-mode)
(defvar cscope-option-other)
(defvar cscope-option-use-inverted-index)
(defvar cscope-output-buffer-name)
(defvar cscope-process)
(defvar cscope-program)
(defvar cscope-result-separator)
(defvar eglot-server-programs)
(defvar tags-completion-table)
(defvar tags-table-computed-list)
(defvar tags-table-computed-list-for)
(defvar tags-table-list-pointer)
(defvar tags-table-list-started-at)
(defvar tags-table-set-list)
(defvar tags-file-name)
(defvar tags-included-tables)
(defvar tags-table-files)
(defvar tags-table-list)

(defvar url-http-end-of-headers)
(defvar url-http-response-status)
(defvar url-request-extra-headers)
(defvar url-user-agent)

(defvar kmode-test--dispatch-count 0
  "Number of times the dispatcher test command has run.")

(defun kmode-test--dispatch-command ()
  "Record one invocation from `kmode-dispatch'."
  (interactive)
  (cl-incf kmode-test--dispatch-count))

(defun kmode-test--other-flymake-backend (_report-function &rest _arguments)
  "Stand in for an unrelated Flymake backend during coexistence tests.")

(defconst kmode-test--project-root
  (file-name-as-directory
   (expand-file-name ".." (file-name-directory
                            (or load-file-name buffer-file-name))))
  "Absolute path to the kmode-emacs checkout under test.")

(defconst kmode-test--optional-features
  (mapcar (lambda (file)
            (intern (file-name-base file)))
          (directory-files kmode-test--project-root nil
                           "\\`kmode-.*\\.el\\'"))
  "Kmode-emacs modules discovered in and loaded from the checkout.")

(defconst kmode-test--lore-atom
  (concat
   "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
   "<feed xmlns=\"http://www.w3.org/2005/Atom\">\n"
   " <title>Kmode test results</title>\n"
   " <entry>\n"
   "  <author><name>Alice &amp; Bob</name></author>\n"
   "  <title>[PATCH] Fix &amp; explain wakeups</title>\n"
   "  <updated>2026-09-08T12:34:56Z</updated>\n"
   "  <link rel=\"alternate\""
   " href=\"https://lore.kernel.org/all/id%2Fpart@example.com/\"/>\n"
   " </entry>\n"
   " <entry>\n"
   "  <title>Re: data structure lifetime</title>\n"
   "  <updated>2025-01-02T03:04:05Z</updated>\n"
   "  <link href=\"https://lore.kernel.org/all/second@example.net/\"/>\n"
   " </entry>\n"
   " <entry><title>Entry without a link</title></entry>\n"
   "</feed>\n")
  "Small offline Atom fixture for Lore parser and transport tests.")

(dolist (feature kmode-test--optional-features)
  (let ((source (expand-file-name (concat (symbol-name feature) ".el")
                                  kmode-test--project-root)))
    (when (file-exists-p source)
      ;; Load an explicit path because the KUnit module `kmode-test.el' and
      ;; this ERT file intentionally live in different directories.
      (unless (featurep feature)
        (load source nil nil t)))))

(defun kmode-test--write-file (root relative &optional contents mode)
  "Create RELATIVE below ROOT with CONTENTS and optional file MODE."
  (let ((file (expand-file-name relative root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (or contents "")))
    (when mode
      (set-file-modes file mode))
    file))

(cl-defmacro kmode-test-with-kernel-tree ((root) &body body)
  "Bind ROOT to a disposable synthetic kernel tree while running BODY."
  (declare (indent 1) (debug ((symbolp) body)))
  `(let* ((,root (make-temp-file "kmode-kernel-" t))
          (kmode--root-cache (make-hash-table :test #'equal))
          (kmode--selected-profiles (make-hash-table :test #'equal))
          (kmode--last-root nil)
          (kmode--actions (copy-sequence kmode--actions))
          (kmode-root-override nil)
          (kmode-profile nil)
          (kmode-output-directory nil)
          (kmode-arch nil)
          (kmode-cross-compile nil)
          (kmode-compiler nil)
          (kmode-jobs nil)
          (kmode-make-arguments nil))
     (unwind-protect
         (progn
           (dolist (marker kmode-root-markers)
             (kmode-test--write-file ,root marker))
           (kmode-test--write-file ,root "drivers/net/kmode_dummy.c"
                                    "int kmode_dummy;\n")
           (let ((default-directory (file-name-as-directory ,root)))
             ,@body))
       (ignore-errors (delete-directory ,root t)))))

(cl-defmacro kmode-test-with-fake-vng ((program) &body body)
  "Run BODY with PROGRAM bound to an executable fake vng path."
  (declare (indent 1) (debug ((symbolp) body)))
  `(let* ((kmode-test-vng-bin (make-temp-file "kmode-vng-bin-" t))
          (,program (expand-file-name "vng-fake" kmode-test-vng-bin))
          (kmode-vng-program ,program)
          (kmode-vng-home-directory
           (file-name-as-directory kmode-test-vng-bin))
          (kmode-vng-trust-default-options nil)
          (kmode-vng-confirm-host-access nil))
     (unwind-protect
         (progn
           (kmode-test--write-file
            kmode-test-vng-bin "vng-fake" "#!/bin/sh\nexit 0\n" #o755)
           ,@body)
       (ignore-errors (delete-directory kmode-test-vng-bin t)))))

(defun kmode-test--make-exited-process (buffer exit-code)
  "Return a process in BUFFER that has exited with EXIT-CODE."
  (let ((process
         (make-process
          :name (generate-new-buffer-name "kmode-test-exit")
          :buffer buffer
          :command (list (or shell-file-name "/bin/sh")
                         (or shell-command-switch "-c")
                         (format "exit %d" exit-code))
          :noquery t)))
    (while (process-live-p process)
      (accept-process-output process 0.05))
    process))

(ert-deftest kmode-test/modules-load-when-present ()
  "Every module present in the checkout must load and provide its feature."
  (dolist (feature kmode-test--optional-features)
    (let ((source (expand-file-name (concat (symbol-name feature) ".el")
                                    kmode-test--project-root)))
      (when (file-exists-p source)
        (should (featurep feature))))))

(ert-deftest kmode-test/kernel-root-requires-every-marker ()
  (kmode-test-with-kernel-tree (root)
    (should (kmode-kernel-root-p root))
    (delete-file (expand-file-name "MAINTAINERS" root))
    (should-not (kmode-kernel-root-p root))))

(ert-deftest kmode-test/locate-root-from-directory-and-file ()
  (kmode-test-with-kernel-tree (root)
    (let* ((nested (expand-file-name "drivers/net/" root))
           (source (expand-file-name "kmode_dummy.c" nested))
           (expected (file-name-as-directory root)))
      (should (equal (kmode-locate-root nested) expected))
      (should (equal (kmode-locate-root source) expected)))))

(ert-deftest kmode-test/locate-root-honors-buffer-override ()
  (kmode-test-with-kernel-tree (root)
    (with-temp-buffer
      (setq default-directory
            (file-name-as-directory (make-temp-file "kmode-outside-" t)))
      (unwind-protect
          (progn
            (setq-local kmode-root-override root)
            (should (equal (kmode-locate-root)
                           (file-name-as-directory root))))
        (delete-directory default-directory t)))))

(ert-deftest kmode-test/root-override-wins-over-a-negative-cache-entry ()
  (kmode-test-with-kernel-tree (root)
    (with-temp-buffer
      (let ((outside (make-temp-file "kmode-outside-" t)))
        (unwind-protect
            (progn
              (setq default-directory (file-name-as-directory outside))
              (should-not (kmode-locate-root))
              (setq-local kmode-root-override root)
              (should (equal (kmode-locate-root)
                             (file-name-as-directory root))))
          (delete-directory outside t))))))

(ert-deftest kmode-test/root-errors-cleanly-outside-a-kernel-tree ()
  (let* ((outside (make-temp-file "kmode-outside-" t))
         (default-directory (file-name-as-directory outside))
         (kmode--root-cache (make-hash-table :test #'equal))
         (kmode-root-override nil))
    (unwind-protect
        (progn
          (should-not (kmode-root t))
          (should-error (kmode-root) :type 'user-error))
      (delete-directory outside t))))

(ert-deftest kmode-test/root-cache-can-be-cleared-after-tree-appears ()
  (let* ((root (make-temp-file "kmode-late-kernel-" t))
         (default-directory (file-name-as-directory root))
         (kmode--root-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (should-not (kmode-locate-root))
          (dolist (marker kmode-root-markers)
            (kmode-test--write-file root marker))
          (should-not (kmode-locate-root))
          (kmode-clear-caches)
          (should (equal (kmode-locate-root)
                         (file-name-as-directory root))))
      (delete-directory root t))))

(ert-deftest kmode-test/command-root-prefers-current-tree-and-remembers-it ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (kmode-test-with-kernel-tree (current-root)
    (kmode-test-with-kernel-tree (remembered-root)
      (let ((kmode--last-root (file-name-as-directory remembered-root)))
        (with-temp-buffer
          (setq default-directory
                (file-name-as-directory
                 (expand-file-name "drivers/net" current-root)))
          (cl-letf (((symbol-function 'read-directory-name)
                     (lambda (&rest _arguments)
                       (ert-fail "Current kernel context prompted for a root"))))
            (should (equal (kmode-command-root)
                           (file-name-as-directory current-root))))
          (should (equal kmode--last-root
                         (file-name-as-directory current-root))))))))

(ert-deftest kmode-test/command-root-revalidates-cached-current-tree ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (kmode-test-with-kernel-tree (stale-root)
    (kmode-test-with-kernel-tree (remembered-root)
      (let ((kmode--last-root (file-name-as-directory remembered-root))
            (kmode-default-root nil))
        (with-temp-buffer
          (setq default-directory
                (file-name-as-directory
                 (expand-file-name "drivers/net" stale-root)))
          ;; Prime `kmode-locate-root' with a result which the filesystem no
          ;; longer supports before asking a project-wide command for a root.
          (should (equal (kmode-root t)
                         (file-name-as-directory stale-root)))
          (delete-file (expand-file-name "MAINTAINERS" stale-root))
          (cl-letf (((symbol-function 'read-directory-name)
                     (lambda (&rest _arguments)
                       (ert-fail "A valid remembered root should not prompt"))))
            (should (equal (kmode-command-root)
                           (file-name-as-directory remembered-root))))
          (should (equal kmode--last-root
                         (file-name-as-directory remembered-root))))))))

(ert-deftest kmode-test/command-root-uses-valid-configured-default ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((outside (make-temp-file "kmode-command-default-" t))
           (expected (file-name-as-directory root))
           (kmode--last-root nil)
           (kmode-default-root (expand-file-name "drivers/net" root)))
      (unwind-protect
          (with-temp-buffer
            (setq default-directory (file-name-as-directory outside))
            (cl-letf (((symbol-function 'read-directory-name)
                       (lambda (&rest _arguments)
                         (ert-fail "valid configured root should not prompt"))))
              (should (equal (kmode-command-root) expected))
              (should (equal kmode--last-root expected))))
        (delete-directory outside t)))))

(ert-deftest kmode-test/command-root-reuses-valid-remembered-tree ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((outside (make-temp-file "kmode-outside-" t))
          (kmode--last-root (file-name-as-directory root)))
      (unwind-protect
          (with-temp-buffer
            (setq default-directory (file-name-as-directory outside))
            (cl-letf (((symbol-function 'read-directory-name)
                       (lambda (&rest _arguments)
                         (ert-fail "Valid remembered root prompted again"))))
              (should (equal (kmode-command-root)
                             (file-name-as-directory root))))
            (should-not (bound-and-true-p kmode-mode)))
        (delete-directory outside t)))))

(ert-deftest kmode-test/command-root-prompts-for-stale-root-and-accepts-nested-directory ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((outside (make-temp-file "kmode-outside-" t))
          (kmode--last-root nil)
          (prompt-count 0))
      (unwind-protect
          (with-temp-buffer
            (setq default-directory (file-name-as-directory outside)
                  kmode--last-root (file-name-as-directory outside))
            (cl-letf (((symbol-function 'read-directory-name)
                       (lambda (&rest _arguments)
                         (cl-incf prompt-count)
                         (expand-file-name "drivers/net" root))))
              (should (equal (kmode-command-root)
                             (file-name-as-directory root))))
            (should (= prompt-count 1))
            (should (equal kmode--last-root
                           (file-name-as-directory root))))
        (delete-directory outside t)))))

(ert-deftest kmode-test/command-root-rejects-non-kernel-selection ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (let ((outside (make-temp-file "kmode-outside-" t))
        (kmode--root-cache (make-hash-table :test #'equal))
        (kmode--last-root nil))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory (file-name-as-directory outside))
          (cl-letf (((symbol-function 'read-directory-name)
                     (lambda (&rest _arguments) outside)))
            (should-error (kmode-command-root) :type 'user-error))
          (should-not kmode--last-root))
      (delete-directory outside t))))

(ert-deftest kmode-test/positive-jobs-normalizes-supported-values ()
  (should (integerp (kmode--positive-jobs 'auto)))
  (should (> (kmode--positive-jobs 'auto) 0))
  (should (= (kmode--positive-jobs 1) 1))
  (should (= (kmode--positive-jobs 32) 32))
  (should-not (kmode--positive-jobs nil))
  (dolist (bad '(0 -1 "8" many))
    (should-error (kmode--positive-jobs bad) :type 'user-error)))

(ert-deftest kmode-test/context-resolves-profile-paths-and-toolchain ()
  (kmode-test-with-kernel-tree (root)
    (let ((kmode-profiles
           '(("default"
              :description "Cross build"
              :arch "arm64"
              :cross-compile "aarch64-linux-gnu-"
              :compiler clang
              :output "build/arm64"
              :jobs 7
              :make-arguments ("V=1" "W=1")
              :image "arch/arm64/boot/Image"
              :vmlinux "vmlinux"))))
      (let ((context (kmode-resolve-context root)))
        (should (equal (kmode-context-root context)
                       (file-name-as-directory root)))
        (should (equal (kmode-context-profile context) "default"))
        (should (equal (kmode-context-output context)
                       (file-name-as-directory
                        (expand-file-name "build/arm64" root))))
        (should (equal (kmode-context-arch context) "arm64"))
        (should (equal (kmode-context-cross-compile context)
                       "aarch64-linux-gnu-"))
        (should (eq (kmode-context-compiler context) 'clang))
        (should (= (kmode-context-jobs context) 7))
        (should (equal (kmode-context-make-arguments context)
                       '("V=1" "W=1")))
        (should (string-match-p "default.*arm64.*clang/LLVM"
                                (kmode-profile-description context)))))))

(ert-deftest kmode-test/context-buffer-locals-override-profile ()
  (kmode-test-with-kernel-tree (root)
    (let ((kmode-profiles
           '(("default"
              :arch "x86"
              :cross-compile "old-"
              :compiler gcc
              :output "old-output"
              :jobs 2
              :make-arguments ("PROFILE=1")))))
      (with-temp-buffer
        (setq-local kmode-output-directory "new output")
        (setq-local kmode-arch "riscv")
        (setq-local kmode-cross-compile "riscv64-linux-gnu-")
        (setq-local kmode-compiler 'clang)
        (setq-local kmode-jobs 9)
        (setq-local kmode-make-arguments '("LOCAL=1"))
        (let ((context (kmode-resolve-context root)))
          (should (equal (kmode-context-output context)
                         (file-name-as-directory
                          (expand-file-name "new output" root))))
          (should (equal (kmode-context-arch context) "riscv"))
          (should (equal (kmode-context-cross-compile context)
                         "riscv64-linux-gnu-"))
          (should (eq (kmode-context-compiler context) 'clang))
          (should (= (kmode-context-jobs context) 9))
          (should (equal (kmode-context-make-arguments context)
                         '("LOCAL=1" "PROFILE=1"))))))))

(ert-deftest kmode-test/context-functions-can-refine-context ()
  (kmode-test-with-kernel-tree (root)
    (let ((kmode-context-functions
           (list (lambda (context)
                   (setf (kmode-context-arch context) "um")
                   context))))
      (should (equal (kmode-context-arch (kmode-resolve-context root))
                     "um")))))

(ert-deftest kmode-test/profile-selection-is-scoped-by-root ()
  (kmode-test-with-kernel-tree (root)
    (let ((other-root (make-temp-file "kmode-other-kernel-" t))
          (kmode-default-profile "default"))
      (unwind-protect
          (progn
            (puthash (file-name-as-directory root) "debug"
                     kmode--selected-profiles)
            (should (equal (kmode-current-profile-name
                            (file-name-as-directory root))
                           "debug"))
            (should (equal (kmode-current-profile-name other-root)
                           "default")))
        (delete-directory other-root t)))))

(ert-deftest kmode-test/unknown-profile-is-an-actionable-user-error ()
  (let ((kmode-profiles '(("default" :compiler auto))))
    (should-error (kmode--profile-entry "missing") :type 'user-error)))

(ert-deftest kmode-test/shell-command-preserves-hostile-arguments ()
  (let* ((program (or (executable-find "printf") "/usr/bin/printf"))
         (payload '("plain"
                    "two words"
                    "single'quote"
                    "double\"quote"
                    "$HOME"
                    "$(printf EXPANDED)"
                    "`printf EXPANDED`"
                    "semi;printf EXPANDED"))
         (arguments (cons "%s\\n" payload))
         (command (kmode-shell-command program arguments))
         (actual (shell-command-to-string command))
         (expected (concat (mapconcat #'identity payload "\n") "\n")))
    (should (equal actual expected))))

(ert-deftest kmode-test/start-command-quotes-argv-and-isolates-buffer ()
  (kmode-test-with-kernel-tree (root)
    (let* ((workdir (expand-file-name "drivers/net/" root))
           (arguments '("-C" "/tree with spaces" "target;not-a-command"))
           observed)
      (cl-letf (((symbol-function 'compilation-start)
                 (lambda (command mode name-function)
                   (setq observed
                         (list command mode (funcall name-function mode)
                               default-directory))
                   'kmode-test-buffer)))
        (should (eq (kmode-start-command "build" "make" arguments workdir)
                    'kmode-test-buffer)))
      (should (equal (nth 0 observed)
                     (kmode-shell-command "make" arguments)))
      (should (eq (nth 1 observed) 'kmode-compilation-mode))
      (should (equal (nth 2 observed)
                     (format "*kmode:%s:%s:build*"
                             (kmode-root-id root)
                             (kmode-current-profile-name root))))
      (should (equal (nth 3 observed)
                     (file-name-as-directory workdir))))))

(ert-deftest kmode-test/start-command-installs-finish-hook-before-launch ()
  (kmode-test-with-kernel-tree (root)
    (let* ((context (kmode-resolve-context root))
           (callback (lambda (_buffer _status)))
           (buffer (generate-new-buffer " *kmode-finish-before-launch*"))
           callback-present process-started)
      (unwind-protect
          (cl-letf (((symbol-function 'compilation-start)
                     (lambda (_command mode _name-function)
                       (with-current-buffer buffer
                         (funcall mode)
                         (funcall compilation-process-setup-function)
                         (setq callback-present
                               (memq callback compilation-finish-functions))
                         ;; This represents the point where Compilation would
                         ;; create its process.
                         (setq process-started t))
                       buffer)))
            (should
             (eq (kmode-start-command
                  "finish" "true" nil root nil nil context callback)
                 buffer))
            (should process-started)
            (should callback-present))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest kmode-test/build-argv-reflects-complete-cross-profile ()
  (unless (featurep 'kmode-build)
    (ert-skip "kmode-build.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((output (file-name-as-directory
                    (expand-file-name "output with spaces" root)))
           (context
            (kmode--make-context
             :root (file-name-as-directory root)
             :profile "ci"
             :output output
             :arch "arm64"
             :cross-compile "aarch64-linux-gnu-"
             :compiler 'clang
             :jobs 8
             :make-arguments '("KCFLAGS=-Werror")))
           (arguments
            (kmode-build-make-arguments
             context '("Image" "modules") '("V=1"))))
      (should
       (equal arguments
              (list "-j8"
                    "ARCH=arm64"
                    "CROSS_COMPILE=aarch64-linux-gnu-"
                    "LLVM=1"
                    (concat "O=" (directory-file-name output))
                    "KCFLAGS=-Werror"
                    "V=1"
                    "Image"
                    "modules"))))))

(ert-deftest kmode-test/build-argv-omits-inapplicable-options ()
  (unless (featurep 'kmode-build)
    (ert-skip "kmode-build.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((context
           (kmode--make-context
            :root (file-name-as-directory root)
            :profile "native"
            :output (file-name-as-directory root)
            :compiler 'gcc
            :jobs nil)))
      (should (equal (kmode-build-make-arguments context '("vmlinux"))
                     '("vmlinux"))))))

(ert-deftest kmode-test/build-target-validation-blocks-make-injection ()
  (unless (featurep 'kmode-build)
    (ert-skip "kmode-build.el is not present"))
  (dolist (target '("" "-j99" "ARCH=attacker" "all;echo-pwned"
                    "$(shell,id)" "target with spaces"))
    (should-error (kmode-build--target target) :type 'user-error))
  (dolist (target '("vmlinux" "drivers/net/" "kernel/sched/core.o"
                    "rust-analyzer" "foo+bar@baz%quux"))
    (should (equal (kmode-build--target target) target))))

(ert-deftest kmode-test/build-argv-validates-context-fields ()
  (unless (featurep 'kmode-build)
    (ert-skip "kmode-build.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((valid
           (kmode--make-context
            :root (file-name-as-directory root)
            :profile "test"
            :output (file-name-as-directory root)
            :compiler 'auto)))
      (dolist (mutation
               (list
                (lambda (context) (setf (kmode-context-root context) "relative"))
                (lambda (context) (setf (kmode-context-output context) nil))
                (lambda (context) (setf (kmode-context-compiler context) 'icc))
                (lambda (context) (setf (kmode-context-jobs context) 0))
                (lambda (context) (setf (kmode-context-arch context) ""))
                (lambda (context)
                  (setf (kmode-context-cross-compile context) ""))))
        (let ((context (copy-kmode-context valid)))
          (funcall mutation context)
          (should-error (kmode-build-make-arguments context)
                        :type 'user-error))))))

(ert-deftest kmode-test/build-argv-rejects-managed-output-overrides ()
  (unless (featurep 'kmode-build)
    (ert-skip "kmode-build.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((context (kmode--make-context
                    :root (file-name-as-directory root)
                    :profile "managed-output"
                    :output (file-name-as-directory
                             (expand-file-name "output" root))
                    :compiler 'auto)))
      (dolist (argument '("O=/tmp/wrong" "O:=relative" "O+=suffix"
                          "O = /tmp/wrong" " O=/tmp/wrong"
                          "KBUILD_OUTPUT=/tmp/wrong"
                          "KBUILD_OUTPUT ?= /tmp/wrong"
                          "KBUILD_OUTPUT::=/tmp/wrong"
                          "KBUILD_OUTPUT ::= /tmp/wrong"
                          "KBUILD_OUTPUT:::=/tmp/wrong"
                          "KBUILD_OUTPUT != printf-wrong"))
        (let ((profile-context (copy-kmode-context context)))
          (setf (kmode-context-make-arguments profile-context)
                (list argument))
          (should-error (kmode-build-make-arguments profile-context)
                        :type 'user-error))
        (should-error
         (kmode-build-make-arguments context nil (list argument))
         :type 'user-error))
      (dolist (argument '("V=1" "KCFLAGS=-Werror"
                          "OUTPUT=/tmp/allowed"
                          "KBUILD_OUTPUT_SUFFIX=allowed"
                          "OOPS=allowed" "o=/tmp/lowercase"
                          "FOO=O=/tmp/embedded"))
        (should (member argument
                        (kmode-build-make-arguments
                         context nil (list argument))))))))

(ert-deftest kmode-test/build-object-and-directory-targets-are-relative ()
  (unless (featurep 'kmode-build)
    (ert-skip "kmode-build.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((context (kmode-resolve-context root)))
      (with-temp-buffer
        (setq buffer-file-name
              (expand-file-name "drivers/net/kmode_dummy.c" root))
        (should (equal (kmode-build--current-object-target context)
                       "drivers/net/kmode_dummy.o"))
        (should (equal (kmode-build--current-directory-target context)
                       "drivers/net/")))
      (with-temp-buffer
        (setq buffer-file-name (expand-file-name "README.md" root))
        (should-error (kmode-build--current-object-target context)
                      :type 'user-error))
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root))
        (should-not (kmode-build--current-directory-target context))))))

(ert-deftest kmode-test/file-in-root-accepts-members-and-rejects-outsiders ()
  (kmode-test-with-kernel-tree (root)
    (let* ((inside (expand-file-name "drivers/net/kmode_dummy.c" root))
           (outside (make-temp-file "kmode-outsider-"))
           (context (kmode-resolve-context root)))
      (unwind-protect
          (progn
            (should (equal (kmode-file-in-root inside context)
                           "drivers/net/kmode_dummy.c"))
            (should-error (kmode-file-in-root outside context)
                          :type 'user-error))
        (delete-file outside)))))

(ert-deftest kmode-test/tool-path-prefers-a-kernel-tree-tool ()
  (kmode-test-with-kernel-tree (root)
    (let* ((tool (kmode-test--write-file
                  root "scripts/kmode-test-tool" "#!/bin/sh\nexit 0\n" #o755))
           (context (kmode-resolve-context root)))
      (should (equal (kmode-tool-path "scripts/kmode-test-tool" context)
                     tool))
      (should-error
       (kmode-require-tool "kmode-tool-that-must-not-exist-7c592" context)
       :type 'user-error))))

(ert-deftest kmode-test/flymake-parser-maps-checkpatch-severity-and-location ()
  (unless (featurep 'kmode-flymake)
    (ert-skip "kmode-flymake.el is not present"))
  (with-temp-buffer
    (insert "first line\nsecond token\nthird alpha beta\nfourth line")
    (let ((source (current-buffer))
          (output (generate-new-buffer " *kmode-flymake-parse*")))
      (unwind-protect
          (progn
            (with-current-buffer output
              (insert "ERROR:CODE_STYLE: bad style\n"
                      "#12: FILE: /tmp/snapshot.c:2:\n"
                      "+second token\n"
                      "WARNING: suspicious expression\n"
                      "FILE: /tmp/a:path/snapshot.c:3:7:\n"
                      "CHECK:\n"
                      "FILE: snapshot.c:99:\n"))
            (let ((diagnostics
                   (kmode-checkpatch-flymake--parse-output output source)))
              (should (= (length diagnostics) 3))
              (should (equal (mapcar #'flymake-diagnostic-type diagnostics)
                             '(:error :warning :note)))
              (should (equal (flymake-diagnostic-text (nth 0 diagnostics))
                             "checkpatch ERROR: CODE_STYLE: bad style"))
              (should (equal (flymake-diagnostic-text (nth 2 diagnostics))
                             "checkpatch CHECK"))
              (with-current-buffer source
                (should (= (line-number-at-pos
                            (flymake-diagnostic-beg (nth 0 diagnostics)))
                           2))
                (should (= (line-number-at-pos
                            (flymake-diagnostic-beg (nth 1 diagnostics)))
                           3))
                (goto-char (flymake-diagnostic-beg (nth 1 diagnostics)))
                (should (= (current-column) 6))
                ;; Flymake clamps an out-of-range diagnostic to the last line.
                (should (= (line-number-at-pos
                            (flymake-diagnostic-beg (nth 2 diagnostics)))
                           4)))))
        (when (buffer-live-p output)
          (kill-buffer output))))))

(ert-deftest kmode-test/flymake-extension-preserves-kernel-source-kind ()
  (unless (featurep 'kmode-flymake)
    (ert-skip "kmode-flymake.el is not present"))
  (dolist (extension '(".c" ".h" ".S" ".s" ".rs"))
    (with-temp-buffer
      (setq buffer-file-name (concat "/tmp/kmode-source" extension))
      (should (equal (kmode-checkpatch-flymake--source-extension)
                     extension))))
  (with-temp-buffer
    (setq major-mode 'rust-mode)
    (should (equal (kmode-checkpatch-flymake--source-extension) ".rs")))
  (with-temp-buffer
    (setq buffer-file-name "/tmp/not-source.txt")
    (should-not (kmode-checkpatch-flymake--source-extension))))

(ert-deftest kmode-test/flymake-backend-reports-missing-tool-without-signaling ()
  (unless (featurep 'kmode-flymake)
    (ert-skip "kmode-flymake.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (with-temp-buffer
      (setq default-directory (file-name-as-directory root)
            buffer-file-name
            (expand-file-name "drivers/net/kmode_dummy.c" root))
      (insert "int unsaved_change;\n")
      (let (report-action report-properties)
        (kmode-checkpatch-flymake
         (lambda (action &rest properties)
           (setq report-action action
                 report-properties properties)))
        (should (eq report-action :panic))
        (should (string-match-p
                 "executable scripts/checkpatch\\.pl"
                 (plist-get report-properties :explanation)))
        (should-not kmode-checkpatch-flymake--process)
        (should-not kmode-checkpatch-flymake--temporary-file)
        (should-not kmode-checkpatch-flymake--output-buffer)))))

(ert-deftest kmode-test/flymake-backend-uses-direct-argv-and-unsaved-snapshot ()
  (unless (featurep 'kmode-flymake)
    (ert-skip "kmode-flymake.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((tool (expand-file-name "scripts/checkpatch.pl" root))
           (fake-process
            (make-pipe-process
             :name (generate-new-buffer-name "kmode-flymake-process")
             :noquery t))
           captured-properties
           observed-directory
           report-action
           temporary
           output
           sentinel
           (kmode-test--enable-subr-trampolines nil))
      (set-file-modes tool #o755)
      (unwind-protect
          (with-temp-buffer
            (setq default-directory (file-name-as-directory root)
                  buffer-file-name
                  (expand-file-name "drivers/net/kmode_dummy.c" root))
            (insert "int live_buffer_value;\n")
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest properties)
                         (setq captured-properties properties
                               observed-directory default-directory)
                         fake-process)))
              (kmode-checkpatch-flymake
               (lambda (action &rest _properties)
                 (setq report-action action))))
            (setq temporary kmode-checkpatch-flymake--temporary-file
                  output kmode-checkpatch-flymake--output-buffer
                  sentinel (plist-get captured-properties :sentinel))
            (should (equal observed-directory (file-name-as-directory root)))
            (should (equal
                     (plist-get captured-properties :command)
                     (list tool "--no-tree" "--strict" "--file" temporary)))
            (should (string-suffix-p ".c" temporary))
            (should (equal (with-temp-buffer
                             (insert-file-contents temporary)
                             (buffer-string))
                           "int live_buffer_value;\n"))
            (with-current-buffer output
              (insert "ERROR: unsaved failure\n"
                      "FILE: /tmp/generated.c:1:\n"))
            (set-process-sentinel fake-process #'ignore)
            (delete-process fake-process)
            (funcall sentinel fake-process "finished\n")
            (should (= (length report-action) 1))
            (should (eq (flymake-diagnostic-type (car report-action)) :error))
            (should-not (file-exists-p temporary))
            (should-not (buffer-live-p output))
            (should-not kmode-checkpatch-flymake--request)
            (should-not kmode-checkpatch-flymake--process)
            (should-not kmode-checkpatch-flymake--temporary-file)
            (should-not kmode-checkpatch-flymake--output-buffer))
        (when (process-live-p fake-process)
          (delete-process fake-process))
        (when (and temporary (file-exists-p temporary))
          (delete-file temporary))
        (when (buffer-live-p output)
          (kill-buffer output))))))

(ert-deftest kmode-test/flymake-fast-sentinel-cannot-leave-stale-state ()
  (unless (featurep 'kmode-flymake)
    (ert-skip "kmode-flymake.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((tool (expand-file-name "scripts/checkpatch.pl" root))
           (fake-process
            (make-pipe-process
             :name (generate-new-buffer-name "kmode-flymake-fast")
             :noquery t))
           captured-temporary
           captured-output
           report-action
           (kmode-test--enable-subr-trampolines nil))
      (set-file-modes tool #o755)
      (unwind-protect
          (with-temp-buffer
            (setq default-directory (file-name-as-directory root)
                  buffer-file-name
                  (expand-file-name "drivers/net/kmode_dummy.rs" root))
            (insert "fn unsaved_fast_path() {}\n")
            (cl-letf
                (((symbol-function 'make-process)
                  (lambda (&rest properties)
                    (setq captured-output (plist-get properties :buffer)
                          captured-temporary
                          (car (last (plist-get properties :command))))
                    (with-current-buffer captured-output
                      (insert "WARNING: fast diagnostic\n"
                              "FILE: /tmp/fast.rs:1:\n"))
                    ;; Simulate completion from inside `make-process', before
                    ;; the caller can assign the returned process object.
                    (set-process-sentinel fake-process #'ignore)
                    (delete-process fake-process)
                    (funcall (plist-get properties :sentinel)
                             fake-process "finished\n")
                    fake-process)))
              (kmode-checkpatch-flymake
               (lambda (action &rest _properties)
                 (setq report-action action))))
            (should (= (length report-action) 1))
            (should (eq (flymake-diagnostic-type (car report-action))
                        :warning))
            (should-not kmode-checkpatch-flymake--request)
            (should-not kmode-checkpatch-flymake--process)
            (should-not kmode-checkpatch-flymake--temporary-file)
            (should-not kmode-checkpatch-flymake--output-buffer)
            (should-not (file-exists-p captured-temporary))
            (should-not (buffer-live-p captured-output)))
        (when (process-live-p fake-process)
          (delete-process fake-process))
        (when (and captured-temporary
                   (file-exists-p captured-temporary))
          (delete-file captured-temporary))
        (when (buffer-live-p captured-output)
          (kill-buffer captured-output))))))

(ert-deftest kmode-test/flymake-new-run-cancels-and-cleans-stale-process ()
  (unless (featurep 'kmode-flymake)
    (ert-skip "kmode-flymake.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((tool (expand-file-name "scripts/checkpatch.pl" root))
           (first-process
            (make-pipe-process
             :name (generate-new-buffer-name "kmode-flymake-first")
             :noquery t))
           (second-process
            (make-pipe-process
             :name (generate-new-buffer-name "kmode-flymake-second")
             :noquery t))
           (processes (list first-process second-process))
           calls
           captures
           first-temporary
           first-output
           (kmode-test--enable-subr-trampolines nil))
      (set-file-modes tool #o755)
      (unwind-protect
          (with-temp-buffer
            (setq default-directory (file-name-as-directory root)
                  buffer-file-name
                  (expand-file-name "drivers/net/kmode_dummy.c" root))
            (insert "int generation;\n")
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest properties)
                         (push properties captures)
                         (prog1 (car processes)
                           (setq processes (cdr processes))))))
              (kmode-checkpatch-flymake
               (lambda (action &rest _properties) (push action calls)))
              (setq first-temporary
                    kmode-checkpatch-flymake--temporary-file
                    first-output kmode-checkpatch-flymake--output-buffer)
              (kmode-checkpatch-flymake
               (lambda (action &rest _properties) (push action calls))))
            (should-not (process-live-p first-process))
            (should-not (file-exists-p first-temporary))
            (should-not (buffer-live-p first-output))
            (should (eq kmode-checkpatch-flymake--process second-process))
            ;; Even a late invocation of the captured old sentinel is stale.
            (funcall (plist-get (cadr captures) :sentinel)
                     first-process "deleted\n")
            (should-not calls)
            (kmode-checkpatch-flymake--cancel)
            (should-not (process-live-p second-process))
            (should-not kmode-checkpatch-flymake--process))
        (dolist (process (list first-process second-process))
          (when (process-live-p process)
            (delete-process process)))))))

(ert-deftest kmode-test/flymake-spawn-failure-cleans-resources-and-panics ()
  (unless (featurep 'kmode-flymake)
    (ert-skip "kmode-flymake.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((tool (expand-file-name "scripts/checkpatch.pl" root))
          captured-properties
          report-action
          report-properties
          (kmode-test--enable-subr-trampolines nil))
      (set-file-modes tool #o755)
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root)
              buffer-file-name
              (expand-file-name "drivers/net/kmode_dummy.S" root))
        (insert "nop\n")
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest properties)
                     (setq captured-properties properties)
                     (error "Synthetic spawn failure"))))
          (kmode-checkpatch-flymake
           (lambda (action &rest properties)
             (setq report-action action
                   report-properties properties))))
        (let* ((command (plist-get captured-properties :command))
               (temporary (car (last command)))
               (output (plist-get captured-properties :buffer)))
          (should (eq report-action :panic))
          (should (string-match-p "Synthetic spawn failure"
                                  (plist-get report-properties :explanation)))
          (should (string-suffix-p ".S" temporary))
          (should-not (file-exists-p temporary))
          (should-not (buffer-live-p output)))))))

(ert-deftest kmode-test/flymake-mode-rejects-nonexecutable-tree-tool-early ()
  (unless (featurep 'kmode-flymake)
    (ert-skip "kmode-flymake.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (with-temp-buffer
      (setq default-directory (file-name-as-directory root)
            buffer-file-name
            (expand-file-name "drivers/net/kmode_dummy.c" root))
      (let ((error-data
             (should-error (kmode-checkpatch-flymake-mode 1)
                           :type 'user-error)))
        (should (string-match-p
                 "needs executable scripts/checkpatch\\.pl"
                 (error-message-string error-data))))
      (should-not kmode-checkpatch-flymake-mode)
      (should-not flymake-mode)
      (should-not (memq #'kmode-checkpatch-flymake
                        flymake-diagnostic-functions))
      (should-not kmode-checkpatch-flymake--request)
      (should-not kmode-checkpatch-flymake--process))))

(ert-deftest kmode-test/flymake-mode-coexists-with-existing-backends ()
  (unless (featurep 'kmode-flymake)
    (ert-skip "kmode-flymake.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (set-file-modes (expand-file-name "scripts/checkpatch.pl" root) #o755)
    (with-temp-buffer
      (setq default-directory (file-name-as-directory root)
            buffer-file-name
            (expand-file-name "drivers/net/kmode_dummy.c" root))
      (setq-local flymake-mode t)
      (setq-local flymake-diagnostic-functions
                  '(kmode-test--other-flymake-backend))
      (let ((starts 0)
            (cleared 'not-called))
        (cl-letf (((symbol-function 'flymake-start)
                   (lambda (&optional _deferred _force)
                     (cl-incf starts))))
          (kmode-checkpatch-flymake-mode 1))
        (should kmode-checkpatch-flymake-mode)
        (should (= starts 1))
        (should (equal flymake-diagnostic-functions
                       '(kmode-test--other-flymake-backend
                         kmode-checkpatch-flymake)))
        (setq-local kmode-checkpatch-flymake--report-function
                    (lambda (action &rest _properties)
                      (setq cleared (list action))))
        (kmode-checkpatch-flymake-mode -1)
        (should-not kmode-checkpatch-flymake-mode)
        (should flymake-mode)
        (should (equal flymake-diagnostic-functions
                       '(kmode-test--other-flymake-backend)))
        (should (equal cleared '(nil)))
        (should-not (memq #'kmode-checkpatch-flymake--cancel
                          kill-buffer-hook))))))

(ert-deftest kmode-test/flymake-action-is-registered-but-mode-defaults-off ()
  (unless (featurep 'kmode-flymake)
    (ert-skip "kmode-flymake.el is not present"))
  (with-temp-buffer
    (should-not kmode-checkpatch-flymake-mode))
  (should
   (seq-find (lambda (action)
               (eq (kmode-action-id action) 'checkpatch-flymake))
             (kmode-actions t))))

(ert-deftest kmode-test/actions-replace-identities-filter-and-sort ()
  (let ((kmode--actions nil))
    (kmode-register-action 'zeta "Zulu" "Build" #'ignore)
    (kmode-register-action 'alpha "Alpha" "Build" #'ignore)
    (kmode-register-action 'hidden "Hidden" "Review" #'ignore
                            :predicate (lambda () nil))
    (kmode-register-action 'broken "Broken" "Review" #'ignore
                            :predicate (lambda () (error "not available")))
    (kmode-register-action 'zeta "Aardvark" "Debug" #'ignore)
    (should (equal (mapcar #'kmode-action-id (kmode-actions))
                   '(alpha zeta)))
    (should (= (length (kmode-actions t)) 4))
    (should (equal (kmode-action-title
                    (seq-find (lambda (action)
                                (eq (kmode-action-id action) 'zeta))
                              (kmode-actions t)))
                   "Aardvark"))))

(ert-deftest kmode-test/checkpatch-diagnostic-regexp-captures-location ()
  (let ((regexp (nth 1 (assq 'kmode-checkpatch
                              compilation-error-regexp-alist-alist))))
    (should (string-match regexp "FILE: drivers/net/demo.c:42:7:"))
    (should (equal (match-string 1 "FILE: drivers/net/demo.c:42:7:")
                   "drivers/net/demo.c"))
    (should (equal (match-string 2 "FILE: drivers/net/demo.c:42:7:") "42"))
    (should (equal (match-string 3 "FILE: drivers/net/demo.c:42:7:") "7"))))

(ert-deftest kmode-test/compilation-mode-installs-local-kernel-behavior ()
  (with-temp-buffer
    (kmode-compilation-mode)
    (should (eq major-mode 'kmode-compilation-mode))
    (should (memq 'kmode-checkpatch compilation-error-regexp-alist))
    (should (memq #'ansi-color-compilation-filter compilation-filter-hook))))

(ert-deftest kmode-test/navigation-parses-includes-and-config-symbols ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "kmode-navigate.el is not present"))
  (with-temp-buffer
    (insert "  # include <linux/sched.h>\n")
    (goto-char (point-min))
    (should (equal (kmode--line-include) "linux/sched.h")))
  (with-temp-buffer
    (insert "IS_ENABLED(CONFIG_PREEMPT_RT)")
    (search-backward "CONFIG_PREEMPT_RT")
    (should (equal (kmode--config-at-point) "PREEMPT_RT")))
  (with-temp-buffer
    (insert "CONFIG_not_uppercase")
    (goto-char (point-min))
    (should-not (kmode--config-at-point))))

(ert-deftest kmode-test/navigation-fallback-finds-kconfig-definitions ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "kmode-navigate.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (kmode-test--write-file
     root "drivers/Kconfig"
     "menuconfig KMODE_MENU\n\nconfig KMODE_DRIVER\n\tbool \"test\"\n")
    (let ((matches (kmode--search-kconfig-fallback "KMODE_DRIVER" root)))
      (should (= (length matches) 1))
      (should (equal (file-relative-name (caar matches) root)
                     "drivers/Kconfig"))
      (should (= (nth 1 (car matches)) 3)))))

(ert-deftest kmode-test/navigation-resolves-source-header-counterpart ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "kmode-navigate.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((buffer-file-name
           (expand-file-name "drivers/net/kmode_dummy.c" root))
          visited)
      (cl-letf (((symbol-function 'kmode--rg-files)
                 (lambda (_root)
                   '("drivers/net/kmode_dummy.c"
                     "include/linux/kmode_dummy.h")))
                ((symbol-function 'find-file)
                 (lambda (file) (setq visited file))))
        (kmode-toggle-header-source))
      (should (equal visited
                     (expand-file-name "include/linux/kmode_dummy.h" root))))))

(ert-deftest kmode-test/navigation-finds-nearest-kbuild-owner ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "kmode-navigate.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((owner (kmode-test--write-file root "drivers/net/Kbuild"
                                           "obj-y += kmode_dummy.o\n"))
           (buffer-file-name
            (expand-file-name "drivers/net/kmode_dummy.c" root))
           visited)
      (cl-letf (((symbol-function 'find-file)
                 (lambda (file) (setq visited file))))
        (kmode-find-kbuild))
      (should (equal visited owner)))))

(ert-deftest kmode-test/kconfig-parses-source-statements ()
  (unless (featurep 'kmode-kconfig)
    (ert-skip "kmode-kconfig.el is not present"))
  (dolist (case '(("source \"drivers/Kconfig\"" . "drivers/Kconfig")
                  ("rsource ../Kconfig.common" . "../Kconfig.common")
                  ("osource \"optional/Kconfig\"" . "optional/Kconfig")
                  ("orsource arch/$(SRCARCH)/Kconfig" .
                   "arch/$(SRCARCH)/Kconfig")))
    (with-temp-buffer
      (insert (car case))
      (should (equal (kmode-kconfig--source-at-point) (cdr case)))))
  (with-temp-buffer
    (insert "orsource \"subsystem/Kconfig.optional\"")
    (should
     (equal (kmode-kconfig--source-statement-at-point)
            '(orsource . "subsystem/Kconfig.optional"))))
  (with-temp-buffer
    (insert "config NOT_A_SOURCE")
    (should-not (kmode-kconfig--source-at-point))))

(ert-deftest kmode-test/kconfig-indentation-tracks-block-symbol-and-help ()
  (unless (featurep 'kmode-kconfig)
    (ert-skip "kmode-kconfig.el is not present"))
  (with-temp-buffer
    (insert "menu \"Drivers\"\n"
            "config KMODE_DRIVER\n"
            "bool \"Kmode-emacs driver\"\n"
            "help\n"
            "Developer-facing help text.\n"
            "endmenu\n")
    (kmode-kconfig-mode)
    (cl-labels ((indent-at
                 (line)
                 (goto-char (point-min))
                 (forward-line (1- line))
                 (kmode-kconfig-calculate-indent)))
      (should (= (indent-at 1) 0))
      (should (= (indent-at 2) 8))
      (should (= (indent-at 3) 16))
      (should (= (indent-at 4) 16))
      (should (= (indent-at 5) 24))
      (should (= (indent-at 6) 0))
      (goto-char (point-min))
      (forward-line 4)
      (kmode-kconfig-indent-line)
      (should (= (current-indentation) 24)))))

(ert-deftest kmode-test/kconfig-source-expands-active-architecture ()
  (unless (featurep 'kmode-kconfig)
    (ert-skip "kmode-kconfig.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((target (kmode-test--write-file root "arch/arm64/Kconfig"
                                            "config ARM64\n"))
           (kmode-profiles
            '(("default" :arch "arm64" :compiler auto :jobs nil)))
           visited)
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root))
        (insert "source \"arch/$(SRCARCH)/Kconfig\"\n")
        (goto-char (point-min))
        (cl-letf (((symbol-function 'find-file)
                   (lambda (file) (setq visited file))))
          (kmode-kconfig-follow-source)))
      (should (equal visited target)))))

(ert-deftest kmode-test/kconfig-rsource-is-relative-to-containing-file ()
  (unless (featurep 'kmode-kconfig)
    (ert-skip "kmode-kconfig.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((source (kmode-test--write-file root "drivers/Kconfig"))
           (target (kmode-test--write-file
                    root "drivers/Kconfig.local" "config LOCAL\n"))
           visited)
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root)
              buffer-file-name source)
        (insert "rsource \"Kconfig.local\"\n")
        (goto-char (point-min))
        (cl-letf (((symbol-function 'find-file)
                   (lambda (file) (setq visited file))))
          (kmode-kconfig-follow-source)))
      (should (equal visited target)))))

(ert-deftest kmode-test/x86-64-srcarch-drives-kconfig-and-includes ()
  (unless (and (featurep 'kmode-kconfig)
               (featurep 'kmode-navigate))
    (ert-skip "Kconfig/navigation modules are not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((kconfig (kmode-test--write-file
                     root "arch/x86/Kconfig" "config X86\n"))
           (header (kmode-test--write-file
                    root "arch/x86/include/asm/processor.h" ""))
           (kmode-profiles
            '(("default" :arch "x86_64" :compiler auto :jobs nil)))
           (context (kmode-resolve-context root))
           visited)
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root))
        (insert "source \"arch/$(SRCARCH)/Kconfig\"\n")
        (goto-char (point-min))
        (cl-letf (((symbol-function 'find-file)
                   (lambda (file) (setq visited file))))
          (kmode-kconfig-follow-source)))
      (should (equal visited kconfig))
      (should (member header
                      (kmode--include-candidates
                       "asm/processor.h" context)))
      (should-not
       (seq-some (lambda (path)
                   (string-match-p "/arch/x86_64/" path))
                 (kmode--include-candidates
                  "asm/processor.h" context))))))

(ert-deftest kmode-test/kconfig-source-rejects-variables-and-tree-escapes ()
  (unless (featurep 'kmode-kconfig)
    (ert-skip "kmode-kconfig.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((outside (make-temp-file "kmode-kconfig-outside-" t))
           (outside-target
            (kmode-test--write-file outside "Kconfig" "config OUTSIDE\n"))
           (escape-link (expand-file-name "escape" root)))
      (ignore outside-target)
      (unwind-protect
          (progn
            (make-symbolic-link outside escape-link)
            (dolist (statement '("source \"arch/$UNKNOWN/Kconfig\""
                                 "source \"../Kconfig\""
                                 "source \"escape/Kconfig\""))
              (with-temp-buffer
                (setq default-directory (file-name-as-directory root)
                      buffer-file-name (expand-file-name "Kconfig" root))
                (insert statement)
                (should-error (kmode-kconfig-follow-source)
                              :type 'user-error))))
        (delete-directory outside t)))))

(ert-deftest kmode-test/qemu-argv-expands-profile-tokens-without-splitting ()
  (unless (featurep 'kmode-debug)
    (ert-skip "kmode-debug.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((kmode-profiles
            '(("debug profile"
               :arch "riscv"
               :compiler clang
               :jobs nil
               :output "out with spaces"
               :image "arch/riscv/boot/Image"
               :vmlinux "symbols/vmlinux"
               :qemu-command
               ("qemu-system-riscv64"
                "-kernel" "%i"
                "-append" "profile=%p root=%r"
                "-device" "loader,file=%v"
                "--output=%o"))))
           (kmode-default-profile "debug profile")
           (context (kmode-resolve-context root))
           (output (directory-file-name (kmode-context-output context))))
      (should
       (equal
        (kmode-qemu-arguments context)
        (list
         "qemu-system-riscv64"
         "-kernel" (expand-file-name "arch/riscv/boot/Image" output)
         "-append"
         (format "profile=debug profile root=%s" (directory-file-name root))
         "-device"
         (concat "loader,file=" (expand-file-name "symbols/vmlinux" output))
         (concat "--output=" output)))))))

(ert-deftest kmode-test/qemu-argv-rejects-missing-or-non-string-items ()
  (unless (featurep 'kmode-debug)
    (ert-skip "kmode-debug.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((context (kmode--make-context
                    :root (file-name-as-directory root)
                    :profile "broken"
                    :output (file-name-as-directory root)
                    :arch "x86_64")))
      (should-error (kmode-qemu-arguments context) :type 'user-error)
      (setf (kmode-context-qemu-command context) '("qemu-system-x86_64" 42))
      (should-error (kmode-qemu-arguments context) :type 'user-error))))

(ert-deftest kmode-test/vng-build-run-debug-preview-exec-argv-is-exact ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((output (file-name-as-directory
                    (expand-file-name "vng-output" root)))
           (guest-root (file-name-as-directory
                        (expand-file-name "guest-root" root)))
           (context
            (kmode--make-context
             :root (file-name-as-directory root)
             :profile "vng exact"
             :output output
             :arch "riscv"
             :cross-compile "riscv64-linux-gnu-"
             :compiler 'clang
             :jobs 7
             :vng-root guest-root
             :vng-append '("console=ttyS0 panic=1"
                           "probe=$(touch not-run); value=a b")
             :vng-arguments '("--memory" "2G"
                              "--disable-monitor")
             :vng-debug-arguments '("--disable-kvm")
             :vng-build-arguments '("--verbose" "--skip-modules")
             :vng-make-arguments '("LOCALVERSION=-kmode test;$(nope)"
                                   "KCFLAGS=-DVALUE=a b")))
           (output-name (directory-file-name output))
           (root-name (directory-file-name guest-root))
           (run-common
            (list "--run" output-name
                  "--arch" "riscv64"
                  "--root" root-name
                  "--memory" "2G"
                  "--disable-monitor"))
           (append-arguments
            '("--append" "console=ttyS0 panic=1"
              "--append" "probe=$(touch not-run); value=a b"))
           (guest-command "printf '%s' 'guest; $(literal)'"))
      (make-directory output t)
      (make-directory guest-root t)
      (cl-letf (((symbol-function 'kmode-vng--native-architecture)
                 (lambda () "amd64")))
        (should
         (equal
          (kmode-vng-command-arguments 'build context)
          (list "--build"
                "--arch" "riscv64"
                "--cross-compile" "riscv64-linux-gnu-"
                "--jobs" "7"
                "--verbose" "--skip-modules"
                "--"
                (concat "O=" output-name)
                "LLVM=1"
                "LOCALVERSION=-kmode test;$(nope)"
                "KCFLAGS=-DVALUE=a b")))
        (should
         (equal (kmode-vng-command-arguments 'run context)
                (append run-common append-arguments)))
        (should
         (equal (kmode-vng-command-arguments 'debug context)
                (append run-common '("--disable-kvm")
                        append-arguments '("--debug"))))
        (should
         (equal (kmode-vng-command-arguments 'preview context)
                (append run-common append-arguments '("--dry-run"))))
        (should
         (equal (kmode-vng-command-arguments 'exec context guest-command)
                (append run-common append-arguments
                        (list "--exec" guest-command)))))
      (should-not (file-exists-p (expand-file-name "not-run" root))))))

(ert-deftest kmode-test/vng-profile-fields-resolve-into-context-and-argv ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((kmode-profiles
            '(("virt profile"
               :arch "arm64"
               :compiler clang
               :jobs 5
               :output "profile-output"
               :vng-arch "arm64"
               :vng-root "root-fs"
               :vng-append ("panic=1" "console=ttyAMA0 earlycon")
               :vng-arguments ("--memory" "3072M")
               :vng-debug-arguments ("--disable-kvm")
               :vng-build-arguments ("--skip-modules")
               :vng-make-arguments ("LOCALVERSION=-profile"))))
           (kmode-default-profile "virt profile")
           (output (file-name-as-directory
                    (expand-file-name "profile-output" root)))
           (guest-root (file-name-as-directory
                        (expand-file-name "root-fs" root))))
      (make-directory output t)
      (make-directory guest-root t)
      (let ((context (kmode-resolve-context root)))
        (should (equal (kmode-context-profile context) "virt profile"))
        (should (equal (kmode-context-output context) output))
        (should (equal (kmode-context-vng-root context) guest-root))
        (should (equal (kmode-context-vng-append context)
                       '("panic=1" "console=ttyAMA0 earlycon")))
        (should
         (equal
          (kmode-vng-command-arguments 'debug context)
          (list "--run" (directory-file-name output)
                "--arch" "arm64"
                "--root" (directory-file-name guest-root)
                "--memory" "3072M"
                "--disable-kvm"
                "--append" "panic=1"
                "--append" "console=ttyAMA0 earlycon"
                "--debug")))))))

(ert-deftest kmode-test/vng-profile-validation-blocks-managed-overrides ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((base
           (kmode--make-context
            :root (file-name-as-directory root)
            :profile "validation"
            :output (file-name-as-directory root)
            :compiler 'auto
            :jobs nil)))
      (dolist (case
               (list
                (cons 'run
                      (lambda (context)
                        (setf (kmode-context-vng-arguments context)
                              '("--run=/tmp/other"))))
                (cons 'debug
                      (lambda (context)
                        (setf (kmode-context-vng-debug-arguments context)
                              '("-rbad"))))
                (cons 'build
                      (lambda (context)
                        (setf (kmode-context-vng-build-arguments context)
                              '("--"))))
                (cons 'build
                      (lambda (context)
                        (setf (kmode-context-vng-make-arguments context)
                              '("O=/tmp/other"))))
                (cons 'run
                      (lambda (context)
                        (setf (kmode-context-vng-append context) "panic=1")))
                (cons 'build
                      (lambda (context)
                        (setf (kmode-context-vng-arch context) "mips64")))))
        (let ((context (copy-kmode-context base)))
          (funcall (cdr case) context)
          (should-error (kmode-vng-command-arguments (car case) context)
                        :type 'user-error)))
      (let ((context (copy-kmode-context base)))
        (setf (kmode-context-output context) "relative-output")
        (should-error (kmode-vng-command-arguments 'run context)
                      :type 'user-error)))))

(ert-deftest kmode-test/vng-cross-architecture-requires-existing-root ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((context
            (kmode--make-context
             :root (file-name-as-directory root)
             :profile "cross"
             :output (file-name-as-directory root)
             :arch "riscv"
             :cross-compile "riscv64-linux-gnu-"
             :compiler 'auto
             :jobs nil))
           (guest-root (file-name-as-directory
                        (expand-file-name "existing-root" root))))
      (cl-letf (((symbol-function 'kmode-vng--native-architecture)
                 (lambda () "amd64")))
        (should-error (kmode-vng-command-arguments 'run context)
                      :type 'user-error)
        (setf (kmode-context-vng-root context)
              (file-name-as-directory
               (expand-file-name "missing root" root)))
        (should-error (kmode-vng-command-arguments 'run context)
                      :type 'user-error)
        (make-directory guest-root t)
        (setf (kmode-context-vng-root context) guest-root)
        (should
         (equal (kmode-vng-command-arguments 'run context)
                (list "--run" (directory-file-name root)
                      "--arch" "riscv64"
                      "--root" (directory-file-name guest-root))))))))

(ert-deftest kmode-test/vng-pass-through-parser-fails-closed ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((base
           (kmode--make-context
            :root (file-name-as-directory root)
            :profile "strict arguments"
            :output (file-name-as-directory root)
            :compiler 'auto
            :jobs nil)))
      (dolist (arguments
               '(("--deb")
                 ("--ru=/tmp/other")
                 ("-vr")
                 ("-D/tmp/disk")
                 ("--debug")
                 ("--root-disk=/tmp/root.img")
                 ("--append=panic=1")
                 ("--memory")
                 ("--memory" "--rw")
                 ("positional")
                 ("--console=70000")))
        (let ((context (copy-kmode-context base)))
          (setf (kmode-context-vng-arguments context) arguments)
          (should-error (kmode-vng-command-arguments 'run context)
                        :type 'user-error)))
      (let ((context (copy-kmode-context base)))
        (setf (kmode-context-vng-build-arguments context) '("--memory=2G"))
        (should-error (kmode-vng-command-arguments 'build context)
                      :type 'user-error))
      (let ((context (copy-kmode-context base)))
        (setf (kmode-context-vng-arguments context)
              '("--memory=2G" "--pin=0,1" "--rwdir=/tmp/shared"))
        (should
         (equal (kmode-vng-command-arguments 'run context)
                (list "--run" (directory-file-name root)
                      "--memory=2G" "--pin=0,1"
                      "--rwdir=/tmp/shared")))))))

(ert-deftest kmode-test/vng-architecture-requires-coherent-disambiguation ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((base
           (kmode--make-context
            :root (file-name-as-directory root)
            :profile "architecture"
            :output (file-name-as-directory root)
            :compiler 'auto
            :jobs nil)))
      (cl-letf (((symbol-function 'kmode-vng--native-architecture)
                 (lambda () "amd64"))
                ((symbol-function 'kmode-native-arch)
                 (lambda () "x86")))
        (let ((context (copy-kmode-context base)))
          (setf (kmode-context-arch context) "x86")
          (should (equal (kmode-vng-architecture context) "amd64")))
        (let ((context (copy-kmode-context base)))
          (setf (kmode-context-arch context) "riscv")
          (should-error (kmode-vng-architecture context) :type 'user-error)
          (setf (kmode-context-vng-arch context) "riscv64")
          (should (equal (kmode-vng-architecture context) "riscv64")))
        (let ((context (copy-kmode-context base)))
          (setf (kmode-context-cross-compile context)
                "aarch64-linux-gnu-")
          (should (equal (kmode-vng-architecture context) "arm64")))
        (let ((context (copy-kmode-context base)))
          (setf (kmode-context-arch context) "arm64"
                (kmode-context-vng-arch context) "riscv64")
          (should-error (kmode-vng-architecture context) :type 'user-error))
        (let ((context (copy-kmode-context base)))
          (setf (kmode-context-arch context) "riscv"
                (kmode-context-cross-compile context)
                "aarch64-linux-gnu-")
          (should-error (kmode-vng-architecture context)
                        :type 'user-error))))))

(ert-deftest kmode-test/vng-runtime-rejects-upstream-shell-unsafe-values ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (kmode-test-with-fake-vng (program)
      (let* ((safe-output (file-name-as-directory
                           (expand-file-name "safe-output" root)))
             (unsafe-output (file-name-as-directory
                             (expand-file-name "unsafe output;dollar$" root)))
             (unsafe-root (file-name-as-directory
                           (expand-file-name "unsafe root;dollar$" root)))
             (base
              (kmode--make-context
               :root (file-name-as-directory root)
               :profile "unsafe"
               :output safe-output
               :compiler 'auto
               :jobs nil))
             (cases
              (list
               (cons 'run
                     (lambda (context)
                       (setf (kmode-context-output context) unsafe-output)))
               (cons 'run
                     (lambda (context)
                       (setf (kmode-context-vng-root context) unsafe-root)))
               (cons 'run
                     (lambda (context)
                       (setf (kmode-context-vng-arguments context)
                             '("--memory" "2 G"))))
               (cons 'debug
                     (lambda (context)
                       (setf (kmode-context-vng-debug-arguments context)
                             '("--qemu-opts=a;b"))))))
             (spawned nil)
             (kmode-test--enable-subr-trampolines nil))
        (ignore program)
        (make-directory safe-output t)
        (make-directory unsafe-output t)
        (make-directory unsafe-root t)
        (cl-letf (((symbol-function 'make-comint-in-buffer)
                   (lambda (&rest _arguments) (setq spawned t))))
          (dolist (case cases)
            (let ((context (copy-kmode-context base)))
              (funcall (cdr case) context)
              (should-error
               (kmode-vng--start-runtime (car case) context)
               :type 'user-error))))
        (should-not spawned)))))

(ert-deftest kmode-test/vng-untrusted-default-options-block-launch ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (kmode-test-with-fake-vng (program)
      (let* ((configuration
              (kmode-test--write-file
               kmode-vng-home-directory
               ".config/virtme-ng/virtme-ng.conf"
               "{\"default_opts\": {\"run\": \"host\", \"rw\": true}}\n"))
             (context
              (kmode--make-context
               :root (file-name-as-directory root)
               :profile "default"
               :output (file-name-as-directory root)
               :compiler 'auto
               :jobs nil))
             (spawned nil)
             (kmode-test--enable-subr-trampolines nil))
        (ignore configuration program)
        (cl-letf (((symbol-function 'make-comint-in-buffer)
                   (lambda (&rest _arguments) (setq spawned t))))
          (should-error (kmode-vng--start-runtime 'run context)
                        :type 'user-error))
        (should-not spawned)
        (should-not (kmode-vng-config-safe-p))
        (let ((kmode-vng-trust-default-options t))
          (should-not (kmode-vng-config-safe-p))
          (should-error (kmode-vng--assert-config-safe)
                        :type 'user-error))))))

(ert-deftest kmode-test/vng-trusted-defaults-drive-effective-safety-state ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (kmode-test-with-fake-vng (program)
      (let* ((configuration
              (kmode-test--write-file
               kmode-vng-home-directory
               ".config/virtme-ng/virtme-ng.conf"
               (concat "{\"default_opts\": {"
                       "\"debug\": true, \"rw\": true, "
                       "\"console\": 2345, \"memory\": \"2G\"}}\n")))
             (kmode-vng-trust-default-options t)
             (context
              (kmode--make-context
               :root (file-name-as-directory root)
               :profile "trusted defaults"
               :output (file-name-as-directory root)
               :compiler 'auto
               :jobs nil))
             prompt
             (kmode-test--enable-subr-trampolines nil))
        (ignore configuration program)
        (should (kmode-vng-config-safe-p))
        (should (kmode-vng--default-debug-value nil))
        (should
         (kmode-vng--global-runtime-p
          (kmode-vng-command-arguments 'run context)))
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (question) (setq prompt question) nil)))
          (let ((kmode-vng-confirm-host-access t))
            (should-error
             (kmode-vng--confirm-host-access
              (kmode-vng-command-arguments 'run context))
             :type 'user-error)))
        (should (string-match-p (regexp-quote "--rw") prompt))
        (should (string-match-p (regexp-quote "--console") prompt))
        (kmode-test--write-file
         kmode-vng-home-directory ".config/virtme-ng/virtme-ng.conf"
         "{\"default_opts\": {\"debug\": false}}\n")
        (should-not (kmode-vng--default-debug-value t))
        (should-not (kmode-vng--global-runtime-p '("--debug")))))))

(ert-deftest kmode-test/vng-trusted-defaults-reject-unsafe-values ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (kmode-test-with-fake-vng (program)
      (let ((kmode-vng-trust-default-options t))
        (ignore root program)
        (dolist (contents
                 '("{\"default_opts\": {\"unknown_future_option\": true}}\n"
                   "{\"default_opts\": {\"qemu\": \"evil;command\"}}\n"
                   "{\"default_opts\": {\"console\": 70000}}\n"
                   "{\"default_opts\": {\"rwdir\": \"/tmp/not-a-list\"}}\n"))
          (kmode-test--write-file
           kmode-vng-home-directory ".config/virtme-ng/virtme-ng.conf"
           contents)
          (should-not (kmode-vng-config-safe-p))
          (should-error (kmode-vng--assert-config-safe)
                        :type 'user-error))))))

(ert-deftest kmode-test/vng-runtime-plan-allows-only-preflight-to-miss-output ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (kmode-test-with-fake-vng (program)
      (let* ((output (file-name-as-directory
                      (expand-file-name "future-output" root)))
             (context
              (kmode--make-context
               :root (file-name-as-directory root)
               :profile "future output"
               :output output
               :compiler 'auto
               :jobs nil))
             plan spawned)
        (ignore program)
        (should-not (file-exists-p output))
        (cl-letf (((symbol-function 'kmode-vng-config-file)
                   (lambda () nil)))
          (setq plan (kmode-vng--prepare-runtime 'run context nil t))
          (should
           (equal (plist-get plan :arguments)
                  (list "--run" (directory-file-name output))))
          (cl-letf (((symbol-function 'make-comint-in-buffer)
                     (lambda (&rest _arguments) (setq spawned t))))
            (should-error
             (kmode-vng--start-runtime 'run context nil plan t)
             :type 'user-error)))
        (should-not spawned)))))

(ert-deftest kmode-test/vng-runtime-plan-rejects-default-mutation-before-spawn ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (kmode-test-with-fake-vng (program)
      (let* ((relative ".config/virtme-ng/virtme-ng.conf")
             (kmode-vng-trust-default-options t)
             (context
              (kmode--make-context
               :root (file-name-as-directory root)
               :profile "config snapshot"
               :output (file-name-as-directory root)
               :compiler 'auto
               :jobs nil))
             plan spawned prompted selected
             (kmode-test--enable-subr-trampolines nil))
        (ignore program)
        (kmode-test--write-file
         kmode-vng-home-directory relative
         "{\"default_opts\": {\"memory\": \"1G\"}}\n")
        (setq plan (kmode-vng--prepare-runtime 'run context))
        (kmode-test--write-file
         kmode-vng-home-directory relative
         "{\"default_opts\": {\"memory\": \"2G\"}}\n")
        (cl-letf (((symbol-function 'make-comint-in-buffer)
                   (lambda (&rest _arguments) (setq spawned t)))
                  ((symbol-function 'yes-or-no-p)
                   (lambda (&rest _arguments) (setq prompted t) t))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (&rest _arguments) (setq selected t))))
          (should-error
           (kmode-vng--start-runtime 'run context nil plan t)
           :type 'user-error))
        (should-not spawned)
        (should-not prompted)
        (should-not selected)))))

(ert-deftest kmode-test/vng-build-run-callback-is-early-exact-and-noninteractive ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (kmode-test-with-fake-vng (program)
      (let* ((root (file-name-as-directory root))
             (context
              (kmode--make-context
               :root root
               :profile "chained"
               :output root
               :compiler 'auto
               :jobs nil
               :vng-arguments '("--rw")))
             (success-buffer (generate-new-buffer " *kmode-vng-build-zero*"))
             (failure-buffer (generate-new-buffer " *kmode-vng-build-seven*"))
             (success-process
              (kmode-test--make-exited-process success-buffer 0))
             (failure-process
              (kmode-test--make-exited-process failure-buffer 7))
             active-buffer finish-status phase
             (prompt-count 0)
             (callback-prompt-count 0)
             (selection-count 0)
             (spawn-count 0)
             runtime-processes runtime-buffers
             (kmode-test--enable-subr-trampolines nil))
        (ignore program)
        (with-current-buffer success-buffer
          (setq-local kmode-compilation-process success-process))
        (with-current-buffer failure-buffer
          (setq-local kmode-compilation-process failure-process))
        (unwind-protect
            (let ((kmode-vng-confirm-host-access t))
              (cl-letf
                  (((symbol-function 'kmode-vng-config-file)
                    (lambda () nil))
                   ((symbol-function 'kmode-resolve-context)
                    (lambda (&optional _root) context))
                   ((symbol-function 'kmode-vng--start-managed)
                    (lambda (operation candidate resource finish-function)
                      (should (eq operation 'build))
                      (should (equal candidate context))
                      (should (equal resource root))
                      (should (functionp finish-function))
                      (with-current-buffer active-buffer
                        (setq-local compilation-finish-functions
                                    (list finish-function))
                        (should (memq finish-function
                                      compilation-finish-functions)))
                      ;; Simulate a cached build completing before this mocked
                      ;; launcher can return to `kmode-vng-build-and-run'.
                      (setq phase 'callback)
                      (funcall finish-function active-buffer finish-status)
                      (with-current-buffer active-buffer
                        (should-not (memq finish-function
                                          compilation-finish-functions)))
                      active-buffer))
                   ((symbol-function 'make-comint-in-buffer)
                    (lambda (_name candidate _executable _startfile
                                   &rest _arguments)
                      (cl-incf spawn-count)
                      (push candidate runtime-buffers)
                      (let ((process
                             (make-pipe-process
                              :name (generate-new-buffer-name
                                     "kmode-vng-chained")
                              :buffer candidate
                              :noquery t)))
                        (push process runtime-processes))
                      candidate))
                   ((symbol-function 'yes-or-no-p)
                    (lambda (&rest _arguments)
                      (if (eq phase 'preflight)
                          (progn (cl-incf prompt-count) t)
                        (cl-incf callback-prompt-count)
                        t)))
                   ((symbol-function 'pop-to-buffer)
                    (lambda (&rest _arguments)
                      (cl-incf selection-count))))
                (setq active-buffer success-buffer
                      finish-status "exited abnormally with code 99\n"
                      phase 'preflight)
                (should (eq (kmode-vng-build-and-run) success-buffer))
                (should (= spawn-count 1))
                (should (= prompt-count 1))
                (should (= callback-prompt-count 0))
                (should (= selection-count 0))

                ;; Remove the successful guest before the second preflight.
                (dolist (process runtime-processes)
                  (when (process-live-p process)
                    (delete-process process)))
                (dolist (buffer runtime-buffers)
                  (when (buffer-live-p buffer)
                    (kill-buffer buffer)))
                (setq runtime-processes nil
                      runtime-buffers nil
                      active-buffer failure-buffer
                      finish-status "finished\n"
                      phase 'preflight)
                (should (eq (kmode-vng-build-and-run) failure-buffer))
                ;; The human strings said the opposite, but only exit status
                ;; controls whether the guest starts.
                (should (= spawn-count 1))
                (should (= prompt-count 2))
                (should (= callback-prompt-count 0))
                (should (= selection-count 0))))
          (dolist (process runtime-processes)
            (when (process-live-p process)
              (delete-process process)))
          (dolist (buffer runtime-buffers)
            (when (buffer-live-p buffer)
              (kill-buffer buffer)))
          (dolist (buffer (list success-buffer failure-buffer))
            (when (buffer-live-p buffer)
              (kill-buffer buffer))))))))

(ert-deftest kmode-test/vng-debug-conflicts-with-raw-qemu-endpoints ()
  (unless (and (featurep 'kmode-virtme) (featurep 'kmode-debug))
    (ert-skip "vng/QEMU integration is not present"))
  (kmode-test-with-kernel-tree (root)
    (kmode-test-with-fake-vng (program)
      (let* ((arguments
              '("-s"
                "-gdb" "tcp:127.0.0.1:001234,server=on"
                "-qmp=unix:run/qmp.sock,server=on"
                "-qmp=tcp:localhost:3636,server=on"))
             (resources (kmode-qemu-runtime-resources arguments root))
             (owner-buffer (generate-new-buffer " *kmode-qemu-endpoints*"))
             (owner
              (make-pipe-process
               :name (generate-new-buffer-name "kmode-qemu-endpoints")
               :buffer owner-buffer
               :noquery t))
             (context
              (kmode--make-context
               :root (file-name-as-directory root)
               :profile "endpoint conflict"
               :output (file-name-as-directory root)
               :compiler 'auto
               :jobs nil
               :vng-arguments '("--console=04444" "--ssh")))
             (kmode-test--enable-subr-trampolines nil))
        (ignore program)
        (should
         (equal resources
                (list "tcp-port:1234"
                      (concat "unix-socket:"
                              (expand-file-name "run/qmp.sock" root))
                      "tcp-port:3636")))
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'kmode-vng-config-file)
                         (lambda () nil)))
                (should
                 (equal
                  (plist-get (kmode-vng--prepare-runtime 'debug context)
                             :resources)
                  '("tcp-port:1234" "tcp-port:3636"
                    "tcp-port:4444" "tcp-port:2222"))))

              (kmode-test--write-file
               kmode-vng-home-directory
               ".config/virtme-ng/virtme-ng.conf"
               (concat "{\"default_opts\": {"
                       "\"console\": 5555, \"ssh\": 6666}}\n"))
              (let ((kmode-vng-trust-default-options t))
                (should
                 (equal
                  (plist-get (kmode-vng--prepare-runtime 'run context)
                             :resources)
                  '("tcp-port:5555" "tcp-port:6666"))))

              (process-put owner 'kmode-runtime-kind 'qemu)
              (kmode-mark-process-runtime-resources owner resources)
              (cl-letf (((symbol-function 'kmode-vng-config-file)
                         (lambda () nil)))
                (should-error
                 (kmode-vng--prepare-runtime 'debug context)
                 :type 'user-error)))
          (when (process-live-p owner)
            (delete-process owner))
          (when (buffer-live-p owner-buffer)
            (kill-buffer owner-buffer)))))))

(ert-deftest kmode-test/vng-debug-spawns-direct-argv-and-tags-ownership ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (kmode-test-with-fake-vng (program)
      (let* ((root (file-name-as-directory root))
             (output (file-name-as-directory
                      (expand-file-name "runtime-output" root)))
             (context
              (kmode--make-context
               :root root
               :profile "debug profile"
               :output output
               :compiler 'auto
               :jobs nil
               :vng-arguments '("--memory" "2G")
               :vng-debug-arguments '("--disable-kvm")
               :vng-append '("panic=1; probe=$(not-a-host-shell)")))
             (expected-arguments
              (list "--run" (directory-file-name output)
                    "--memory" "2G"
                    "--disable-kvm"
                    "--append" "panic=1; probe=$(not-a-host-shell)"
                    "--debug"))
             captured process buffer
             (kmode-test--enable-subr-trampolines nil))
        (make-directory output t)
        (unwind-protect
            (cl-letf
                (((symbol-function 'make-comint-in-buffer)
                  (lambda (name candidate executable startfile &rest arguments)
                    (setq captured
                          (list name candidate executable startfile arguments
                                default-directory
                                (copy-sequence process-environment)))
                    (setq process
                          (make-pipe-process
                           :name (generate-new-buffer-name "kmode-vng-debug")
                           :buffer candidate
                           :noquery t))
                    candidate))
                 ((symbol-function 'pop-to-buffer)
                  (lambda (candidate &rest _arguments) candidate)))
              (setq buffer (kmode-vng--start-runtime 'debug context))
              (should
               (equal (nth 0 captured)
                      (substring (buffer-name buffer) 1 -1)))
              (should (eq (nth 1 captured) buffer))
              (should (equal (nth 2 captured) program))
              (should-not (nth 3 captured))
              (should (equal (nth 4 captured) expected-arguments))
              (should (equal (nth 5 captured) root))
              (let ((process-environment (nth 6 captured)))
                (should-not (getenv "ARCH"))
                (should-not (getenv "KBUILD_OUTPUT"))
                (should
                 (equal (getenv "HOME")
                        (directory-file-name kmode-vng-home-directory))))
              (should (eq (buffer-local-value 'major-mode buffer)
                          'kmode-vng-mode))
              (should (equal (process-get process 'kmode-root) root))
              (should (equal (process-get process 'kmode-profile)
                             "debug profile"))
              (should (eq (process-get process 'kmode-runtime-kind) 'vng))
              (should (process-get process 'kmode-vng-debug))
              (should (process-get process 'kmode-vng-global))
              (should
               (equal (process-get process 'kmode-runtime-resources)
                      '("tcp-port:1234" "tcp-port:3636")))
              (should
               (equal (process-get process 'kmode-process-resource)
                      (kmode-process-resource-key output)))
              (should (equal (process-get process 'kmode-context) context))
              (should-not (process-query-on-exit-flag process)))
          (when (process-live-p process)
            (delete-process process))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest kmode-test/vng-runtime-honors-canonical-output-lock ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (kmode-test-with-fake-vng (program)
      (let* ((output (file-name-as-directory
                      (expand-file-name "owned-output" root)))
             (alias (expand-file-name "output-alias" root))
             (owner-buffer (generate-new-buffer " *kmode-vng-build-owner*"))
             (owner
              (make-pipe-process
               :name (generate-new-buffer-name "kmode-vng-build-owner")
               :buffer owner-buffer
               :noquery t))
             (context
              (kmode--make-context
               :root (file-name-as-directory root)
               :profile "run"
               :output (file-name-as-directory alias)
               :compiler 'auto
               :jobs nil))
             (spawned nil)
             (kmode-test--enable-subr-trampolines nil))
        (ignore program)
        (make-directory output t)
        (make-symbolic-link output alias)
        (unwind-protect
            (progn
              (kmode-mark-process-resource owner-buffer output)
              (cl-letf (((symbol-function 'make-comint-in-buffer)
                         (lambda (&rest _arguments) (setq spawned t))))
                (should-error (kmode-vng--start-runtime 'run context)
                              :type 'user-error))
              (should-not spawned))
          (when (process-live-p owner)
            (delete-process owner))
          (when (buffer-live-p owner-buffer)
            (kill-buffer owner-buffer)))))))

(ert-deftest kmode-test/vng-debug-global-lock-crosses-worktrees ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (kmode-test-with-fake-vng (program)
      (let* ((other-root (file-name-as-directory
                          (make-temp-file "kmode-vng-other-root-" t)))
             (other-output (file-name-as-directory
                            (expand-file-name "output" other-root)))
             (owner-buffer (generate-new-buffer " *kmode-vng-global-owner*"))
             (owner
              (make-pipe-process
               :name (generate-new-buffer-name "kmode-vng-global-owner")
               :buffer owner-buffer
               :noquery t))
             (context
              (kmode--make-context
               :root other-root
               :profile "other"
               :output other-output
               :compiler 'auto
               :jobs nil))
             (spawned nil)
             (kmode-test--enable-subr-trampolines nil))
        (ignore root program)
        (make-directory other-output t)
        (process-put owner 'kmode-runtime-kind 'vng)
        (process-put owner 'kmode-root "/unrelated/kernel/")
        (process-put owner 'kmode-profile "debug")
        (process-put owner 'kmode-vng-global t)
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'make-comint-in-buffer)
                         (lambda (&rest _arguments) (setq spawned t))))
                (should-error (kmode-vng--start-runtime 'debug context)
                              :type 'user-error))
              (should-not spawned))
          (when (process-live-p owner)
            (delete-process owner))
          (when (buffer-live-p owner-buffer)
            (kill-buffer owner-buffer))
          (ignore-errors (delete-directory other-root t)))))))

(ert-deftest kmode-test/vng-orphan-remains-owned-and-stop-finds-it ()
  (unless (featurep 'kmode-virtme)
    (ert-skip "kmode-virtme.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "orphan-output" root)))
           (context
            (kmode--make-context
             :root root
             :profile "default"
             :output output
             :compiler 'auto
             :jobs nil))
           (buffer (generate-new-buffer " *kmode-vng-orphan*"))
           (process
            (make-pipe-process
             :name (generate-new-buffer-name "kmode-vng-orphan")
             :buffer buffer
             :noquery t))
           interrupted
           (kmode-test--enable-subr-trampolines nil))
      (make-directory output t)
      (unwind-protect
          (progn
            (kmode-mark-process-context buffer root "default")
            (kmode-mark-process-resource buffer output)
            (process-put process 'kmode-runtime-kind 'vng)
            (process-put process 'kmode-vng-debug nil)
            (process-put process 'kmode-vng-global nil)
            (process-put process 'kmode-context (copy-kmode-context context))
            (set-process-buffer process nil)
            (kill-buffer buffer)
            (should (memq process (kmode-vng-processes context)))
            (should (eq process (kmode-resource-process output)))
            (cl-letf (((symbol-function 'interrupt-process)
                       (lambda (candidate &rest _arguments)
                         (setq interrupted candidate))))
              (with-temp-buffer
                (setq default-directory root)
                (kmode-vng-stop)))
            (should (eq interrupted process)))
        (when (process-live-p process)
          (delete-process process))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest kmode-test/vng-actions-and-prefix-keymap-are-discoverable ()
  (unless (and (featurep 'kmode-virtme) (featurep 'kmode-emacs))
    (ert-skip "virtme mode integration is not present"))
  (dolist (entry '((vng-build kmode-vng-build "Run")
                   (vng-run kmode-vng-run "Run")
                   (vng-preview kmode-vng-preview "Run")
                   (vng-debug kmode-vng-debug "Debug")
                   (vng-stop kmode-vng-stop "Run")))
    (let ((action
           (seq-find (lambda (candidate)
                       (eq (kmode-action-id candidate) (nth 0 entry)))
                     (kmode-actions t))))
      (should action)
      (should (eq (kmode-action-command action) (nth 1 entry)))
      (should (equal (kmode-action-group action) (nth 2 entry)))))
  (should (eq (lookup-key kmode-command-map (kbd "v")) kmode-vng-map))
  (dolist (binding '(("b" . kmode-vng-build)
                     ("r" . kmode-vng-run)
                     ("p" . kmode-vng-preview)
                     ("d" . kmode-vng-debug)
                     ("x" . kmode-vng-stop)))
    (should (eq (lookup-key kmode-vng-map (kbd (car binding)))
                (cdr binding)))))

(ert-deftest kmode-test/navigation-xref-commands-and-prefix-bindings ()
  (unless (and (featurep 'kmode-navigate) (featurep 'kmode-emacs))
    (ert-skip "navigation mode integration is not present"))
  (should (eq (lookup-key kmode-command-map (kbd "n"))
              kmode-navigation-map))
  (should (eq (lookup-key kmode-navigation-map (kbd "d"))
              'kmode-find-definition))
  (should (eq (lookup-key kmode-navigation-map (kbd "r"))
              'kmode-find-usages))
  (should (eq (lookup-key kmode-navigation-map (kbd "a"))
              'kmode-find-function-callers))
  (should (eq (lookup-key kmode-navigation-map (kbd "b"))
              'kmode-navigation-back))
  (let ((kmode-usages-backend 'xref)
        calls)
    (cl-letf (((symbol-function 'xref-find-definitions)
               (lambda () (interactive) (push 'definition calls)))
              ((symbol-function 'xref-find-references)
               (lambda (identifier)
                 (push (list 'usages identifier) calls)))
              ((symbol-function 'xref-go-back)
               (lambda () (interactive) (push 'back calls))))
      (with-temp-buffer
        (insert "wake_up_process")
        (goto-char (point-min))
        (call-interactively #'kmode-find-definition)
        (call-interactively #'kmode-find-usages)
        (kmode-find-callers "mutex_lock" 'xref)
        (call-interactively #'kmode-navigation-back)))
    (should
     (equal (nreverse calls)
            '(definition
              (usages "wake_up_process")
              (usages "mutex_lock")
              back)))))

(ert-deftest kmode-test/usages-extract-kernel-identifiers ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "navigation integration is not present"))
  (dolist (case '(("struct task_struct" 1 "task_struct")
                  ("typedef struct task_struct task_t;" 1 "task_struct")
                  ("object->state" 9 "state")
                  ("READ_ONCE(value)" 1 "READ_ONCE")
                  ("global_value" 4 "global_value")))
    (with-temp-buffer
      (c-mode)
      (insert (nth 0 case))
      (goto-char (nth 1 case))
      (should (equal (kmode--kernel-identifier-at-point) (nth 2 case))))))

(ert-deftest kmode-test/usages-auto-backend-priority-is-honest ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "navigation integration is not present"))
  (let (semantic cscope)
    (cl-letf (((symbol-function 'kmode--eglot-semantic-references-p)
               (lambda () semantic))
              ((symbol-function 'kmode-cscope-available-p)
               (lambda () cscope)))
      (setq semantic t cscope t)
      (should (eq (kmode--select-usages-backend 'auto) 'xref))
      (setq semantic nil)
      (should (eq (kmode--select-usages-backend 'auto) 'cscope))
      (setq cscope nil)
      (should (eq (kmode--select-usages-backend 'auto) 'text))
      (should (eq (kmode--select-usages-backend 'xref) 'xref))
      (should-error (kmode--select-usages-backend 'unknown)
                    :type 'user-error))))

(ert-deftest kmode-test/usages-cscope-passes-symbol-and-labels-results ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "navigation integration is not present"))
  (let* ((cscope-output-buffer-name
          (generate-new-buffer-name " *kmode-usages-cscope*"))
         (result (get-buffer-create cscope-output-buffer-name))
         observed)
    (unwind-protect
        (cl-letf (((symbol-function 'kmode-cscope-available-p)
                   (lambda () t))
                  ((symbol-function 'kmode--call-xcscope)
                   (lambda (command &optional identifier)
                     (setq observed (list command identifier)))))
          (kmode-find-usages "task_struct" 'cscope)
          (should
           (equal observed '(cscope-find-this-symbol "task_struct")))
          (with-current-buffer result
            (should (equal (buffer-name) cscope-output-buffer-name))
            (should (string-match-p
                     "task_struct" (format "%s" header-line-format)))
            (should (string-match-p
                     "not semantic" (format "%s" header-line-format)))))
      (when (buffer-live-p result)
        (kill-buffer result)))))

(ert-deftest kmode-test/usages-text-fallback-is-visibly-labelled ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "navigation integration is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((result (generate-new-buffer " *kmode-usages-text*"))
           (next-error-last-buffer nil)
           observed defaults-called)
      (unwind-protect
          (with-temp-buffer
            (setq default-directory (file-name-as-directory root))
            (cl-letf (((symbol-function 'rgrep)
                       (lambda (regexp files directory &optional _confirm)
                         (setq observed (list regexp files directory)
                               next-error-last-buffer result)))
                      ((symbol-function 'grep-compute-defaults)
                       (lambda () (setq defaults-called t)))
                      ((symbol-function 'kmode-tool-path)
                       (lambda (tool &optional _context)
                         (should (equal tool "rg"))
                         nil)))
              (kmode-find-usages "wake_up_process" 'text))
            (should defaults-called)
            (should (equal (nth 1 observed) kmode-usages-text-files))
            (should (equal (nth 2 observed) (file-name-as-directory root)))
            (should (string-match-p "wake_up_process" (car observed)))
            (with-current-buffer result
              (should (string-match-p
                       "\\`\\*kmode textual usages: wake_up_process\\*"
                       (buffer-name)))
              (should (string-match-p
                       "TEXT MATCHES" (format "%s" header-line-format)))
              (should (string-match-p
                       "not semantic" (format "%s" header-line-format)))))
        (when (buffer-live-p result)
          (kill-buffer result))))))

(ert-deftest kmode-test/usages-prefers-async-safely-quoted-ripgrep ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "navigation integration is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((result (generate-new-buffer " *kmode-usages-rg*"))
           (kmode-usages-text-files "*.c *.h")
           observed)
      (unwind-protect
          (with-temp-buffer
            (setq default-directory (file-name-as-directory root))
            (cl-letf
                (((symbol-function 'kmode-tool-path)
                  (lambda (tool &optional _context)
                    (should (equal tool "rg"))
                    "/host/bin/rg"))
                 ((symbol-function 'rgrep)
                  (lambda (&rest _arguments)
                    (ert-fail "rgrep must not run when rg is available")))
                 ((symbol-function 'compilation-start)
                  (lambda (command mode name-function &rest _arguments)
                    (setq observed
                          (list command mode (funcall name-function "grep")))
                    result)))
              (kmode-find-usages "wake_up_process" 'text))
            (should
             (equal
              (nth 0 observed)
              (mapconcat
               #'shell-quote-argument
               '("/host/bin/rg" "--no-config" "--line-number" "--no-heading"
                 "--with-filename" "--color" "never" "--fixed-strings"
                 "--word-regexp" "--glob" "*.c" "--glob" "*.h"
                 "--" "wake_up_process" ".")
               " ")))
            (should (eq (nth 1 observed) 'grep-mode))
            (should (string-match-p
                     "kmode textual usages: wake_up_process" (nth 2 observed)))
            (with-current-buffer result
              (should (string-match-p
                       "RIPGREP TEXT MATCHES"
                       (format "%s" header-line-format)))))
        (when (buffer-live-p result)
          (kill-buffer result))))))

(ert-deftest kmode-test/usages-forced-missing-cscope-is-actionable ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "navigation integration is not present"))
  (cl-letf (((symbol-function 'kmode-cscope-available-p)
             (lambda () nil)))
    (should-error (kmode-find-usages "mutex_lock" 'cscope)
                  :type 'user-error)))

(ert-deftest kmode-test/function-callers-prefers-dedicated-cscope-query ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "navigation integration is not present"))
  (let* ((cscope-output-buffer-name
          (generate-new-buffer-name " *kmode-callers-cscope*"))
         (result (get-buffer-create cscope-output-buffer-name))
         semantic-checked observed)
    (unwind-protect
        (cl-letf (((symbol-function 'kmode-cscope-available-p)
                   (lambda () t))
                  ((symbol-function 'kmode--eglot-semantic-references-p)
                   (lambda () (setq semantic-checked t)))
                  ((symbol-function 'kmode--call-xcscope)
                   (lambda (command &optional identifier)
                     (setq observed (list command identifier)))))
          (kmode-find-function-callers "wake_up_process")
          (should-not semantic-checked)
          (should
           (equal observed
                  '(cscope-find-functions-calling-this-function
                    "wake_up_process")))
          (with-current-buffer result
            (should (equal (buffer-name) cscope-output-buffer-name))
            (should (string-match-p
                     "wake_up_process" (format "%s" header-line-format)))
            (should (string-match-p
                     "FUNCTION CALLERS" (format "%s" header-line-format)))))
      (when (buffer-live-p result)
        (kill-buffer result)))))

(ert-deftest kmode-test/function-callers-falls-back-to-references-then-text ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "navigation integration is not present"))
  (let ((result (generate-new-buffer " *kmode-callers-text*"))
        semantic references textual)
    (unwind-protect
        (cl-letf (((symbol-function 'kmode-cscope-available-p)
                   (lambda () nil))
                  ((symbol-function 'kmode--eglot-semantic-references-p)
                   (lambda () semantic))
                  ((symbol-function 'xref-find-references)
                   (lambda (identifier) (setq references identifier)))
                  ((symbol-function 'kmode--find-textual-usages)
                   (lambda (identifier)
                     (setq textual identifier)
                     result)))
          (setq semantic t)
          (kmode-find-function-callers "mutex_lock")
          (should (equal references "mutex_lock"))
          (should-not textual)
          (setq semantic nil references nil)
          (kmode-find-function-callers "mutex_unlock")
          (should-not references)
          (should (equal textual "mutex_unlock"))
          (with-current-buffer result
            (should (string-match-p
                     "textual caller candidates: mutex_unlock"
                     (buffer-name)))
            (should (string-match-p
                     "non-call uses" (format "%s" header-line-format)))))
      (when (buffer-live-p result)
        (kill-buffer result)))))

(ert-deftest kmode-test/navigation-back-supports-emacs-28-xref ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "navigation integration is not present"))
  (let ((legacy-command (intern "xref-pop-marker-stack"))
        calls)
    (cl-letf (((symbol-function 'xref-go-back) nil)
              ((symbol-function legacy-command)
               (lambda () (interactive) (push 'legacy-back calls))))
      (call-interactively #'kmode-navigation-back))
    (should (equal calls '(legacy-back)))))

(ert-deftest kmode-test/dispatcher-runs-available-and-rejects-hidden-action ()
  (unless (featurep 'kmode-ui)
    (ert-skip "kmode-ui.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((kmode--actions nil)
          (kmode-test--dispatch-count 0)
          (chosen-id 'run)
          ;; Replacing a primitive should not ask native compilation to emit
          ;; a trampoline into the user's cache during this isolated test.
          (kmode-test--enable-subr-trampolines nil))
      (should (equal (kmode-root) (file-name-as-directory root)))
      (kmode-register-action 'run "Run probe" "Test"
                              #'kmode-test--dispatch-command)
      (kmode-register-action 'hidden "Hidden probe" "Test"
                              #'kmode-test--dispatch-command
                              :predicate (lambda () nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _arguments)
                   (car
                    (seq-find
                     (lambda (candidate)
                       (eq (kmode-action-id (cdr candidate)) chosen-id))
                     collection)))))
        (kmode-dispatch)
        (should (= kmode-test--dispatch-count 1))
        (setq chosen-id 'hidden)
        (should-error (kmode-dispatch t) :type 'user-error)
        (should (= kmode-test--dispatch-count 1))))))

(ert-deftest kmode-test/dashboard-renders-health-and-action-availability ()
  (unless (featurep 'kmode-ui)
    (ert-skip "kmode-ui.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (kmode-test--write-file root ".config" "CONFIG_KMODE=y\n")
    (let ((kmode--actions nil)
          (kmode-profiles '(("default" :compiler auto :jobs nil))))
      (kmode-register-action 'available "Available action" "Build" #'ignore
                              :description "Ready to run")
      (kmode-register-action 'unavailable "Unavailable action" "Review"
                              #'ignore :predicate (lambda () nil))
      (with-temp-buffer
        (kmode-dashboard-mode)
        (setq-local kmode-dashboard-root (file-name-as-directory root))
        (cl-letf (((symbol-function 'kmode--git-string)
                   (lambda (_root &rest arguments)
                     (if (equal arguments '("branch" "--show-current"))
                         "topic/test"
                       ""))))
          (kmode-dashboard-refresh))
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-match-p "KMODE // KERNEL FLIGHT DECK" text))
          (should (string-match-p "topic/test.*clean" text))
          (should (string-match-p "\\.config[[:space:]]+ready" text))
          (should (string-match-p "Compile DB[[:space:]]+missing" text))
          (should (string-match-p "clangd index[[:space:]]+missing" text))
          (should (string-match-p "TAGS[[:space:]]+missing" text))
          (should (string-match-p "cscope[[:space:]]+missing" text))
          (should (string-match-p "Available action.*Ready to run" text))
          (should (string-match-p "Unavailable action" text)))
        (goto-char (point-min))
        (search-forward "Available action")
        (should (button-at (1- (point))))
        (search-forward "Unavailable action")
        (should-not (button-at (1- (point))))))))

(ert-deftest kmode-test/dashboard-index-storage-rows-follow-profile-output ()
  (unless (featurep 'kmode-ui)
    (ert-skip "kmode-ui.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "profile-output" root)))
           (origin (generate-new-buffer " *kmode-dashboard-storage-origin*"))
           (dashboard (generate-new-buffer " *kmode-dashboard-storage*"))
           (kmode--actions nil)
           (kmode-profiles
            `(("default" :compiler auto :jobs nil :output ,output))))
      (make-directory output t)
      ;; Decoys in the source root must not make an out-of-tree profile ready.
      (kmode-test--write-file root "compile_commands.json" "[]\n")
      (kmode-test--write-file root "TAGS")
      (kmode-test--write-file root "cscope.out")
      (make-directory (expand-file-name ".cache/clangd/index" root) t)
      (unwind-protect
          (progn
            (with-current-buffer origin
              (setq default-directory root))
            (with-current-buffer dashboard
              (kmode-dashboard-mode)
              (setq-local kmode-dashboard-root root)
              (setq-local kmode-dashboard-origin origin)
              (setq-local kmode-root-override root)
              (setq default-directory root)
              (cl-letf (((symbol-function 'kmode--git-string)
                         (lambda (&rest _arguments) "")))
                (kmode-dashboard-refresh))
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (dolist (row '("Compile DB" "clangd index" "TAGS" "cscope"))
                  (should (string-match-p
                           (format "%s[[:space:]]+missing" row) text))))
              (kmode-test--write-file output "compile_commands.json" "[]\n")
              (kmode-test--write-file output "TAGS")
              (kmode-test--write-file output "cscope.out")
              (make-directory (expand-file-name ".cache/clangd/index" output) t)
              (cl-letf (((symbol-function 'kmode--git-string)
                         (lambda (&rest _arguments) "")))
                (kmode-dashboard-refresh))
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (dolist (row '("Compile DB" "clangd index" "TAGS" "cscope"))
                  (should (string-match-p
                           (format "%s[[:space:]]+ready" row) text))))))
        (when (buffer-live-p dashboard)
          (kill-buffer dashboard))
        (when (buffer-live-p origin)
          (kill-buffer origin))))))

(ert-deftest kmode-test/dashboard-uses-origin-buffer-context ()
  (unless (featurep 'kmode-ui)
    (ert-skip "kmode-ui.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "origin-output" root)))
           (origin (generate-new-buffer " *kmode-dashboard-origin*"))
           (dashboard (generate-new-buffer " *kmode-dashboard-context*"))
           (kmode-profiles
            `(("default" :compiler auto :jobs nil)
              ("origin-profile" :compiler clang :jobs 3)))
           (kmode--actions nil))
      (unwind-protect
          (progn
            (with-current-buffer origin
              (setq default-directory root)
              (setq-local kmode-profile "origin-profile")
              (setq-local kmode-output-directory output))
            (kmode-register-action
             'origin-only "Origin-only action" "Build" #'ignore
             :predicate
             (lambda ()
               (and (equal kmode-profile "origin-profile")
                    (equal kmode-output-directory output))))
            (with-current-buffer dashboard
              (kmode-dashboard-mode)
              (setq-local kmode-dashboard-root root)
              (setq-local kmode-dashboard-origin origin)
              (setq-local kmode-root-override root)
              (setq default-directory root)
              (let ((context (kmode--dashboard-context)))
                (should (equal (kmode-context-profile context)
                               "origin-profile"))
                (should (equal (kmode-context-output context) output)))
              (cl-letf (((symbol-function 'kmode--git-string)
                         (lambda (&rest _arguments) "")))
                (kmode-dashboard-refresh))
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (should (string-match-p "origin-profile" text))
                (should (string-match-p
                         (regexp-quote (abbreviate-file-name output)) text)))
              (goto-char (point-min))
              (search-forward "Origin-only action")
              (should (button-at (1- (point))))))
        (when (buffer-live-p dashboard)
          (kill-buffer dashboard))
        (when (buffer-live-p origin)
          (kill-buffer origin))))))

(ert-deftest kmode-test/dashboard-launches-from-outside-with-selected-root ()
  (unless (and (featurep 'kmode-ui) (featurep 'kmode-emacs))
    (ert-skip "kmode dashboard integration is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (outside (make-temp-file "kmode-dashboard-outside-" t))
           (origin (generate-new-buffer " *kmode-dashboard-outside-origin*"))
           (kmode--last-root nil)
           displayed
           refreshed)
      (unwind-protect
          (progn
            (with-current-buffer origin
              (setq default-directory (file-name-as-directory outside))
              (cl-letf (((symbol-function 'read-directory-name)
                         (lambda (&rest _arguments)
                           (expand-file-name "drivers/net" root)))
                        ((symbol-function 'kmode-dashboard-refresh)
                         (lambda () (setq refreshed t)))
                        ((symbol-function 'pop-to-buffer)
                         (lambda (buffer-or-name &rest _arguments)
                           (setq displayed (get-buffer buffer-or-name)))))
                (kmode-dashboard))
              (should (equal default-directory
                             (file-name-as-directory outside)))
              (should-not (local-variable-p 'kmode-root-override origin))
              (should-not (bound-and-true-p kmode-mode)))
            (should refreshed)
            (should (buffer-live-p displayed))
            (with-current-buffer displayed
              (should (derived-mode-p 'kmode-dashboard-mode))
              (should (equal kmode-dashboard-root root))
              (should (eq kmode-dashboard-origin origin))
              (should (equal kmode-root-override root))
              (should (equal default-directory root)))
            (should (equal kmode--last-root root)))
        (when (buffer-live-p displayed)
          (kill-buffer displayed))
        (when (buffer-live-p origin)
          (kill-buffer origin))
        (delete-directory outside t)))))

(ert-deftest kmode-test/impact-button-rejects-context-drift ()
  (unless (featurep 'kmode-impact)
    (ert-skip "kmode-impact.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (origin (generate-new-buffer " *kmode-impact-origin*"))
           (report (generate-new-buffer " *kmode-impact-report*"))
           expected
           button
           ran)
      (unwind-protect
          (progn
            (with-current-buffer origin
              (setq default-directory root)
              (setq expected (kmode-resolve-context root)))
            (with-current-buffer report
              (setq-local kmode-impact-root root)
              (setq-local kmode-impact-origin origin)
              (setq-local kmode-impact-context expected)
              (insert-text-button
               "run"
               'kmode-impact-function (lambda () (setq ran t))
               'kmode-impact-arguments nil
               'action #'ignore)
              (setq button (button-at (point-min)))
              (kmode-impact--run-button button))
            (should ran)
            (setq ran nil)
            (with-current-buffer origin
              (setq-local kmode-output-directory
                          (expand-file-name "changed-output" root)))
            (with-current-buffer report
              (should-error (kmode-impact--run-button button)
                            :type 'user-error))
            (should-not ran))
        (when (buffer-live-p report)
          (kill-buffer report))
        (when (buffer-live-p origin)
          (kill-buffer origin))))))

(ert-deftest kmode-test/mode-refuses-non-kernel-buffers-cleanly ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (let* ((outside (make-temp-file "kmode-outside-" t))
         (kmode--root-cache (make-hash-table :test #'equal))
         (kmode-set-compile-command nil))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory (file-name-as-directory outside))
          (should-error (kmode-mode 1) :type 'user-error)
          (should-not kmode-mode)
          (should-not kmode--saved-locals))
      (delete-directory outside t))))

(ert-deftest kmode-test/global-mode-exposes-prefix-outside-kernel-trees ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (let ((outside (make-temp-file "kmode-global-outside-" t))
        (global-map (copy-keymap global-map))
        (was-enabled (bound-and-true-p kmode-global-mode))
        (kmode-set-compile-command nil)
        (kmode-apply-kernel-c-style nil))
    (unwind-protect
        (progn
          (kmode-global-mode -1)
          (define-key global-map (kbd "C-c k") nil)
          (with-temp-buffer
            (setq default-directory (file-name-as-directory outside)
                  buffer-file-name (expand-file-name "notes.c" outside))
            (kmode-global-mode 1)
            (should kmode-global-mode)
            (should-not (bound-and-true-p kmode-mode))
            (should (eq (lookup-key kmode-global-mode-map (kbd "C-c k"))
                        kmode-command-map))
            (should (eq (key-binding (kbd "C-c k k"))
                        'kmode-dashboard))
            (should (eq (key-binding (kbd "C-c k n d"))
                        'kmode-find-definition))
            (kmode-global-mode -1)
            (should-not kmode-global-mode)
            (should-not (key-binding (kbd "C-c k k")))))
      (kmode-global-mode -1)
      (when was-enabled
        (kmode-global-mode 1))
      (delete-directory outside t))))

(ert-deftest kmode-test/global-mode-disable-cleans-up-buffer-local-mode ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((source (expand-file-name "drivers/net/kmode_dummy.c" root))
          (global-map (copy-keymap global-map))
          (was-enabled (bound-and-true-p kmode-global-mode))
          (kmode-set-compile-command nil)
          (kmode-apply-kernel-c-style nil)
          buffer)
      (unwind-protect
          (progn
            (kmode-global-mode -1)
            (define-key global-map (kbd "C-c k") nil)
            (setq buffer (find-file-noselect source))
            (with-current-buffer buffer
              (should-not (bound-and-true-p kmode-mode)))
            (kmode-global-mode 1)
            (with-current-buffer buffer
              (should (bound-and-true-p kmode-mode))
              (should (eq (key-binding (kbd "C-c k k"))
                          'kmode-dashboard)))
            (kmode-global-mode -1)
            (with-current-buffer buffer
              (should-not (bound-and-true-p kmode-mode))
              (should-not (key-binding (kbd "C-c k k")))))
        (kmode-global-mode -1)
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when was-enabled
          (kmode-global-mode 1))))))

(ert-deftest kmode-test/global-mode-does-not-clobber-global-prefix ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (let* ((outside (make-temp-file "kmode-global-binding-" t))
         (global-map (copy-keymap global-map))
         (foreign-map (let ((map (make-sparse-keymap)))
                        (define-key map (kbd "x") #'ignore)
                        map))
         (was-enabled (bound-and-true-p kmode-global-mode))
         (kmode-set-compile-command nil)
         (kmode-apply-kernel-c-style nil))
    (unwind-protect
        (progn
          (kmode-global-mode -1)
          (define-key global-map (kbd "C-c k") foreign-map)
          (with-temp-buffer
            (setq default-directory (file-name-as-directory outside))
            (kmode-global-mode 1)
            (should (eq (lookup-key global-map (kbd "C-c k")) foreign-map))
            (should (eq (key-binding (kbd "C-c k k"))
                        'kmode-dashboard))
            (kmode-global-mode -1)
            (should (eq (lookup-key global-map (kbd "C-c k")) foreign-map))
            (should (eq (key-binding (kbd "C-c k x")) 'ignore))
            (should-not (key-binding (kbd "C-c k k")))))
      (kmode-global-mode -1)
      (when was-enabled
        (kmode-global-mode 1))
      (delete-directory outside t))))

(ert-deftest kmode-test/mode-restores-c-buffer-style-on-disable ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((kmode-set-compile-command nil)
          (kmode-apply-kernel-c-style t))
      (with-temp-buffer
        (c-mode)
        (setq default-directory (file-name-as-directory
                                 (expand-file-name "drivers/net" root)))
        (setq-local indent-tabs-mode nil)
        (setq-local tab-width 3)
        (setq-local c-basic-offset 2)
        (kmode-mode 1)
        (should kmode-mode)
        (should indent-tabs-mode)
        (should (= tab-width 8))
        (should (= c-basic-offset 8))
        (kmode-mode -1)
        (should-not kmode-mode)
        (should-not indent-tabs-mode)
        (should (= tab-width 3))
        (should (= c-basic-offset 2))))))

(ert-deftest kmode-test/mode-restores-existing-compile-command ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((kmode-set-compile-command t)
          (kmode-apply-kernel-c-style nil))
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root))
        (setq-local compile-command "make previous")
        (cl-letf (((symbol-function 'kmode-refresh-compile-command)
                   (lambda (&optional _context)
                     (setq-local compile-command "make kmode"))))
          (kmode-mode 1)
          (should (equal compile-command "make kmode"))
          (kmode-mode -1))
        (should (equal compile-command "make previous"))))))

(ert-deftest kmode-test/project-finder-returns-project-protocol-value ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((project (kmode-project-find
                    (expand-file-name "drivers/net" root))))
      (should (eq (car project) 'kmode))
      (should (equal (project-root project)
                     (file-name-as-directory root))))))

(ert-deftest kmode-test/build-environment-removes-checkout-path-shadow ()
  (unless (featurep 'kmode-build)
    (ert-skip "kmode-build.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((checkout-bin (file-name-as-directory
                          (expand-file-name "tools/bin" root)))
           (outside-bin (file-name-as-directory
                         (make-temp-file "kmode-safe-path-" t)))
           (separator (if (characterp path-separator)
                          (char-to-string path-separator)
                        path-separator))
           (context (kmode-resolve-context root))
           (kmode-build-trusted-path-directories nil)
           (process-environment
            (list
             (concat "PATH="
                     (string-join
                      (list "" "." (directory-file-name checkout-bin)
                            (directory-file-name outside-bin))
                      separator))
             "KMODE_TEST_KEEP=present")))
      (make-directory checkout-bin t)
      (kmode-test--write-file checkout-bin "rg" "#!/bin/sh\nexit 99\n" #o755)
      (kmode-test--write-file outside-bin "rg" "#!/bin/sh\nexit 0\n" #o755)
      (unwind-protect
          (let ((clean (kmode-build-process-environment context)))
            (let ((process-environment clean))
              (should
               (equal (split-string (getenv "PATH")
                                    (regexp-quote separator) t)
                      (list (directory-file-name outside-bin))))
              (should (equal (getenv "KMODE_TEST_KEEP") "present"))))
        (delete-directory outside-bin t)))))

(ert-deftest kmode-test/navigation-resolves-rg-through-safe-tool-path ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "kmode-navigate.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let (resolved invocation)
      (cl-letf (((symbol-function 'kmode-tool-path)
                 (lambda (tool context)
                   (setq resolved (list tool context))
                   "/trusted/bin/rg"))
                ((symbol-function 'process-file)
                 (lambda (program infile destination display &rest arguments)
                   (setq invocation
                         (list program infile destination display arguments))
                   (insert "drivers/net/kmode_dummy.c:7:needle here\n")
                   0)))
        (should
         (equal
          (kmode--search-lines-with-rg "needle" '("*.c") root)
          (list (list (expand-file-name "drivers/net/kmode_dummy.c" root)
                      7 "needle here")))))
      (should (equal (car resolved) "rg"))
      (should
       (equal (kmode-context-root (cadr resolved))
              (file-name-as-directory root)))
      (should
       (equal invocation
              (list "/trusted/bin/rg" nil t nil
                    '("--line-number" "--no-heading" "--color" "never"
                      "--glob" "*.c" "--" "needle" ".")))))))

(ert-deftest kmode-test/bare-tools-cannot-be-shadowed-by-the-kernel-tree ()
  (kmode-test-with-kernel-tree (root)
    (let* ((name "kmode-tree-shadow-candidate-71b2")
           (shadow (kmode-test--write-file
                    root name "#!/bin/sh\nexit 0\n" #o755))
           (context (kmode-resolve-context root))
           (path-only-directory (make-temp-file "kmode-exec-path-" t))
           (exec-path (list path-only-directory)))
      (unwind-protect
          (progn
            (should-not (kmode-tool-path name context))
            (should (equal (kmode-tool-path (concat "./" name) context)
                           shadow)))
        (delete-directory path-only-directory t)))))

(ert-deftest kmode-test/resource-locks-find-orphaned-cross-profile-processes ()
  (kmode-test-with-kernel-tree (root)
    (let* ((resource (file-name-as-directory
                      (expand-file-name "build-output" root)))
           (buffer (generate-new-buffer " *kmode-resource-owner*"))
           (process (make-pipe-process
                     :name (generate-new-buffer-name "kmode-resource-owner")
                     :buffer buffer
                     :noquery t))
           (context (kmode--make-context
                     :root (file-name-as-directory root)
                     :profile "default"
                     :output resource
                     :compiler 'auto))
           (kmode-test--enable-subr-trampolines nil)
           interrupted)
      (make-directory resource t)
      (unwind-protect
          (progn
            (kmode-mark-process-context
             buffer (file-name-as-directory root) "other-profile")
            (kmode-mark-process-resource buffer resource)
            ;; Simulate killing a process buffer without killing its child.
            (set-process-buffer process nil)
            (kill-buffer buffer)
            (should-not (memq process (kmode-running-processes context)))
            (should (memq process (kmode-running-processes context t)))
            (should (eq process
                        (kmode-resource-process
                         (expand-file-name "../build-output" resource))))
            (should-error (kmode-assert-resource-available resource)
                          :type 'user-error)
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt collection &rest _arguments)
                         (caar collection)))
                      ((symbol-function 'interrupt-process)
                       (lambda (candidate &rest _arguments)
                         (setq interrupted candidate))))
              (with-temp-buffer
                (setq default-directory (file-name-as-directory root))
                (call-interactively #'kmode-cancel-job)))
            (should (eq interrupted process)))
        (when (process-live-p process)
          (delete-process process))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest kmode-test/build-environment-removes-ambient-selectors ()
  (unless (featurep 'kmode-build)
    (ert-skip "kmode-build.el is not present"))
  (let* ((selectors kmode-build-sanitized-environment-variables)
         (process-environment
          (append (mapcar (lambda (name) (concat name "=host-value"))
                          selectors)
                  '("KMODE_TEST_KEEP=present")))
         (clean (kmode-build-process-environment)))
    (let ((process-environment clean))
      (dolist (name selectors)
        (should-not (getenv name)))
      (should (equal (getenv "KMODE_TEST_KEEP") "present")))
    ;; Constructing the sanitized copy must not mutate the caller's binding.
    (should (equal (getenv "ARCH") "host-value"))))

(ert-deftest kmode-test/build-start-uses-the-sanitized-environment ()
  (unless (featurep 'kmode-build)
    (ert-skip "kmode-build.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((context (kmode--make-context
                     :root (file-name-as-directory root)
                     :profile "default"
                     :output (file-name-as-directory root)
                     :compiler 'auto))
           (process-environment
            '("ARCH=host-arch" "KBUILD_OUTPUT=/host/output"
              "KMODE_TEST_KEEP=present"))
           observed)
      (cl-letf (((symbol-function 'kmode-require-tool)
                 (lambda (&rest _arguments) "/usr/bin/make"))
                ((symbol-function 'kmode-refresh-compile-command)
                 (lambda (&optional _context) "make"))
                ((symbol-function 'kmode-start-command)
                 (lambda (&rest _arguments)
                   (setq observed (copy-sequence process-environment))
                   'kmode-test-build-buffer)))
        (should (eq (kmode-build--start "build" nil nil nil context)
                    'kmode-test-build-buffer)))
      (let ((process-environment observed))
        (should-not (getenv "ARCH"))
        (should-not (getenv "KBUILD_OUTPUT"))
        (should (equal (getenv "KMODE_TEST_KEEP") "present"))))))

(ert-deftest kmode-test/kunit-directories-are-isolated-and-hash-distinct ()
  (unless (featurep 'kmode-test)
    (ert-skip "kmode-test.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((output (file-name-as-directory (expand-file-name "output" root)))
           (kmode-kunit-build-directory nil)
           (default-context
            (kmode--make-context
             :root (file-name-as-directory root) :profile "default"
             :output output :compiler 'auto))
           (slash-context
            (kmode--make-context
             :root (file-name-as-directory root) :profile "topic/a"
             :output output :compiler 'auto))
           (space-context
            (kmode--make-context
             :root (file-name-as-directory root) :profile "topic a"
             :output output :compiler 'auto))
           (default-dir (kmode-kunit-resolve-build-directory
                         default-context))
           (slash-dir (kmode-kunit-resolve-build-directory slash-context))
           (space-dir (kmode-kunit-resolve-build-directory space-context)))
      (dolist (directory (list default-dir slash-dir space-dir))
        (should (string-prefix-p output directory))
        (should-not (equal (directory-file-name output)
                           (directory-file-name directory))))
      (should (equal (file-name-nondirectory
                      (directory-file-name default-dir))
                     ".kunit"))
      ;; Both names slug to "topic-a"; the profile hash must disambiguate them.
      (should-not (equal slash-dir space-dir))
      (should (string-match-p
               "\\.kunit-topic-a-[[:xdigit:]]\\{6\\}/\\'" slash-dir))
      (should (string-match-p
               "\\.kunit-topic-a-[[:xdigit:]]\\{6\\}/\\'" space-dir)))))

(ert-deftest kmode-test/kunit-filter-cannot-be-an-option ()
  (unless (featurep 'kmode-test)
    (ert-skip "kmode-test.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((context (kmode--make-context
                    :root (file-name-as-directory root)
                    :profile "default"
                    :output (file-name-as-directory root)
                    :compiler 'auto)))
      (dolist (filter '("--help" "-x" "suite\n--jobs=99"))
        (should-error (kmode-kunit-arguments 'run context filter)
                      :type 'user-error))
      (should (member "suite.case*"
                      (kmode-kunit-arguments
                       'run context "suite.case*"))))))

(ert-deftest kmode-test/kselftest-collections-parse-plus-equals ()
  (unless (featurep 'kmode-test)
    (ert-skip "kmode-test.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (kmode-test--write-file
     root "tools/testing/selftests/Makefile"
     (concat "TARGETS += net\n"
             "TARGETS = timers\n"
             "  TARGETS   +=   pidfd io_uring # supported subsets\n"
             "NOT_TARGETS += ignored\n"))
    (let ((context (kmode-resolve-context root)))
      (should (equal (kmode-kselftest-collections context)
                     '("io_uring" "net" "pidfd" "timers"))))))

(ert-deftest kmode-test/sparse-nil-level-uses-customized-default ()
  (unless (featurep 'kmode-build)
    (ert-skip "kmode-build.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (ignore root)
    (let ((kmode-build-sparse-level 2)
          (kmode-build-default-target nil)
          observed)
      (cl-letf (((symbol-function 'kmode-require-tool)
                 (lambda (&rest _arguments) "/usr/bin/sparse"))
                ((symbol-function 'kmode-build--start)
                 (lambda (label targets &optional arguments mode context)
                   (setq observed
                         (list label targets arguments mode context)))))
        (kmode-build-sparse nil))
      (should (equal observed '("sparse" nil ("C=2") nil nil))))))

(ert-deftest kmode-test/review-ranges-reject-options-and-whitespace ()
  (unless (featurep 'kmode-review)
    (ert-skip "kmode-review.el is not present"))
  (dolist (range '("" "--cached" "HEAD main" "HEAD\nmain"))
    (should-error (kmode-review--validate-range range) :type 'user-error))
  (should (equal (kmode-review--validate-range "v6.10..HEAD")
                 "v6.10..HEAD")))

(ert-deftest kmode-test/git-diff-failure-cleans-temporary-patch ()
  (unless (featurep 'kmode-review)
    (ert-skip "kmode-review.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (ignore root)
    (let ((real-make-temp-file (symbol-function 'make-temp-file))
          temporary)
      (cl-letf (((symbol-function 'make-temp-file)
                 (lambda (&rest arguments)
                   (setq temporary
                         (apply real-make-temp-file arguments))))
                ((symbol-function 'kmode--git-path)
                 (lambda (&optional _context) "/usr/bin/git"))
                ((symbol-function 'process-file)
                 (lambda (&rest _arguments) 128)))
        (should-error (kmode--write-git-diff '("--cached" "--binary"))
                      :type 'user-error))
      (should temporary)
      (should-not (file-exists-p temporary)))))

(ert-deftest kmode-test/flymake-snapshot-widens-a-narrowed-buffer ()
  (unless (featurep 'kmode-flymake)
    (ert-skip "kmode-flymake.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((tool (expand-file-name "scripts/checkpatch.pl" root))
           (process (make-pipe-process
                     :name (generate-new-buffer-name "kmode-flymake-wide")
                     :noquery t))
           temporary
           (full-text "first line\nvisible line\nlast line\n")
           (kmode-test--enable-subr-trampolines nil))
      (set-file-modes tool #o755)
      (unwind-protect
          (with-temp-buffer
            (setq default-directory (file-name-as-directory root)
                  buffer-file-name
                  (expand-file-name "drivers/net/kmode_dummy.c" root))
            (insert full-text)
            (goto-char (point-min))
            (forward-line 1)
            (let ((begin (point)))
              (forward-line 1)
              (narrow-to-region begin (point)))
            (unwind-protect
                (progn
                  (cl-letf (((symbol-function 'make-process)
                             (lambda (&rest properties)
                               (setq temporary
                                     (car (last
                                           (plist-get properties :command))))
                               process)))
                    (kmode-checkpatch-flymake
                     (lambda (&rest _arguments) nil)))
                  (should (buffer-narrowed-p))
                  (should
                   (equal (with-temp-buffer
                            (insert-file-contents-literally temporary)
                            (buffer-string))
                          full-text)))
              (kmode-checkpatch-flymake--cancel)))
        (when (process-live-p process)
          (delete-process process))
        (when (and temporary (file-exists-p temporary))
          (delete-file temporary))))))

(ert-deftest kmode-test/start-command-seeds-pinned-context-on-reused-buffer ()
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory (expand-file-name "new-output" root)))
           (old-output
            (file-name-as-directory (expand-file-name "old-output" root)))
           (context (kmode--make-context
                     :root root :profile "pinned" :output output
                     :compiler 'auto))
           (buffer-name
            (format "*kmode:%s:pinned:reuse*" (kmode-root-id root)))
           (buffer (get-buffer-create buffer-name))
           observed)
      (make-directory output t)
      (make-directory old-output t)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (setq-local kmode-process-root "/stale/root/")
              (setq-local kmode-process-profile "stale")
              (setq-local kmode-process-resource old-output))
            (cl-letf (((symbol-function 'compilation-start)
                       (lambda (command mode name-function)
                         (setq observed
                               (list command mode
                                     (funcall name-function mode)
                                     default-directory))
                         (with-current-buffer buffer
                           (should (equal kmode-process-root root))
                           (should (equal kmode-process-profile "pinned"))
                           (should
                            (equal kmode-process-resource
                                   (kmode-process-resource-key output))))
                         buffer)))
              (should
               (eq (kmode-start-shell-command
                    "reuse" "echo pinned" root nil output context)
                   buffer)))
            (should (equal observed
                           (list "echo pinned" 'kmode-compilation-mode
                                 buffer-name root))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest kmode-test/kernel-c-style-installs-offsets-and-restores-state ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((kmode-set-compile-command nil)
          (kmode-auto-activate-tags nil)
          (kmode-apply-kernel-c-style t)
          (kmode-kernel-fill-column 88)
          (kmode-show-trailing-whitespace t)
          (kmode-require-final-newline t))
      (with-temp-buffer
        (c-mode)
        (setq default-directory
              (file-name-as-directory (expand-file-name "drivers/net" root)))
        (setq-local indent-tabs-mode nil)
        (setq-local tab-width 3)
        (setq-local c-basic-offset 2)
        (setq-local c-label-minimum-indentation 4)
        (setq-local fill-column 72)
        (setq-local show-trailing-whitespace nil)
        (setq-local require-final-newline nil)
        (c-set-offset 'arglist-close '+)
        (c-set-offset 'arglist-cont-nonempty '++)
        (let ((original-offsets (copy-tree c-offsets-alist)))
          (kmode-mode 1)
          (should
           (eq (cdr (assq 'arglist-close c-offsets-alist))
               'kmode--c-lineup-arglist-tabs-only))
          (should
           (equal (cdr (assq 'arglist-cont-nonempty c-offsets-alist))
                  '(c-lineup-gcc-asm-reg
                    kmode--c-lineup-arglist-tabs-only)))
          (should indent-tabs-mode)
          (should (= tab-width 8))
          (should (= c-basic-offset 8))
          (should (= c-label-minimum-indentation 0))
          (should (= fill-column 88))
          (should show-trailing-whitespace)
          (should require-final-newline)
          (kmode-mode -1)
          (should (equal c-offsets-alist original-offsets)))
        (should-not indent-tabs-mode)
        (should (= tab-width 3))
        (should (= c-basic-offset 2))
        (should (= c-label-minimum-indentation 4))
        (should (= fill-column 72))
        (should-not show-trailing-whitespace)
        (should-not require-final-newline)))))

(ert-deftest kmode-test/profile-output-tags-activate-locally-and-restore ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((output (file-name-as-directory
                    (expand-file-name "profile-output" root)))
           (table (kmode-test--write-file output "TAGS"))
           (kmode-set-compile-command nil)
           (kmode-apply-kernel-c-style nil)
           (kmode-auto-activate-tags t))
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root))
        (setq-local kmode-output-directory output)
        (setq-local tags-file-name "/user/existing/TAGS")
        (setq-local tags-table-list '("/user/one" "/user/two"))
        (kmode-mode 1)
        (should (equal tags-file-name table))
        (should-not tags-table-list)
        (kmode-mode -1)
        (should (equal tags-file-name "/user/existing/TAGS"))
        (should (equal tags-table-list '("/user/one" "/user/two")))))))

(ert-deftest kmode-test/index-build-commands-check-tools-and-delegate-exactly ()
  (unless (featurep 'kmode-build)
    (ert-skip "kmode-build.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((context (kmode--make-context
                    :root (file-name-as-directory root)
                    :profile "index"
                    :output (file-name-as-directory root)
                    :compiler 'auto))
          required
          started)
      (cl-letf (((symbol-function 'kmode-resolve-context)
                 (lambda (&optional _root) context))
                ((symbol-function 'kmode-require-tool)
                 (lambda (tool observed-context)
                   (push (list tool observed-context) required)
                   (concat "/host/bin/" tool)))
                ((symbol-function 'kmode-build--start)
                 (lambda (&rest arguments)
                   (push arguments started)
                   'index-build)))
        (should (eq (kmode-build-tags) 'index-build))
        (should (equal (car started)
                       (list "tags" '("TAGS") nil nil context
                             #'kmode-build--tags-finished)))
        (should (equal (car required) (list "etags" context)))
        (setq required nil started nil)
        (should (eq (kmode-build-cscope) 'index-build))
        (should (equal (car started)
                       (list "cscope" '("cscope") nil nil context
                             #'kmode-build--cscope-finished)))
        (should (equal (car required) (list "cscope" context)))))))

(ert-deftest kmode-test/index-build-commands-stop-when-tools-are-missing ()
  (unless (featurep 'kmode-build)
    (ert-skip "kmode-build.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((context (kmode--make-context
                    :root (file-name-as-directory root)
                    :profile "index"
                    :output (file-name-as-directory root)
                    :compiler 'auto))
          started)
      (cl-letf (((symbol-function 'kmode-resolve-context)
                 (lambda (&optional _root) context))
                ((symbol-function 'kmode-require-tool)
                 (lambda (tool _context)
                   (user-error "missing %s" tool)))
                ((symbol-function 'kmode-build--start)
                 (lambda (&rest _arguments) (setq started t))))
        (should-error (kmode-build-tags) :type 'user-error)
        (should-not started)
        (should-error (kmode-build-cscope) :type 'user-error)
        (should-not started)))))

(ert-deftest kmode-test/build-start-forwards-finish-callback ()
  (unless (featurep 'kmode-build)
    (ert-skip "kmode-build.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory (expand-file-name "output" root)))
           (context (kmode--make-context
                     :root root :profile "index" :output output
                     :compiler 'auto))
           (finish (lambda (_buffer _status) 'finished))
           observed)
      (make-directory output t)
      (cl-letf (((symbol-function 'kmode-require-tool)
                 (lambda (_tool _context) "/host/bin/make"))
                ((symbol-function 'kmode-refresh-compile-command)
                 (lambda (&optional _context) "make"))
                ((symbol-function 'kmode-build-process-environment)
                 (lambda (&optional _context) process-environment))
                ((symbol-function 'kmode-start-command)
                 (lambda (&rest arguments)
                   (setq observed arguments)
                   'build-buffer)))
        (should (eq (kmode-build--start
                     "tags" '("TAGS") nil nil context finish)
                    'build-buffer)))
      (should
       (equal observed
              (list "tags" "/host/bin/make"
                    (list (concat "O=" (directory-file-name output)) "TAGS")
                    root nil output context finish finish))))))

(ert-deftest kmode-test/index-finish-callbacks-require-readable-artifacts ()
  (unless (featurep 'kmode-build)
    (ert-skip "kmode-build.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "index-output" root)))
           (buffer (generate-new-buffer " *kmode-index-finish*"))
           messages)
      (make-directory output t)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (setq-local kmode-process-root root)
              (setq-local kmode-process-resource
                          (kmode-process-resource-key output)))
            (cl-letf (((symbol-function 'kmode-compilation-succeeded-p)
                       (lambda (_buffer) t))
                      ((symbol-function 'kmode-refresh-project-buffers)
                       #'ignore)
                      ((symbol-function 'kmode--refresh-tags-file-buffer)
                       #'ignore)
                      ((symbol-function 'message)
                       (lambda (format-string &rest arguments)
                         (push (apply #'format format-string arguments)
                               messages))))
              (kmode-build--tags-finished buffer "finished\n")
              (kmode-build--cscope-finished buffer "finished\n")
              (should-not
               (seq-some (lambda (text)
                           (string-match-p "index is ready\\|database is ready"
                                           text))
                         messages))
              (should
               (seq-some (lambda (text)
                           (string-match-p "no readable index exists" text))
                         messages))
              (let ((stale (kmode-test--write-file output "cscope.out" "old")))
                (set-file-times stale (seconds-to-time 1)))
              (kmode-test--write-file output "cscope.files" "-k\n-q\n")
              (kmode-build--cscope-finished buffer "finished\n")
              (should-not
               (seq-some (lambda (text)
                           (string-match-p "cscope database is ready" text))
                         messages))
              (setq messages nil)
              (kmode-test--write-file output "TAGS")
              (kmode-test--write-file output "cscope.out" "current")
              (kmode-build--tags-finished buffer "finished\n")
              (kmode-build--cscope-finished buffer "finished\n")
              (should
               (seq-some (lambda (text)
                           (string-match-p "TAGS index is ready" text))
                         messages))
              (should
               (seq-some (lambda (text)
                           (string-match-p "cscope database is ready" text))
                         messages))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest kmode-test/tags-failed-finish-does-not-publish-partial-table ()
  (unless (featurep 'kmode-build)
    (ert-skip "TAGS integration is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "tags-output" root)))
           (table (kmode-test--write-file output "TAGS" "partial\n"))
           (buffer (generate-new-buffer " *kmode-tags-failed-build*"))
           (file-refreshes 0)
           (project-refreshes 0))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (setq-local kmode-process-root root)
              (setq-local kmode-process-resource
                          (kmode-process-resource-key output)))
            (cl-letf (((symbol-function 'kmode-compilation-succeeded-p)
                       (lambda (_buffer) nil))
                      ((symbol-function 'kmode--refresh-tags-file-buffer)
                       (lambda (_file) (cl-incf file-refreshes)))
                      ((symbol-function 'kmode-refresh-project-buffers)
                       (lambda (_root) (cl-incf project-refreshes))))
              ;; A readable artifact from a failed build may be truncated.
              (kmode-build--tags-finished buffer "exited abnormally\n")
              (should (zerop file-refreshes))
              (should (zerop project-refreshes))
              ;; Once it disappears, active bindings must be invalidated.
              (delete-file table)
              (kmode-build--tags-finished buffer "exited abnormally\n")
              (should (= file-refreshes 1))
              (should (= project-refreshes 1))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest kmode-test/tags-failed-finish-clears-disappeared-bindings ()
  (unless (and (featurep 'kmode-build) (featurep 'kmode-emacs))
    (ert-skip "TAGS integration is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "tags-output" root)))
           (table (kmode-test--write-file output "TAGS"))
           (source (generate-new-buffer " *kmode-tags-source*"))
           (build (generate-new-buffer " *kmode-tags-build*"))
           (kmode-set-compile-command nil)
           (kmode-apply-kernel-c-style nil)
           (kmode-auto-activate-tags t))
      (unwind-protect
          (progn
            (with-current-buffer source
              (setq default-directory root)
              (setq-local kmode-output-directory output)
              (setq-local tags-file-name nil)
              (setq-local tags-table-list nil)
              (kmode-mode 1)
              (should (equal tags-file-name table))
              (setq-local tags-completion-table '(stale-profile-cache)))
            (delete-file table)
            (with-current-buffer build
              (setq-local kmode-process-root root)
              (setq-local kmode-process-resource
                          (kmode-process-resource-key output)))
            (cl-letf (((symbol-function 'kmode-compilation-succeeded-p)
                       (lambda (_buffer) nil)))
              (kmode-build--tags-finished build "exited abnormally\n"))
            (with-current-buffer source
              (should-not tags-file-name)
              (should-not tags-table-list)
              (should-not tags-completion-table)))
        (when (buffer-live-p source)
          (with-current-buffer source
            (when (bound-and-true-p kmode-mode)
              (kmode-mode -1)))
          (kill-buffer source))
        (when (buffer-live-p build)
          (kill-buffer build))))))

(ert-deftest kmode-test/profile-switch-resets-etags-completion-cache ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "kmode-emacs.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output-a (file-name-as-directory (expand-file-name "index-a" root)))
           (output-b (file-name-as-directory (expand-file-name "index-b" root)))
           (table-a (kmode-test--write-file output-a "TAGS"))
           (table-b (kmode-test--write-file output-b "TAGS"))
           (kmode-profiles
            `(("a" :compiler auto :output ,output-a)
              ("b" :compiler auto :output ,output-b)))
           (kmode-set-compile-command nil)
           (kmode-apply-kernel-c-style nil)
           (kmode-auto-activate-tags t))
      (with-temp-buffer
        (setq default-directory root)
        (setq-local kmode-profile "a")
        (setq-local tags-file-name "/user/original/TAGS")
        (setq-local tags-table-list '("/user/original"))
        (setq-local tags-completion-table '(user-cache))
        (setq-local tags-table-computed-list '(user-computed))
        (setq-local tags-table-computed-list-for '(user-for))
        (setq-local tags-table-list-pointer '(user-pointer))
        (setq-local tags-table-list-started-at '(user-start))
        (setq-local tags-table-set-list '((user-set)))
        (kmode-mode 1)
        (should (equal tags-file-name table-a))
        (should-not tags-completion-table)
        (should-not tags-table-computed-list)
        (should-not tags-table-computed-list-for)
        (should-not tags-table-list-pointer)
        (should-not tags-table-list-started-at)
        (should-not tags-table-set-list)
        (setq-local tags-completion-table '(profile-a-cache))
        (setq-local tags-table-computed-list '(profile-a-computed))
        (setq-local tags-table-set-list '((profile-a-set)))
        (setq-local kmode-profile "b")
        (kmode-refresh-tags-table)
        (should (equal tags-file-name table-b))
        (should-not tags-completion-table)
        (should-not tags-table-computed-list)
        (should-not tags-table-set-list)
        (kmode-mode -1)
        (should (equal tags-file-name "/user/original/TAGS"))
        (should (equal tags-table-list '("/user/original")))
        (should (equal tags-completion-table '(user-cache)))
        (should (equal tags-table-computed-list '(user-computed)))
        (should (equal tags-table-computed-list-for '(user-for)))
        (should (equal tags-table-list-pointer '(user-pointer)))
        (should (equal tags-table-list-started-at '(user-start)))
        (should (equal tags-table-set-list '((user-set))))))))

(ert-deftest kmode-test/tags-state-restores-identity-and-topology ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "TAGS integration is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "tags-output" root)))
           (_table (kmode-test--write-file output "TAGS"))
           (user-table-list (list "/user/one/TAGS" "/user/two/TAGS"))
           (user-computed-list (list "/user/one/TAGS" "/user/two/TAGS"))
           (user-pointer (cdr user-computed-list))
           (user-set-list (list user-table-list user-computed-list))
           (user-completion (list 'user-cache))
           (kmode-set-compile-command nil)
           (kmode-apply-kernel-c-style nil)
           (kmode-auto-activate-tags t))
      (with-temp-buffer
        (setq default-directory root)
        (setq-local kmode-output-directory output)
        (setq-local tags-file-name (car user-table-list))
        (setq-local tags-table-list user-table-list)
        (setq-local tags-completion-table user-completion)
        (setq-local tags-table-computed-list user-computed-list)
        (setq-local tags-table-computed-list-for user-table-list)
        (setq-local tags-table-list-pointer user-pointer)
        (setq-local tags-table-list-started-at user-pointer)
        (setq-local tags-table-set-list user-set-list)
        (kmode-mode 1)
        (kmode-mode -1)
        (should (eq tags-file-name (car user-table-list)))
        (should (eq tags-table-list user-table-list))
        (should (eq tags-completion-table user-completion))
        (should (eq tags-table-computed-list user-computed-list))
        (should (eq tags-table-computed-list-for user-table-list))
        (should (eq tags-table-list-pointer user-pointer))
        (should (eq tags-table-list-started-at user-pointer))
        (should (eq tags-table-list-pointer tags-table-list-started-at))
        (should (eq tags-table-set-list user-set-list))
        (should (eq (car tags-table-set-list) tags-table-list))
        (should (eq (cadr tags-table-set-list)
                    tags-table-computed-list))))))

(ert-deftest kmode-test/tags-file-buffer-refresh-preserves-user-edits ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "TAGS integration is not present"))
  (let* ((directory (make-temp-file "kmode-tags-buffer-" t))
         (file (kmode-test--write-file directory "TAGS" "old\n"))
         (buffer (find-file-noselect file)))
    (unwind-protect
        (progn
          (kmode-test--write-file directory "TAGS" "new contents\n")
          (kmode--refresh-tags-file-buffer file)
          (with-current-buffer buffer
            (should (equal (buffer-string) "new contents\n"))
            (goto-char (point-max))
            (insert "user edit\n"))
          (kmode-test--write-file directory "TAGS" "disk changed again\n")
          (kmode--refresh-tags-file-buffer file)
          (should (buffer-live-p buffer))
          (with-current-buffer buffer
            (should (string-suffix-p "user edit\n" (buffer-string)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest kmode-test/tags-file-buffer-refresh-reinitializes-caches ()
  (unless (featurep 'kmode-emacs)
    (ert-skip "TAGS integration is not present"))
  (let* ((directory (make-temp-file "kmode-tags-cache-" t))
         (file (kmode-test--write-file
                directory "TAGS" "\f\nold.c,0\n"))
         (buffer (find-file-noselect file)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (require 'etags)
            (tags-table-mode)
            (setq-local tags-table-files '(stale-file))
            (setq-local tags-completion-table '(stale-completion))
            (setq-local tags-included-tables '(stale-include)))
          (kmode-test--write-file
           directory "TAGS" "\f\na-much-longer-file-name.c,0\n")
          (kmode--refresh-tags-file-buffer file)
          (with-current-buffer buffer
            (should (equal (buffer-string)
                           "\f\na-much-longer-file-name.c,0\n"))
            (should-not tags-table-files)
            (should-not tags-completion-table)
            (should-not tags-included-tables)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest kmode-test/recompile-reinstalls-persistent-finish-callback ()
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (context (kmode--make-context
                     :root root :profile "persistent" :output root
                     :compiler 'auto))
           (callback-count 0)
           (callback (lambda (_buffer _status)
                       (cl-incf callback-count)))
           buffer)
      (unwind-protect
          (progn
            (setq buffer
                  (apply #'kmode-start-shell-command
                         (list "persistent-callback" "true" root nil root
                               context callback callback)))
            (while (get-buffer-process buffer)
              (accept-process-output nil 0.05))
            (should (= callback-count 1))
            (with-current-buffer buffer
              (kmode-recompile))
            (while (get-buffer-process buffer)
              (accept-process-output nil 0.05))
            (should (= callback-count 2)))
        (when (buffer-live-p buffer)
          (when-let ((process (get-buffer-process buffer)))
            (delete-process process))
          (kill-buffer buffer))))))

(ert-deftest kmode-test/reused-job-clears-old-persistent-finish-callback ()
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (context (kmode--make-context
                     :root root :profile "callback-clear" :output root
                     :compiler 'auto))
           (callback-count 0)
           (callback (lambda (_buffer _status)
                       (cl-incf callback-count)))
           buffer)
      (unwind-protect
          (progn
            (setq buffer
                  (kmode-start-shell-command
                   "callback-clear" "true" root nil root context
                   callback callback))
            (while (get-buffer-process buffer)
              (accept-process-output nil 0.05))
            (should (= callback-count 1))
            (should
             (eq buffer
                 (kmode-start-shell-command
                  "callback-clear" "true" root nil root context)))
            (while (get-buffer-process buffer)
              (accept-process-output nil 0.05))
            (should (= callback-count 1))
            (with-current-buffer buffer
              (should-not kmode-process-finish-function)))
        (when (buffer-live-p buffer)
          (when-let ((process (get-buffer-process buffer)))
            (delete-process process))
          (kill-buffer buffer))))))

(ert-deftest kmode-test/cscope-file-list-alone-is-not-query-ready ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "cscope integration is not present"))
  (kmode-test-with-kernel-tree (root)
    (let ((output (file-name-as-directory
                   (expand-file-name "cscope-output" root))))
      (kmode-test--write-file output "cscope.files" "-k\n-q\n")
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root))
        (setq-local kmode-output-directory output)
        (cl-letf (((symbol-function 'locate-library)
                   (lambda (_library) "/host/xcscope.el"))
                  ((symbol-function 'kmode-tool-path)
                   (lambda (tool &optional _context)
                     (and (equal tool "cscope") "/host/bin/cscope"))))
          (should-not (kmode-cscope-available-p)))))))

(ert-deftest kmode-test/cscope-does-not-fallback-to-source-root ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "cscope integration is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "empty-profile-output" root)))
           called)
      (make-directory output t)
      (kmode-test--write-file root "cscope.out")
      (with-temp-buffer
        (setq default-directory root)
        (setq-local kmode-output-directory output)
        (cl-letf (((symbol-function 'locate-library)
                   (lambda (_library) "/host/xcscope.el"))
                  ((symbol-function 'kmode-tool-path)
                   (lambda (tool &optional _context)
                     (and (equal tool "cscope") "/host/bin/cscope")))
                  ((symbol-function 'kmode-require-tool)
                   (lambda (_tool _context) "/host/bin/cscope"))
                  ((symbol-function 'require)
                   (lambda (&rest _arguments) t))
                  ((symbol-function 'cscope-find-global-definition)
                   (lambda () (interactive) (setq called t))))
          (should-not (kmode-cscope-available-p))
          (should-error (kmode-cscope-find-definition) :type 'user-error)))
      (should-not called))))

(ert-deftest kmode-test/xcscope-wrappers-delegate-profile-local-state ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "kmode-navigate.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "cscope-output" root)))
           (_database (kmode-test--write-file output "cscope.out"))
           (cscope-output-buffer-name
            (generate-new-buffer-name " *kmode-cscope-state*"))
           (cscope-result-separator "================================\n")
           (cscope-process nil)
           (kmode-test--enable-subr-trampolines nil)
           (cscope-program "outer-program")
           (cscope-initial-directory "/outer/database")
           (cscope-option-kernel-mode nil)
           (cscope-database-regexps '((".*" ("/outer/mapped"))))
           (cscope-database-file "outer.out")
           (cscope-index-file "outer.files")
           (cscope-option-do-not-update-database nil)
           (cscope-option-include-directories '("/outer/include"))
           (cscope-option-other '("--outer-option"))
           (cscope-option-disable-compression t)
           (cscope-option-use-inverted-index nil)
           observed)
      (with-temp-buffer
        (setq default-directory root)
        (setq-local kmode-output-directory output)
        (cl-letf (((symbol-function 'kmode-require-tool)
                   (lambda (tool _context)
                     (should (equal tool "cscope"))
                     "/host/bin/cscope"))
                  ((symbol-function 'require)
                   (lambda (&rest _arguments) t))
                  ((symbol-function 'cscope-find-global-definition)
                   (lambda ()
                     (interactive)
                     (setq observed
                           (list cscope-program cscope-initial-directory
                                 cscope-option-kernel-mode
                                 cscope-database-regexps
                                 cscope-database-file cscope-index-file
                                 cscope-option-do-not-update-database
                                 cscope-option-other
                                 cscope-option-include-directories
                                 cscope-option-disable-compression
                                 cscope-option-use-inverted-index
                                 default-directory))))
                  ((symbol-function 'cscope-find-this-symbol)
                   (lambda ()
                     (interactive)
                     (error "simulated xcscope failure"))))
          (kmode-cscope-find-definition)
          (should-error (kmode-cscope-find-symbol) :type 'error)))
      (should
       (equal observed
              (list "/host/bin/cscope" (directory-file-name output)
                    t nil "cscope.out" "cscope.files" t nil nil nil nil root)))
      (should (equal cscope-program "outer-program"))
      (should (equal cscope-initial-directory "/outer/database"))
      (should-not cscope-option-kernel-mode)
      (should (equal cscope-database-regexps
                     '((".*" ("/outer/mapped")))))
      (should (equal cscope-database-file "outer.out"))
      (should (equal cscope-index-file "outer.files"))
      (should-not cscope-option-do-not-update-database)
      (should (equal cscope-option-other '("--outer-option")))
      (should (equal cscope-option-include-directories '("/outer/include")))
      (should cscope-option-disable-compression)
      (should-not cscope-option-use-inverted-index)
      (when-let ((buffer (get-buffer cscope-output-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest kmode-test/xcscope-result-rerun-retains-only-its-profile-state ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "kmode-navigate.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "rerun-cscope-output" root)))
           (_database (kmode-test--write-file output "cscope.out"))
           (_inverted-in (kmode-test--write-file output "cscope.in.out"))
           (_inverted-postings
            (kmode-test--write-file output "cscope.po.out"))
           (cscope-output-buffer-name
            (generate-new-buffer-name " *kmode-cscope-rerun*"))
           (result-buffer (get-buffer-create cscope-output-buffer-name))
           (cscope-result-separator "================================\n")
           (cscope-process nil)
           (cscope-program "outer-program")
           (cscope-initial-directory "/outer/database")
           (cscope-option-kernel-mode nil)
           (cscope-database-regexps '((".*" (("/outer/mapped")))))
           (cscope-database-file "outer.out")
           (cscope-index-file "outer.files")
           (cscope-option-do-not-update-database nil)
           (cscope-option-include-directories '("/outer/include"))
           (cscope-option-other '("--outer-option"))
           (cscope-option-disable-compression t)
           (cscope-option-use-inverted-index nil)
           old-beginning new-beginning launch-observed rerun-observed)
      (unwind-protect
          (progn
            ;; Pre-existing native xcscope buffer locals must survive a Kmode
            ;; launch, and its older result must not receive Kmode state.
            (with-current-buffer result-buffer
              (setq-local cscope-program "buffer-program")
              (setq-local cscope-option-include-directories
                          '("/buffer/include"))
              (setq old-beginning (point))
              (insert cscope-result-separator "old result\n")
              (put-text-property
               old-beginning (1+ old-beginning) 'cscope-stored-search
               '(cscope-find-global-definition "old")))
            (with-temp-buffer
              (setq default-directory root)
              (setq-local kmode-output-directory output)
              (cl-letf
                  (((symbol-function 'kmode-require-tool)
                    (lambda (_tool _context) "/profile/bin/cscope"))
                   ((symbol-function 'require)
                    (lambda (&rest _arguments) t))
                   ((symbol-function 'cscope-find-global-definition)
                    (lambda (&optional symbol)
                      (interactive)
                      (with-current-buffer result-buffer
                        (let ((observed
                               (list cscope-program
                                     cscope-initial-directory
                                     cscope-option-do-not-update-database
                                     cscope-option-include-directories
                                     cscope-option-kernel-mode
                                     cscope-option-other
                                     cscope-option-disable-compression
                                     cscope-option-use-inverted-index
                                     cscope-database-regexps
                                     cscope-database-file
                                     cscope-index-file)))
                          (if symbol
                              (setq rerun-observed observed)
                            (setq launch-observed observed)))
                        (setq new-beginning (point-max))
                        (goto-char (point-max))
                        (insert cscope-result-separator "new result\n")
                        (put-text-property
                         new-beginning (1+ new-beginning)
                         'cscope-stored-search
                         `(cscope-find-global-definition
                           ,(or symbol "needle")))))))
                (kmode-cscope-find-definition)))
            (let ((expected
                   (list "/profile/bin/cscope"
                         (directory-file-name output)
                         t nil t nil nil t nil
                         "cscope.out" "cscope.files")))
              (should (equal launch-observed expected))
              (with-current-buffer result-buffer
                (should (equal cscope-program "buffer-program"))
                (should (equal cscope-option-include-directories
                               '("/buffer/include")))
                (should
                 (equal (get-text-property
                         old-beginning 'cscope-stored-search)
                        '(cscope-find-global-definition "old")))
                (goto-char new-beginning)
                (let ((stored (get-text-property
                               new-beginning 'cscope-stored-search)))
                  (should (eq (car stored) 'kmode--xcscope-rerun))
                  ;; This mirrors native xcscope's `r': delete the selected
                  ;; result, leave point at its beginning, and eval its
                  ;; cscope-stored-search form.
                  (delete-region new-beginning (point-max))
                  (goto-char new-beginning)
                  (cl-letf
                      (((symbol-function 'cscope-find-global-definition)
                        (lambda (&optional symbol)
                          (with-current-buffer result-buffer
                            (setq rerun-observed
                                  (list
                                   cscope-program
                                   cscope-initial-directory
                                   cscope-option-do-not-update-database
                                   cscope-option-include-directories
                                   cscope-option-kernel-mode
                                   cscope-option-other
                                   cscope-option-disable-compression
                                   cscope-option-use-inverted-index
                                   cscope-database-regexps
                                   cscope-database-file
                                   cscope-index-file))
                            (setq new-beginning (point-max))
                            (goto-char (point-max))
                            (insert cscope-result-separator "new result\n")
                            (put-text-property
                             new-beginning (1+ new-beginning)
                             'cscope-stored-search
                             `(cscope-find-global-definition
                               ,(or symbol "needle")))))))
                    (eval stored))
                  (should (equal rerun-observed expected))
                  (should
                   (eq (car (get-text-property
                             new-beginning 'cscope-stored-search))
                       'kmode--xcscope-rerun))))
              (should (equal cscope-program "outer-program"))
              (should (equal cscope-option-include-directories
                             '("/outer/include")))))
        (when (buffer-live-p result-buffer)
          (kill-buffer result-buffer))))))

(ert-deftest kmode-test/xcscope-wrapper-rejects-missing-profile-database ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "kmode-navigate.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "empty-cscope-output" root)))
           (kmode-test--enable-subr-trampolines nil)
           called)
      (make-directory output t)
      (with-temp-buffer
        (setq default-directory root)
        (setq-local kmode-output-directory output)
        (cl-letf (((symbol-function 'kmode-require-tool)
                   (lambda (_tool _context) "/host/bin/cscope"))
                  ((symbol-function 'require)
                   (lambda (&rest _arguments) t))
                  ((symbol-function
                    'cscope-find-functions-calling-this-function)
                   (lambda () (interactive) (setq called t))))
          (should-error (kmode-cscope-find-callers) :type 'user-error)))
      (should-not called))))

(ert-deftest kmode-test/cscope-inverted-index-needs-both-companions ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "cscope integration is not present"))
  (let ((directory (make-temp-file "kmode-cscope-index-" t)))
    (unwind-protect
        (progn
          (should-not (kmode--cscope-inverted-index-p directory))
          (kmode-test--write-file directory "cscope.in.out")
          (should-not (kmode--cscope-inverted-index-p directory))
          (kmode-test--write-file directory "cscope.po.out")
          (should (kmode--cscope-inverted-index-p directory)))
      (delete-directory directory t))))

(ert-deftest kmode-test/clangd-command-composes-profile-and-user-arguments ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "kmode-navigate.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "clangd-output" root)))
           (_database
            (kmode-test--write-file output "compile_commands.json" "[]\n"))
           (kmode-test--enable-subr-trampolines nil)
           (kmode-clangd-arguments
            '("--background-index" "--header-insertion=never"
              "--query-driver=/opt/cross-*"))
           started)
      (with-temp-buffer
        (c-mode)
        (setq default-directory root)
        (setq-local kmode-output-directory output)
        (setq-local eglot-server-programs
                    '((c-mode . ("old-clangd"))
                      (python-mode . ("pylsp"))))
        (cl-letf (((symbol-function 'kmode-require-tool)
                   (lambda (tool _context)
                     (should (equal tool "clangd"))
                     "/host/bin/clangd"))
                  ((symbol-function 'require)
                   (lambda (&rest _arguments) t))
                  ((symbol-function 'eglot-ensure)
                   (lambda () (setq started t))))
          (kmode-eglot-ensure))
        (should started)
        (should
         (equal (cdr (assq 'c-mode eglot-server-programs))
                (list "/host/bin/clangd"
                      (concat "--compile-commands-dir="
                              (directory-file-name output))
                      "--background-index" "--header-insertion=never"
                      "--query-driver=/opt/cross-*")))
        (should (equal (cdr (assq 'python-mode eglot-server-programs))
                       '("pylsp")))
        (should (= (cl-count 'c-mode eglot-server-programs
                             :key #'car :test #'eq)
                   1))))))

(ert-deftest kmode-test/clangd-setup-preserves-inherited-server-alist ()
  (unless (featurep 'kmode-navigate)
    (ert-skip "kmode-navigate.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "clangd-output" root)))
           (_database
            (kmode-test--write-file output "compile_commands.json" "[]\n"))
           (inherited '((python-mode . ("pylsp"))
                        (c-mode . ("global-clangd"))
                        (rust-mode . ("rust-analyzer"))))
           (original (copy-tree inherited))
           (eglot-server-programs inherited)
           (kmode-test--enable-subr-trampolines nil)
           started)
      (with-temp-buffer
        (c-mode)
        (setq default-directory root)
        (setq-local kmode-output-directory output)
        (should-not (local-variable-p 'eglot-server-programs))
        (cl-letf (((symbol-function 'kmode-require-tool)
                   (lambda (tool _context)
                     (should (equal tool "clangd"))
                     "/host/bin/clangd"))
                  ((symbol-function 'require)
                   (lambda (&rest _arguments) t))
                  ((symbol-function 'eglot-ensure)
                   (lambda () (setq started t))))
          (kmode-eglot-ensure))
        (should started)
        (should (local-variable-p 'eglot-server-programs))
        (should
         (equal (mapcar #'car eglot-server-programs)
                '(c-mode python-mode rust-mode))))
      (should (equal inherited original)))))

(ert-deftest kmode-test/index-navigation-keymaps-actions-and-wrappers ()
  (unless (and (featurep 'kmode-emacs)
               (featurep 'kmode-build)
               (featurep 'kmode-navigate))
    (ert-skip "index navigation integration is not present"))
  (should (eq (lookup-key kmode-navigation-map (kbd "t"))
              'kmode-build-tags))
  (should (eq (lookup-key kmode-navigation-map (kbd "C"))
              kmode-cscope-map))
  (dolist (binding '(("b" . kmode-build-cscope)
                     ("d" . kmode-cscope-find-definition)
                     ("r" . kmode-cscope-find-callers)
                     ("c" . kmode-cscope-find-callees)
                     ("s" . kmode-cscope-find-symbol)
                     ("t" . kmode-cscope-find-text)
                     ("i" . kmode-cscope-find-includers)))
    (should (eq (lookup-key kmode-cscope-map (kbd (car binding)))
                (cdr binding))))
  (dolist (entry '((kmode-build-tags kmode-build-tags)
                   (kmode-build-cscope kmode-build-cscope)
                   (cscope-definition kmode-cscope-find-definition)
                   (cscope-callers kmode-cscope-find-callers)
                   (cscope-callees kmode-cscope-find-callees)))
    (let ((action
           (seq-find (lambda (candidate)
                       (eq (kmode-action-id candidate) (car entry)))
                     (kmode-actions t))))
      (should action)
      (should (eq (kmode-action-command action) (cadr entry)))
      (should (equal (kmode-action-group action) "Navigate"))))
  (let (delegated)
    (cl-letf (((symbol-function 'kmode--call-xcscope)
               (lambda (command) (push command delegated))))
      (dolist (command '(kmode-cscope-find-symbol
                         kmode-cscope-find-definition
                         kmode-cscope-find-callers
                         kmode-cscope-find-callees
                         kmode-cscope-find-text
                         kmode-cscope-find-includers))
        (call-interactively command)))
    (should
     (equal (nreverse delegated)
            '(cscope-find-this-symbol
              cscope-find-global-definition
              cscope-find-functions-calling-this-function
              cscope-find-called-functions
              cscope-find-this-text-string
              cscope-find-files-including-file)))))

(ert-deftest kmode-test/lore-query-construction-is-scoped-and-escaped ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (let ((kmode-lore-default-date-range "5.years.ago.."))
    (should
     (equal (kmode-lore--quote-term "name\\\"part")
            "\"name\\\\\\\"part\""))
    (let ((query (kmode-lore--symbol-query "wake_up_process")))
      (dolist (field '("s:" "nq:" "dfhh:" "dfa:" "dfb:" "dfctx:"))
        (should (string-match-p
                 (regexp-quote (concat field "\"wake_up_process\""))
                 query)))
      (should (string-suffix-p "AND rt:5.years.ago.." query)))
    (should
     (equal (kmode-lore--file-query "drivers/net/a b.c")
            "(dfn:\"drivers/net/a b.c\") AND rt:5.years.ago.."))
    (let ((query
           (kmode-lore--context-query
            "wake_up_process" "kernel/workqueue.c")))
      (should (string-match-p
               (regexp-quote "dfn:\"kernel/workqueue.c\"") query))
      (should (string-match-p
               (regexp-quote "dfhh:\"wake_up_process\"") query))
      (should (string-match-p
               (regexp-quote "nq:\"wake_up_process\"") query))))
  (let ((kmode-lore-default-date-range nil))
    (should-not
     (string-match-p "rt:" (kmode-lore--symbol-query "wake_up_process")))))

(ert-deftest kmode-test/lore-query-validation-rejects-unsafe-input ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (should (equal (kmode-lore--validate-query "  s:sched  ") "s:sched"))
  (should-error (kmode-lore--validate-query "") :type 'user-error)
  (should-error (kmode-lore--validate-query "s:foo\nbar")
                :type 'user-error)
  (let ((kmode-lore-max-query-length 4))
    (should-error (kmode-lore--validate-query "abcde")
                  :type 'user-error)))

(ert-deftest kmode-test/lore-identifier-skips-c-type-tags ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (dolist (case '(("struct task_struct *task;" . "task_struct")
                  ("union sched_class_data value;" . "sched_class_data")
                  ("enum migration_status state;" . "migration_status")))
    (with-temp-buffer
      (c-mode)
      (insert (car case))
      (goto-char (point-min))
      (should (equal (kmode-lore--identifier-at-point) (cdr case)))))
  (with-temp-buffer
    (insert "work_struct")
    (let ((transient-mark-mode t))
      (set-mark (point-min))
      (goto-char (point-max))
      (setq mark-active t)
      (should (equal (kmode-lore--identifier-at-point) "work_struct"))))
  (with-temp-buffer
    (insert "not an identifier")
    (let ((transient-mark-mode t))
      (set-mark (point-min))
      (goto-char (point-max))
      (setq mark-active t)
      (should-not (kmode-lore--identifier-at-point)))))

(ert-deftest kmode-test/lore-search-url-encodes-query-and-page-state ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (let ((kmode-lore-base-url "https://lore.kernel.org/all")
        (kmode-lore-result-limit 7))
    (should
     (equal
      (kmode-lore--search-url
       "dfn:\"drivers/a b.c\" AND x:y&z" 14 'relevance)
      (concat
       "https://lore.kernel.org/all/"
       "?q=dfn%3A%22drivers%2Fa%20b.c%22%20AND%20x%3Ay%26z"
       "&x=A&l=7&o=14&t=1&r=1")))
    (should-not
     (string-match-p
      "&r=1"
      (kmode-lore--search-url "s:sched" 0 'date)))))

(ert-deftest kmode-test/lore-atom-parser-decodes-compact-results ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (with-temp-buffer
    (insert kmode-test--lore-atom)
    (let ((results
           (kmode-lore--parse-atom
            (point-min) (point-max) "symbol")))
      (should (= (length results) 2))
      (let ((first (nth 0 results))
            (second (nth 1 results)))
        (should
         (equal (kmode-lore-result-message-id first)
                "id/part@example.com"))
        (should
         (equal (kmode-lore-result-subject first)
                "[PATCH] Fix & explain wakeups"))
        (should (equal (kmode-lore-result-author first) "Alice & Bob"))
        (should
         (equal (kmode-lore-result-date first)
                "2026-09-08T12:34:56Z"))
        (should (equal (kmode-lore-result-scope first) "symbol"))
        (should
         (equal (kmode-lore-result-url second)
                "https://lore.kernel.org/all/second@example.net/"))
        (should (equal (kmode-lore-result-author second) "(unknown)")))))
  (with-temp-buffer
    (insert "<?xml version=\"1.0\"?><not-a-feed/>")
    (should-error
     (kmode-lore--parse-atom (point-min) (point-max) "query"))))

(ert-deftest kmode-test/lore-cache-round-trips-results-with-safe-modes ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (let* ((directory (make-temp-file "kmode-lore-cache-" t))
         (kmode-lore-cache-directory
          (file-name-as-directory directory))
         (kmode-lore-cache-ttl 3600)
         (result
          (kmode-lore--make-result
           :message-id "id@example.com"
           :subject "[PATCH] scheduler change"
           :author "Kernel Hacker"
           :date "2026-09-08T01:02:03Z"
           :url "https://lore.kernel.org/all/id@example.com/"
           :scope "context")))
    (unwind-protect
        (with-temp-buffer
          (setq-local kmode-lore--query "s:scheduler")
          (setq-local kmode-lore--offset 0)
          (setq-local kmode-lore--order 'date)
          (kmode-lore--cache-write (list result))
          (let* ((file (kmode-lore--cache-file))
                 (cached (kmode-lore--cache-read))
                 (decoded (car (plist-get cached :results))))
            (should (file-regular-p file))
            (should (= (logand (file-modes directory) #o777) #o700))
            (should (= (logand (file-modes file) #o777) #o600))
            (should (plist-get cached :fresh))
            (should
             (equal (kmode-lore-result-message-id decoded)
                    "id@example.com"))
            (should
             (equal (kmode-lore-result-subject decoded)
                    "[PATCH] scheduler change"))
            (should (equal (kmode-lore-result-scope decoded) "context"))
            (let ((kmode-lore-cache-ttl -1))
              (should-not
               (plist-get (kmode-lore--cache-read) :fresh)))))
      (ignore-errors (delete-directory directory t)))))

(ert-deftest kmode-test/lore-cache-clear-is-contained-and-symlink-safe ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (let* ((base (make-temp-file "kmode-lore-clear-" t))
         (directory (expand-file-name "cache/" base))
         (kmode-lore-cache-directory directory)
         (valid
          (expand-file-name
           (format "kmode-lore-%s.json" (make-string 64 ?a))
           directory))
         (link
          (expand-file-name
           (format "kmode-lore-%s.json" (make-string 64 ?b))
           directory))
         (unrelated (expand-file-name "notes.json" directory))
         (outside (expand-file-name "outside.json" base)))
    (unwind-protect
        (progn
          (make-directory directory t)
          (with-temp-file valid (insert "{}\n"))
          (with-temp-file unrelated (insert "keep\n"))
          (with-temp-file outside (insert "outside\n"))
          (make-symbolic-link outside link)
          (kmode-lore-clear-cache)
          (should-not (file-exists-p valid))
          (should (file-exists-p unrelated))
          (should (file-symlink-p link))
          (should (file-exists-p outside)))
      (ignore-errors (delete-directory base t)))))

(ert-deftest kmode-test/lore-symbol-validation-is-explicit ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (should (equal (kmode-lore--validate-symbol " wake_up_process ")
                 "wake_up_process"))
  (dolist (value '(nil "" "two symbols" "bad-name" "line\nbreak"))
    (should-error (kmode-lore--validate-symbol value) :type 'user-error))
  (should-error (kmode-lore--symbol-query "") :type 'user-error))

(ert-deftest kmode-test/lore-origin-url-trust-and-legacy-normalization ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (should
   (equal
    (kmode-lore--trusted-origin-url
     "<https://lkml.kernel.org/r/id%2Fpart@example.com>")
    "https://lore.kernel.org/all/id%2Fpart%40example.com/"))
  (should
   (equal
    (kmode-lore--trusted-origin-url
     "https://lore.kernel.org/all/native@example.com/")
    "https://lore.kernel.org/all/native@example.com/"))
  (dolist (url '("http://lore.kernel.org/all/nope/"
                 "https://lore.kernel.org.evil.invalid/all/nope/"
                 "https://evil.invalid/lore.kernel.org/all/nope/"
                 "https://lkml.kernel.org/not-r/nope@example.com"))
    (should-not (kmode-lore--trusted-origin-url url))))

(ert-deftest kmode-test/lore-cache-key-includes-scope-and-page-size ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (with-temp-buffer
    (setq-local kmode-lore--query "s:wakeup")
    (setq-local kmode-lore--scope "symbol")
    (setq-local kmode-lore--offset 0)
    (setq-local kmode-lore--order 'date)
    (let* ((kmode-lore-result-limit 20)
           (symbol-20 (kmode-lore--cache-key))
           (symbol-10
            (let ((kmode-lore-result-limit 10))
              (kmode-lore--cache-key)))
           (file-20
            (progn
              (setq-local kmode-lore--scope "file")
              (kmode-lore--cache-key))))
      (should-not (equal symbol-20 symbol-10))
      (should-not (equal symbol-20 file-20)))))

(ert-deftest kmode-test/lore-status-shows-freshness-and-empty-hint ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (let ((kmode-lore--status "cached")
        (kmode-lore--fetched-at 0.0)
        (kmode-lore--offset 0)
        (kmode-lore--order 'date)
        (kmode-lore--query "s:wakeup")
        (kmode-lore-result-limit 20))
    (should
     (string-match-p "fetched 1970-01-01 00:00 UTC"
                     (kmode-lore--status-header))))
  (should
   (string-match-p
    "press s to edit"
    (kmode-lore--status-with-results "live" nil)))
  (should (equal (kmode-lore--status-with-results "live" '(result))
                 "live")))

(ert-deftest kmode-test/lore-global-context-can-be-symbol-only ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (with-temp-buffer
    (insert "wake_up_process")
    (goto-char (point-min))
    (let (query scope)
      (cl-letf (((symbol-function 'kmode-root)
                 (lambda (&optional noerror)
                   (should noerror)
                   nil))
                ((symbol-function 'kmode-lore--start-search)
                 (lambda (value label &optional _force)
                   (setq query value scope label))))
        (kmode-lore-context-at-point))
      (should (equal scope "context"))
      (should (string-match-p "wake_up_process" query))
      (should-not (string-match-p "dfn:" query)))))

(ert-deftest kmode-test/lore-why-falls-back-for-unsafe-provenance ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (dolist (modified '(t nil))
    (with-temp-buffer
      (insert "wake_up_process")
      (set-buffer-modified-p modified)
      (let (fallback origin-called)
        (cl-letf (((symbol-function 'kmode-lore--origin-links)
                   (lambda ()
                     (setq origin-called t)
                     (user-error "not tracked")))
                  ((symbol-function 'kmode-lore-context-at-point)
                   (lambda () (setq fallback t))))
          (kmode-lore-why))
        (should fallback)
        (should (eq origin-called (not modified)))))))

(ert-deftest kmode-test/lore-root-directory-query-drops-dot-slash ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (with-temp-buffer
      (setq default-directory (file-name-as-directory root))
      (let ((kmode-lore-default-date-range nil)
            query)
        (cl-letf (((symbol-function 'kmode-lore--start-search)
                   (lambda (value _scope &optional _force)
                     (setq query value))))
          (kmode-lore-search-directory))
        (should (equal query "dfn:\"*\""))))))

(ert-deftest kmode-test/lore-origin-links-use-blame-and-trusted-trailers ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (kmode-test-with-kernel-tree (root)
    (with-temp-buffer
      (setq default-directory (file-name-as-directory root))
      (setq buffer-file-name
            (expand-file-name "drivers/net/kmode_dummy.c" root))
      (insert "int kmode_dummy;\n")
      (goto-char (point-min))
      (let (calls)
        (cl-letf
            (((symbol-function 'kmode-lore--git-output)
              (lambda (arguments)
                (push arguments calls)
                (if (equal (car arguments) "blame")
                    (concat (make-string 40 ?a) " 1 1 1\n")
                  (concat
                   "Explain the change\n\n"
                   "Link: <https://lore.kernel.org/all/first@example.com/>\n"
                   "Link: https://example.com/not-lore\n"
                   "link: https://lore.kernel.org/lkml/second@example.net/\n"
                   "Link: https://lkml.kernel.org/r/legacy@example.org\n"
                   "Link: https://lore.kernel.org.evil.invalid/all/nope/\n"
                   "Link: https://lore.kernel.org/all/first@example.com/\n")))))
          (should
           (equal
            (kmode-lore--origin-links)
            '("https://lore.kernel.org/all/first@example.com/"
              "https://lore.kernel.org/lkml/second@example.net/"
              "https://lore.kernel.org/all/legacy%40example.org/"))))
        (setq calls (nreverse calls))
        (should
         (equal
          (car calls)
          '("blame" "--porcelain" "-L" "1,1" "--"
            "drivers/net/kmode_dummy.c")))
        (should
         (equal
          (cadr calls)
          (list "show" "-s" "--format=%B" (make-string 40 ?a)))))
      (cl-letf
          (((symbol-function 'kmode-lore--git-output)
            (lambda (_arguments)
              (concat (make-string 40 ?0) " 1 1 1\n"))))
        (should-not (kmode-lore--origin-links))))))

(ert-deftest kmode-test/lore-actions-and-result-bindings-are-discoverable ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (should (eq (lookup-key kmode-command-map (kbd "L")) kmode-lore-map))
  (should (eq (lookup-key kmode-navigation-map (kbd "l"))
              (quote kmode-lore-context-at-point)))
  (dolist (binding '(("." . kmode-lore-context-at-point)
                     ("s" . kmode-lore-search-symbol)
                     ("f" . kmode-lore-search-file)
                     ("d" . kmode-lore-search-directory)
                     ("q" . kmode-lore-search)
                     ("w" . kmode-lore-why)
                     ("c" . kmode-lore-clear-cache)))
    (should (eq (lookup-key kmode-lore-map (kbd (car binding)))
                (cdr binding))))
  (dolist (entry '((lore-context kmode-lore-context-at-point)
                   (lore-why kmode-lore-why)
                   (lore-file kmode-lore-search-file)
                   (lore-search kmode-lore-search)))
    (let ((action
           (seq-find
            (lambda (candidate)
              (eq (kmode-action-id candidate) (car entry)))
            (kmode-actions t))))
      (should action)
      (should (eq (kmode-action-command action) (cadr entry)))
      (should (equal (kmode-action-group action) "Review"))))
  (dolist (binding '(("RET" . kmode-lore-open-message)
                     ("o" . kmode-lore-browse-message)
                     ("T" . kmode-lore-browse-thread)
                     ("w" . kmode-lore-copy-url)
                     ("m" . kmode-lore-copy-message-id)
                     ("g" . kmode-lore-refresh)
                     ("N" . kmode-lore-next-page)
                     ("P" . kmode-lore-previous-page)
                     ("r" . kmode-lore-toggle-order)))
    (should
     (eq (lookup-key kmode-lore-results-mode-map
                     (kbd (car binding)))
         (cdr binding)))))

(ert-deftest kmode-test/lore-request-is-asynchronous-and-network-is-mocked ()
  (unless (featurep 'kmode-lore)
    (ert-skip "kmode-lore.el is not present"))
  (let* ((directory (make-temp-file "kmode-lore-request-" t))
         (kmode-lore-cache-directory
          (file-name-as-directory directory))
         (kmode-lore-base-url "https://lore.kernel.org/all/")
         (kmode-lore-result-limit 2)
         (kmode-lore-request-timeout 60)
         (target (generate-new-buffer " *kmode-lore-request-test*"))
         (response (generate-new-buffer " *kmode-lore-response-test*"))
         callback callback-arguments requested-url requested-agent
         requested-headers requested-silent requested-inhibit-cookies)
    (unwind-protect
        (progn
          (with-current-buffer target
            (kmode-lore-results-mode)
            (setq-local kmode-lore--query "s:wakeup")
            (setq-local kmode-lore--scope "query")
            (setq-local kmode-lore--offset 0)
            (setq-local kmode-lore--order 'date)
            (cl-letf
                (((symbol-function 'url-retrieve)
                  (lambda (url function arguments
                               &optional silent inhibit-cookies)
                    (setq requested-url url
                          callback function
                          callback-arguments arguments
                          requested-agent url-user-agent
                          requested-headers url-request-extra-headers
                          requested-silent silent
                          requested-inhibit-cookies inhibit-cookies)
                    response)))
              (kmode-lore--request t))
            (should (equal kmode-lore--status "loading"))
            (should (eq kmode-lore--request-buffer response)))
          (should
           (equal requested-url
                  (concat
                   "https://lore.kernel.org/all/"
                   "?q=s%3Awakeup&x=A&l=2&o=0&t=1")))
          (should (equal requested-agent kmode-lore-user-agent))
          (should
           (equal requested-headers
                  '(("Accept" . "application/atom+xml"))))
          (should requested-silent)
          (should requested-inhibit-cookies)
          (with-current-buffer response
            (insert "HTTP/1.1 200 OK\r\nContent-Type: application/atom+xml\r\n\r\n")
            (setq-local url-http-response-status 200)
            (setq-local url-http-end-of-headers (copy-marker (point)))
            (insert kmode-test--lore-atom)
            (apply callback nil callback-arguments))
          (should-not (buffer-live-p response))
          (with-current-buffer target
            (should (equal kmode-lore--status "live"))
            (should (= (length kmode-lore--results) 2))
            (should (= (length tabulated-list-entries) 2))
            (should-not kmode-lore--request-buffer)
            (should-not kmode-lore--timeout-timer)
            (should (numberp kmode-lore--fetched-at))
            (should (file-regular-p (kmode-lore--cache-file)))))
      (when (buffer-live-p response)
        (kill-buffer response))
      (when (buffer-live-p target)
        (kill-buffer target))
      (ignore-errors (delete-directory directory t)))))

(ert-deftest kmode-test/compilation-reinitialization-preserves-ownership ()
  (with-temp-buffer
    (setq-local kmode-process-root "/kernel/root/")
    (setq-local kmode-process-profile "debug")
    (setq-local kmode-process-resource "/kernel/output")
    (kmode-compilation-mode)
    (should (equal kmode-process-root "/kernel/root/"))
    (should (equal kmode-process-profile "debug"))
    (should (equal kmode-process-resource "/kernel/output"))))

(defun kmode-test-checkdoc-batch ()
  "Check shipped kmode-emacs source files and exit nonzero on style warnings."
  (require 'checkdoc)
  (let ((files (sort (directory-files default-directory t
                                      "\\`kmode.*\\.el\\'")
                     #'string-lessp))
        issues)
    (dolist (file files)
      (cl-letf (((symbol-function 'warn)
                 (lambda (format-string &rest arguments)
                   (push (apply #'format format-string arguments) issues))))
        (checkdoc-file file)))
    (if issues
        (progn
          (princ "Checkdoc reported style problems:\n")
          (dolist (issue (nreverse issues))
            (princ issue)
            (terpri))
          (kill-emacs 1))
      (princ (format "Checkdoc passed for %d source files.\n"
                     (length files))))))

(provide 'kmode-tests)

;;; kmode-test.el ends here
