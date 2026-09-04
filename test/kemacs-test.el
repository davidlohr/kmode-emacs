;;; kemacs-test.el --- Tests for Kemacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; These tests deliberately build tiny synthetic kernel trees.  They should
;; never need a Linux checkout, a compiler toolchain, or network access.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'flymake)
(require 'subr-x)
(require 'kemacs-core)

(declare-function kemacs-build--current-directory-target "kemacs-build")
(declare-function kemacs-build--current-object-target "kemacs-build")
(declare-function kemacs-build--start "kemacs-build")
(declare-function kemacs-build--target "kemacs-build")
(declare-function kemacs-build-make-arguments "kemacs-build")
(declare-function kemacs-build-process-environment "kemacs-build")
(declare-function kemacs-build-sparse "kemacs-build")
(declare-function kemacs--dashboard-context "kemacs-ui")
(declare-function kemacs--include-candidates "kemacs-navigate")
(declare-function kemacs--search-lines-with-rg "kemacs-navigate")
(declare-function kemacs-impact--run-button "kemacs-impact")
(declare-function kemacs-kselftest-collections "kemacs-test")
(declare-function kemacs-kunit-arguments "kemacs-test")
(declare-function kemacs-kunit-resolve-build-directory "kemacs-test")
(declare-function kemacs-review--validate-range "kemacs-review")
(declare-function kemacs--write-git-diff "kemacs-review")
(declare-function kemacs--config-at-point "kemacs-navigate")
(declare-function kemacs-find-callers "kemacs-navigate")
(declare-function kemacs-find-definition "kemacs-navigate")
(declare-function kemacs-find-kbuild "kemacs-navigate")
(declare-function kemacs--line-include "kemacs-navigate")
(declare-function kemacs-navigation-back "kemacs-navigate")
(declare-function kemacs--search-kconfig-fallback "kemacs-navigate")
(declare-function kemacs-toggle-header-source "kemacs-navigate")
(declare-function kemacs-kconfig--source-at-point "kemacs-kconfig")
(declare-function kemacs-kconfig--source-statement-at-point "kemacs-kconfig")
(declare-function kemacs-kconfig-calculate-indent "kemacs-kconfig")
(declare-function kemacs-kconfig-follow-source "kemacs-kconfig")
(declare-function kemacs-kconfig-indent-line "kemacs-kconfig")
(declare-function kemacs-kconfig-mode "kemacs-kconfig")
(declare-function kemacs-qemu-arguments "kemacs-debug")
(declare-function kemacs-qemu-runtime-resources "kemacs-debug")
(declare-function kemacs-vng--assert-config-safe "kemacs-virtme")
(declare-function kemacs-vng--confirm-host-access "kemacs-virtme")
(declare-function kemacs-vng--default-debug-value "kemacs-virtme")
(declare-function kemacs-vng--global-runtime-p "kemacs-virtme")
(declare-function kemacs-vng--prepare-runtime "kemacs-virtme")
(declare-function kemacs-vng--start-runtime "kemacs-virtme")
(declare-function kemacs-vng-architecture "kemacs-virtme")
(declare-function kemacs-vng-build-and-run "kemacs-virtme")
(declare-function kemacs-vng-command-arguments "kemacs-virtme")
(declare-function kemacs-vng-config-safe-p "kemacs-virtme")
(declare-function kemacs-vng-processes "kemacs-virtme")
(declare-function kemacs-vng-stop "kemacs-virtme")
(declare-function kemacs-dashboard-mode "kemacs-ui")
(declare-function kemacs-dashboard-refresh "kemacs-ui")
(declare-function kemacs-dispatch "kemacs-ui")
(declare-function kemacs-mode "kemacs-mode")
(declare-function kemacs-project-find "kemacs-mode")
(declare-function kemacs-checkpatch-flymake "kemacs-flymake")
(declare-function kemacs-checkpatch-flymake--cancel "kemacs-flymake")
(declare-function kemacs-checkpatch-flymake--parse-output "kemacs-flymake")
(declare-function kemacs-checkpatch-flymake--source-extension "kemacs-flymake")
(declare-function kemacs-checkpatch-flymake-mode "kemacs-flymake")

(defvar comp-enable-subr-trampolines)
(defvar kemacs--saved-locals)
(defvar kemacs-apply-kernel-c-style)
(defvar kemacs-build-default-target)
(defvar kemacs-build-sanitized-environment-variables)
(defvar kemacs-build-trusted-path-directories)
(defvar kemacs-build-sparse-level)
(defvar kemacs-dashboard-root)
(defvar kemacs-dashboard-origin)
(defvar kemacs-impact-context)
(defvar kemacs-impact-origin)
(defvar kemacs-impact-root)
(defvar kemacs-mode)
(defvar kemacs-kunit-build-directory)
(defvar kemacs-set-compile-command)
(defvar kemacs-command-map)
(defvar kemacs-navigation-map)
(defvar kemacs-vng-confirm-host-access)
(defvar kemacs-vng-home-directory)
(defvar kemacs-vng-map)
(defvar kemacs-vng-program)
(defvar kemacs-vng-trust-default-options)
(defvar kemacs-checkpatch-flymake--output-buffer)
(defvar kemacs-checkpatch-flymake--process)
(defvar kemacs-checkpatch-flymake--report-function)
(defvar kemacs-checkpatch-flymake--request)
(defvar kemacs-checkpatch-flymake--started-flymake)
(defvar kemacs-checkpatch-flymake--temporary-file)
(defvar kemacs-checkpatch-flymake-mode)

(defvar kemacs-test--dispatch-count 0
  "Number of times the dispatcher test command has run.")

(defun kemacs-test--dispatch-command ()
  "Record one invocation from `kemacs-dispatch'."
  (interactive)
  (cl-incf kemacs-test--dispatch-count))

(defun kemacs-test--other-flymake-backend (_report-function &rest _arguments)
  "Stand in for an unrelated Flymake backend during coexistence tests.")

(defconst kemacs-test--project-root
  (file-name-as-directory
   (expand-file-name ".." (file-name-directory
                            (or load-file-name buffer-file-name))))
  "Absolute path to the Kemacs checkout under test.")

(defconst kemacs-test--optional-features
  (mapcar (lambda (file)
            (intern (file-name-base file)))
          (directory-files kemacs-test--project-root nil
                           "\\`kemacs-.*\\.el\\'"))
  "Kemacs modules discovered in and loaded from the checkout.")

(dolist (feature kemacs-test--optional-features)
  (let ((source (expand-file-name (concat (symbol-name feature) ".el")
                                  kemacs-test--project-root)))
    (when (file-exists-p source)
      ;; Load an explicit path because the KUnit module `kemacs-test.el' and
      ;; this ERT file intentionally live in different directories.
      (unless (featurep feature)
        (load source nil nil t)))))

(defun kemacs-test--write-file (root relative &optional contents mode)
  "Create RELATIVE below ROOT with CONTENTS and optional file MODE."
  (let ((file (expand-file-name relative root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (or contents "")))
    (when mode
      (set-file-modes file mode))
    file))

(cl-defmacro kemacs-test-with-kernel-tree ((root) &body body)
  "Bind ROOT to a disposable synthetic kernel tree while running BODY."
  (declare (indent 1) (debug ((symbolp) body)))
  `(let* ((,root (make-temp-file "kemacs-kernel-" t))
          (kemacs--root-cache (make-hash-table :test #'equal))
          (kemacs--selected-profiles (make-hash-table :test #'equal))
          (kemacs--actions (copy-sequence kemacs--actions))
          (kemacs-root-override nil)
          (kemacs-profile nil)
          (kemacs-output-directory nil)
          (kemacs-arch nil)
          (kemacs-cross-compile nil)
          (kemacs-compiler nil)
          (kemacs-jobs nil)
          (kemacs-make-arguments nil))
     (unwind-protect
         (progn
           (dolist (marker kemacs-root-markers)
             (kemacs-test--write-file ,root marker))
           (kemacs-test--write-file ,root "drivers/net/kemacs_dummy.c"
                                    "int kemacs_dummy;\n")
           (let ((default-directory (file-name-as-directory ,root)))
             ,@body))
       (ignore-errors (delete-directory ,root t)))))

(cl-defmacro kemacs-test-with-fake-vng ((program) &body body)
  "Run BODY with PROGRAM bound to an executable fake vng path."
  (declare (indent 1) (debug ((symbolp) body)))
  `(let* ((kemacs-test-vng-bin (make-temp-file "kemacs-vng-bin-" t))
          (,program (expand-file-name "vng-fake" kemacs-test-vng-bin))
          (kemacs-vng-program ,program)
          (kemacs-vng-home-directory
           (file-name-as-directory kemacs-test-vng-bin))
          (kemacs-vng-trust-default-options nil)
          (kemacs-vng-confirm-host-access nil))
     (unwind-protect
         (progn
           (kemacs-test--write-file
            kemacs-test-vng-bin "vng-fake" "#!/bin/sh\nexit 0\n" #o755)
           ,@body)
       (ignore-errors (delete-directory kemacs-test-vng-bin t)))))

(defun kemacs-test--make-exited-process (buffer exit-code)
  "Return a process in BUFFER that has exited with EXIT-CODE."
  (let ((process
         (make-process
          :name (generate-new-buffer-name "kemacs-test-exit")
          :buffer buffer
          :command (list (or shell-file-name "/bin/sh")
                         (or shell-command-switch "-c")
                         (format "exit %d" exit-code))
          :noquery t)))
    (while (process-live-p process)
      (accept-process-output process 0.05))
    process))

(ert-deftest kemacs-test/modules-load-when-present ()
  "Every module present in the checkout must load and provide its feature."
  (dolist (feature kemacs-test--optional-features)
    (let ((source (expand-file-name (concat (symbol-name feature) ".el")
                                    kemacs-test--project-root)))
      (when (file-exists-p source)
        (should (featurep feature))))))

(ert-deftest kemacs-test/kernel-root-requires-every-marker ()
  (kemacs-test-with-kernel-tree (root)
    (should (kemacs-kernel-root-p root))
    (delete-file (expand-file-name "MAINTAINERS" root))
    (should-not (kemacs-kernel-root-p root))))

(ert-deftest kemacs-test/locate-root-from-directory-and-file ()
  (kemacs-test-with-kernel-tree (root)
    (let* ((nested (expand-file-name "drivers/net/" root))
           (source (expand-file-name "kemacs_dummy.c" nested))
           (expected (file-name-as-directory root)))
      (should (equal (kemacs-locate-root nested) expected))
      (should (equal (kemacs-locate-root source) expected)))))

(ert-deftest kemacs-test/locate-root-honors-buffer-override ()
  (kemacs-test-with-kernel-tree (root)
    (with-temp-buffer
      (setq default-directory
            (file-name-as-directory (make-temp-file "kemacs-outside-" t)))
      (unwind-protect
          (progn
            (setq-local kemacs-root-override root)
            (should (equal (kemacs-locate-root)
                           (file-name-as-directory root))))
        (delete-directory default-directory t)))))

(ert-deftest kemacs-test/root-override-wins-over-a-negative-cache-entry ()
  (kemacs-test-with-kernel-tree (root)
    (with-temp-buffer
      (let ((outside (make-temp-file "kemacs-outside-" t)))
        (unwind-protect
            (progn
              (setq default-directory (file-name-as-directory outside))
              (should-not (kemacs-locate-root))
              (setq-local kemacs-root-override root)
              (should (equal (kemacs-locate-root)
                             (file-name-as-directory root))))
          (delete-directory outside t))))))

(ert-deftest kemacs-test/root-errors-cleanly-outside-a-kernel-tree ()
  (let* ((outside (make-temp-file "kemacs-outside-" t))
         (default-directory (file-name-as-directory outside))
         (kemacs--root-cache (make-hash-table :test #'equal))
         (kemacs-root-override nil))
    (unwind-protect
        (progn
          (should-not (kemacs-root t))
          (should-error (kemacs-root) :type 'user-error))
      (delete-directory outside t))))

(ert-deftest kemacs-test/root-cache-can-be-cleared-after-tree-appears ()
  (let* ((root (make-temp-file "kemacs-late-kernel-" t))
         (default-directory (file-name-as-directory root))
         (kemacs--root-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (should-not (kemacs-locate-root))
          (dolist (marker kemacs-root-markers)
            (kemacs-test--write-file root marker))
          (should-not (kemacs-locate-root))
          (kemacs-clear-caches)
          (should (equal (kemacs-locate-root)
                         (file-name-as-directory root))))
      (delete-directory root t))))

(ert-deftest kemacs-test/positive-jobs-normalizes-supported-values ()
  (should (integerp (kemacs--positive-jobs 'auto)))
  (should (> (kemacs--positive-jobs 'auto) 0))
  (should (= (kemacs--positive-jobs 1) 1))
  (should (= (kemacs--positive-jobs 32) 32))
  (should-not (kemacs--positive-jobs nil))
  (dolist (bad '(0 -1 "8" many))
    (should-error (kemacs--positive-jobs bad) :type 'user-error)))

(ert-deftest kemacs-test/context-resolves-profile-paths-and-toolchain ()
  (kemacs-test-with-kernel-tree (root)
    (let ((kemacs-profiles
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
      (let ((context (kemacs-resolve-context root)))
        (should (equal (kemacs-context-root context)
                       (file-name-as-directory root)))
        (should (equal (kemacs-context-profile context) "default"))
        (should (equal (kemacs-context-output context)
                       (file-name-as-directory
                        (expand-file-name "build/arm64" root))))
        (should (equal (kemacs-context-arch context) "arm64"))
        (should (equal (kemacs-context-cross-compile context)
                       "aarch64-linux-gnu-"))
        (should (eq (kemacs-context-compiler context) 'clang))
        (should (= (kemacs-context-jobs context) 7))
        (should (equal (kemacs-context-make-arguments context)
                       '("V=1" "W=1")))
        (should (string-match-p "default.*arm64.*clang/LLVM"
                                (kemacs-profile-description context)))))))

(ert-deftest kemacs-test/context-buffer-locals-override-profile ()
  (kemacs-test-with-kernel-tree (root)
    (let ((kemacs-profiles
           '(("default"
              :arch "x86"
              :cross-compile "old-"
              :compiler gcc
              :output "old-output"
              :jobs 2
              :make-arguments ("PROFILE=1")))))
      (with-temp-buffer
        (setq-local kemacs-output-directory "new output")
        (setq-local kemacs-arch "riscv")
        (setq-local kemacs-cross-compile "riscv64-linux-gnu-")
        (setq-local kemacs-compiler 'clang)
        (setq-local kemacs-jobs 9)
        (setq-local kemacs-make-arguments '("LOCAL=1"))
        (let ((context (kemacs-resolve-context root)))
          (should (equal (kemacs-context-output context)
                         (file-name-as-directory
                          (expand-file-name "new output" root))))
          (should (equal (kemacs-context-arch context) "riscv"))
          (should (equal (kemacs-context-cross-compile context)
                         "riscv64-linux-gnu-"))
          (should (eq (kemacs-context-compiler context) 'clang))
          (should (= (kemacs-context-jobs context) 9))
          (should (equal (kemacs-context-make-arguments context)
                         '("LOCAL=1" "PROFILE=1"))))))))

(ert-deftest kemacs-test/context-functions-can-refine-context ()
  (kemacs-test-with-kernel-tree (root)
    (let ((kemacs-context-functions
           (list (lambda (context)
                   (setf (kemacs-context-arch context) "um")
                   context))))
      (should (equal (kemacs-context-arch (kemacs-resolve-context root))
                     "um")))))

(ert-deftest kemacs-test/profile-selection-is-scoped-by-root ()
  (kemacs-test-with-kernel-tree (root)
    (let ((other-root (make-temp-file "kemacs-other-kernel-" t))
          (kemacs-default-profile "default"))
      (unwind-protect
          (progn
            (puthash (file-name-as-directory root) "debug"
                     kemacs--selected-profiles)
            (should (equal (kemacs-current-profile-name
                            (file-name-as-directory root))
                           "debug"))
            (should (equal (kemacs-current-profile-name other-root)
                           "default")))
        (delete-directory other-root t)))))

(ert-deftest kemacs-test/unknown-profile-is-an-actionable-user-error ()
  (let ((kemacs-profiles '(("default" :compiler auto))))
    (should-error (kemacs--profile-entry "missing") :type 'user-error)))

(ert-deftest kemacs-test/shell-command-preserves-hostile-arguments ()
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
         (command (kemacs-shell-command program arguments))
         (actual (shell-command-to-string command))
         (expected (concat (mapconcat #'identity payload "\n") "\n")))
    (should (equal actual expected))))

(ert-deftest kemacs-test/start-command-quotes-argv-and-isolates-buffer ()
  (kemacs-test-with-kernel-tree (root)
    (let* ((workdir (expand-file-name "drivers/net/" root))
           (arguments '("-C" "/tree with spaces" "target;not-a-command"))
           observed)
      (cl-letf (((symbol-function 'compilation-start)
                 (lambda (command mode name-function)
                   (setq observed
                         (list command mode (funcall name-function mode)
                               default-directory))
                   'kemacs-test-buffer)))
        (should (eq (kemacs-start-command "build" "make" arguments workdir)
                    'kemacs-test-buffer)))
      (should (equal (nth 0 observed)
                     (kemacs-shell-command "make" arguments)))
      (should (eq (nth 1 observed) 'kemacs-compilation-mode))
      (should (equal (nth 2 observed)
                     (format "*kemacs:%s:%s:build*"
                             (kemacs-root-id root)
                             (kemacs-current-profile-name root))))
      (should (equal (nth 3 observed)
                     (file-name-as-directory workdir))))))

(ert-deftest kemacs-test/start-command-installs-finish-hook-before-launch ()
  (kemacs-test-with-kernel-tree (root)
    (let* ((context (kemacs-resolve-context root))
           (callback (lambda (_buffer _status)))
           (buffer (generate-new-buffer " *kemacs-finish-before-launch*"))
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
             (eq (kemacs-start-command
                  "finish" "true" nil root nil nil context callback)
                 buffer))
            (should process-started)
            (should callback-present))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest kemacs-test/build-argv-reflects-complete-cross-profile ()
  (unless (featurep 'kemacs-build)
    (ert-skip "kemacs-build.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((output (file-name-as-directory
                    (expand-file-name "output with spaces" root)))
           (context
            (kemacs--make-context
             :root (file-name-as-directory root)
             :profile "ci"
             :output output
             :arch "arm64"
             :cross-compile "aarch64-linux-gnu-"
             :compiler 'clang
             :jobs 8
             :make-arguments '("KCFLAGS=-Werror")))
           (arguments
            (kemacs-build-make-arguments
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

(ert-deftest kemacs-test/build-argv-omits-inapplicable-options ()
  (unless (featurep 'kemacs-build)
    (ert-skip "kemacs-build.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let ((context
           (kemacs--make-context
            :root (file-name-as-directory root)
            :profile "native"
            :output (file-name-as-directory root)
            :compiler 'gcc
            :jobs nil)))
      (should (equal (kemacs-build-make-arguments context '("vmlinux"))
                     '("vmlinux"))))))

(ert-deftest kemacs-test/build-target-validation-blocks-make-injection ()
  (unless (featurep 'kemacs-build)
    (ert-skip "kemacs-build.el is not present"))
  (dolist (target '("" "-j99" "ARCH=attacker" "all;echo-pwned"
                    "$(shell,id)" "target with spaces"))
    (should-error (kemacs-build--target target) :type 'user-error))
  (dolist (target '("vmlinux" "drivers/net/" "kernel/sched/core.o"
                    "rust-analyzer" "foo+bar@baz%quux"))
    (should (equal (kemacs-build--target target) target))))

(ert-deftest kemacs-test/build-argv-validates-context-fields ()
  (unless (featurep 'kemacs-build)
    (ert-skip "kemacs-build.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let ((valid
           (kemacs--make-context
            :root (file-name-as-directory root)
            :profile "test"
            :output (file-name-as-directory root)
            :compiler 'auto)))
      (dolist (mutation
               (list
                (lambda (context) (setf (kemacs-context-root context) "relative"))
                (lambda (context) (setf (kemacs-context-output context) nil))
                (lambda (context) (setf (kemacs-context-compiler context) 'icc))
                (lambda (context) (setf (kemacs-context-jobs context) 0))
                (lambda (context) (setf (kemacs-context-arch context) ""))
                (lambda (context)
                  (setf (kemacs-context-cross-compile context) ""))))
        (let ((context (copy-kemacs-context valid)))
          (funcall mutation context)
          (should-error (kemacs-build-make-arguments context)
                        :type 'user-error))))))

(ert-deftest kemacs-test/build-object-and-directory-targets-are-relative ()
  (unless (featurep 'kemacs-build)
    (ert-skip "kemacs-build.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let ((context (kemacs-resolve-context root)))
      (with-temp-buffer
        (setq buffer-file-name
              (expand-file-name "drivers/net/kemacs_dummy.c" root))
        (should (equal (kemacs-build--current-object-target context)
                       "drivers/net/kemacs_dummy.o"))
        (should (equal (kemacs-build--current-directory-target context)
                       "drivers/net/")))
      (with-temp-buffer
        (setq buffer-file-name (expand-file-name "README.md" root))
        (should-error (kemacs-build--current-object-target context)
                      :type 'user-error))
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root))
        (should-not (kemacs-build--current-directory-target context))))))

(ert-deftest kemacs-test/file-in-root-accepts-members-and-rejects-outsiders ()
  (kemacs-test-with-kernel-tree (root)
    (let* ((inside (expand-file-name "drivers/net/kemacs_dummy.c" root))
           (outside (make-temp-file "kemacs-outsider-"))
           (context (kemacs-resolve-context root)))
      (unwind-protect
          (progn
            (should (equal (kemacs-file-in-root inside context)
                           "drivers/net/kemacs_dummy.c"))
            (should-error (kemacs-file-in-root outside context)
                          :type 'user-error))
        (delete-file outside)))))

(ert-deftest kemacs-test/tool-path-prefers-a-kernel-tree-tool ()
  (kemacs-test-with-kernel-tree (root)
    (let* ((tool (kemacs-test--write-file
                  root "scripts/kemacs-test-tool" "#!/bin/sh\nexit 0\n" #o755))
           (context (kemacs-resolve-context root)))
      (should (equal (kemacs-tool-path "scripts/kemacs-test-tool" context)
                     tool))
      (should-error
       (kemacs-require-tool "kemacs-tool-that-must-not-exist-7c592" context)
       :type 'user-error))))

(ert-deftest kemacs-test/flymake-parser-maps-checkpatch-severity-and-location ()
  (unless (featurep 'kemacs-flymake)
    (ert-skip "kemacs-flymake.el is not present"))
  (with-temp-buffer
    (insert "first line\nsecond token\nthird alpha beta\nfourth line")
    (let ((source (current-buffer))
          (output (generate-new-buffer " *kemacs-flymake-parse*")))
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
                   (kemacs-checkpatch-flymake--parse-output output source)))
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

(ert-deftest kemacs-test/flymake-extension-preserves-kernel-source-kind ()
  (unless (featurep 'kemacs-flymake)
    (ert-skip "kemacs-flymake.el is not present"))
  (dolist (extension '(".c" ".h" ".S" ".s" ".rs"))
    (with-temp-buffer
      (setq buffer-file-name (concat "/tmp/kemacs-source" extension))
      (should (equal (kemacs-checkpatch-flymake--source-extension)
                     extension))))
  (with-temp-buffer
    (setq major-mode 'rust-mode)
    (should (equal (kemacs-checkpatch-flymake--source-extension) ".rs")))
  (with-temp-buffer
    (setq buffer-file-name "/tmp/not-source.txt")
    (should-not (kemacs-checkpatch-flymake--source-extension))))

(ert-deftest kemacs-test/flymake-backend-reports-missing-tool-without-signaling ()
  (unless (featurep 'kemacs-flymake)
    (ert-skip "kemacs-flymake.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (with-temp-buffer
      (setq default-directory (file-name-as-directory root)
            buffer-file-name
            (expand-file-name "drivers/net/kemacs_dummy.c" root))
      (insert "int unsaved_change;\n")
      (let (report-action report-properties)
        (kemacs-checkpatch-flymake
         (lambda (action &rest properties)
           (setq report-action action
                 report-properties properties)))
        (should (eq report-action :panic))
        (should (string-match-p
                 "executable scripts/checkpatch\\.pl"
                 (plist-get report-properties :explanation)))
        (should-not kemacs-checkpatch-flymake--process)
        (should-not kemacs-checkpatch-flymake--temporary-file)
        (should-not kemacs-checkpatch-flymake--output-buffer)))))

(ert-deftest kemacs-test/flymake-backend-uses-direct-argv-and-unsaved-snapshot ()
  (unless (featurep 'kemacs-flymake)
    (ert-skip "kemacs-flymake.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((tool (expand-file-name "scripts/checkpatch.pl" root))
           (fake-process
            (make-pipe-process
             :name (generate-new-buffer-name "kemacs-flymake-process")
             :noquery t))
           captured-properties
           observed-directory
           report-action
           temporary
           output
           sentinel
           (comp-enable-subr-trampolines nil))
      (set-file-modes tool #o755)
      (unwind-protect
          (with-temp-buffer
            (setq default-directory (file-name-as-directory root)
                  buffer-file-name
                  (expand-file-name "drivers/net/kemacs_dummy.c" root))
            (insert "int live_buffer_value;\n")
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest properties)
                         (setq captured-properties properties
                               observed-directory default-directory)
                         fake-process)))
              (kemacs-checkpatch-flymake
               (lambda (action &rest _properties)
                 (setq report-action action))))
            (setq temporary kemacs-checkpatch-flymake--temporary-file
                  output kemacs-checkpatch-flymake--output-buffer
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
            (should-not kemacs-checkpatch-flymake--request)
            (should-not kemacs-checkpatch-flymake--process)
            (should-not kemacs-checkpatch-flymake--temporary-file)
            (should-not kemacs-checkpatch-flymake--output-buffer))
        (when (process-live-p fake-process)
          (delete-process fake-process))
        (when (and temporary (file-exists-p temporary))
          (delete-file temporary))
        (when (buffer-live-p output)
          (kill-buffer output))))))

(ert-deftest kemacs-test/flymake-fast-sentinel-cannot-leave-stale-state ()
  (unless (featurep 'kemacs-flymake)
    (ert-skip "kemacs-flymake.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((tool (expand-file-name "scripts/checkpatch.pl" root))
           (fake-process
            (make-pipe-process
             :name (generate-new-buffer-name "kemacs-flymake-fast")
             :noquery t))
           captured-temporary
           captured-output
           report-action
           (comp-enable-subr-trampolines nil))
      (set-file-modes tool #o755)
      (unwind-protect
          (with-temp-buffer
            (setq default-directory (file-name-as-directory root)
                  buffer-file-name
                  (expand-file-name "drivers/net/kemacs_dummy.rs" root))
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
              (kemacs-checkpatch-flymake
               (lambda (action &rest _properties)
                 (setq report-action action))))
            (should (= (length report-action) 1))
            (should (eq (flymake-diagnostic-type (car report-action))
                        :warning))
            (should-not kemacs-checkpatch-flymake--request)
            (should-not kemacs-checkpatch-flymake--process)
            (should-not kemacs-checkpatch-flymake--temporary-file)
            (should-not kemacs-checkpatch-flymake--output-buffer)
            (should-not (file-exists-p captured-temporary))
            (should-not (buffer-live-p captured-output)))
        (when (process-live-p fake-process)
          (delete-process fake-process))
        (when (and captured-temporary
                   (file-exists-p captured-temporary))
          (delete-file captured-temporary))
        (when (buffer-live-p captured-output)
          (kill-buffer captured-output))))))

(ert-deftest kemacs-test/flymake-new-run-cancels-and-cleans-stale-process ()
  (unless (featurep 'kemacs-flymake)
    (ert-skip "kemacs-flymake.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((tool (expand-file-name "scripts/checkpatch.pl" root))
           (first-process
            (make-pipe-process
             :name (generate-new-buffer-name "kemacs-flymake-first")
             :noquery t))
           (second-process
            (make-pipe-process
             :name (generate-new-buffer-name "kemacs-flymake-second")
             :noquery t))
           (processes (list first-process second-process))
           calls
           captures
           first-temporary
           first-output
           (comp-enable-subr-trampolines nil))
      (set-file-modes tool #o755)
      (unwind-protect
          (with-temp-buffer
            (setq default-directory (file-name-as-directory root)
                  buffer-file-name
                  (expand-file-name "drivers/net/kemacs_dummy.c" root))
            (insert "int generation;\n")
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest properties)
                         (push properties captures)
                         (prog1 (car processes)
                           (setq processes (cdr processes))))))
              (kemacs-checkpatch-flymake
               (lambda (action &rest _properties) (push action calls)))
              (setq first-temporary
                    kemacs-checkpatch-flymake--temporary-file
                    first-output kemacs-checkpatch-flymake--output-buffer)
              (kemacs-checkpatch-flymake
               (lambda (action &rest _properties) (push action calls))))
            (should-not (process-live-p first-process))
            (should-not (file-exists-p first-temporary))
            (should-not (buffer-live-p first-output))
            (should (eq kemacs-checkpatch-flymake--process second-process))
            ;; Even a late invocation of the captured old sentinel is stale.
            (funcall (plist-get (cadr captures) :sentinel)
                     first-process "deleted\n")
            (should-not calls)
            (kemacs-checkpatch-flymake--cancel)
            (should-not (process-live-p second-process))
            (should-not kemacs-checkpatch-flymake--process))
        (dolist (process (list first-process second-process))
          (when (process-live-p process)
            (delete-process process)))))))

(ert-deftest kemacs-test/flymake-spawn-failure-cleans-resources-and-panics ()
  (unless (featurep 'kemacs-flymake)
    (ert-skip "kemacs-flymake.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let ((tool (expand-file-name "scripts/checkpatch.pl" root))
          captured-properties
          report-action
          report-properties
          (comp-enable-subr-trampolines nil))
      (set-file-modes tool #o755)
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root)
              buffer-file-name
              (expand-file-name "drivers/net/kemacs_dummy.S" root))
        (insert "nop\n")
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest properties)
                     (setq captured-properties properties)
                     (error "Synthetic spawn failure"))))
          (kemacs-checkpatch-flymake
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

(ert-deftest kemacs-test/flymake-mode-rejects-nonexecutable-tree-tool-early ()
  (unless (featurep 'kemacs-flymake)
    (ert-skip "kemacs-flymake.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (with-temp-buffer
      (setq default-directory (file-name-as-directory root)
            buffer-file-name
            (expand-file-name "drivers/net/kemacs_dummy.c" root))
      (let ((error-data
             (should-error (kemacs-checkpatch-flymake-mode 1)
                           :type 'user-error)))
        (should (string-match-p
                 "needs executable scripts/checkpatch\\.pl"
                 (error-message-string error-data))))
      (should-not kemacs-checkpatch-flymake-mode)
      (should-not flymake-mode)
      (should-not (memq #'kemacs-checkpatch-flymake
                        flymake-diagnostic-functions))
      (should-not kemacs-checkpatch-flymake--request)
      (should-not kemacs-checkpatch-flymake--process))))

(ert-deftest kemacs-test/flymake-mode-coexists-with-existing-backends ()
  (unless (featurep 'kemacs-flymake)
    (ert-skip "kemacs-flymake.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (set-file-modes (expand-file-name "scripts/checkpatch.pl" root) #o755)
    (with-temp-buffer
      (setq default-directory (file-name-as-directory root)
            buffer-file-name
            (expand-file-name "drivers/net/kemacs_dummy.c" root))
      (setq-local flymake-mode t)
      (setq-local flymake-diagnostic-functions
                  '(kemacs-test--other-flymake-backend))
      (let ((starts 0)
            (cleared 'not-called))
        (cl-letf (((symbol-function 'flymake-start)
                   (lambda (&optional _deferred _force)
                     (cl-incf starts))))
          (kemacs-checkpatch-flymake-mode 1))
        (should kemacs-checkpatch-flymake-mode)
        (should (= starts 1))
        (should (equal flymake-diagnostic-functions
                       '(kemacs-test--other-flymake-backend
                         kemacs-checkpatch-flymake)))
        (setq-local kemacs-checkpatch-flymake--report-function
                    (lambda (action &rest _properties)
                      (setq cleared (list action))))
        (kemacs-checkpatch-flymake-mode -1)
        (should-not kemacs-checkpatch-flymake-mode)
        (should flymake-mode)
        (should (equal flymake-diagnostic-functions
                       '(kemacs-test--other-flymake-backend)))
        (should (equal cleared '(nil)))
        (should-not (memq #'kemacs-checkpatch-flymake--cancel
                          kill-buffer-hook))))))

(ert-deftest kemacs-test/flymake-action-is-registered-but-mode-defaults-off ()
  (unless (featurep 'kemacs-flymake)
    (ert-skip "kemacs-flymake.el is not present"))
  (with-temp-buffer
    (should-not kemacs-checkpatch-flymake-mode))
  (should
   (seq-find (lambda (action)
               (eq (kemacs-action-id action) 'checkpatch-flymake))
             (kemacs-actions t))))

(ert-deftest kemacs-test/actions-replace-identities-filter-and-sort ()
  (let ((kemacs--actions nil))
    (kemacs-register-action 'zeta "Zulu" "Build" #'ignore)
    (kemacs-register-action 'alpha "Alpha" "Build" #'ignore)
    (kemacs-register-action 'hidden "Hidden" "Review" #'ignore
                            :predicate (lambda () nil))
    (kemacs-register-action 'broken "Broken" "Review" #'ignore
                            :predicate (lambda () (error "not available")))
    (kemacs-register-action 'zeta "Aardvark" "Debug" #'ignore)
    (should (equal (mapcar #'kemacs-action-id (kemacs-actions))
                   '(alpha zeta)))
    (should (= (length (kemacs-actions t)) 4))
    (should (equal (kemacs-action-title
                    (seq-find (lambda (action)
                                (eq (kemacs-action-id action) 'zeta))
                              (kemacs-actions t)))
                   "Aardvark"))))

(ert-deftest kemacs-test/checkpatch-diagnostic-regexp-captures-location ()
  (let ((regexp (nth 1 (assq 'kemacs-checkpatch
                              compilation-error-regexp-alist-alist))))
    (should (string-match regexp "FILE: drivers/net/demo.c:42:7:"))
    (should (equal (match-string 1 "FILE: drivers/net/demo.c:42:7:")
                   "drivers/net/demo.c"))
    (should (equal (match-string 2 "FILE: drivers/net/demo.c:42:7:") "42"))
    (should (equal (match-string 3 "FILE: drivers/net/demo.c:42:7:") "7"))))

(ert-deftest kemacs-test/compilation-mode-installs-local-kernel-behavior ()
  (with-temp-buffer
    (kemacs-compilation-mode)
    (should (eq major-mode 'kemacs-compilation-mode))
    (should (memq 'kemacs-checkpatch compilation-error-regexp-alist))
    (should (memq #'ansi-color-compilation-filter compilation-filter-hook))))

(ert-deftest kemacs-test/navigation-parses-includes-and-config-symbols ()
  (unless (featurep 'kemacs-navigate)
    (ert-skip "kemacs-navigate.el is not present"))
  (with-temp-buffer
    (insert "  # include <linux/sched.h>\n")
    (goto-char (point-min))
    (should (equal (kemacs--line-include) "linux/sched.h")))
  (with-temp-buffer
    (insert "IS_ENABLED(CONFIG_PREEMPT_RT)")
    (search-backward "CONFIG_PREEMPT_RT")
    (should (equal (kemacs--config-at-point) "PREEMPT_RT")))
  (with-temp-buffer
    (insert "CONFIG_not_uppercase")
    (goto-char (point-min))
    (should-not (kemacs--config-at-point))))

(ert-deftest kemacs-test/navigation-fallback-finds-kconfig-definitions ()
  (unless (featurep 'kemacs-navigate)
    (ert-skip "kemacs-navigate.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (kemacs-test--write-file
     root "drivers/Kconfig"
     "menuconfig KEMACS_MENU\n\nconfig KEMACS_DRIVER\n\tbool \"test\"\n")
    (let ((matches (kemacs--search-kconfig-fallback "KEMACS_DRIVER" root)))
      (should (= (length matches) 1))
      (should (equal (file-relative-name (caar matches) root)
                     "drivers/Kconfig"))
      (should (= (nth 1 (car matches)) 3)))))

(ert-deftest kemacs-test/navigation-resolves-source-header-counterpart ()
  (unless (featurep 'kemacs-navigate)
    (ert-skip "kemacs-navigate.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let ((buffer-file-name
           (expand-file-name "drivers/net/kemacs_dummy.c" root))
          visited)
      (cl-letf (((symbol-function 'kemacs--rg-files)
                 (lambda (_root)
                   '("drivers/net/kemacs_dummy.c"
                     "include/linux/kemacs_dummy.h")))
                ((symbol-function 'find-file)
                 (lambda (file) (setq visited file))))
        (kemacs-toggle-header-source))
      (should (equal visited
                     (expand-file-name "include/linux/kemacs_dummy.h" root))))))

(ert-deftest kemacs-test/navigation-finds-nearest-kbuild-owner ()
  (unless (featurep 'kemacs-navigate)
    (ert-skip "kemacs-navigate.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((owner (kemacs-test--write-file root "drivers/net/Kbuild"
                                           "obj-y += kemacs_dummy.o\n"))
           (buffer-file-name
            (expand-file-name "drivers/net/kemacs_dummy.c" root))
           visited)
      (cl-letf (((symbol-function 'find-file)
                 (lambda (file) (setq visited file))))
        (kemacs-find-kbuild))
      (should (equal visited owner)))))

(ert-deftest kemacs-test/kconfig-parses-source-statements ()
  (unless (featurep 'kemacs-kconfig)
    (ert-skip "kemacs-kconfig.el is not present"))
  (dolist (case '(("source \"drivers/Kconfig\"" . "drivers/Kconfig")
                  ("rsource ../Kconfig.common" . "../Kconfig.common")
                  ("osource \"optional/Kconfig\"" . "optional/Kconfig")
                  ("orsource arch/$(SRCARCH)/Kconfig" .
                   "arch/$(SRCARCH)/Kconfig")))
    (with-temp-buffer
      (insert (car case))
      (should (equal (kemacs-kconfig--source-at-point) (cdr case)))))
  (with-temp-buffer
    (insert "orsource \"subsystem/Kconfig.optional\"")
    (should
     (equal (kemacs-kconfig--source-statement-at-point)
            '(orsource . "subsystem/Kconfig.optional"))))
  (with-temp-buffer
    (insert "config NOT_A_SOURCE")
    (should-not (kemacs-kconfig--source-at-point))))

(ert-deftest kemacs-test/kconfig-indentation-tracks-block-symbol-and-help ()
  (unless (featurep 'kemacs-kconfig)
    (ert-skip "kemacs-kconfig.el is not present"))
  (with-temp-buffer
    (insert "menu \"Drivers\"\n"
            "config KEMACS_DRIVER\n"
            "bool \"Kemacs driver\"\n"
            "help\n"
            "Developer-facing help text.\n"
            "endmenu\n")
    (kemacs-kconfig-mode)
    (cl-labels ((indent-at
                 (line)
                 (goto-char (point-min))
                 (forward-line (1- line))
                 (kemacs-kconfig-calculate-indent)))
      (should (= (indent-at 1) 0))
      (should (= (indent-at 2) 8))
      (should (= (indent-at 3) 16))
      (should (= (indent-at 4) 16))
      (should (= (indent-at 5) 24))
      (should (= (indent-at 6) 0))
      (goto-char (point-min))
      (forward-line 4)
      (kemacs-kconfig-indent-line)
      (should (= (current-indentation) 24)))))

(ert-deftest kemacs-test/kconfig-source-expands-active-architecture ()
  (unless (featurep 'kemacs-kconfig)
    (ert-skip "kemacs-kconfig.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((target (kemacs-test--write-file root "arch/arm64/Kconfig"
                                            "config ARM64\n"))
           (kemacs-profiles
            '(("default" :arch "arm64" :compiler auto :jobs nil)))
           visited)
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root))
        (insert "source \"arch/$(SRCARCH)/Kconfig\"\n")
        (goto-char (point-min))
        (cl-letf (((symbol-function 'find-file)
                   (lambda (file) (setq visited file))))
          (kemacs-kconfig-follow-source)))
      (should (equal visited target)))))

(ert-deftest kemacs-test/kconfig-rsource-is-relative-to-containing-file ()
  (unless (featurep 'kemacs-kconfig)
    (ert-skip "kemacs-kconfig.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((source (kemacs-test--write-file root "drivers/Kconfig"))
           (target (kemacs-test--write-file
                    root "drivers/Kconfig.local" "config LOCAL\n"))
           visited)
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root)
              buffer-file-name source)
        (insert "rsource \"Kconfig.local\"\n")
        (goto-char (point-min))
        (cl-letf (((symbol-function 'find-file)
                   (lambda (file) (setq visited file))))
          (kemacs-kconfig-follow-source)))
      (should (equal visited target)))))

(ert-deftest kemacs-test/x86-64-srcarch-drives-kconfig-and-includes ()
  (unless (and (featurep 'kemacs-kconfig)
               (featurep 'kemacs-navigate))
    (ert-skip "Kconfig/navigation modules are not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((kconfig (kemacs-test--write-file
                     root "arch/x86/Kconfig" "config X86\n"))
           (header (kemacs-test--write-file
                    root "arch/x86/include/asm/processor.h" ""))
           (kemacs-profiles
            '(("default" :arch "x86_64" :compiler auto :jobs nil)))
           (context (kemacs-resolve-context root))
           visited)
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root))
        (insert "source \"arch/$(SRCARCH)/Kconfig\"\n")
        (goto-char (point-min))
        (cl-letf (((symbol-function 'find-file)
                   (lambda (file) (setq visited file))))
          (kemacs-kconfig-follow-source)))
      (should (equal visited kconfig))
      (should (member header
                      (kemacs--include-candidates
                       "asm/processor.h" context)))
      (should-not
       (seq-some (lambda (path)
                   (string-match-p "/arch/x86_64/" path))
                 (kemacs--include-candidates
                  "asm/processor.h" context))))))

(ert-deftest kemacs-test/kconfig-source-rejects-variables-and-tree-escapes ()
  (unless (featurep 'kemacs-kconfig)
    (ert-skip "kemacs-kconfig.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((outside (make-temp-file "kemacs-kconfig-outside-" t))
           (outside-target
            (kemacs-test--write-file outside "Kconfig" "config OUTSIDE\n"))
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
                (should-error (kemacs-kconfig-follow-source)
                              :type 'user-error))))
        (delete-directory outside t)))))

(ert-deftest kemacs-test/qemu-argv-expands-profile-tokens-without-splitting ()
  (unless (featurep 'kemacs-debug)
    (ert-skip "kemacs-debug.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((kemacs-profiles
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
           (kemacs-default-profile "debug profile")
           (context (kemacs-resolve-context root))
           (output (directory-file-name (kemacs-context-output context))))
      (should
       (equal
        (kemacs-qemu-arguments context)
        (list
         "qemu-system-riscv64"
         "-kernel" (expand-file-name "arch/riscv/boot/Image" output)
         "-append"
         (format "profile=debug profile root=%s" (directory-file-name root))
         "-device"
         (concat "loader,file=" (expand-file-name "symbols/vmlinux" output))
         (concat "--output=" output)))))))

(ert-deftest kemacs-test/qemu-argv-rejects-missing-or-non-string-items ()
  (unless (featurep 'kemacs-debug)
    (ert-skip "kemacs-debug.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let ((context (kemacs--make-context
                    :root (file-name-as-directory root)
                    :profile "broken"
                    :output (file-name-as-directory root)
                    :arch "x86_64")))
      (should-error (kemacs-qemu-arguments context) :type 'user-error)
      (setf (kemacs-context-qemu-command context) '("qemu-system-x86_64" 42))
      (should-error (kemacs-qemu-arguments context) :type 'user-error))))

(ert-deftest kemacs-test/vng-build-run-debug-preview-exec-argv-is-exact ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((output (file-name-as-directory
                    (expand-file-name "vng-output" root)))
           (guest-root (file-name-as-directory
                        (expand-file-name "guest-root" root)))
           (context
            (kemacs--make-context
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
             :vng-make-arguments '("LOCALVERSION=-kemacs test;$(nope)"
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
      (cl-letf (((symbol-function 'kemacs-vng--native-architecture)
                 (lambda () "amd64")))
        (should
         (equal
          (kemacs-vng-command-arguments 'build context)
          (list "--build"
                "--arch" "riscv64"
                "--cross-compile" "riscv64-linux-gnu-"
                "--jobs" "7"
                "--verbose" "--skip-modules"
                "--"
                (concat "O=" output-name)
                "LLVM=1"
                "LOCALVERSION=-kemacs test;$(nope)"
                "KCFLAGS=-DVALUE=a b")))
        (should
         (equal (kemacs-vng-command-arguments 'run context)
                (append run-common append-arguments)))
        (should
         (equal (kemacs-vng-command-arguments 'debug context)
                (append run-common '("--disable-kvm")
                        append-arguments '("--debug"))))
        (should
         (equal (kemacs-vng-command-arguments 'preview context)
                (append run-common append-arguments '("--dry-run"))))
        (should
         (equal (kemacs-vng-command-arguments 'exec context guest-command)
                (append run-common append-arguments
                        (list "--exec" guest-command)))))
      (should-not (file-exists-p (expand-file-name "not-run" root))))))

(ert-deftest kemacs-test/vng-profile-fields-resolve-into-context-and-argv ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((kemacs-profiles
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
           (kemacs-default-profile "virt profile")
           (output (file-name-as-directory
                    (expand-file-name "profile-output" root)))
           (guest-root (file-name-as-directory
                        (expand-file-name "root-fs" root))))
      (make-directory output t)
      (make-directory guest-root t)
      (let ((context (kemacs-resolve-context root)))
        (should (equal (kemacs-context-profile context) "virt profile"))
        (should (equal (kemacs-context-output context) output))
        (should (equal (kemacs-context-vng-root context) guest-root))
        (should (equal (kemacs-context-vng-append context)
                       '("panic=1" "console=ttyAMA0 earlycon")))
        (should
         (equal
          (kemacs-vng-command-arguments 'debug context)
          (list "--run" (directory-file-name output)
                "--arch" "arm64"
                "--root" (directory-file-name guest-root)
                "--memory" "3072M"
                "--disable-kvm"
                "--append" "panic=1"
                "--append" "console=ttyAMA0 earlycon"
                "--debug")))))))

(ert-deftest kemacs-test/vng-profile-validation-blocks-managed-overrides ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let ((base
           (kemacs--make-context
            :root (file-name-as-directory root)
            :profile "validation"
            :output (file-name-as-directory root)
            :compiler 'auto
            :jobs nil)))
      (dolist (case
               (list
                (cons 'run
                      (lambda (context)
                        (setf (kemacs-context-vng-arguments context)
                              '("--run=/tmp/other"))))
                (cons 'debug
                      (lambda (context)
                        (setf (kemacs-context-vng-debug-arguments context)
                              '("-rbad"))))
                (cons 'build
                      (lambda (context)
                        (setf (kemacs-context-vng-build-arguments context)
                              '("--"))))
                (cons 'build
                      (lambda (context)
                        (setf (kemacs-context-vng-make-arguments context)
                              '("O=/tmp/other"))))
                (cons 'run
                      (lambda (context)
                        (setf (kemacs-context-vng-append context) "panic=1")))
                (cons 'build
                      (lambda (context)
                        (setf (kemacs-context-vng-arch context) "mips64")))))
        (let ((context (copy-kemacs-context base)))
          (funcall (cdr case) context)
          (should-error (kemacs-vng-command-arguments (car case) context)
                        :type 'user-error)))
      (let ((context (copy-kemacs-context base)))
        (setf (kemacs-context-output context) "relative-output")
        (should-error (kemacs-vng-command-arguments 'run context)
                      :type 'user-error)))))

(ert-deftest kemacs-test/vng-cross-architecture-requires-existing-root ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((context
            (kemacs--make-context
             :root (file-name-as-directory root)
             :profile "cross"
             :output (file-name-as-directory root)
             :arch "riscv"
             :cross-compile "riscv64-linux-gnu-"
             :compiler 'auto
             :jobs nil))
           (guest-root (file-name-as-directory
                        (expand-file-name "existing-root" root))))
      (cl-letf (((symbol-function 'kemacs-vng--native-architecture)
                 (lambda () "amd64")))
        (should-error (kemacs-vng-command-arguments 'run context)
                      :type 'user-error)
        (setf (kemacs-context-vng-root context)
              (file-name-as-directory
               (expand-file-name "missing root" root)))
        (should-error (kemacs-vng-command-arguments 'run context)
                      :type 'user-error)
        (make-directory guest-root t)
        (setf (kemacs-context-vng-root context) guest-root)
        (should
         (equal (kemacs-vng-command-arguments 'run context)
                (list "--run" (directory-file-name root)
                      "--arch" "riscv64"
                      "--root" (directory-file-name guest-root))))))))

(ert-deftest kemacs-test/vng-pass-through-parser-fails-closed ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let ((base
           (kemacs--make-context
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
        (let ((context (copy-kemacs-context base)))
          (setf (kemacs-context-vng-arguments context) arguments)
          (should-error (kemacs-vng-command-arguments 'run context)
                        :type 'user-error)))
      (let ((context (copy-kemacs-context base)))
        (setf (kemacs-context-vng-build-arguments context) '("--memory=2G"))
        (should-error (kemacs-vng-command-arguments 'build context)
                      :type 'user-error))
      (let ((context (copy-kemacs-context base)))
        (setf (kemacs-context-vng-arguments context)
              '("--memory=2G" "--pin=0,1" "--rwdir=/tmp/shared"))
        (should
         (equal (kemacs-vng-command-arguments 'run context)
                (list "--run" (directory-file-name root)
                      "--memory=2G" "--pin=0,1"
                      "--rwdir=/tmp/shared")))))))

(ert-deftest kemacs-test/vng-architecture-requires-coherent-disambiguation ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let ((base
           (kemacs--make-context
            :root (file-name-as-directory root)
            :profile "architecture"
            :output (file-name-as-directory root)
            :compiler 'auto
            :jobs nil)))
      (cl-letf (((symbol-function 'kemacs-vng--native-architecture)
                 (lambda () "amd64"))
                ((symbol-function 'kemacs-native-arch)
                 (lambda () "x86")))
        (let ((context (copy-kemacs-context base)))
          (setf (kemacs-context-arch context) "x86")
          (should (equal (kemacs-vng-architecture context) "amd64")))
        (let ((context (copy-kemacs-context base)))
          (setf (kemacs-context-arch context) "riscv")
          (should-error (kemacs-vng-architecture context) :type 'user-error)
          (setf (kemacs-context-vng-arch context) "riscv64")
          (should (equal (kemacs-vng-architecture context) "riscv64")))
        (let ((context (copy-kemacs-context base)))
          (setf (kemacs-context-cross-compile context)
                "aarch64-linux-gnu-")
          (should (equal (kemacs-vng-architecture context) "arm64")))
        (let ((context (copy-kemacs-context base)))
          (setf (kemacs-context-arch context) "arm64"
                (kemacs-context-vng-arch context) "riscv64")
          (should-error (kemacs-vng-architecture context) :type 'user-error))
        (let ((context (copy-kemacs-context base)))
          (setf (kemacs-context-arch context) "riscv"
                (kemacs-context-cross-compile context)
                "aarch64-linux-gnu-")
          (should-error (kemacs-vng-architecture context)
                        :type 'user-error))))))

(ert-deftest kemacs-test/vng-runtime-rejects-upstream-shell-unsafe-values ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (kemacs-test-with-fake-vng (program)
      (let* ((safe-output (file-name-as-directory
                           (expand-file-name "safe-output" root)))
             (unsafe-output (file-name-as-directory
                             (expand-file-name "unsafe output;dollar$" root)))
             (unsafe-root (file-name-as-directory
                           (expand-file-name "unsafe root;dollar$" root)))
             (base
              (kemacs--make-context
               :root (file-name-as-directory root)
               :profile "unsafe"
               :output safe-output
               :compiler 'auto
               :jobs nil))
             (cases
              (list
               (cons 'run
                     (lambda (context)
                       (setf (kemacs-context-output context) unsafe-output)))
               (cons 'run
                     (lambda (context)
                       (setf (kemacs-context-vng-root context) unsafe-root)))
               (cons 'run
                     (lambda (context)
                       (setf (kemacs-context-vng-arguments context)
                             '("--memory" "2 G"))))
               (cons 'debug
                     (lambda (context)
                       (setf (kemacs-context-vng-debug-arguments context)
                             '("--qemu-opts=a;b"))))))
             (spawned nil)
             (comp-enable-subr-trampolines nil))
        (ignore program)
        (make-directory safe-output t)
        (make-directory unsafe-output t)
        (make-directory unsafe-root t)
        (cl-letf (((symbol-function 'make-comint-in-buffer)
                   (lambda (&rest _arguments) (setq spawned t))))
          (dolist (case cases)
            (let ((context (copy-kemacs-context base)))
              (funcall (cdr case) context)
              (should-error
               (kemacs-vng--start-runtime (car case) context)
               :type 'user-error))))
        (should-not spawned)))))

(ert-deftest kemacs-test/vng-untrusted-default-options-block-launch ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (kemacs-test-with-fake-vng (program)
      (let* ((configuration
              (kemacs-test--write-file
               kemacs-vng-home-directory
               ".config/virtme-ng/virtme-ng.conf"
               "{\"default_opts\": {\"run\": \"host\", \"rw\": true}}\n"))
             (context
              (kemacs--make-context
               :root (file-name-as-directory root)
               :profile "default"
               :output (file-name-as-directory root)
               :compiler 'auto
               :jobs nil))
             (spawned nil)
             (comp-enable-subr-trampolines nil))
        (ignore configuration program)
        (cl-letf (((symbol-function 'make-comint-in-buffer)
                   (lambda (&rest _arguments) (setq spawned t))))
          (should-error (kemacs-vng--start-runtime 'run context)
                        :type 'user-error))
        (should-not spawned)
        (should-not (kemacs-vng-config-safe-p))
        (let ((kemacs-vng-trust-default-options t))
          (should-not (kemacs-vng-config-safe-p))
          (should-error (kemacs-vng--assert-config-safe)
                        :type 'user-error))))))

(ert-deftest kemacs-test/vng-trusted-defaults-drive-effective-safety-state ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (kemacs-test-with-fake-vng (program)
      (let* ((configuration
              (kemacs-test--write-file
               kemacs-vng-home-directory
               ".config/virtme-ng/virtme-ng.conf"
               (concat "{\"default_opts\": {"
                       "\"debug\": true, \"rw\": true, "
                       "\"console\": 2345, \"memory\": \"2G\"}}\n")))
             (kemacs-vng-trust-default-options t)
             (context
              (kemacs--make-context
               :root (file-name-as-directory root)
               :profile "trusted defaults"
               :output (file-name-as-directory root)
               :compiler 'auto
               :jobs nil))
             prompt
             (comp-enable-subr-trampolines nil))
        (ignore configuration program)
        (should (kemacs-vng-config-safe-p))
        (should (kemacs-vng--default-debug-value nil))
        (should
         (kemacs-vng--global-runtime-p
          (kemacs-vng-command-arguments 'run context)))
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (question) (setq prompt question) nil)))
          (let ((kemacs-vng-confirm-host-access t))
            (should-error
             (kemacs-vng--confirm-host-access
              (kemacs-vng-command-arguments 'run context))
             :type 'user-error)))
        (should (string-match-p (regexp-quote "--rw") prompt))
        (should (string-match-p (regexp-quote "--console") prompt))
        (kemacs-test--write-file
         kemacs-vng-home-directory ".config/virtme-ng/virtme-ng.conf"
         "{\"default_opts\": {\"debug\": false}}\n")
        (should-not (kemacs-vng--default-debug-value t))
        (should-not (kemacs-vng--global-runtime-p '("--debug")))))))

(ert-deftest kemacs-test/vng-trusted-defaults-reject-unsafe-values ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (kemacs-test-with-fake-vng (program)
      (let ((kemacs-vng-trust-default-options t))
        (ignore root program)
        (dolist (contents
                 '("{\"default_opts\": {\"unknown_future_option\": true}}\n"
                   "{\"default_opts\": {\"qemu\": \"evil;command\"}}\n"
                   "{\"default_opts\": {\"console\": 70000}}\n"
                   "{\"default_opts\": {\"rwdir\": \"/tmp/not-a-list\"}}\n"))
          (kemacs-test--write-file
           kemacs-vng-home-directory ".config/virtme-ng/virtme-ng.conf"
           contents)
          (should-not (kemacs-vng-config-safe-p))
          (should-error (kemacs-vng--assert-config-safe)
                        :type 'user-error))))))

(ert-deftest kemacs-test/vng-runtime-plan-allows-only-preflight-to-miss-output ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (kemacs-test-with-fake-vng (program)
      (let* ((output (file-name-as-directory
                      (expand-file-name "future-output" root)))
             (context
              (kemacs--make-context
               :root (file-name-as-directory root)
               :profile "future output"
               :output output
               :compiler 'auto
               :jobs nil))
             plan spawned)
        (ignore program)
        (should-not (file-exists-p output))
        (cl-letf (((symbol-function 'kemacs-vng-config-file)
                   (lambda () nil)))
          (setq plan (kemacs-vng--prepare-runtime 'run context nil t))
          (should
           (equal (plist-get plan :arguments)
                  (list "--run" (directory-file-name output))))
          (cl-letf (((symbol-function 'make-comint-in-buffer)
                     (lambda (&rest _arguments) (setq spawned t))))
            (should-error
             (kemacs-vng--start-runtime 'run context nil plan t)
             :type 'user-error)))
        (should-not spawned)))))

(ert-deftest kemacs-test/vng-runtime-plan-rejects-default-mutation-before-spawn ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (kemacs-test-with-fake-vng (program)
      (let* ((relative ".config/virtme-ng/virtme-ng.conf")
             (kemacs-vng-trust-default-options t)
             (context
              (kemacs--make-context
               :root (file-name-as-directory root)
               :profile "config snapshot"
               :output (file-name-as-directory root)
               :compiler 'auto
               :jobs nil))
             plan spawned prompted selected
             (comp-enable-subr-trampolines nil))
        (ignore program)
        (kemacs-test--write-file
         kemacs-vng-home-directory relative
         "{\"default_opts\": {\"memory\": \"1G\"}}\n")
        (setq plan (kemacs-vng--prepare-runtime 'run context))
        (kemacs-test--write-file
         kemacs-vng-home-directory relative
         "{\"default_opts\": {\"memory\": \"2G\"}}\n")
        (cl-letf (((symbol-function 'make-comint-in-buffer)
                   (lambda (&rest _arguments) (setq spawned t)))
                  ((symbol-function 'yes-or-no-p)
                   (lambda (&rest _arguments) (setq prompted t) t))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (&rest _arguments) (setq selected t))))
          (should-error
           (kemacs-vng--start-runtime 'run context nil plan t)
           :type 'user-error))
        (should-not spawned)
        (should-not prompted)
        (should-not selected)))))

(ert-deftest kemacs-test/vng-build-run-callback-is-early-exact-and-noninteractive ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (kemacs-test-with-fake-vng (program)
      (let* ((root (file-name-as-directory root))
             (context
              (kemacs--make-context
               :root root
               :profile "chained"
               :output root
               :compiler 'auto
               :jobs nil
               :vng-arguments '("--rw")))
             (success-buffer (generate-new-buffer " *kemacs-vng-build-zero*"))
             (failure-buffer (generate-new-buffer " *kemacs-vng-build-seven*"))
             (success-process
              (kemacs-test--make-exited-process success-buffer 0))
             (failure-process
              (kemacs-test--make-exited-process failure-buffer 7))
             active-buffer finish-status phase
             (prompt-count 0)
             (callback-prompt-count 0)
             (selection-count 0)
             (spawn-count 0)
             runtime-processes runtime-buffers
             (comp-enable-subr-trampolines nil))
        (ignore program)
        (with-current-buffer success-buffer
          (setq-local kemacs-compilation-process success-process))
        (with-current-buffer failure-buffer
          (setq-local kemacs-compilation-process failure-process))
        (unwind-protect
            (let ((kemacs-vng-confirm-host-access t))
              (cl-letf
                  (((symbol-function 'kemacs-vng-config-file)
                    (lambda () nil))
                   ((symbol-function 'kemacs-resolve-context)
                    (lambda (&optional _root) context))
                   ((symbol-function 'kemacs-vng--start-managed)
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
                      ;; launcher can return to `kemacs-vng-build-and-run'.
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
                                     "kemacs-vng-chained")
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
                (should (eq (kemacs-vng-build-and-run) success-buffer))
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
                (should (eq (kemacs-vng-build-and-run) failure-buffer))
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

(ert-deftest kemacs-test/vng-debug-conflicts-with-raw-qemu-endpoints ()
  (unless (and (featurep 'kemacs-virtme) (featurep 'kemacs-debug))
    (ert-skip "vng/QEMU integration is not present"))
  (kemacs-test-with-kernel-tree (root)
    (kemacs-test-with-fake-vng (program)
      (let* ((arguments
              '("-s"
                "-gdb" "tcp:127.0.0.1:001234,server=on"
                "-qmp=unix:run/qmp.sock,server=on"
                "-qmp=tcp:localhost:3636,server=on"))
             (resources (kemacs-qemu-runtime-resources arguments root))
             (owner-buffer (generate-new-buffer " *kemacs-qemu-endpoints*"))
             (owner
              (make-pipe-process
               :name (generate-new-buffer-name "kemacs-qemu-endpoints")
               :buffer owner-buffer
               :noquery t))
             (context
              (kemacs--make-context
               :root (file-name-as-directory root)
               :profile "endpoint conflict"
               :output (file-name-as-directory root)
               :compiler 'auto
               :jobs nil
               :vng-arguments '("--console=04444" "--ssh")))
             (comp-enable-subr-trampolines nil))
        (ignore program)
        (should
         (equal resources
                (list "tcp-port:1234"
                      (concat "unix-socket:"
                              (expand-file-name "run/qmp.sock" root))
                      "tcp-port:3636")))
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'kemacs-vng-config-file)
                         (lambda () nil)))
                (should
                 (equal
                  (plist-get (kemacs-vng--prepare-runtime 'debug context)
                             :resources)
                  '("tcp-port:1234" "tcp-port:3636"
                    "tcp-port:4444" "tcp-port:2222"))))

              (kemacs-test--write-file
               kemacs-vng-home-directory
               ".config/virtme-ng/virtme-ng.conf"
               (concat "{\"default_opts\": {"
                       "\"console\": 5555, \"ssh\": 6666}}\n"))
              (let ((kemacs-vng-trust-default-options t))
                (should
                 (equal
                  (plist-get (kemacs-vng--prepare-runtime 'run context)
                             :resources)
                  '("tcp-port:5555" "tcp-port:6666"))))

              (process-put owner 'kemacs-runtime-kind 'qemu)
              (kemacs-mark-process-runtime-resources owner resources)
              (cl-letf (((symbol-function 'kemacs-vng-config-file)
                         (lambda () nil)))
                (should-error
                 (kemacs-vng--prepare-runtime 'debug context)
                 :type 'user-error)))
          (when (process-live-p owner)
            (delete-process owner))
          (when (buffer-live-p owner-buffer)
            (kill-buffer owner-buffer)))))))

(ert-deftest kemacs-test/vng-debug-spawns-direct-argv-and-tags-ownership ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (kemacs-test-with-fake-vng (program)
      (let* ((root (file-name-as-directory root))
             (output (file-name-as-directory
                      (expand-file-name "runtime-output" root)))
             (context
              (kemacs--make-context
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
             (comp-enable-subr-trampolines nil))
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
                           :name (generate-new-buffer-name "kemacs-vng-debug")
                           :buffer candidate
                           :noquery t))
                    candidate))
                 ((symbol-function 'pop-to-buffer)
                  (lambda (candidate &rest _arguments) candidate)))
              (setq buffer (kemacs-vng--start-runtime 'debug context))
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
                        (directory-file-name kemacs-vng-home-directory))))
              (should (eq (buffer-local-value 'major-mode buffer)
                          'kemacs-vng-mode))
              (should (equal (process-get process 'kemacs-root) root))
              (should (equal (process-get process 'kemacs-profile)
                             "debug profile"))
              (should (eq (process-get process 'kemacs-runtime-kind) 'vng))
              (should (process-get process 'kemacs-vng-debug))
              (should (process-get process 'kemacs-vng-global))
              (should
               (equal (process-get process 'kemacs-runtime-resources)
                      '("tcp-port:1234" "tcp-port:3636")))
              (should
               (equal (process-get process 'kemacs-process-resource)
                      (kemacs-process-resource-key output)))
              (should (equal (process-get process 'kemacs-context) context))
              (should-not (process-query-on-exit-flag process)))
          (when (process-live-p process)
            (delete-process process))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest kemacs-test/vng-runtime-honors-canonical-output-lock ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (kemacs-test-with-fake-vng (program)
      (let* ((output (file-name-as-directory
                      (expand-file-name "owned-output" root)))
             (alias (expand-file-name "output-alias" root))
             (owner-buffer (generate-new-buffer " *kemacs-vng-build-owner*"))
             (owner
              (make-pipe-process
               :name (generate-new-buffer-name "kemacs-vng-build-owner")
               :buffer owner-buffer
               :noquery t))
             (context
              (kemacs--make-context
               :root (file-name-as-directory root)
               :profile "run"
               :output (file-name-as-directory alias)
               :compiler 'auto
               :jobs nil))
             (spawned nil)
             (comp-enable-subr-trampolines nil))
        (ignore program)
        (make-directory output t)
        (make-symbolic-link output alias)
        (unwind-protect
            (progn
              (kemacs-mark-process-resource owner-buffer output)
              (cl-letf (((symbol-function 'make-comint-in-buffer)
                         (lambda (&rest _arguments) (setq spawned t))))
                (should-error (kemacs-vng--start-runtime 'run context)
                              :type 'user-error))
              (should-not spawned))
          (when (process-live-p owner)
            (delete-process owner))
          (when (buffer-live-p owner-buffer)
            (kill-buffer owner-buffer)))))))

(ert-deftest kemacs-test/vng-debug-global-lock-crosses-worktrees ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (kemacs-test-with-fake-vng (program)
      (let* ((other-root (file-name-as-directory
                          (make-temp-file "kemacs-vng-other-root-" t)))
             (other-output (file-name-as-directory
                            (expand-file-name "output" other-root)))
             (owner-buffer (generate-new-buffer " *kemacs-vng-global-owner*"))
             (owner
              (make-pipe-process
               :name (generate-new-buffer-name "kemacs-vng-global-owner")
               :buffer owner-buffer
               :noquery t))
             (context
              (kemacs--make-context
               :root other-root
               :profile "other"
               :output other-output
               :compiler 'auto
               :jobs nil))
             (spawned nil)
             (comp-enable-subr-trampolines nil))
        (ignore root program)
        (make-directory other-output t)
        (process-put owner 'kemacs-runtime-kind 'vng)
        (process-put owner 'kemacs-root "/unrelated/kernel/")
        (process-put owner 'kemacs-profile "debug")
        (process-put owner 'kemacs-vng-global t)
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'make-comint-in-buffer)
                         (lambda (&rest _arguments) (setq spawned t))))
                (should-error (kemacs-vng--start-runtime 'debug context)
                              :type 'user-error))
              (should-not spawned))
          (when (process-live-p owner)
            (delete-process owner))
          (when (buffer-live-p owner-buffer)
            (kill-buffer owner-buffer))
          (ignore-errors (delete-directory other-root t)))))))

(ert-deftest kemacs-test/vng-orphan-remains-owned-and-stop-finds-it ()
  (unless (featurep 'kemacs-virtme)
    (ert-skip "kemacs-virtme.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "orphan-output" root)))
           (context
            (kemacs--make-context
             :root root
             :profile "default"
             :output output
             :compiler 'auto
             :jobs nil))
           (buffer (generate-new-buffer " *kemacs-vng-orphan*"))
           (process
            (make-pipe-process
             :name (generate-new-buffer-name "kemacs-vng-orphan")
             :buffer buffer
             :noquery t))
           interrupted
           (comp-enable-subr-trampolines nil))
      (make-directory output t)
      (unwind-protect
          (progn
            (kemacs-mark-process-context buffer root "default")
            (kemacs-mark-process-resource buffer output)
            (process-put process 'kemacs-runtime-kind 'vng)
            (process-put process 'kemacs-vng-debug nil)
            (process-put process 'kemacs-vng-global nil)
            (process-put process 'kemacs-context (copy-kemacs-context context))
            (set-process-buffer process nil)
            (kill-buffer buffer)
            (should (memq process (kemacs-vng-processes context)))
            (should (eq process (kemacs-resource-process output)))
            (cl-letf (((symbol-function 'interrupt-process)
                       (lambda (candidate &rest _arguments)
                         (setq interrupted candidate))))
              (with-temp-buffer
                (setq default-directory root)
                (kemacs-vng-stop)))
            (should (eq interrupted process)))
        (when (process-live-p process)
          (delete-process process))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest kemacs-test/vng-actions-and-prefix-keymap-are-discoverable ()
  (unless (and (featurep 'kemacs-virtme) (featurep 'kemacs-mode))
    (ert-skip "virtme mode integration is not present"))
  (dolist (entry '((vng-build kemacs-vng-build "Run")
                   (vng-run kemacs-vng-run "Run")
                   (vng-preview kemacs-vng-preview "Run")
                   (vng-debug kemacs-vng-debug "Debug")
                   (vng-stop kemacs-vng-stop "Run")))
    (let ((action
           (seq-find (lambda (candidate)
                       (eq (kemacs-action-id candidate) (nth 0 entry)))
                     (kemacs-actions t))))
      (should action)
      (should (eq (kemacs-action-command action) (nth 1 entry)))
      (should (equal (kemacs-action-group action) (nth 2 entry)))))
  (should (eq (lookup-key kemacs-command-map (kbd "v")) kemacs-vng-map))
  (dolist (binding '(("b" . kemacs-vng-build)
                     ("r" . kemacs-vng-run)
                     ("p" . kemacs-vng-preview)
                     ("d" . kemacs-vng-debug)
                     ("x" . kemacs-vng-stop)))
    (should (eq (lookup-key kemacs-vng-map (kbd (car binding)))
                (cdr binding)))))

(ert-deftest kemacs-test/navigation-xref-commands-and-prefix-bindings ()
  (unless (and (featurep 'kemacs-navigate) (featurep 'kemacs-mode))
    (ert-skip "navigation mode integration is not present"))
  (should (eq (lookup-key kemacs-command-map (kbd "n"))
              kemacs-navigation-map))
  (should (eq (lookup-key kemacs-navigation-map (kbd "d"))
              'kemacs-find-definition))
  (should (eq (lookup-key kemacs-navigation-map (kbd "r"))
              'kemacs-find-callers))
  (should (eq (lookup-key kemacs-navigation-map (kbd "b"))
              'kemacs-navigation-back))
  (let (calls)
    (cl-letf (((symbol-function 'xref-find-definitions)
               (lambda () (interactive) (push 'definition calls)))
              ((symbol-function 'xref-find-references)
               (lambda () (interactive) (push 'callers calls)))
              ((symbol-function 'xref-go-back)
               (lambda () (interactive) (push 'back calls))))
      (call-interactively #'kemacs-find-definition)
      (call-interactively #'kemacs-find-callers)
      (call-interactively #'kemacs-navigation-back))
    (should (equal (nreverse calls) '(definition callers back)))))

(ert-deftest kemacs-test/dispatcher-runs-available-and-rejects-hidden-action ()
  (unless (featurep 'kemacs-ui)
    (ert-skip "kemacs-ui.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let ((kemacs--actions nil)
          (kemacs-test--dispatch-count 0)
          (chosen-id 'run)
          ;; Replacing a primitive should not ask native compilation to emit
          ;; a trampoline into the user's cache during this isolated test.
          (comp-enable-subr-trampolines nil))
      (should (equal (kemacs-root) (file-name-as-directory root)))
      (kemacs-register-action 'run "Run probe" "Test"
                              #'kemacs-test--dispatch-command)
      (kemacs-register-action 'hidden "Hidden probe" "Test"
                              #'kemacs-test--dispatch-command
                              :predicate (lambda () nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _arguments)
                   (car
                    (seq-find
                     (lambda (candidate)
                       (eq (kemacs-action-id (cdr candidate)) chosen-id))
                     collection)))))
        (kemacs-dispatch)
        (should (= kemacs-test--dispatch-count 1))
        (setq chosen-id 'hidden)
        (should-error (kemacs-dispatch t) :type 'user-error)
        (should (= kemacs-test--dispatch-count 1))))))

(ert-deftest kemacs-test/dashboard-renders-health-and-action-availability ()
  (unless (featurep 'kemacs-ui)
    (ert-skip "kemacs-ui.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (kemacs-test--write-file root ".config" "CONFIG_KEMACS=y\n")
    (let ((kemacs--actions nil)
          (kemacs-profiles '(("default" :compiler auto :jobs nil))))
      (kemacs-register-action 'available "Available action" "Build" #'ignore
                              :description "Ready to run")
      (kemacs-register-action 'unavailable "Unavailable action" "Review"
                              #'ignore :predicate (lambda () nil))
      (with-temp-buffer
        (kemacs-dashboard-mode)
        (setq-local kemacs-dashboard-root (file-name-as-directory root))
        (cl-letf (((symbol-function 'kemacs--git-string)
                   (lambda (_root &rest arguments)
                     (if (equal arguments '("branch" "--show-current"))
                         "topic/test"
                       ""))))
          (kemacs-dashboard-refresh))
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-match-p "KEMACS // KERNEL FLIGHT DECK" text))
          (should (string-match-p "topic/test.*clean" text))
          (should (string-match-p "\\.config[[:space:]]+ready" text))
          (should (string-match-p "Compile DB[[:space:]]+missing" text))
          (should (string-match-p "Available action.*Ready to run" text))
          (should (string-match-p "Unavailable action" text)))
        (goto-char (point-min))
        (search-forward "Available action")
        (should (button-at (1- (point))))
        (search-forward "Unavailable action")
        (should-not (button-at (1- (point))))))))

(ert-deftest kemacs-test/dashboard-uses-origin-buffer-context ()
  (unless (featurep 'kemacs-ui)
    (ert-skip "kemacs-ui.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory
                    (expand-file-name "origin-output" root)))
           (origin (generate-new-buffer " *kemacs-dashboard-origin*"))
           (dashboard (generate-new-buffer " *kemacs-dashboard-context*"))
           (kemacs-profiles
            `(("default" :compiler auto :jobs nil)
              ("origin-profile" :compiler clang :jobs 3)))
           (kemacs--actions nil))
      (unwind-protect
          (progn
            (with-current-buffer origin
              (setq default-directory root)
              (setq-local kemacs-profile "origin-profile")
              (setq-local kemacs-output-directory output))
            (kemacs-register-action
             'origin-only "Origin-only action" "Build" #'ignore
             :predicate
             (lambda ()
               (and (equal kemacs-profile "origin-profile")
                    (equal kemacs-output-directory output))))
            (with-current-buffer dashboard
              (kemacs-dashboard-mode)
              (setq-local kemacs-dashboard-root root)
              (setq-local kemacs-dashboard-origin origin)
              (setq-local kemacs-root-override root)
              (setq default-directory root)
              (let ((context (kemacs--dashboard-context)))
                (should (equal (kemacs-context-profile context)
                               "origin-profile"))
                (should (equal (kemacs-context-output context) output)))
              (cl-letf (((symbol-function 'kemacs--git-string)
                         (lambda (&rest _arguments) "")))
                (kemacs-dashboard-refresh))
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (should (string-match-p "origin-profile" text))
                (should (string-match-p
                         (regexp-quote (directory-file-name output)) text)))
              (goto-char (point-min))
              (search-forward "Origin-only action")
              (should (button-at (1- (point))))))
        (when (buffer-live-p dashboard)
          (kill-buffer dashboard))
        (when (buffer-live-p origin)
          (kill-buffer origin))))))

(ert-deftest kemacs-test/impact-button-rejects-context-drift ()
  (unless (featurep 'kemacs-impact)
    (ert-skip "kemacs-impact.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (origin (generate-new-buffer " *kemacs-impact-origin*"))
           (report (generate-new-buffer " *kemacs-impact-report*"))
           expected
           button
           ran)
      (unwind-protect
          (progn
            (with-current-buffer origin
              (setq default-directory root)
              (setq expected (kemacs-resolve-context root)))
            (with-current-buffer report
              (setq-local kemacs-impact-root root)
              (setq-local kemacs-impact-origin origin)
              (setq-local kemacs-impact-context expected)
              (insert-text-button
               "run"
               'kemacs-impact-function (lambda () (setq ran t))
               'kemacs-impact-arguments nil
               'action #'ignore)
              (setq button (button-at (point-min)))
              (kemacs-impact--run-button button))
            (should ran)
            (setq ran nil)
            (with-current-buffer origin
              (setq-local kemacs-output-directory
                          (expand-file-name "changed-output" root)))
            (with-current-buffer report
              (should-error (kemacs-impact--run-button button)
                            :type 'user-error))
            (should-not ran))
        (when (buffer-live-p report)
          (kill-buffer report))
        (when (buffer-live-p origin)
          (kill-buffer origin))))))

(ert-deftest kemacs-test/mode-refuses-non-kernel-buffers-cleanly ()
  (unless (featurep 'kemacs-mode)
    (ert-skip "kemacs-mode.el is not present"))
  (let* ((outside (make-temp-file "kemacs-outside-" t))
         (kemacs--root-cache (make-hash-table :test #'equal))
         (kemacs-set-compile-command nil))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory (file-name-as-directory outside))
          (should-error (kemacs-mode 1) :type 'user-error)
          (should-not kemacs-mode)
          (should-not kemacs--saved-locals))
      (delete-directory outside t))))

(ert-deftest kemacs-test/mode-restores-c-buffer-style-on-disable ()
  (unless (featurep 'kemacs-mode)
    (ert-skip "kemacs-mode.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let ((kemacs-set-compile-command nil)
          (kemacs-apply-kernel-c-style t))
      (with-temp-buffer
        (c-mode)
        (setq default-directory (file-name-as-directory
                                 (expand-file-name "drivers/net" root)))
        (setq-local indent-tabs-mode nil)
        (setq-local tab-width 3)
        (setq-local c-basic-offset 2)
        (kemacs-mode 1)
        (should kemacs-mode)
        (should indent-tabs-mode)
        (should (= tab-width 8))
        (should (= c-basic-offset 8))
        (kemacs-mode -1)
        (should-not kemacs-mode)
        (should-not indent-tabs-mode)
        (should (= tab-width 3))
        (should (= c-basic-offset 2))))))

(ert-deftest kemacs-test/mode-restores-existing-compile-command ()
  (unless (featurep 'kemacs-mode)
    (ert-skip "kemacs-mode.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let ((kemacs-set-compile-command t)
          (kemacs-apply-kernel-c-style nil))
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root))
        (setq-local compile-command "make previous")
        (cl-letf (((symbol-function 'kemacs-refresh-compile-command)
                   (lambda (&optional _context)
                     (setq-local compile-command "make kemacs"))))
          (kemacs-mode 1)
          (should (equal compile-command "make kemacs"))
          (kemacs-mode -1))
        (should (equal compile-command "make previous"))))))

(ert-deftest kemacs-test/project-finder-returns-project-protocol-value ()
  (unless (featurep 'kemacs-mode)
    (ert-skip "kemacs-mode.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let ((project (kemacs-project-find
                    (expand-file-name "drivers/net" root))))
      (should (eq (car project) 'kemacs))
      (should (equal (project-root project)
                     (file-name-as-directory root))))))

(ert-deftest kemacs-test/build-environment-removes-checkout-path-shadow ()
  (unless (featurep 'kemacs-build)
    (ert-skip "kemacs-build.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((checkout-bin (file-name-as-directory
                          (expand-file-name "tools/bin" root)))
           (outside-bin (file-name-as-directory
                         (make-temp-file "kemacs-safe-path-" t)))
           (separator (if (characterp path-separator)
                          (char-to-string path-separator)
                        path-separator))
           (context (kemacs-resolve-context root))
           (kemacs-build-trusted-path-directories nil)
           (process-environment
            (list
             (concat "PATH="
                     (string-join
                      (list "" "." (directory-file-name checkout-bin)
                            (directory-file-name outside-bin))
                      separator))
             "KEMACS_TEST_KEEP=present")))
      (make-directory checkout-bin t)
      (kemacs-test--write-file checkout-bin "rg" "#!/bin/sh\nexit 99\n" #o755)
      (kemacs-test--write-file outside-bin "rg" "#!/bin/sh\nexit 0\n" #o755)
      (unwind-protect
          (let ((clean (kemacs-build-process-environment context)))
            (let ((process-environment clean))
              (should
               (equal (split-string (getenv "PATH")
                                    (regexp-quote separator) t)
                      (list (directory-file-name outside-bin))))
              (should (equal (getenv "KEMACS_TEST_KEEP") "present"))))
        (delete-directory outside-bin t)))))

(ert-deftest kemacs-test/navigation-resolves-rg-through-safe-tool-path ()
  (unless (featurep 'kemacs-navigate)
    (ert-skip "kemacs-navigate.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let (resolved invocation)
      (cl-letf (((symbol-function 'kemacs-tool-path)
                 (lambda (tool context)
                   (setq resolved (list tool context))
                   "/trusted/bin/rg"))
                ((symbol-function 'process-file)
                 (lambda (program infile destination display &rest arguments)
                   (setq invocation
                         (list program infile destination display arguments))
                   (insert "drivers/net/kemacs_dummy.c:7:needle here\n")
                   0)))
        (should
         (equal
          (kemacs--search-lines-with-rg "needle" '("*.c") root)
          (list (list (expand-file-name "drivers/net/kemacs_dummy.c" root)
                      7 "needle here")))))
      (should (equal (car resolved) "rg"))
      (should
       (equal (kemacs-context-root (cadr resolved))
              (file-name-as-directory root)))
      (should
       (equal invocation
              (list "/trusted/bin/rg" nil t nil
                    '("--line-number" "--no-heading" "--color" "never"
                      "--glob" "*.c" "--" "needle" ".")))))))

(ert-deftest kemacs-test/bare-tools-cannot-be-shadowed-by-the-kernel-tree ()
  (kemacs-test-with-kernel-tree (root)
    (let* ((name "kemacs-tree-shadow-candidate-71b2")
           (shadow (kemacs-test--write-file
                    root name "#!/bin/sh\nexit 0\n" #o755))
           (context (kemacs-resolve-context root))
           (path-only-directory (make-temp-file "kemacs-exec-path-" t))
           (exec-path (list path-only-directory)))
      (unwind-protect
          (progn
            (should-not (kemacs-tool-path name context))
            (should (equal (kemacs-tool-path (concat "./" name) context)
                           shadow)))
        (delete-directory path-only-directory t)))))

(ert-deftest kemacs-test/resource-locks-find-orphaned-cross-profile-processes ()
  (kemacs-test-with-kernel-tree (root)
    (let* ((resource (file-name-as-directory
                      (expand-file-name "build-output" root)))
           (buffer (generate-new-buffer " *kemacs-resource-owner*"))
           (process (make-pipe-process
                     :name (generate-new-buffer-name "kemacs-resource-owner")
                     :buffer buffer
                     :noquery t))
           (context (kemacs--make-context
                     :root (file-name-as-directory root)
                     :profile "default"
                     :output resource
                     :compiler 'auto))
           (comp-enable-subr-trampolines nil)
           interrupted)
      (make-directory resource t)
      (unwind-protect
          (progn
            (kemacs-mark-process-context
             buffer (file-name-as-directory root) "other-profile")
            (kemacs-mark-process-resource buffer resource)
            ;; Simulate killing a process buffer without killing its child.
            (set-process-buffer process nil)
            (kill-buffer buffer)
            (should-not (memq process (kemacs-running-processes context)))
            (should (memq process (kemacs-running-processes context t)))
            (should (eq process
                        (kemacs-resource-process
                         (expand-file-name "../build-output" resource))))
            (should-error (kemacs-assert-resource-available resource)
                          :type 'user-error)
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt collection &rest _arguments)
                         (caar collection)))
                      ((symbol-function 'interrupt-process)
                       (lambda (candidate &rest _arguments)
                         (setq interrupted candidate))))
              (with-temp-buffer
                (setq default-directory (file-name-as-directory root))
                (call-interactively #'kemacs-cancel-job)))
            (should (eq interrupted process)))
        (when (process-live-p process)
          (delete-process process))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest kemacs-test/build-environment-removes-ambient-selectors ()
  (unless (featurep 'kemacs-build)
    (ert-skip "kemacs-build.el is not present"))
  (let* ((selectors kemacs-build-sanitized-environment-variables)
         (process-environment
          (append (mapcar (lambda (name) (concat name "=host-value"))
                          selectors)
                  '("KEMACS_TEST_KEEP=present")))
         (clean (kemacs-build-process-environment)))
    (let ((process-environment clean))
      (dolist (name selectors)
        (should-not (getenv name)))
      (should (equal (getenv "KEMACS_TEST_KEEP") "present")))
    ;; Constructing the sanitized copy must not mutate the caller's binding.
    (should (equal (getenv "ARCH") "host-value"))))

(ert-deftest kemacs-test/build-start-uses-the-sanitized-environment ()
  (unless (featurep 'kemacs-build)
    (ert-skip "kemacs-build.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((context (kemacs--make-context
                     :root (file-name-as-directory root)
                     :profile "default"
                     :output (file-name-as-directory root)
                     :compiler 'auto))
           (process-environment
            '("ARCH=host-arch" "KBUILD_OUTPUT=/host/output"
              "KEMACS_TEST_KEEP=present"))
           observed)
      (cl-letf (((symbol-function 'kemacs-require-tool)
                 (lambda (&rest _arguments) "/usr/bin/make"))
                ((symbol-function 'kemacs-refresh-compile-command)
                 (lambda (&optional _context) "make"))
                ((symbol-function 'kemacs-start-command)
                 (lambda (&rest _arguments)
                   (setq observed (copy-sequence process-environment))
                   'kemacs-test-build-buffer)))
        (should (eq (kemacs-build--start "build" nil nil nil context)
                    'kemacs-test-build-buffer)))
      (let ((process-environment observed))
        (should-not (getenv "ARCH"))
        (should-not (getenv "KBUILD_OUTPUT"))
        (should (equal (getenv "KEMACS_TEST_KEEP") "present"))))))

(ert-deftest kemacs-test/kunit-directories-are-isolated-and-hash-distinct ()
  (unless (featurep 'kemacs-test)
    (ert-skip "kemacs-test.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((output (file-name-as-directory (expand-file-name "output" root)))
           (kemacs-kunit-build-directory nil)
           (default-context
            (kemacs--make-context
             :root (file-name-as-directory root) :profile "default"
             :output output :compiler 'auto))
           (slash-context
            (kemacs--make-context
             :root (file-name-as-directory root) :profile "topic/a"
             :output output :compiler 'auto))
           (space-context
            (kemacs--make-context
             :root (file-name-as-directory root) :profile "topic a"
             :output output :compiler 'auto))
           (default-dir (kemacs-kunit-resolve-build-directory
                         default-context))
           (slash-dir (kemacs-kunit-resolve-build-directory slash-context))
           (space-dir (kemacs-kunit-resolve-build-directory space-context)))
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

(ert-deftest kemacs-test/kunit-filter-cannot-be-an-option ()
  (unless (featurep 'kemacs-test)
    (ert-skip "kemacs-test.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let ((context (kemacs--make-context
                    :root (file-name-as-directory root)
                    :profile "default"
                    :output (file-name-as-directory root)
                    :compiler 'auto)))
      (dolist (filter '("--help" "-x" "suite\n--jobs=99"))
        (should-error (kemacs-kunit-arguments 'run context filter)
                      :type 'user-error))
      (should (member "suite.case*"
                      (kemacs-kunit-arguments
                       'run context "suite.case*"))))))

(ert-deftest kemacs-test/kselftest-collections-parse-plus-equals ()
  (unless (featurep 'kemacs-test)
    (ert-skip "kemacs-test.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (kemacs-test--write-file
     root "tools/testing/selftests/Makefile"
     (concat "TARGETS += net\n"
             "TARGETS = timers\n"
             "  TARGETS   +=   pidfd io_uring # supported subsets\n"
             "NOT_TARGETS += ignored\n"))
    (let ((context (kemacs-resolve-context root)))
      (should (equal (kemacs-kselftest-collections context)
                     '("io_uring" "net" "pidfd" "timers"))))))

(ert-deftest kemacs-test/sparse-nil-level-uses-customized-default ()
  (unless (featurep 'kemacs-build)
    (ert-skip "kemacs-build.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (ignore root)
    (let ((kemacs-build-sparse-level 2)
          (kemacs-build-default-target nil)
          observed)
      (cl-letf (((symbol-function 'kemacs-require-tool)
                 (lambda (&rest _arguments) "/usr/bin/sparse"))
                ((symbol-function 'kemacs-build--start)
                 (lambda (label targets &optional arguments mode context)
                   (setq observed
                         (list label targets arguments mode context)))))
        (kemacs-build-sparse nil))
      (should (equal observed '("sparse" nil ("C=2") nil nil))))))

(ert-deftest kemacs-test/review-ranges-reject-options-and-whitespace ()
  (unless (featurep 'kemacs-review)
    (ert-skip "kemacs-review.el is not present"))
  (dolist (range '("" "--cached" "HEAD main" "HEAD\nmain"))
    (should-error (kemacs-review--validate-range range) :type 'user-error))
  (should (equal (kemacs-review--validate-range "v6.10..HEAD")
                 "v6.10..HEAD")))

(ert-deftest kemacs-test/git-diff-failure-cleans-temporary-patch ()
  (unless (featurep 'kemacs-review)
    (ert-skip "kemacs-review.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (ignore root)
    (let ((real-make-temp-file (symbol-function 'make-temp-file))
          temporary)
      (cl-letf (((symbol-function 'make-temp-file)
                 (lambda (&rest arguments)
                   (setq temporary
                         (apply real-make-temp-file arguments))))
                ((symbol-function 'kemacs--git-path)
                 (lambda (&optional _context) "/usr/bin/git"))
                ((symbol-function 'process-file)
                 (lambda (&rest _arguments) 128)))
        (should-error (kemacs--write-git-diff '("--cached" "--binary"))
                      :type 'user-error))
      (should temporary)
      (should-not (file-exists-p temporary)))))

(ert-deftest kemacs-test/flymake-snapshot-widens-a-narrowed-buffer ()
  (unless (featurep 'kemacs-flymake)
    (ert-skip "kemacs-flymake.el is not present"))
  (kemacs-test-with-kernel-tree (root)
    (let* ((tool (expand-file-name "scripts/checkpatch.pl" root))
           (process (make-pipe-process
                     :name (generate-new-buffer-name "kemacs-flymake-wide")
                     :noquery t))
           temporary
           (full-text "first line\nvisible line\nlast line\n")
           (comp-enable-subr-trampolines nil))
      (set-file-modes tool #o755)
      (unwind-protect
          (with-temp-buffer
            (setq default-directory (file-name-as-directory root)
                  buffer-file-name
                  (expand-file-name "drivers/net/kemacs_dummy.c" root))
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
                    (kemacs-checkpatch-flymake
                     (lambda (&rest _arguments) nil)))
                  (should (buffer-narrowed-p))
                  (should
                   (equal (with-temp-buffer
                            (insert-file-contents-literally temporary)
                            (buffer-string))
                          full-text)))
              (kemacs-checkpatch-flymake--cancel)))
        (when (process-live-p process)
          (delete-process process))
        (when (and temporary (file-exists-p temporary))
          (delete-file temporary))))))

(ert-deftest kemacs-test/start-command-seeds-pinned-context-on-reused-buffer ()
  (kemacs-test-with-kernel-tree (root)
    (let* ((root (file-name-as-directory root))
           (output (file-name-as-directory (expand-file-name "new-output" root)))
           (old-output
            (file-name-as-directory (expand-file-name "old-output" root)))
           (context (kemacs--make-context
                     :root root :profile "pinned" :output output
                     :compiler 'auto))
           (buffer-name
            (format "*kemacs:%s:pinned:reuse*" (kemacs-root-id root)))
           (buffer (get-buffer-create buffer-name))
           observed)
      (make-directory output t)
      (make-directory old-output t)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (setq-local kemacs-process-root "/stale/root/")
              (setq-local kemacs-process-profile "stale")
              (setq-local kemacs-process-resource old-output))
            (cl-letf (((symbol-function 'compilation-start)
                       (lambda (command mode name-function)
                         (setq observed
                               (list command mode
                                     (funcall name-function mode)
                                     default-directory))
                         (with-current-buffer buffer
                           (should (equal kemacs-process-root root))
                           (should (equal kemacs-process-profile "pinned"))
                           (should
                            (equal kemacs-process-resource
                                   (kemacs-process-resource-key output))))
                         buffer)))
              (should
               (eq (kemacs-start-shell-command
                    "reuse" "echo pinned" root nil output context)
                   buffer)))
            (should (equal observed
                           (list "echo pinned" 'kemacs-compilation-mode
                                 buffer-name root))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest kemacs-test/compilation-reinitialization-preserves-ownership ()
  (with-temp-buffer
    (setq-local kemacs-process-root "/kernel/root/")
    (setq-local kemacs-process-profile "debug")
    (setq-local kemacs-process-resource "/kernel/output")
    (kemacs-compilation-mode)
    (should (equal kemacs-process-root "/kernel/root/"))
    (should (equal kemacs-process-profile "debug"))
    (should (equal kemacs-process-resource "/kernel/output"))))

(defun kemacs-test-checkdoc-batch ()
  "Check shipped Kemacs source files and exit nonzero on style warnings."
  (require 'checkdoc)
  (let ((files (sort (directory-files default-directory t
                                      "\\`kemacs.*\\.el\\'")
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

(provide 'kemacs-tests)

;;; kemacs-test.el ends here
