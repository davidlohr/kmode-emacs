;;; kmode-analyze.el --- Optional kernel static analysis -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: kmode-emacs contributors
;; Keywords: tools, c, linux
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Compact front ends for analysis facilities already integrated with Kbuild.
;; Every option is passed as an individual make argument, and external tools
;; are checked before a potentially expensive asynchronous job is started.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kmode-core)
(require 'kmode-build)

(defgroup kmode-analyze nil
  "Optional static-analysis commands for Linux kernel trees."
  :group 'kmode
  :prefix "kmode-analyze-")

(defcustom kmode-analyze-warning-level 1
  "Default Kbuild extra-warning level.

Levels 1 through 3 progressively enable noisier warning groups."
  :type '(choice (const 1) (const 2) (const 3))
  :group 'kmode-analyze)

(defcustom kmode-analyze-smatch-level 1
  "Default source-checking level for Smatch.

Level 1 checks files rebuilt by make.  Level 2 checks every source file
needed by the selected target."
  :type '(choice (const :tag "Check rebuilt files (C=1)" 1)
                 (const :tag "Check all files (C=2)" 2))
  :group 'kmode-analyze)

(defcustom kmode-analyze-smatch-program "smatch"
  "Smatch executable required by `kmode-analyze-smatch'."
  :type 'string
  :group 'kmode-analyze)

(defcustom kmode-analyze-spatch-program "spatch"
  "Coccinelle executable required by analysis commands."
  :type 'string
  :group 'kmode-analyze)

(defconst kmode-analyze-coccinelle-modes
  '(report context org patch chain rep+ctxt)
  "Coccinelle modes recognized by the kernel coccicheck script.")

(defun kmode-analyze--warning-level (level)
  "Validate and return Kbuild warning LEVEL."
  (unless (memq level '(1 2 3))
    (user-error "Kernel warning level must be 1, 2, or 3"))
  level)

(defun kmode-analyze--checker-level (level)
  "Validate and return a Kbuild source-checker LEVEL."
  (unless (memq level '(1 2))
    (user-error "Source-checking level must be 1 or 2"))
  level)

(defun kmode-analyze--program-value (program description)
  "Validate executable PROGRAM used for DESCRIPTION as one command token."
  (unless (and (stringp program)
               (string-match-p "\\`[[:alnum:]_./+-]+\\'" program)
               (not (string-prefix-p "-" program)))
    (user-error "%s executable is unsafe or invalid: %S"
                description program))
  program)

(defun kmode-analyze--coccinelle-mode (mode)
  "Validate and return Coccinelle MODE as a string."
  (let ((symbol (cond ((symbolp mode) mode)
                      ((stringp mode) (intern-soft mode)))))
    (unless (memq symbol kmode-analyze-coccinelle-modes)
      (user-error "Unsupported Coccinelle mode: %S" mode))
    (symbol-name symbol)))

(defun kmode-analyze--current-or-default-targets (&optional context)
  "Return the current object target in CONTEXT, or configured default goals."
  (or (and buffer-file-name
           (condition-case nil
               (list (kmode-build--current-object-target context))
             (user-error nil)))
      (kmode-build--default-targets)))

(defun kmode-analyze--kernel-target-p (target &optional context)
  "Return non-nil if TARGET has a rule in CONTEXT's top-level Makefile."
  (let* ((context (or context (and (kmode-root t)
                                   (kmode-resolve-context))))
         (makefile (and context
                        (expand-file-name "Makefile"
                                          (kmode-context-root context)))))
    (and makefile
         (file-readable-p makefile)
         (with-temp-buffer
           (insert-file-contents-literally makefile)
           (goto-char (point-min))
           (re-search-forward
            (format "^[^#:\n]*\\_<%s\\_>[^:\n]*:"
                    (regexp-quote target))
            nil t)))))

(defun kmode-analyze--safe-make-path (path description)
  "Reject make-sensitive characters in PATH used for DESCRIPTION."
  (when (string-match-p "[[:cntrl:]$]" path)
    (user-error "%s has characters unsafe for a make variable: %S"
                description path))
  path)

(defun kmode-analyze--directory-value (directory context)
  "Return safe root-relative DIRECTORY for Kbuild M= in CONTEXT."
  (when directory
    (let* ((root (kmode-context-root context))
           (absolute (file-name-as-directory
                      (expand-file-name directory root))))
      (unless (file-directory-p absolute)
        (user-error "Coccinelle directory does not exist: %s" absolute))
      (unless (or (kmode-build--same-directory-p absolute root)
                  (file-in-directory-p absolute root))
        (user-error "Coccinelle directory is outside kernel tree: %s"
                    absolute))
      (unless (kmode-build--same-directory-p absolute root)
        (kmode-analyze--safe-make-path
         (directory-file-name (file-relative-name absolute root))
         "Coccinelle directory")))))

(defun kmode-analyze--cocci-value (cocci context)
  "Return validated COCCI path for CONTEXT, preserving outside paths."
  (when cocci
    (let* ((root (kmode-context-root context))
           (absolute (expand-file-name cocci root))
           (value (if (file-in-directory-p absolute root)
                      (file-relative-name absolute root)
                    absolute)))
      (unless (and (file-regular-p absolute) (file-readable-p absolute))
        (user-error "Coccinelle semantic patch is not readable: %s"
                    absolute))
      (kmode-analyze--safe-make-path value "Coccinelle semantic patch"))))

(defun kmode-analyze-coccinelle-arguments
    (mode &optional directory cocci context)
  "Return coccicheck make arguments for MODE in CONTEXT.

DIRECTORY limits analysis through Kbuild's M= variable.  COCCI selects one
semantic patch.  Each result is one complete make variable assignment."
  (let* ((context (or context (kmode-resolve-context)))
         (directory (kmode-analyze--directory-value directory context))
         (cocci (kmode-analyze--cocci-value cocci context))
         (spatch (kmode-analyze--program-value
                  kmode-analyze-spatch-program "Coccinelle")))
    (append
     (list (concat "MODE=" (kmode-analyze--coccinelle-mode mode)))
     (unless (equal spatch "spatch")
       (list (concat "SPATCH=" spatch)))
     (when directory (list (concat "M=" directory)))
     (when cocci (list (concat "COCCI=" cocci))))))

(defun kmode-analyze--require-target (target context)
  "Require kernel Makefile TARGET in CONTEXT or signal an actionable error."
  (unless (kmode-analyze--kernel-target-p target context)
    (user-error "This kernel tree does not provide the `%s' make target"
                target)))

;;;###autoload
(defun kmode-analyze-warning-build (&optional level)
  "Build with Kbuild warning LEVEL, preferring the current object.

LEVEL defaults to `kmode-analyze-warning-level'.  With a prefix argument,
prompt for a level from 1 through 3.  If the current buffer has no Kbuild
object, build `kmode-build-default-target' instead."
  (interactive
   (list
    (if current-prefix-arg
        (read-number "Kernel warning level (1-3): "
                     kmode-analyze-warning-level)
      kmode-analyze-warning-level)))
  (setq level (kmode-analyze--warning-level
               (or level kmode-analyze-warning-level)))
  (let ((context (kmode-resolve-context)))
    (kmode-build--start
     (format "warnings-W%d" level)
     (kmode-analyze--current-or-default-targets context)
     (list (format "W=%d" level)))))

;;;###autoload
(defun kmode-analyze-smatch (&optional level)
  "Run Smatch at source-checking LEVEL on the current object or default build.

LEVEL defaults to `kmode-analyze-smatch-level'.  With a prefix argument,
prompt for level 1 or 2.  The checker runs with Smatch's kernel profile."
  (interactive
   (list
    (if current-prefix-arg
        (read-number "Smatch checking level (1 or 2): "
                     kmode-analyze-smatch-level)
      kmode-analyze-smatch-level)))
  (setq level (kmode-analyze--checker-level
               (or level kmode-analyze-smatch-level)))
  (let* ((context (kmode-resolve-context))
         (smatch (kmode-analyze--program-value
                  kmode-analyze-smatch-program "Smatch")))
    (kmode-require-tool smatch context)
    (kmode-build--start
     (format "smatch-C%d" level)
     (kmode-analyze--current-or-default-targets context)
     (list (format "C=%d" level)
           (format "CHECK=%s -p=kernel"
                   smatch)))))

(defun kmode-analyze--coccinelle-interactive-arguments ()
  "Read optional Coccinelle scope arguments after a prefix invocation."
  (if (not current-prefix-arg)
      (list nil nil)
    (let* ((context (kmode-resolve-context))
           (root (kmode-context-root context))
           (directory
            (when (y-or-n-p "Limit Coccinelle to the current directory? ")
              (if buffer-file-name
                  (file-name-directory buffer-file-name)
                default-directory)))
           (cocci
            (when (y-or-n-p "Run one specific semantic patch? ")
              (let ((start (expand-file-name "scripts/coccinelle/" root)))
                (read-file-name
                 "COCCI file: " (if (file-directory-p start) start root)
                 nil t nil
                 (lambda (path)
                   (or (file-directory-p path)
                       (and (file-readable-p path)
                            (string-suffix-p ".cocci" path)))))))))
      (list directory cocci))))

;;;###autoload
(defun kmode-analyze-coccinelle-report (&optional directory cocci)
  "Run the kernel's Coccinelle report asynchronously.

DIRECTORY, when non-nil, limits coccicheck with M=.  COCCI, when non-nil,
selects one semantic patch.  With a prefix argument, interactively choose
whether to use the current directory and whether to select a COCCI file.
This command always uses MODE=report and never applies generated patches."
  (interactive (kmode-analyze--coccinelle-interactive-arguments))
  (let* ((context (kmode-resolve-context))
         (spatch (kmode-analyze--program-value
                  kmode-analyze-spatch-program "Coccinelle")))
    (kmode-require-tool spatch context)
    (kmode-require-tool "scripts/coccicheck" context)
    (kmode-analyze--require-target "coccicheck" context)
    (kmode-build--start
     "coccinelle-report" '("coccicheck")
     (kmode-analyze-coccinelle-arguments
      'report directory cocci context))))

(defun kmode-analyze--clang-config-p (context)
  "Return non-nil for a Clang-selected or Clang-configured CONTEXT."
  (pcase (kmode-context-compiler context)
    ('clang t)
    ('gcc nil)
    (_
     (let ((config (expand-file-name ".config"
                                     (kmode-context-output context))))
       (and (file-readable-p config)
            (with-temp-buffer
              (insert-file-contents-literally config)
              (goto-char (point-min))
              (re-search-forward "^CONFIG_CC_IS_CLANG=y$" nil t)))))))

(defun kmode-analyze-clang-analyzer-available-p ()
  "Return non-nil when the active profile supports the Clang analyzer target."
  (condition-case nil
      (let* ((root (kmode-root t))
             (context (and root (kmode-resolve-context root))))
        (and context
             (kmode-build-available-p)
             (kmode-analyze--kernel-target-p "clang-analyzer" context)
             (kmode-analyze--clang-config-p context)
             (kmode-tool-path "scripts/clang-tools/run-clang-tools.py"
                               context)
             (kmode-tool-path "clang-tidy" context)
             (kmode-tool-path "python3" context)))
    (error nil)))

;;;###autoload
(defun kmode-analyze-clang-analyzer ()
  "Run the kernel's clang static-analyzer target asynchronously.

The active profile must select Clang, or an automatic profile must already
have a Clang-built `.config'.  The kernel helper uses clang-tidy's analyzer
checks over the generated compilation database."
  (interactive)
  (let ((context (kmode-resolve-context)))
    (kmode-analyze--require-target "clang-analyzer" context)
    (unless (kmode-analyze--clang-config-p context)
      (user-error "Clang analyzer needs a Clang profile; select :compiler clang"))
    (kmode-require-tool "scripts/clang-tools/run-clang-tools.py" context)
    (kmode-require-tool "clang-tidy" context)
    (kmode-require-tool "python3" context)
    (kmode-build--start "clang-analyzer" '("clang-analyzer"))))

(defun kmode-analyze--vmlinux (context)
  "Return CONTEXT's expected vmlinux path."
  (let ((configured (kmode-context-vmlinux context)))
    (if (and configured (file-name-absolute-p configured))
        configured
      (expand-file-name (or configured "vmlinux")
                        (kmode-context-output context)))))

(defun kmode-analyze--objdump-program (context)
  "Return the objdump program expected by CONTEXT's toolchain."
  (if (eq (kmode-context-compiler context) 'clang)
      "llvm-objdump"
    (concat (or (kmode-context-cross-compile context) "") "objdump")))

(defun kmode-analyze-checkstack-available-p ()
  "Return non-nil when checkstack can inspect the active profile's artifacts."
  (condition-case nil
      (let* ((root (kmode-root t))
             (context (and root (kmode-resolve-context root))))
        (and context
             (kmode-build-available-p)
             (kmode-analyze--kernel-target-p "checkstack" context)
             (file-readable-p (kmode-analyze--vmlinux context))
             (kmode-tool-path "scripts/checkstack.pl" context)
             (kmode-tool-path "perl" context)
             (kmode-tool-path (kmode-analyze--objdump-program context)
                               context)))
    (error nil)))

;;;###autoload
(defun kmode-analyze-checkstack ()
  "Run Kbuild's checkstack report on the active profile's built artifacts."
  (interactive)
  (let* ((context (kmode-resolve-context))
         (vmlinux (kmode-analyze--vmlinux context)))
    (kmode-analyze--require-target "checkstack" context)
    (unless (file-readable-p vmlinux)
      (user-error "No vmlinux at %s; build the active profile first" vmlinux))
    (kmode-require-tool "scripts/checkstack.pl" context)
    (kmode-require-tool "perl" context)
    (kmode-require-tool (kmode-analyze--objdump-program context) context)
    (kmode-build--start "checkstack" '("checkstack"))))

(defun kmode-analyze-smatch-available-p ()
  "Return non-nil when Smatch and kernel builds are available."
  (condition-case nil
      (let* ((root (kmode-root t))
             (context (and root (kmode-resolve-context root)))
             (smatch (kmode-analyze--program-value
                      kmode-analyze-smatch-program "Smatch")))
        (and context
             (kmode-build-available-p)
             (kmode-tool-path smatch context)))
    (error nil)))

(defun kmode-analyze-coccinelle-available-p ()
  "Return non-nil when the active kernel tree can run coccicheck."
  (condition-case nil
      (let* ((root (kmode-root t))
             (context (and root (kmode-resolve-context root)))
             (spatch (kmode-analyze--program-value
                      kmode-analyze-spatch-program "Coccinelle")))
        (and context
             (kmode-build-available-p)
             (kmode-analyze--kernel-target-p "coccicheck" context)
             (kmode-tool-path "scripts/coccicheck" context)
             (kmode-tool-path spatch context)))
    (error nil)))

(kmode-register-action
 'kmode-analyze-warning-build "Build with extra warnings" "Check"
 #'kmode-analyze-warning-build
 :predicate #'kmode-build-available-p
 :description "Build the current object or profile with Kbuild W=1")
(kmode-register-action
 'kmode-analyze-smatch "Run Smatch" "Check" #'kmode-analyze-smatch
 :predicate #'kmode-analyze-smatch-available-p
 :description "Run Smatch with its kernel profile through Kbuild")
(kmode-register-action
 'kmode-analyze-coccinelle "Run Coccinelle report" "Check"
 #'kmode-analyze-coccinelle-report
 :predicate #'kmode-analyze-coccinelle-available-p
 :description "Run semantic-patch reports for the tree or current directory")
(kmode-register-action
 'kmode-analyze-clang "Run Clang analyzer" "Check"
 #'kmode-analyze-clang-analyzer
 :predicate #'kmode-analyze-clang-analyzer-available-p
 :description "Analyze the Clang profile's compilation database")
(kmode-register-action
 'kmode-analyze-checkstack "Run checkstack" "Check"
 #'kmode-analyze-checkstack
 :predicate #'kmode-analyze-checkstack-available-p
 :description "Report large stack frames in vmlinux and modules")

(provide 'kmode-analyze)

;;; kmode-analyze.el ends here
