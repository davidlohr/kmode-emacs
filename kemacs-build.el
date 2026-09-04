;;; kemacs-build.el --- Profile-aware Linux kernel builds -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Kemacs contributors
;; Keywords: tools, c, linux
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Safe, asynchronous front ends for the Linux kernel's Makefile.  Build
;; settings come from `kemacs-context', so every command consistently honors
;; the selected architecture, toolchain, output tree, and parallelism.

;;; Code:

(require 'cl-lib)
(require 'compile)
(require 'term)
(require 'subr-x)
(require 'kemacs-core)

(defgroup kemacs-build nil
  "Profile-aware Linux kernel build commands."
  :group 'kemacs
  :prefix "kemacs-build-")

(defcustom kemacs-build-make-program "make"
  "Program used to invoke the kernel build system."
  :type 'string
  :group 'kemacs-build)

(defcustom kemacs-build-default-target nil
  "Target built by `kemacs-build'.

Nil or an empty string asks the kernel Makefile to use its default target."
  :type '(choice (const :tag "Kernel default" nil)
                 (string :tag "Make target"))
  :group 'kemacs-build)

(defcustom kemacs-build-sparse-level 1
  "Kernel sparse checking level used by `kemacs-build-sparse'.

Level 1 checks files that are rebuilt.  Level 2 checks all source files
needed for the requested target."
  :type '(choice (const :tag "Check rebuilt files (C=1)" 1)
                 (const :tag "Check all files (C=2)" 2))
  :group 'kemacs-build)

(defcustom kemacs-build-sanitized-environment-variables
  '("ARCH" "SRCARCH" "CROSS_COMPILE" "CROSS_COMPILE_COMPAT"
    "LLVM" "LLVM_IAS" "LLVM_SUFFIX" "CLANG_TRIPLE"
    "O" "KBUILD_OUTPUT" "KBUILD_SRC" "KCONFIG_CONFIG"
    "CC" "HOSTCC" "HOSTCXX" "MAKEFLAGS" "MFLAGS" "GNUMAKEFLAGS")
  "Environment variables removed from profile-managed build processes.

These variables can otherwise override the architecture, toolchain, output,
configuration, or Make behavior represented by a Kemacs context.  Put an
intentional override in a profile's `:make-arguments' instead."
  :type '(repeat string)
  :group 'kemacs-build)

(defcustom kemacs-build-trusted-path-directories nil
  "Checkout-contained PATH directories allowed in managed child processes.

Managed jobs normally remove empty, relative, and kernel-tree-contained PATH
entries so a checkout cannot shadow host tools used by Make or virtme-ng.
Every entry here must name an absolute directory and is an explicit trust
decision for kernel trees that intentionally provide executable tool shims."
  :type '(repeat directory)
  :group 'kemacs-build)

(defvar kemacs-build-target-history nil
  "History of targets entered through `kemacs-build-target'.")

(defvar compile-history)

(defun kemacs-build--safe-path (context)
  "Return a child PATH isolated from CONTEXT's source checkout."
  (when-let ((path (getenv "PATH")))
    (let* ((separator (if (characterp path-separator)
                          (char-to-string path-separator)
                        path-separator))
           (root (and context
                      (directory-file-name
                       (file-truename (kemacs-context-root context)))))
           (trusted
            (mapcar (lambda (directory)
                      (unless (and (stringp directory)
                                   (file-name-absolute-p directory))
                        (user-error
                         "Trusted child PATH directory must be absolute: %S"
                         directory))
                      (condition-case nil
                          (directory-file-name (file-truename directory))
                        (file-error (directory-file-name directory))))
                    kemacs-build-trusted-path-directories)))
      (mapconcat
       #'identity
       (seq-filter
        (lambda (directory)
          (and (not (string-empty-p directory))
               (file-name-absolute-p directory)
               (let ((canonical
                      (condition-case nil
                          (directory-file-name (file-truename directory))
                        (file-error (directory-file-name directory)))))
                 (or (null root)
                     (member canonical trusted)
                     (not (file-in-directory-p canonical root))))))
        (split-string path (regexp-quote separator)))
       separator))))

(defun kemacs-build-process-environment (&optional context)
  "Return a process environment isolated from ambient build selectors.

CONTEXT, when non-nil, also removes untrusted PATH entries inside its source
checkout."
  (let ((process-environment (copy-sequence process-environment)))
    (dolist (variable kemacs-build-sanitized-environment-variables)
      (setenv variable nil))
    (when-let ((safe-path (kemacs-build--safe-path context)))
      (setenv "PATH" safe-path))
    process-environment))

(defun kemacs-build--same-directory-p (left right)
  "Return non-nil when directory names LEFT and RIGHT denote the same path."
  (equal (directory-file-name (expand-file-name left))
         (directory-file-name (expand-file-name right))))

(defun kemacs-build--strings (values purpose)
  "Validate VALUES as command arguments used for PURPOSE and return a copy."
  (mapcar
   (lambda (value)
     (unless (and (stringp value) (not (string-empty-p value)))
       (user-error "%s must contain non-empty strings, got %S"
                   purpose value))
     value)
   values))

(defun kemacs-build--target (target)
  "Validate and return kernel Makefile TARGET.

Targets are deliberately more restrictive than arbitrary make arguments.
This keeps a value read at the minibuffer from being interpreted as an
option, assignment, or make expression."
  (unless (and (stringp target)
               (string-match-p
                "\\`[[:alnum:]_./+@%-]+\\'" target)
               (not (string-prefix-p "-" target))
               (not (string-prefix-p "/" target))
               (not (string-match-p
                     "\\(?:\\`\\|/\\)\\.\\.\\(?:/\\|\\'\\)" target)))
    (user-error "Unsafe or invalid kernel make target: %S" target))
  target)

(defun kemacs-build--targets (targets)
  "Validate TARGETS and return a new list."
  (mapcar #'kemacs-build--target targets))

(defun kemacs-build-make-arguments (context &optional targets extra-arguments)
  "Return a safe make argument vector for CONTEXT.

TARGETS is a list of Makefile goals.  EXTRA-ARGUMENTS is a list of trusted
make options or variable assignments for this invocation.  Architecture,
cross compiler, LLVM selection, output directory, job count, and profile
arguments are added automatically.  Each returned string is one process
argument; callers must not concatenate the result into an unquoted shell
command."
  (let* ((context (or context (kemacs-resolve-context)))
         (root (kemacs-context-root context))
         (output (kemacs-context-output context))
         (arch (kemacs-context-arch context))
         (cross-compile (kemacs-context-cross-compile context))
         (compiler (kemacs-context-compiler context))
         (jobs (kemacs-context-jobs context))
         (profile-arguments
          (kemacs-build--strings (or (kemacs-context-make-arguments context)
                                     nil)
                                 "Profile make arguments")))
    (unless (and (stringp root) (file-name-absolute-p root))
      (user-error "Kernel context has an invalid source root: %S" root))
    (unless (and (stringp output) (file-name-absolute-p output))
      (user-error "Kernel context has an invalid output directory: %S" output))
    (when (and arch (not (and (stringp arch) (not (string-empty-p arch)))))
      (user-error "Kernel ARCH must be a non-empty string, got %S" arch))
    (when (and cross-compile
               (not (and (stringp cross-compile)
                         (not (string-empty-p cross-compile)))))
      (user-error "Kernel CROSS_COMPILE must be a non-empty string, got %S"
                  cross-compile))
    (unless (memq compiler '(auto gcc clang))
      (user-error "Unsupported kernel compiler: %S" compiler))
    (when (and jobs (not (and (integerp jobs) (> jobs 0))))
      (user-error "Kernel job count must be positive, got %S" jobs))
    (append
     (when jobs (list (format "-j%d" jobs)))
     (when arch (list (concat "ARCH=" arch)))
     (when cross-compile (list (concat "CROSS_COMPILE=" cross-compile)))
     (when (eq compiler 'clang) '("LLVM=1"))
     (unless (kemacs-build--same-directory-p root output)
       (list (concat "O=" (directory-file-name output))))
     profile-arguments
     (kemacs-build--strings (or extra-arguments nil)
                            "Extra make arguments")
     (kemacs-build--targets (or targets nil)))))

(defun kemacs-build-command (&optional context targets extra-arguments)
  "Return the shell command for a kernel build.

CONTEXT, TARGETS, and EXTRA-ARGUMENTS have the meanings documented by
`kemacs-build-make-arguments'.  The result is suitable for `compile-command'
and safely quotes every process argument."
  (let* ((context (or context (kemacs-resolve-context)))
         (program (kemacs-require-tool kemacs-build-make-program context)))
    (kemacs-shell-command
     program
     (kemacs-build-make-arguments context targets extra-arguments))))

(defun kemacs-build--default-targets ()
  "Return the configured default target as a goal list."
  (if (and kemacs-build-default-target
           (not (string-empty-p kemacs-build-default-target)))
      (list (kemacs-build--target kemacs-build-default-target))
    nil))

(defun kemacs-build--start
    (label targets &optional extra-arguments mode context)
  "Start a kernel build named LABEL for TARGETS.

EXTRA-ARGUMENTS are additional make arguments.  MODE, when non-nil, is
forwarded to `kemacs-start-command'.  CONTEXT defaults to the current
resolved context and can pin a previously confirmed operation."
  (let* ((context (or context (kemacs-resolve-context)))
         (program (kemacs-require-tool kemacs-build-make-program context))
         (arguments
          (kemacs-build-make-arguments context targets extra-arguments)))
    (kemacs-refresh-compile-command context)
    (let ((process-environment (kemacs-build-process-environment context)))
      (kemacs-start-command label program arguments
                            (kemacs-context-root context) mode
                            (kemacs-context-output context) context))))

(defun kemacs-build--start-comint (label targets &optional extra-arguments)
  "Start an interactive kernel build named LABEL for TARGETS.

EXTRA-ARGUMENTS are additional make arguments.  Return the comint buffer."
  (let* ((context (kemacs-resolve-context))
         (root (kemacs-context-root context))
         (program (kemacs-require-tool kemacs-build-make-program context))
         (arguments (kemacs-build-make-arguments
                     context targets extra-arguments))
         (name (format "kemacs:%s:%s:%s"
                       (kemacs-root-id root)
                       (kemacs-context-profile context) label))
         (buffer-name (format "*%s*" name))
         (existing (get-buffer-process buffer-name))
         (default-directory root))
    (when (process-live-p existing)
      (user-error "Kemacs command %s is already running" label))
    (kemacs-assert-resource-available (kemacs-context-output context))
    (let* ((process-environment (kemacs-build-process-environment context))
           (buffer (apply #'make-term name program nil arguments)))
      (with-current-buffer buffer
        (term-mode)
        (term-char-mode))
      (kemacs-mark-process-context buffer root
                                   (kemacs-context-profile context))
      (kemacs-mark-process-resource buffer (kemacs-context-output context))
      (pop-to-buffer buffer)
      buffer)))

;;;###autoload
(defun kemacs-refresh-compile-command (&optional context)
  "Refresh the buffer-local `compile-command' from CONTEXT.

When CONTEXT is nil, resolve it from the current buffer.  The command builds
`kemacs-build-default-target', or the kernel's default target when that
option is nil.  Return the resulting command string."
  (interactive)
  (let* ((context (or context (kemacs-resolve-context)))
         (command (kemacs-build-command
                   context (kemacs-build--default-targets))))
    (setq-local compile-command command)
    (when (called-interactively-p 'interactive)
      (message "Kemacs compile command: %s" command))
    command))

;;;###autoload
(defun kemacs-compile (command)
  "Run edited shell COMMAND as a profile-owned compilation job.

Unlike a raw `compile' invocation, this command sanitizes ambient Kbuild
selectors, uses a root/profile-specific buffer, and refuses to overlap the
active profile's output directory."
  (interactive
   (list (read-shell-command "Kemacs compile command: "
                             compile-command 'compile-history)))
  (let* ((context (kemacs-resolve-context))
         (root (kemacs-context-root context))
         (output (kemacs-context-output context))
         (process-environment (kemacs-build-process-environment context)))
    (setq-local compile-command command)
    (kemacs-start-shell-command
     "compile" command root nil output context)))

;;;###autoload
(defun kemacs-build ()
  "Build the active profile's default kernel target asynchronously."
  (interactive)
  (kemacs-build--start "build" (kemacs-build--default-targets)))

;;;###autoload
(defun kemacs-build-target (target)
  "Prompt for and asynchronously build kernel Makefile TARGET."
  (interactive
   (list
    (read-string "Kernel make target: " nil
                 'kemacs-build-target-history
                 kemacs-build-default-target)))
  (kemacs-build--start (format "build-%s" target)
                       (list (kemacs-build--target target))))

(defun kemacs-build--current-object-target (&optional context)
  "Return the Kbuild object target for the current source in CONTEXT."
  (let* ((context (or context (kemacs-resolve-context)))
         (relative (kemacs-file-in-root nil context))
         (extension (file-name-extension relative)))
    (cond
     ((equal extension "o") relative)
     ((member extension '("c" "s" "S" "rs"))
      (concat (file-name-sans-extension relative) ".o"))
     (t
      (user-error "Current file is not a Kbuild source or object: %s"
                  relative)))))

;;;###autoload
(defun kemacs-build-current-object ()
  "Build the Kbuild object corresponding to the current source file."
  (interactive)
  (let ((target (kemacs-build--current-object-target)))
    (kemacs-build--start "current-object" (list target))))

;;;###autoload
(defun kemacs-build-current-file ()
  "Build the natural Kbuild object target for the current file.

For C, assembly, and Rust sources this compiles the corresponding `.o'
target.  An object file buffer rebuilds that object directly."
  (interactive)
  (kemacs-build-current-object))

(defun kemacs-build--current-directory-target (&optional context)
  "Return the Kbuild directory target at point for CONTEXT.

Return nil at the source root, which means the default build target."
  (let* ((context (or context (kemacs-resolve-context)))
         (root (kemacs-context-root context))
         (directory (file-name-as-directory
                     (expand-file-name
                      (if buffer-file-name
                          (file-name-directory buffer-file-name)
                        default-directory))))
         (relative (file-relative-name directory root)))
    (when (or (string-prefix-p "../" relative)
              (file-name-absolute-p relative))
      (user-error "%s is outside kernel tree %s" directory root))
    (unless (equal relative "./")
      (file-name-as-directory relative))))

;;;###autoload
(defun kemacs-build-current-directory ()
  "Build the current source directory's Kbuild target asynchronously."
  (interactive)
  (let ((target (kemacs-build--current-directory-target)))
    (kemacs-build--start "current-directory"
                         (and target (list target)))))

;;;###autoload
(defun kemacs-build-defconfig ()
  "Generate the default kernel configuration for the active profile."
  (interactive)
  (kemacs-build--start "defconfig" '("defconfig")))

;;;###autoload
(defun kemacs-build-menuconfig ()
  "Open the kernel menu configuration for the active profile.

The command runs asynchronously in a Term buffer so its terminal user
interface can receive input."
  (interactive)
  (kemacs-build--start-comint "menuconfig" '("menuconfig")))

;;;###autoload
(defun kemacs-build-olddefconfig ()
  "Update an existing kernel configuration with defaults for new symbols."
  (interactive)
  (kemacs-build--start "olddefconfig" '("olddefconfig")))

;;;###autoload
(defun kemacs-build-compile-commands ()
  "Generate `compile_commands.json' for the active kernel build profile."
  (interactive)
  (kemacs-build--start "compile-commands" '("compile_commands.json")))

;;;###autoload
(defun kemacs-build-sparse (&optional level)
  "Run the kernel sparse checker asynchronously at LEVEL.

LEVEL defaults to `kemacs-build-sparse-level'.  With a prefix argument,
prompt for checking level 1 or 2."
  (interactive
   (list
    (if current-prefix-arg
        (read-number "Sparse checking level (1 or 2): "
                     kemacs-build-sparse-level)
      kemacs-build-sparse-level)))
  (setq level (or level kemacs-build-sparse-level))
  (unless (memq level '(1 2))
    (user-error "Sparse checking level must be 1 or 2"))
  (kemacs-require-tool "sparse" (kemacs-resolve-context))
  (kemacs-build--start "sparse" (kemacs-build--default-targets)
                       (list (format "C=%d" level))))

;;;###autoload
(defun kemacs-build-clean ()
  "Run `make clean' for the active profile after confirmation."
  (interactive)
  (let* ((context (kemacs-resolve-context))
         (output (kemacs-context-output context)))
    (unless (yes-or-no-p
             (format "Clean kernel build output in %s? "
                     (abbreviate-file-name output)))
      (user-error "Kernel clean cancelled"))
    (kemacs-build--start "clean" '("clean") nil nil context)))

(defun kemacs-build-available-p ()
  "Return non-nil when a kernel context and make program are available."
  (let ((root (kemacs-root t)))
    (and root
         (kemacs-tool-path kemacs-build-make-program
                           (kemacs-resolve-context root)))))

(defun kemacs-build-current-file-available-p ()
  "Return non-nil for a buildable kernel file in the current buffer."
  (and buffer-file-name
       (kemacs-root t)
       (condition-case nil
           (progn (kemacs-build--current-object-target) t)
         (error nil))))

(defun kemacs-build-sparse-available-p ()
  "Return non-nil when the active tree can run a Sparse build."
  (condition-case nil
      (let* ((root (kemacs-root t))
             (context (and root (kemacs-resolve-context root))))
        (and context
             (kemacs-build-available-p)
             (kemacs-tool-path "sparse" context)))
    (error nil)))

(kemacs-register-action
 'kemacs-build "Build kernel" "Build" #'kemacs-build
 :predicate #'kemacs-build-available-p
 :description "Build the selected profile's default target")
(kemacs-register-action
 'kemacs-compile "Compile edited command..." "Build" #'kemacs-compile
 :predicate #'kemacs-build-available-p
 :description "Edit and run a serialized command for the active output")
(kemacs-register-action
 'kemacs-build-target "Build target..." "Build" #'kemacs-build-target
 :predicate #'kemacs-build-available-p
 :description "Build one explicitly selected Kbuild target")
(kemacs-register-action
 'kemacs-build-current-file "Build current object" "Build"
 #'kemacs-build-current-file
 :predicate #'kemacs-build-current-file-available-p
 :description "Compile the object corresponding to the current source")
(kemacs-register-action
 'kemacs-build-current-directory "Build current directory" "Build"
 #'kemacs-build-current-directory
 :predicate #'kemacs-build-available-p
 :description "Build only the current Kbuild directory")
(kemacs-register-action
 'kemacs-build-sparse "Run sparse" "Check" #'kemacs-build-sparse
 :predicate #'kemacs-build-sparse-available-p
 :description "Run the kernel sparse static checker")
(kemacs-register-action
 'kemacs-build-compile-commands "Generate compile database" "Build"
 #'kemacs-build-compile-commands
 :predicate #'kemacs-build-available-p
 :description "Generate compile_commands.json for language tooling")
(kemacs-register-action
 'kemacs-build-defconfig "Generate defconfig" "Configure"
 #'kemacs-build-defconfig
 :predicate #'kemacs-build-available-p
 :description "Generate the architecture's default configuration")
(kemacs-register-action
 'kemacs-build-menuconfig "Open menuconfig" "Configure"
 #'kemacs-build-menuconfig
 :predicate #'kemacs-build-available-p
 :description "Edit the active build configuration interactively")
(kemacs-register-action
 'kemacs-build-olddefconfig "Run olddefconfig" "Configure"
 #'kemacs-build-olddefconfig
 :predicate #'kemacs-build-available-p
 :description "Accept defaults for newly introduced config symbols")
(kemacs-register-action
 'kemacs-build-clean "Clean build output" "Build" #'kemacs-build-clean
 :predicate #'kemacs-build-available-p
 :description "Clean the selected profile after confirmation")

(provide 'kemacs-build)

;;; kemacs-build.el ends here
