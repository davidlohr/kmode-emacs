;;; kmode-build.el --- Profile-aware Linux kernel builds -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: kmode-emacs contributors
;; Keywords: tools, c, linux
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Safe, asynchronous front ends for the Linux kernel's Makefile.  Build
;; settings come from `kmode-context', so every command consistently honors
;; the selected architecture, toolchain, output tree, and parallelism.

;;; Code:

(require 'cl-lib)
(require 'compile)
(require 'term)
(require 'subr-x)
(require 'kmode-core)

(declare-function kmode-refresh-project-buffers "kmode-emacs"
                  (&optional root))
(declare-function kmode--refresh-tags-file-buffer "kmode-emacs" (file))

(defgroup kmode-build nil
  "Profile-aware Linux kernel build commands."
  :group 'kmode
  :prefix "kmode-build-")

(defcustom kmode-build-make-program "make"
  "Program used to invoke the kernel build system."
  :type 'string
  :group 'kmode-build)

(defcustom kmode-build-default-target nil
  "Target built by `kmode-build'.

Nil or an empty string asks the kernel Makefile to use its default target."
  :type '(choice (const :tag "Kernel default" nil)
                 (string :tag "Make target"))
  :group 'kmode-build)

(defcustom kmode-build-sparse-level 1
  "Kernel sparse checking level used by `kmode-build-sparse'.

Level 1 checks files that are rebuilt.  Level 2 checks all source files
needed for the requested target."
  :type '(choice (const :tag "Check rebuilt files (C=1)" 1)
                 (const :tag "Check all files (C=2)" 2))
  :group 'kmode-build)

(defcustom kmode-build-sanitized-environment-variables
  '("ARCH" "SRCARCH" "CROSS_COMPILE" "CROSS_COMPILE_COMPAT"
    "LLVM" "LLVM_IAS" "LLVM_SUFFIX" "CLANG_TRIPLE"
    "O" "KBUILD_OUTPUT" "KBUILD_SRC" "KCONFIG_CONFIG"
    "CC" "HOSTCC" "HOSTCXX" "MAKEFLAGS" "MFLAGS" "GNUMAKEFLAGS")
  "Environment variables removed from profile-managed build processes.

These variables can otherwise override the architecture, toolchain, output,
configuration, or Make behavior represented by a kmode-emacs context.
Represent managed architecture, toolchain, and output choices through profile
properties.  Use trusted `:make-arguments' only for other intentional Make
settings; `O' and `KBUILD_OUTPUT' assignments are rejected there because
`:output' owns the build directory."
  :type '(repeat string)
  :group 'kmode-build)

(defcustom kmode-build-trusted-path-directories nil
  "Checkout-contained PATH directories allowed in managed child processes.

Managed jobs normally remove empty, relative, and kernel-tree-contained PATH
entries so a checkout cannot shadow host tools used by Make or virtme-ng.
Every entry here must name an absolute directory and is an explicit trust
decision for kernel trees that intentionally provide executable tool shims."
  :type '(repeat directory)
  :group 'kmode-build)

(defvar kmode-build-target-history nil
  "History of targets entered through `kmode-build-target'.")

(defvar compile-history)

(defun kmode-build--safe-path (context)
  "Return a child PATH isolated from CONTEXT's source checkout."
  (when-let ((path (getenv "PATH")))
    (let* ((separator (if (characterp path-separator)
                          (char-to-string path-separator)
                        path-separator))
           (root (and context
                      (directory-file-name
                       (file-truename (kmode-context-root context)))))
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
                    kmode-build-trusted-path-directories)))
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

(defun kmode-build-process-environment (&optional context)
  "Return a process environment isolated from ambient build selectors.

CONTEXT, when non-nil, also removes untrusted PATH entries inside its source
checkout."
  (let ((process-environment (copy-sequence process-environment)))
    (dolist (variable kmode-build-sanitized-environment-variables)
      (setenv variable nil))
    (when-let ((safe-path (kmode-build--safe-path context)))
      (setenv "PATH" safe-path))
    process-environment))

(defun kmode-build--same-directory-p (left right)
  "Return non-nil when directory names LEFT and RIGHT denote the same path."
  (equal (directory-file-name (expand-file-name left))
         (directory-file-name (expand-file-name right))))

(defun kmode-build--strings (values purpose)
  "Validate VALUES as command arguments used for PURPOSE and return a copy."
  (mapcar
   (lambda (value)
     (unless (and (stringp value) (not (string-empty-p value)))
       (user-error "%s must contain non-empty strings, got %S"
                   purpose value))
     value)
   values))

(defun kmode-build--profile-make-arguments (values purpose)
  "Validate configured Make argument VALUES used for PURPOSE.

The profile output is a managed resource.  Callers must express it through
the context's `:output' property, never by replacing Kbuild's output selector."
  (let ((arguments (kmode-build--strings values purpose))
        (case-fold-search nil))
    (dolist (argument arguments)
      (when (string-match-p
             (concat "\\`[[:space:]]*\\(?:O\\|KBUILD_OUTPUT\\)"
                     "[[:space:]]*[+:?!]*=")
             argument)
        (user-error
         "%s cannot override managed output with %S; use profile :output"
         purpose argument)))
    arguments))

(defun kmode-build--target (target)
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

(defun kmode-build--targets (targets)
  "Validate TARGETS and return a new list."
  (mapcar #'kmode-build--target targets))

(defun kmode-build-make-arguments (context &optional targets extra-arguments)
  "Return a safe make argument vector for CONTEXT.

TARGETS is a list of Makefile goals.  EXTRA-ARGUMENTS is a list of trusted
make options or variable assignments for this invocation.  Architecture,
cross compiler, LLVM selection, output directory, job count, and profile
arguments are added automatically.  Each returned string is one process
argument; callers must not concatenate the result into an unquoted shell
command."
  (let* ((context (or context (kmode-resolve-context)))
         (root (kmode-context-root context))
         (output (kmode-context-output context))
         (arch (kmode-context-arch context))
         (cross-compile (kmode-context-cross-compile context))
         (compiler (kmode-context-compiler context))
         (jobs (kmode-context-jobs context))
         (profile-arguments
          (kmode-build--profile-make-arguments
           (or (kmode-context-make-arguments context) nil)
           "Profile make arguments"))
         (extra-arguments (kmode-build--profile-make-arguments
                           (or extra-arguments nil)
                           "Extra make arguments")))
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
     (unless (kmode-build--same-directory-p root output)
       (list (concat "O=" (directory-file-name output))))
     profile-arguments
     extra-arguments
     (kmode-build--targets (or targets nil)))))

(defun kmode-build-command (&optional context targets extra-arguments)
  "Return the shell command for a kernel build.

CONTEXT, TARGETS, and EXTRA-ARGUMENTS have the meanings documented by
`kmode-build-make-arguments'.  The result is suitable for `compile-command'
and safely quotes every process argument."
  (let* ((context (or context (kmode-resolve-context)))
         (program (kmode-require-tool kmode-build-make-program context)))
    (kmode-shell-command
     program
     (kmode-build-make-arguments context targets extra-arguments))))

(defun kmode-build--default-targets ()
  "Return the configured default target as a goal list."
  (if (and kmode-build-default-target
           (not (string-empty-p kmode-build-default-target)))
      (list (kmode-build--target kmode-build-default-target))
    nil))

(defun kmode-build--start
    (label targets &optional extra-arguments mode context finish-function)
  "Start a kernel build named LABEL for TARGETS.

EXTRA-ARGUMENTS are additional make arguments.  MODE, when non-nil, is
forwarded to `kmode-start-command'.  CONTEXT defaults to the current
resolved context and can pin a previously confirmed operation.
FINISH-FUNCTION receives the Compilation buffer and status after the
process exits and is retained by `kmode-recompile'."
  (let* ((context (or context (kmode-resolve-context)))
         (program (kmode-require-tool kmode-build-make-program context))
         (arguments
          (kmode-build-make-arguments context targets extra-arguments)))
    (kmode-refresh-compile-command context)
    (let ((process-environment (kmode-build-process-environment context)))
      (kmode-start-command label program arguments
                            (kmode-context-root context) mode
                            (kmode-context-output context) context
                            finish-function finish-function))))

(defun kmode-build--start-comint (label targets &optional extra-arguments)
  "Start an interactive kernel build named LABEL for TARGETS.

EXTRA-ARGUMENTS are additional make arguments.  Return the comint buffer."
  (let* ((context (kmode-resolve-context))
         (root (kmode-context-root context))
         (program (kmode-require-tool kmode-build-make-program context))
         (arguments (kmode-build-make-arguments
                     context targets extra-arguments))
         (name (format "kmode:%s:%s:%s"
                       (kmode-root-id root)
                       (kmode-context-profile context) label))
         (buffer-name (format "*%s*" name))
         (existing (get-buffer-process buffer-name))
         (default-directory root))
    (when (process-live-p existing)
      (user-error "Kmode-emacs command %s is already running" label))
    (kmode-assert-resource-available (kmode-context-output context))
    (let* ((process-environment (kmode-build-process-environment context))
           (buffer (apply #'make-term name program nil arguments)))
      (with-current-buffer buffer
        (term-mode)
        (term-char-mode))
      (kmode-mark-process-context buffer root
                                   (kmode-context-profile context))
      (kmode-mark-process-resource buffer (kmode-context-output context))
      (pop-to-buffer buffer)
      buffer)))

;;;###autoload
(defun kmode-refresh-compile-command (&optional context)
  "Refresh the buffer-local `compile-command' from CONTEXT.

When CONTEXT is nil, resolve it from the current buffer.  The command builds
`kmode-build-default-target', or the kernel's default target when that
option is nil.  Return the resulting command string."
  (interactive)
  (let* ((context (or context (kmode-resolve-context)))
         (command (kmode-build-command
                   context (kmode-build--default-targets))))
    (setq-local compile-command command)
    (when (called-interactively-p 'interactive)
      (message "Kmode-emacs compile command: %s" command))
    command))

;;;###autoload
(defun kmode-compile (command)
  "Run edited shell COMMAND as a profile-owned compilation job.

Unlike a raw `compile' invocation, this command sanitizes ambient Kbuild
selectors, uses a root/profile-specific buffer, and refuses to overlap the
active profile's output directory."
  (interactive
   (list (read-shell-command "Kmode-emacs compile command: "
                             compile-command 'compile-history)))
  (let* ((context (kmode-resolve-context))
         (root (kmode-context-root context))
         (output (kmode-context-output context))
         (process-environment (kmode-build-process-environment context)))
    (setq-local compile-command command)
    (kmode-start-shell-command
     "compile" command root nil output context)))

;;;###autoload
(defun kmode-build ()
  "Build the active profile's default kernel target asynchronously."
  (interactive)
  (kmode-build--start "build" (kmode-build--default-targets)))

;;;###autoload
(defun kmode-build-target (target)
  "Prompt for and asynchronously build kernel Makefile TARGET."
  (interactive
   (list
    (read-string "Kernel make target: " nil
                 'kmode-build-target-history
                 kmode-build-default-target)))
  (kmode-build--start (format "build-%s" target)
                       (list (kmode-build--target target))))

(defun kmode-build--current-object-target (&optional context)
  "Return the Kbuild object target for the current source in CONTEXT."
  (let* ((context (or context (kmode-resolve-context)))
         (relative (kmode-file-in-root nil context))
         (extension (file-name-extension relative)))
    (cond
     ((equal extension "o") relative)
     ((member extension '("c" "s" "S" "rs"))
      (concat (file-name-sans-extension relative) ".o"))
     (t
      (user-error "Current file is not a Kbuild source or object: %s"
                  relative)))))

;;;###autoload
(defun kmode-build-current-object ()
  "Build the Kbuild object corresponding to the current source file."
  (interactive)
  (let ((target (kmode-build--current-object-target)))
    (kmode-build--start "current-object" (list target))))

;;;###autoload
(defun kmode-build-current-file ()
  "Build the natural Kbuild object target for the current file.

For C, assembly, and Rust sources this compiles the corresponding `.o'
target.  An object file buffer rebuilds that object directly."
  (interactive)
  (kmode-build-current-object))

(defun kmode-build--current-directory-target (&optional context)
  "Return the Kbuild directory target at point for CONTEXT.

Return nil at the source root, which means the default build target."
  (let* ((context (or context (kmode-resolve-context)))
         (root (kmode-context-root context))
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
(defun kmode-build-current-directory ()
  "Build the current source directory's Kbuild target asynchronously."
  (interactive)
  (let ((target (kmode-build--current-directory-target)))
    (kmode-build--start "current-directory"
                         (and target (list target)))))

;;;###autoload
(defun kmode-build-defconfig ()
  "Generate the default kernel configuration for the active profile."
  (interactive)
  (kmode-build--start "defconfig" '("defconfig")))

;;;###autoload
(defun kmode-build-menuconfig ()
  "Open the kernel menu configuration for the active profile.

The command runs asynchronously in a Term buffer so its terminal user
interface can receive input."
  (interactive)
  (kmode-build--start-comint "menuconfig" '("menuconfig")))

;;;###autoload
(defun kmode-build-olddefconfig ()
  "Update an existing kernel configuration with defaults for new symbols."
  (interactive)
  (kmode-build--start "olddefconfig" '("olddefconfig")))

;;;###autoload
(defun kmode-build-compile-commands ()
  "Generate `compile_commands.json' for the active kernel build profile."
  (interactive)
  (kmode-build--start "compile-commands" '("compile_commands.json")))

(defun kmode-build--index-context (buffer)
  "Return BUFFER's root and output directories as a cons cell."
  (when (buffer-live-p buffer)
    (let ((root (or (buffer-local-value 'kmode-process-root buffer)
                    (with-current-buffer buffer (kmode-root t))))
          (output (buffer-local-value 'kmode-process-resource buffer)))
      (and root (cons root (or output root))))))

(defun kmode-build--readable-index-p (file)
  "Return non-nil when FILE is a readable regular index artifact."
  (and (file-regular-p file) (file-readable-p file)))

(defun kmode-build--tags-finished (buffer _status)
  "Refresh kernel buffers after a TAGS build in BUFFER finishes."
  (when-let ((context (kmode-build--index-context buffer)))
    (let* ((file (expand-file-name "TAGS" (cdr context)))
           (succeeded (kmode-compilation-succeeded-p buffer))
           (readable (kmode-build--readable-index-p file)))
      ;; A failed make can leave a truncated but readable TAGS file.  Keep the
      ;; last in-memory table in that case; only clear bindings when it is gone.
      (when (or succeeded (not readable))
        (when (fboundp 'kmode--refresh-tags-file-buffer)
          (kmode--refresh-tags-file-buffer file))
        (when (fboundp 'kmode-refresh-project-buffers)
          (kmode-refresh-project-buffers (car context))))
      (when succeeded
        (if readable
            (message "Kmode-emacs TAGS index is ready: %s"
                     (abbreviate-file-name file))
          (message
           "Kmode-emacs TAGS build finished, but no readable index exists: %s"
           (abbreviate-file-name file)))))))

(defun kmode-build--fresh-cscope-database-p (output)
  "Return non-nil when OUTPUT has a cscope database for its current file list."
  (let ((database (expand-file-name "cscope.out" output))
        (file-list (expand-file-name "cscope.files" output)))
    (and (kmode-build--readable-index-p database)
         (kmode-build--readable-index-p file-list)
         ;; The kernel rewrites cscope.files before invoking cscope.  If the
         ;; old database predates that list, the refresh did not complete.
         (not (file-newer-than-file-p file-list database)))))

(defun kmode-build--cscope-finished (buffer _status)
  "Report the cscope database path after a successful build in BUFFER."
  (when-let ((context (kmode-build--index-context buffer)))
    (let ((file (expand-file-name "cscope.out" (cdr context))))
      (when (kmode-compilation-succeeded-p buffer)
        (if (kmode-build--fresh-cscope-database-p (cdr context))
            (message "Kmode-emacs cscope database is ready: %s"
                     (abbreviate-file-name file))
          (message
           "Kmode-emacs cscope build finished, but no readable database exists: %s"
           (abbreviate-file-name file)))))))

;;;###autoload
(defun kmode-build-tags ()
  "Generate a kernel-aware TAGS table for the active build profile.

This invokes the kernel's own `make TAGS' target, whose `scripts/tags.sh'
understands kernel macros and generated constructs better than a generic
recursive Etags invocation."
  (interactive)
  (let ((context (kmode-resolve-context)))
    (kmode-require-tool "etags" context)
    (kmode-build--start "tags" '("TAGS") nil nil context
                        #'kmode-build--tags-finished)))

;;;###autoload
(defun kmode-build-cscope ()
  "Generate a kernel-aware cscope database for the active build profile."
  (interactive)
  (let ((context (kmode-resolve-context)))
    (kmode-require-tool "cscope" context)
    (kmode-build--start "cscope" '("cscope") nil nil context
                        #'kmode-build--cscope-finished)))

;;;###autoload
(defun kmode-build-sparse (&optional level)
  "Run the kernel sparse checker asynchronously at LEVEL.

LEVEL defaults to `kmode-build-sparse-level'.  With a prefix argument,
prompt for checking level 1 or 2."
  (interactive
   (list
    (if current-prefix-arg
        (read-number "Sparse checking level (1 or 2): "
                     kmode-build-sparse-level)
      kmode-build-sparse-level)))
  (setq level (or level kmode-build-sparse-level))
  (unless (memq level '(1 2))
    (user-error "Sparse checking level must be 1 or 2"))
  (kmode-require-tool "sparse" (kmode-resolve-context))
  (kmode-build--start "sparse" (kmode-build--default-targets)
                       (list (format "C=%d" level))))

;;;###autoload
(defun kmode-build-clean ()
  "Run `make clean' for the active profile after confirmation."
  (interactive)
  (let* ((context (kmode-resolve-context))
         (output (kmode-context-output context)))
    (unless (yes-or-no-p
             (format "Clean kernel build output in %s? "
                     (abbreviate-file-name output)))
      (user-error "Kernel clean cancelled"))
    (kmode-build--start "clean" '("clean") nil nil context)))

(defun kmode-build-available-p ()
  "Return non-nil when a kernel context and make program are available."
  (let ((root (kmode-root t)))
    (and root
         (kmode-tool-path kmode-build-make-program
                           (kmode-resolve-context root)))))

(defun kmode-build-current-file-available-p ()
  "Return non-nil for a buildable kernel file in the current buffer."
  (and buffer-file-name
       (kmode-root t)
       (condition-case nil
           (progn (kmode-build--current-object-target) t)
         (error nil))))

(defun kmode-build-sparse-available-p ()
  "Return non-nil when the active tree can run a Sparse build."
  (condition-case nil
      (let* ((root (kmode-root t))
             (context (and root (kmode-resolve-context root))))
        (and context
             (kmode-build-available-p)
             (kmode-tool-path "sparse" context)))
    (error nil)))

(defun kmode-build-index-available-p (tool)
  "Return non-nil when the active tree can build an index using TOOL."
  (condition-case nil
      (let* ((root (kmode-root t))
             (context (and root (kmode-resolve-context root))))
        (and context
             (kmode-build-available-p)
             (kmode-tool-path tool context)))
    (error nil)))

(kmode-register-action
 'kmode-build "Build kernel" "Build" #'kmode-build
 :predicate #'kmode-build-available-p
 :description "Build the selected profile's default target")
(kmode-register-action
 'kmode-compile "Compile edited command..." "Build" #'kmode-compile
 :predicate #'kmode-build-available-p
 :description "Edit and run a serialized command for the active output")
(kmode-register-action
 'kmode-build-target "Build target..." "Build" #'kmode-build-target
 :predicate #'kmode-build-available-p
 :description "Build one explicitly selected Kbuild target")
(kmode-register-action
 'kmode-build-current-file "Build current object" "Build"
 #'kmode-build-current-file
 :predicate #'kmode-build-current-file-available-p
 :description "Compile the object corresponding to the current source")
(kmode-register-action
 'kmode-build-current-directory "Build current directory" "Build"
 #'kmode-build-current-directory
 :predicate #'kmode-build-available-p
 :description "Build only the current Kbuild directory")
(kmode-register-action
 'kmode-build-sparse "Run sparse" "Check" #'kmode-build-sparse
 :predicate #'kmode-build-sparse-available-p
 :description "Run the kernel sparse static checker")
(kmode-register-action
 'kmode-build-compile-commands "Generate compile database" "Build"
 #'kmode-build-compile-commands
 :predicate #'kmode-build-available-p
 :description "Generate compile_commands.json for language tooling")
(kmode-register-action
 'kmode-build-tags "Generate/refresh TAGS" "Navigate" #'kmode-build-tags
 :predicate (lambda () (kmode-build-index-available-p "etags"))
 :description "Build a profile-aware Etags index with the kernel's tags script")
(kmode-register-action
 'kmode-build-cscope "Generate/refresh cscope" "Navigate"
 #'kmode-build-cscope
 :predicate (lambda () (kmode-build-index-available-p "cscope"))
 :description "Build a profile-aware cscope database with the kernel's tags script")
(kmode-register-action
 'kmode-build-defconfig "Generate defconfig" "Configure"
 #'kmode-build-defconfig
 :predicate #'kmode-build-available-p
 :description "Generate the architecture's default configuration")
(kmode-register-action
 'kmode-build-menuconfig "Open menuconfig" "Configure"
 #'kmode-build-menuconfig
 :predicate #'kmode-build-available-p
 :description "Edit the active build configuration interactively")
(kmode-register-action
 'kmode-build-olddefconfig "Run olddefconfig" "Configure"
 #'kmode-build-olddefconfig
 :predicate #'kmode-build-available-p
 :description "Accept defaults for newly introduced config symbols")
(kmode-register-action
 'kmode-build-clean "Clean build output" "Build" #'kmode-build-clean
 :predicate #'kmode-build-available-p
 :description "Clean the selected profile after confirmation")

(provide 'kmode-build)

;;; kmode-build.el ends here
