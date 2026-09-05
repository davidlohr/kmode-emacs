;;; kmode-test.el --- KUnit and Kselftest integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: kmode-emacs contributors
;; Keywords: tools, c, linux, test
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Profile-aware front ends for the test runners shipped in the Linux kernel
;; tree.  KUnit is run through kunit.py; Kselftest subsets are built and run
;; through the kernel's kselftest target, which in turn uses its TAP runner.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'kmode-core)
(require 'kmode-build)

(defgroup kmode-test nil
  "Linux kernel testing commands."
  :group 'kmode
  :prefix "kmode-")

(defcustom kmode-kunit-python-program "python3"
  "Python interpreter used to run the kernel's KUnit script."
  :type 'string
  :group 'kmode-test)

(defcustom kmode-kunit-script "tools/testing/kunit/kunit.py"
  "KUnit runner path, relative to the kernel source root."
  :type 'string
  :group 'kmode-test)

(defcustom kmode-kunit-build-directory nil
  "Optional KUnit build directory.

An absolute value is used as written.  A relative value is resolved from the
kernel source root.  When nil, kmode-emacs creates an isolated `.kunit'
directory inside the profile output, with a unique profile suffix for
non-default profiles."
  :type '(choice (const :tag "Derive from active profile" nil)
                 (directory :tag "Build directory"))
  :group 'kmode-test)

(defcustom kmode-kunit-config nil
  "Optional KUnit configuration fragment or directory.

Relative paths are resolved from the kernel source root.  Nil lets kunit.py
manage `.kunitconfig' in the active KUnit build directory."
  :type '(choice (const :tag "Use build directory configuration" nil)
                 (file :tag "Configuration path"))
  :group 'kmode-test)

(defcustom kmode-kunit-filter nil
  "Optional default KUnit suite or test glob.

The value is passed as one argument to kunit.py, so shell wildcard expansion
cannot alter it."
  :type '(choice (const :tag "Run every configured test" nil)
                 (string :tag "Test glob"))
  :group 'kmode-test)

(defcustom kmode-kunit-extra-arguments nil
  "Additional trusted command-line arguments passed to kunit.py.

Each list item is passed as one argument."
  :type '(repeat string)
  :group 'kmode-test)

(defcustom kmode-kselftest-default-targets nil
  "Default Kselftest collections offered by `kmode-kselftest-run'."
  :type '(repeat string)
  :group 'kmode-test)

(defcustom kmode-kselftest-summary t
  "When non-nil, request Kselftest's concise summary output."
  :type 'boolean
  :group 'kmode-test)

(defcustom kmode-kselftest-force-targets t
  "When non-nil, fail if any requested Kselftest collection fails to build."
  :type 'boolean
  :group 'kmode-test)

(defvar kmode-kunit-filter-history nil
  "History of KUnit filters entered in the minibuffer.")

(defvar kmode-kunit-config-history nil
  "History of KUnit configuration paths entered in the minibuffer.")

(defvar kmode-kselftest-target-history nil
  "History of Kselftest collection selections.")

(defun kmode-test--nonempty-string (value description)
  "Validate VALUE as a non-empty string used for DESCRIPTION."
  (unless (and (stringp value) (not (string-empty-p value)))
    (user-error "%s must be a non-empty string, got %S" description value))
  value)

(defun kmode-test--profile-slug (profile)
  "Return PROFILE converted to a unique, safe build-directory suffix."
  (let ((slug (replace-regexp-in-string "[^[:alnum:]_.-]+" "-" profile)))
    (format "%s-%s"
            (if (string-empty-p slug) "profile" slug)
            (substring (secure-hash 'sha1 profile) 0 6))))

(defun kmode-kunit-resolve-build-directory (&optional context)
  "Return the absolute KUnit build directory for CONTEXT.

The derivation never reuses the normal Kbuild output directory itself, so
kunit.py cannot replace that profile's `.config' or ordinary artifacts."
  (let* ((context (or context (kmode-resolve-context)))
         (root (kmode-context-root context))
         (output (kmode-context-output context))
         (profile (kmode-context-profile context)))
    (file-name-as-directory
     (expand-file-name
      (cond
       (kmode-kunit-build-directory kmode-kunit-build-directory)
       ((equal profile kmode-default-profile)
        (expand-file-name ".kunit" output))
       (t
        (expand-file-name
         (format ".kunit-%s" (kmode-test--profile-slug profile))
         output)))
      root))))

(defun kmode-kunit--filter (filter)
  "Validate and return optional KUnit FILTER."
  (when (and filter (not (equal filter "")))
    (unless (and (stringp filter)
                 (not (string-prefix-p "-" filter))
                 (not (string-match-p "[[:cntrl:]]" filter)))
      (user-error "Unsafe or invalid KUnit filter: %S" filter))
    filter))

(defun kmode-kunit--config-path (config context)
  "Resolve optional KUnit CONFIG path against CONTEXT and validate it."
  (when (and config (not (string-empty-p config)))
    (let ((path (expand-file-name config (kmode-context-root context))))
      (unless (file-exists-p path)
        (user-error "KUnit configuration does not exist: %s" path))
      path)))

(defun kmode-kunit--make-options (context)
  "Return profile make options to forward through kunit.py for CONTEXT."
  (let ((compiler (kmode-context-compiler context))
        (profile-arguments (kmode-context-make-arguments context)))
    (unless (memq compiler '(auto gcc clang))
      (user-error "Unsupported kernel compiler: %S" compiler))
    (append
     (when (eq compiler 'clang) '("LLVM=1"))
     (mapcar
      (lambda (argument)
        (kmode-test--nonempty-string argument "KUnit make option"))
      profile-arguments))))

(defun kmode-kunit-arguments (subcommand &optional context filter config)
  "Build kunit.py arguments for SUBCOMMAND and CONTEXT.

SUBCOMMAND must be `run', `config', or `build'.  FILTER is an optional test
glob and is valid for `run' only.  CONFIG is an optional `.kunitconfig' file
or directory.  Profile architecture, cross compiler, compiler selection,
make options, job count, and build directory are forwarded automatically."
  (let* ((context (or context (kmode-resolve-context)))
         (subcommand-name
          (if (symbolp subcommand) (symbol-name subcommand) subcommand))
         (arch (kmode-context-arch context))
         (cross-compile (kmode-context-cross-compile context))
         (jobs (kmode-context-jobs context))
         (config (kmode-kunit--config-path config context))
         (filter (kmode-kunit--filter filter)))
    (unless (member subcommand-name '("run" "config" "build"))
      (user-error "Unsupported KUnit subcommand: %S" subcommand))
    (when (and filter (not (equal subcommand-name "run")))
      (user-error "A KUnit filter is only valid for the run subcommand"))
    (when arch
      (kmode-test--nonempty-string arch "KUnit architecture"))
    (when cross-compile
      (kmode-test--nonempty-string cross-compile
                                    "KUnit cross compiler"))
    (when (and jobs (not (and (integerp jobs) (> jobs 0))))
      (user-error "KUnit job count must be positive, got %S" jobs))
    (append
     (list subcommand-name
           (concat "--build_dir="
                   (directory-file-name
                    (kmode-kunit-resolve-build-directory context))))
     (when config (list (concat "--kunitconfig=" config)))
     (when arch (list (concat "--arch=" arch)))
     (when cross-compile
       (list (concat "--cross_compile=" cross-compile)))
     (mapcar (lambda (option) (concat "--make_options=" option))
             (kmode-kunit--make-options context))
     (when (and jobs (member subcommand-name '("run" "build")))
       (list (format "--jobs=%d" jobs)))
     (mapcar
      (lambda (argument)
        (kmode-test--nonempty-string argument "KUnit extra argument"))
      kmode-kunit-extra-arguments)
     (when filter (list filter)))))

(defun kmode-kunit--script (context)
  "Return the readable KUnit script path for CONTEXT or signal an error."
  (let ((script (expand-file-name kmode-kunit-script
                                  (kmode-context-root context))))
    (unless (file-readable-p script)
      (user-error "Kernel tree does not provide KUnit runner %s" script))
    script))

(defun kmode-kunit--start (subcommand label &optional filter config)
  "Start KUnit SUBCOMMAND asynchronously in a buffer named by LABEL.

FILTER and CONFIG are forwarded to `kmode-kunit-arguments'."
  (let* ((context (kmode-resolve-context))
         (python (kmode-require-tool kmode-kunit-python-program context))
         (script (kmode-kunit--script context))
         (arguments
          (cons script
                (kmode-kunit-arguments subcommand context filter config))))
    (let ((process-environment (kmode-build-process-environment context)))
      (kmode-start-command label python arguments
                            (kmode-context-root context) nil
                            (kmode-kunit-resolve-build-directory context)
                            context))))

;;;###autoload
(defun kmode-kunit-run (&optional filter config)
  "Run the active profile's KUnit suite after configuring and building it.

FILTER defaults to `kmode-kunit-filter'.  CONFIG defaults to
`kmode-kunit-config'.  Both values are passed as individual arguments to
the kernel-provided kunit.py runner."
  (interactive)
  (kmode-kunit--start 'run "kunit"
                       (or filter kmode-kunit-filter)
                       (or config kmode-kunit-config)))

;;;###autoload
(defun kmode-kunit-run-filter (filter)
  "Prompt for FILTER and run matching KUnit suites or test cases."
  (interactive
   (list
    (read-string "KUnit test glob: " kmode-kunit-filter
                 'kmode-kunit-filter-history)))
  (kmode-kunit-run
   (kmode-test--nonempty-string filter "KUnit filter")))

;;;###autoload
(defun kmode-kunit-run-config (config)
  "Prompt for CONFIG and run KUnit using that configuration fragment."
  (interactive
   (let* ((root (kmode-root))
          (initial (and kmode-kunit-config
                        (expand-file-name kmode-kunit-config root))))
     (list
      (read-file-name "KUnit configuration: " root initial t nil
                      (lambda (path)
                        (or (file-directory-p path)
                            (file-readable-p path)))))))
  (add-to-history 'kmode-kunit-config-history config)
  (kmode-kunit-run nil config))

;;;###autoload
(defun kmode-kunit-configure ()
  "Prepare the KUnit configuration for the active profile asynchronously."
  (interactive)
  (kmode-kunit--start 'config "kunit-config" nil kmode-kunit-config))

;;;###autoload
(defun kmode-kunit-build ()
  "Configure and build the KUnit kernel for the active profile."
  (interactive)
  (kmode-kunit--start 'build "kunit-build" nil kmode-kunit-config))

(defun kmode-kselftest-collections (&optional context)
  "Return Kselftest collection names declared by CONTEXT's kernel tree."
  (let* ((context (or context (kmode-resolve-context)))
         (makefile (expand-file-name "tools/testing/selftests/Makefile"
                                     (kmode-context-root context)))
         collections)
    (when (file-readable-p makefile)
      (with-temp-buffer
        (insert-file-contents makefile)
        (goto-char (point-min))
        (while (re-search-forward
                (concat "^[[:space:]]*TARGETS[[:space:]]*"
                        "\\(?:\\+=\\|=\\)[[:space:]]*\\([^#\n]+\\)")
                nil t)
          (dolist (name (split-string (match-string-no-properties 1)
                                      "[[:space:]]+" t))
            (when (string-match-p
                   "\\`[[:alnum:]_.+/-]+\\'" name)
              (push name collections))))))
    (sort (delete-dups collections) #'string-lessp)))

(defun kmode-kselftest--normalize-targets (targets)
  "Validate and normalize Kselftest TARGETS as collection names."
  (let ((targets
         (if (stringp targets)
             (split-string targets "[[:space:],]+" t)
           targets)))
    (unless targets
      (user-error "Select at least one Kselftest collection"))
    (mapcar
     (lambda (target)
       (setq target (string-trim target))
       (unless (and (string-match-p "\\`[[:alnum:]_.+/-]+\\'" target)
                    (not (string-prefix-p "/" target))
                    (not (string-match-p
                          "\\(?:\\`\\|/\\)\\.\\.\\(?:/\\|\\'\\)"
                          target)))
         (user-error "Unsafe or invalid Kselftest collection: %S" target))
       target)
     targets)))

(defun kmode-kselftest-read-targets ()
  "Read one or more Kselftest collection names with completion."
  (let* ((context (kmode-resolve-context))
         (candidates (kmode-kselftest-collections context))
         (default (mapconcat #'identity kmode-kselftest-default-targets ","))
         (selection
          (completing-read-multiple
           "Kselftest collections: " candidates nil nil nil
           'kmode-kselftest-target-history
           (unless (string-empty-p default) default))))
    (kmode-kselftest--normalize-targets selection)))

(defun kmode-kselftest--start (targets label)
  "Build and run Kselftest TARGETS asynchronously under LABEL."
  (let* ((context (kmode-resolve-context))
         (targets (kmode-kselftest--normalize-targets targets))
         (program (kmode-require-tool kmode-build-make-program context))
         (extra-arguments
          (append
           (list (concat "TARGETS=" (string-join targets " ")))
           (when kmode-kselftest-summary '("summary=1"))
           (when kmode-kselftest-force-targets '("FORCE_TARGETS=1"))))
         (arguments
          (kmode-build-make-arguments context '("kselftest")
                                       extra-arguments)))
    (let ((process-environment (kmode-build-process-environment context)))
      (kmode-start-command label program arguments
                            (kmode-context-root context) nil
                            (kmode-context-output context) context))))

;;;###autoload
(defun kmode-kselftest-run (targets)
  "Prompt for Kselftest collection TARGETS, then build and run that subset.

The active build profile is honored, including its output directory and
toolchain.  The top-level kernel `kselftest' target invokes the runner scripts
provided by the checked-out kernel rather than a kmode-emacs-specific harness."
  (interactive (list (kmode-kselftest-read-targets)))
  (kmode-kselftest--start targets "kselftest"))

(defun kmode-kselftest-current-collection (&optional context)
  "Return the Kselftest collection containing the current file in CONTEXT."
  (let ((relative (kmode-file-in-root nil
                                       (or context
                                           (kmode-resolve-context)))))
    (if (string-match
         "\\`tools/testing/selftests/\\([^/]+\\)\\(?:/\\|\\'\\)" relative)
        (match-string 1 relative)
      (user-error "Current file is not inside a Kselftest collection"))))

;;;###autoload
(defun kmode-kselftest-run-current ()
  "Build and run the Kselftest collection containing the current file."
  (interactive)
  (let ((collection (kmode-kselftest-current-collection)))
    (kmode-kselftest--start (list collection)
                             (format "kselftest-%s" collection))))

(defun kmode-kunit-available-p ()
  "Return non-nil when the active tree can run its KUnit tool."
  (let ((root (kmode-root t)))
    (and root
         (let ((context (kmode-resolve-context root)))
           (and (file-readable-p
                 (expand-file-name kmode-kunit-script root))
                (kmode-tool-path kmode-kunit-python-program context))))))

(defun kmode-kselftest-available-p ()
  "Return non-nil when the active tree provides Kselftest infrastructure."
  (let ((root (kmode-root t)))
    (and root
         (file-readable-p
          (expand-file-name "tools/testing/selftests/Makefile" root))
         (kmode-build-available-p))))

(defun kmode-kselftest-current-available-p ()
  "Return non-nil when the current file belongs to a Kselftest collection."
  (and (kmode-kselftest-available-p)
       buffer-file-name
       (condition-case nil
           (progn (kmode-kselftest-current-collection) t)
         (error nil))))

(kmode-register-action
 'kmode-kunit-run "Run KUnit" "Test" #'kmode-kunit-run
 :predicate #'kmode-kunit-available-p
 :description "Configure, build, and run KUnit for the active profile")
(kmode-register-action
 'kmode-kunit-run-filter "Run filtered KUnit..." "Test"
 #'kmode-kunit-run-filter
 :predicate #'kmode-kunit-available-p
 :description "Run KUnit suites or cases matching a glob")
(kmode-register-action
 'kmode-kunit-run-config "Run KUnit config..." "Test"
 #'kmode-kunit-run-config
 :predicate #'kmode-kunit-available-p
 :description "Run KUnit with a selected configuration fragment")
(kmode-register-action
 'kmode-kunit-build "Build KUnit kernel" "Test" #'kmode-kunit-build
 :predicate #'kmode-kunit-available-p
 :description "Configure and build the profile's KUnit kernel")
(kmode-register-action
 'kmode-kselftest-run "Run Kselftest subset..." "Test"
 #'kmode-kselftest-run
 :predicate #'kmode-kselftest-available-p
 :description "Build and run selected Kselftest collections")
(kmode-register-action
 'kmode-kselftest-run-current "Run current Kselftest collection" "Test"
 #'kmode-kselftest-run-current
 :predicate #'kmode-kselftest-current-available-p
 :description "Run the collection containing the current file")

(provide 'kmode-test)

;;; kmode-test.el ends here
