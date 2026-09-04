;;; kemacs-analyze.el --- Optional kernel static analysis -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Kemacs contributors
;; Keywords: tools, c, linux
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Compact front ends for analysis facilities already integrated with Kbuild.
;; Every option is passed as an individual make argument, and external tools
;; are checked before a potentially expensive asynchronous job is started.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'kemacs-core)
(require 'kemacs-build)

(defgroup kemacs-analyze nil
  "Optional static-analysis commands for Linux kernel trees."
  :group 'kemacs
  :prefix "kemacs-analyze-")

(defcustom kemacs-analyze-warning-level 1
  "Default Kbuild extra-warning level.

Levels 1 through 3 progressively enable noisier warning groups."
  :type '(choice (const 1) (const 2) (const 3))
  :group 'kemacs-analyze)

(defcustom kemacs-analyze-smatch-level 1
  "Default source-checking level for Smatch.

Level 1 checks files rebuilt by make.  Level 2 checks every source file
needed by the selected target."
  :type '(choice (const :tag "Check rebuilt files (C=1)" 1)
                 (const :tag "Check all files (C=2)" 2))
  :group 'kemacs-analyze)

(defcustom kemacs-analyze-smatch-program "smatch"
  "Smatch executable required by `kemacs-analyze-smatch'."
  :type 'string
  :group 'kemacs-analyze)

(defcustom kemacs-analyze-spatch-program "spatch"
  "Coccinelle executable required by analysis commands."
  :type 'string
  :group 'kemacs-analyze)

(defconst kemacs-analyze-coccinelle-modes
  '(report context org patch chain rep+ctxt)
  "Coccinelle modes recognized by the kernel coccicheck script.")

(defun kemacs-analyze--warning-level (level)
  "Validate and return Kbuild warning LEVEL."
  (unless (memq level '(1 2 3))
    (user-error "Kernel warning level must be 1, 2, or 3"))
  level)

(defun kemacs-analyze--checker-level (level)
  "Validate and return a Kbuild source-checker LEVEL."
  (unless (memq level '(1 2))
    (user-error "Source-checking level must be 1 or 2"))
  level)

(defun kemacs-analyze--program-value (program description)
  "Validate executable PROGRAM used for DESCRIPTION as one command token."
  (unless (and (stringp program)
               (string-match-p "\\`[[:alnum:]_./+-]+\\'" program)
               (not (string-prefix-p "-" program)))
    (user-error "%s executable is unsafe or invalid: %S"
                description program))
  program)

(defun kemacs-analyze--coccinelle-mode (mode)
  "Validate and return Coccinelle MODE as a string."
  (let ((symbol (cond ((symbolp mode) mode)
                      ((stringp mode) (intern-soft mode)))))
    (unless (memq symbol kemacs-analyze-coccinelle-modes)
      (user-error "Unsupported Coccinelle mode: %S" mode))
    (symbol-name symbol)))

(defun kemacs-analyze--current-or-default-targets (&optional context)
  "Return the current object target in CONTEXT, or configured default goals."
  (or (and buffer-file-name
           (condition-case nil
               (list (kemacs-build--current-object-target context))
             (user-error nil)))
      (kemacs-build--default-targets)))

(defun kemacs-analyze--kernel-target-p (target &optional context)
  "Return non-nil if TARGET has a rule in CONTEXT's top-level Makefile."
  (let* ((context (or context (and (kemacs-root t)
                                   (kemacs-resolve-context))))
         (makefile (and context
                        (expand-file-name "Makefile"
                                          (kemacs-context-root context)))))
    (and makefile
         (file-readable-p makefile)
         (with-temp-buffer
           (insert-file-contents-literally makefile)
           (goto-char (point-min))
           (re-search-forward
            (format "^[^#:\n]*\\_<%s\\_>[^:\n]*:"
                    (regexp-quote target))
            nil t)))))

(defun kemacs-analyze--safe-make-path (path description)
  "Reject make-sensitive characters in PATH used for DESCRIPTION."
  (when (string-match-p "[[:cntrl:]$]" path)
    (user-error "%s has characters unsafe for a make variable: %S"
                description path))
  path)

(defun kemacs-analyze--directory-value (directory context)
  "Return safe root-relative DIRECTORY for Kbuild M= in CONTEXT."
  (when directory
    (let* ((root (kemacs-context-root context))
           (absolute (file-name-as-directory
                      (expand-file-name directory root))))
      (unless (file-directory-p absolute)
        (user-error "Coccinelle directory does not exist: %s" absolute))
      (unless (or (kemacs-build--same-directory-p absolute root)
                  (file-in-directory-p absolute root))
        (user-error "Coccinelle directory is outside kernel tree: %s"
                    absolute))
      (unless (kemacs-build--same-directory-p absolute root)
        (kemacs-analyze--safe-make-path
         (directory-file-name (file-relative-name absolute root))
         "Coccinelle directory")))))

(defun kemacs-analyze--cocci-value (cocci context)
  "Return validated COCCI path for CONTEXT, preserving outside paths."
  (when cocci
    (let* ((root (kemacs-context-root context))
           (absolute (expand-file-name cocci root))
           (value (if (file-in-directory-p absolute root)
                      (file-relative-name absolute root)
                    absolute)))
      (unless (and (file-regular-p absolute) (file-readable-p absolute))
        (user-error "Coccinelle semantic patch is not readable: %s"
                    absolute))
      (kemacs-analyze--safe-make-path value "Coccinelle semantic patch"))))

(defun kemacs-analyze-coccinelle-arguments
    (mode &optional directory cocci context)
  "Return coccicheck make arguments for MODE in CONTEXT.

DIRECTORY limits analysis through Kbuild's M= variable.  COCCI selects one
semantic patch.  Each result is one complete make variable assignment."
  (let* ((context (or context (kemacs-resolve-context)))
         (directory (kemacs-analyze--directory-value directory context))
         (cocci (kemacs-analyze--cocci-value cocci context))
         (spatch (kemacs-analyze--program-value
                  kemacs-analyze-spatch-program "Coccinelle")))
    (append
     (list (concat "MODE=" (kemacs-analyze--coccinelle-mode mode)))
     (unless (equal spatch "spatch")
       (list (concat "SPATCH=" spatch)))
     (when directory (list (concat "M=" directory)))
     (when cocci (list (concat "COCCI=" cocci))))))

(defun kemacs-analyze--require-target (target context)
  "Require kernel Makefile TARGET in CONTEXT or signal an actionable error."
  (unless (kemacs-analyze--kernel-target-p target context)
    (user-error "This kernel tree does not provide the `%s' make target"
                target)))

;;;###autoload
(defun kemacs-analyze-warning-build (&optional level)
  "Build with Kbuild warning LEVEL, preferring the current object.

LEVEL defaults to `kemacs-analyze-warning-level'.  With a prefix argument,
prompt for a level from 1 through 3.  If the current buffer has no Kbuild
object, build `kemacs-build-default-target' instead."
  (interactive
   (list
    (if current-prefix-arg
        (read-number "Kernel warning level (1-3): "
                     kemacs-analyze-warning-level)
      kemacs-analyze-warning-level)))
  (setq level (kemacs-analyze--warning-level
               (or level kemacs-analyze-warning-level)))
  (let ((context (kemacs-resolve-context)))
    (kemacs-build--start
     (format "warnings-W%d" level)
     (kemacs-analyze--current-or-default-targets context)
     (list (format "W=%d" level)))))

;;;###autoload
(defun kemacs-analyze-smatch (&optional level)
  "Run Smatch at source-checking LEVEL on the current object or default build.

LEVEL defaults to `kemacs-analyze-smatch-level'.  With a prefix argument,
prompt for level 1 or 2.  The checker runs with Smatch's kernel profile."
  (interactive
   (list
    (if current-prefix-arg
        (read-number "Smatch checking level (1 or 2): "
                     kemacs-analyze-smatch-level)
      kemacs-analyze-smatch-level)))
  (setq level (kemacs-analyze--checker-level
               (or level kemacs-analyze-smatch-level)))
  (let* ((context (kemacs-resolve-context))
         (smatch (kemacs-analyze--program-value
                  kemacs-analyze-smatch-program "Smatch")))
    (kemacs-require-tool smatch context)
    (kemacs-build--start
     (format "smatch-C%d" level)
     (kemacs-analyze--current-or-default-targets context)
     (list (format "C=%d" level)
           (format "CHECK=%s -p=kernel"
                   smatch)))))

(defun kemacs-analyze--coccinelle-interactive-arguments ()
  "Read optional Coccinelle scope arguments after a prefix invocation."
  (if (not current-prefix-arg)
      (list nil nil)
    (let* ((context (kemacs-resolve-context))
           (root (kemacs-context-root context))
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
(defun kemacs-analyze-coccinelle-report (&optional directory cocci)
  "Run the kernel's Coccinelle report asynchronously.

DIRECTORY, when non-nil, limits coccicheck with M=.  COCCI, when non-nil,
selects one semantic patch.  With a prefix argument, interactively choose
whether to use the current directory and whether to select a COCCI file.
This command always uses MODE=report and never applies generated patches."
  (interactive (kemacs-analyze--coccinelle-interactive-arguments))
  (let* ((context (kemacs-resolve-context))
         (spatch (kemacs-analyze--program-value
                  kemacs-analyze-spatch-program "Coccinelle")))
    (kemacs-require-tool spatch context)
    (kemacs-require-tool "scripts/coccicheck" context)
    (kemacs-analyze--require-target "coccicheck" context)
    (kemacs-build--start
     "coccinelle-report" '("coccicheck")
     (kemacs-analyze-coccinelle-arguments
      'report directory cocci context))))

(defun kemacs-analyze--clang-config-p (context)
  "Return non-nil for a Clang-selected or Clang-configured CONTEXT."
  (pcase (kemacs-context-compiler context)
    ('clang t)
    ('gcc nil)
    (_
     (let ((config (expand-file-name ".config"
                                     (kemacs-context-output context))))
       (and (file-readable-p config)
            (with-temp-buffer
              (insert-file-contents-literally config)
              (goto-char (point-min))
              (re-search-forward "^CONFIG_CC_IS_CLANG=y$" nil t)))))))

(defun kemacs-analyze-clang-analyzer-available-p ()
  "Return non-nil when the active profile supports the Clang analyzer target."
  (condition-case nil
      (let* ((root (kemacs-root t))
             (context (and root (kemacs-resolve-context root))))
        (and context
             (kemacs-build-available-p)
             (kemacs-analyze--kernel-target-p "clang-analyzer" context)
             (kemacs-analyze--clang-config-p context)
             (kemacs-tool-path "scripts/clang-tools/run-clang-tools.py"
                               context)
             (kemacs-tool-path "clang-tidy" context)
             (kemacs-tool-path "python3" context)))
    (error nil)))

;;;###autoload
(defun kemacs-analyze-clang-analyzer ()
  "Run the kernel's clang static-analyzer target asynchronously.

The active profile must select Clang, or an automatic profile must already
have a Clang-built `.config'.  The kernel helper uses clang-tidy's analyzer
checks over the generated compilation database."
  (interactive)
  (let ((context (kemacs-resolve-context)))
    (kemacs-analyze--require-target "clang-analyzer" context)
    (unless (kemacs-analyze--clang-config-p context)
      (user-error "Clang analyzer needs a Clang profile; select :compiler clang"))
    (kemacs-require-tool "scripts/clang-tools/run-clang-tools.py" context)
    (kemacs-require-tool "clang-tidy" context)
    (kemacs-require-tool "python3" context)
    (kemacs-build--start "clang-analyzer" '("clang-analyzer"))))

(defun kemacs-analyze--vmlinux (context)
  "Return CONTEXT's expected vmlinux path."
  (let ((configured (kemacs-context-vmlinux context)))
    (if (and configured (file-name-absolute-p configured))
        configured
      (expand-file-name (or configured "vmlinux")
                        (kemacs-context-output context)))))

(defun kemacs-analyze--objdump-program (context)
  "Return the objdump program expected by CONTEXT's toolchain."
  (if (eq (kemacs-context-compiler context) 'clang)
      "llvm-objdump"
    (concat (or (kemacs-context-cross-compile context) "") "objdump")))

(defun kemacs-analyze-checkstack-available-p ()
  "Return non-nil when checkstack can inspect the active profile's artifacts."
  (condition-case nil
      (let* ((root (kemacs-root t))
             (context (and root (kemacs-resolve-context root))))
        (and context
             (kemacs-build-available-p)
             (kemacs-analyze--kernel-target-p "checkstack" context)
             (file-readable-p (kemacs-analyze--vmlinux context))
             (kemacs-tool-path "scripts/checkstack.pl" context)
             (kemacs-tool-path "perl" context)
             (kemacs-tool-path (kemacs-analyze--objdump-program context)
                               context)))
    (error nil)))

;;;###autoload
(defun kemacs-analyze-checkstack ()
  "Run Kbuild's checkstack report on the active profile's built artifacts."
  (interactive)
  (let* ((context (kemacs-resolve-context))
         (vmlinux (kemacs-analyze--vmlinux context)))
    (kemacs-analyze--require-target "checkstack" context)
    (unless (file-readable-p vmlinux)
      (user-error "No vmlinux at %s; build the active profile first" vmlinux))
    (kemacs-require-tool "scripts/checkstack.pl" context)
    (kemacs-require-tool "perl" context)
    (kemacs-require-tool (kemacs-analyze--objdump-program context) context)
    (kemacs-build--start "checkstack" '("checkstack"))))

(defun kemacs-analyze-smatch-available-p ()
  "Return non-nil when Smatch and kernel builds are available."
  (condition-case nil
      (let* ((root (kemacs-root t))
             (context (and root (kemacs-resolve-context root)))
             (smatch (kemacs-analyze--program-value
                      kemacs-analyze-smatch-program "Smatch")))
        (and context
             (kemacs-build-available-p)
             (kemacs-tool-path smatch context)))
    (error nil)))

(defun kemacs-analyze-coccinelle-available-p ()
  "Return non-nil when the active kernel tree can run coccicheck."
  (condition-case nil
      (let* ((root (kemacs-root t))
             (context (and root (kemacs-resolve-context root)))
             (spatch (kemacs-analyze--program-value
                      kemacs-analyze-spatch-program "Coccinelle")))
        (and context
             (kemacs-build-available-p)
             (kemacs-analyze--kernel-target-p "coccicheck" context)
             (kemacs-tool-path "scripts/coccicheck" context)
             (kemacs-tool-path spatch context)))
    (error nil)))

(kemacs-register-action
 'kemacs-analyze-warning-build "Build with extra warnings" "Check"
 #'kemacs-analyze-warning-build
 :predicate #'kemacs-build-available-p
 :description "Build the current object or profile with Kbuild W=1")
(kemacs-register-action
 'kemacs-analyze-smatch "Run Smatch" "Check" #'kemacs-analyze-smatch
 :predicate #'kemacs-analyze-smatch-available-p
 :description "Run Smatch with its kernel profile through Kbuild")
(kemacs-register-action
 'kemacs-analyze-coccinelle "Run Coccinelle report" "Check"
 #'kemacs-analyze-coccinelle-report
 :predicate #'kemacs-analyze-coccinelle-available-p
 :description "Run semantic-patch reports for the tree or current directory")
(kemacs-register-action
 'kemacs-analyze-clang "Run Clang analyzer" "Check"
 #'kemacs-analyze-clang-analyzer
 :predicate #'kemacs-analyze-clang-analyzer-available-p
 :description "Analyze the Clang profile's compilation database")
(kemacs-register-action
 'kemacs-analyze-checkstack "Run checkstack" "Check"
 #'kemacs-analyze-checkstack
 :predicate #'kemacs-analyze-checkstack-available-p
 :description "Report large stack frames in vmlinux and modules")

(provide 'kemacs-analyze)

;;; kemacs-analyze.el ends here
