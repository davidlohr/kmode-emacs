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
(declare-function kmode--search-lines-with-rg "kmode-navigate")
(declare-function kmode-impact--run-button "kmode-impact")
(declare-function kmode-kselftest-collections "kmode-test")
(declare-function kmode-kunit-arguments "kmode-test")
(declare-function kmode-kunit-resolve-build-directory "kmode-test")
(declare-function kmode-review--validate-range "kmode-review")
(declare-function kmode--write-git-diff "kmode-review")
(declare-function kmode--config-at-point "kmode-navigate")
(declare-function kmode-find-callers "kmode-navigate")
(declare-function kmode-find-definition "kmode-navigate")
(declare-function kmode-find-kbuild "kmode-navigate")
(declare-function kmode--line-include "kmode-navigate")
(declare-function kmode-navigation-back "kmode-navigate")
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
(declare-function kmode-dashboard-mode "kmode-ui")
(declare-function kmode-dashboard-refresh "kmode-ui")
(declare-function kmode-dispatch "kmode-ui")
(declare-function kmode-mode "kmode-emacs")
(declare-function kmode-project-find "kmode-emacs")
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
(defvar kmode-mode)
(defvar kmode-kunit-build-directory)
(defvar kmode-set-compile-command)
(defvar kmode-command-map)
(defvar kmode-navigation-map)
(defvar kmode-vng-confirm-host-access)
(defvar kmode-vng-home-directory)
(defvar kmode-vng-map)
(defvar kmode-vng-program)
(defvar kmode-vng-trust-default-options)
(defvar kmode-checkpatch-flymake--output-buffer)
(defvar kmode-checkpatch-flymake--process)
(defvar kmode-checkpatch-flymake--report-function)
(defvar kmode-checkpatch-flymake--request)
(defvar kmode-checkpatch-flymake--started-flymake)
(defvar kmode-checkpatch-flymake--temporary-file)
(defvar kmode-checkpatch-flymake-mode)

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
              'kmode-find-callers))
  (should (eq (lookup-key kmode-navigation-map (kbd "b"))
              'kmode-navigation-back))
  (let (calls)
    (cl-letf (((symbol-function 'xref-find-definitions)
               (lambda () (interactive) (push 'definition calls)))
              ((symbol-function 'xref-find-references)
               (lambda () (interactive) (push 'callers calls)))
              ((symbol-function 'xref-go-back)
               (lambda () (interactive) (push 'back calls))))
      (call-interactively #'kmode-find-definition)
      (call-interactively #'kmode-find-callers)
      (call-interactively #'kmode-navigation-back))
    (should (equal (nreverse calls) '(definition callers back)))))

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
          (should (string-match-p "Available action.*Ready to run" text))
          (should (string-match-p "Unavailable action" text)))
        (goto-char (point-min))
        (search-forward "Available action")
        (should (button-at (1- (point))))
        (search-forward "Unavailable action")
        (should-not (button-at (1- (point))))))))

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
