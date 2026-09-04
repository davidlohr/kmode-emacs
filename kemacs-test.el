;;; kemacs-test.el --- KUnit and Kselftest integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Kemacs contributors
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
(require 'kemacs-core)
(require 'kemacs-build)

(defgroup kemacs-test nil
  "Linux kernel testing commands."
  :group 'kemacs
  :prefix "kemacs-")

(defcustom kemacs-kunit-python-program "python3"
  "Python interpreter used to run the kernel's KUnit script."
  :type 'string
  :group 'kemacs-test)

(defcustom kemacs-kunit-script "tools/testing/kunit/kunit.py"
  "KUnit runner path, relative to the kernel source root."
  :type 'string
  :group 'kemacs-test)

(defcustom kemacs-kunit-build-directory nil
  "Optional KUnit build directory.

An absolute value is used as written.  A relative value is resolved from the
kernel source root.  When nil, Kemacs creates an isolated `.kunit' directory
inside the profile output, with a unique profile suffix for non-default
profiles."
  :type '(choice (const :tag "Derive from active profile" nil)
                 (directory :tag "Build directory"))
  :group 'kemacs-test)

(defcustom kemacs-kunit-config nil
  "Optional KUnit configuration fragment or directory.

Relative paths are resolved from the kernel source root.  Nil lets kunit.py
manage `.kunitconfig' in the active KUnit build directory."
  :type '(choice (const :tag "Use build directory configuration" nil)
                 (file :tag "Configuration path"))
  :group 'kemacs-test)

(defcustom kemacs-kunit-filter nil
  "Optional default KUnit suite or test glob.

The value is passed as one argument to kunit.py, so shell wildcard expansion
cannot alter it."
  :type '(choice (const :tag "Run every configured test" nil)
                 (string :tag "Test glob"))
  :group 'kemacs-test)

(defcustom kemacs-kunit-extra-arguments nil
  "Additional trusted command-line arguments passed to kunit.py.

Each list item is passed as one argument."
  :type '(repeat string)
  :group 'kemacs-test)

(defcustom kemacs-kselftest-default-targets nil
  "Default Kselftest collections offered by `kemacs-kselftest-run'."
  :type '(repeat string)
  :group 'kemacs-test)

(defcustom kemacs-kselftest-summary t
  "When non-nil, request Kselftest's concise summary output."
  :type 'boolean
  :group 'kemacs-test)

(defcustom kemacs-kselftest-force-targets t
  "When non-nil, fail if any requested Kselftest collection fails to build."
  :type 'boolean
  :group 'kemacs-test)

(defvar kemacs-kunit-filter-history nil
  "History of KUnit filters entered in the minibuffer.")

(defvar kemacs-kunit-config-history nil
  "History of KUnit configuration paths entered in the minibuffer.")

(defvar kemacs-kselftest-target-history nil
  "History of Kselftest collection selections.")

(defun kemacs-test--nonempty-string (value description)
  "Validate VALUE as a non-empty string used for DESCRIPTION."
  (unless (and (stringp value) (not (string-empty-p value)))
    (user-error "%s must be a non-empty string, got %S" description value))
  value)

(defun kemacs-test--profile-slug (profile)
  "Return PROFILE converted to a unique, safe build-directory suffix."
  (let ((slug (replace-regexp-in-string "[^[:alnum:]_.-]+" "-" profile)))
    (format "%s-%s"
            (if (string-empty-p slug) "profile" slug)
            (substring (secure-hash 'sha1 profile) 0 6))))

(defun kemacs-kunit-resolve-build-directory (&optional context)
  "Return the absolute KUnit build directory for CONTEXT.

The derivation never reuses the normal Kbuild output directory itself, so
kunit.py cannot replace that profile's `.config' or ordinary artifacts."
  (let* ((context (or context (kemacs-resolve-context)))
         (root (kemacs-context-root context))
         (output (kemacs-context-output context))
         (profile (kemacs-context-profile context)))
    (file-name-as-directory
     (expand-file-name
      (cond
       (kemacs-kunit-build-directory kemacs-kunit-build-directory)
       ((equal profile kemacs-default-profile)
        (expand-file-name ".kunit" output))
       (t
        (expand-file-name
         (format ".kunit-%s" (kemacs-test--profile-slug profile))
         output)))
      root))))

(defun kemacs-kunit--filter (filter)
  "Validate and return optional KUnit FILTER."
  (when (and filter (not (equal filter "")))
    (unless (and (stringp filter)
                 (not (string-prefix-p "-" filter))
                 (not (string-match-p "[[:cntrl:]]" filter)))
      (user-error "Unsafe or invalid KUnit filter: %S" filter))
    filter))

(defun kemacs-kunit--config-path (config context)
  "Resolve optional KUnit CONFIG path against CONTEXT and validate it."
  (when (and config (not (string-empty-p config)))
    (let ((path (expand-file-name config (kemacs-context-root context))))
      (unless (file-exists-p path)
        (user-error "KUnit configuration does not exist: %s" path))
      path)))

(defun kemacs-kunit--make-options (context)
  "Return profile make options to forward through kunit.py for CONTEXT."
  (let ((compiler (kemacs-context-compiler context))
        (profile-arguments (kemacs-context-make-arguments context)))
    (unless (memq compiler '(auto gcc clang))
      (user-error "Unsupported kernel compiler: %S" compiler))
    (append
     (when (eq compiler 'clang) '("LLVM=1"))
     (mapcar
      (lambda (argument)
        (kemacs-test--nonempty-string argument "KUnit make option"))
      profile-arguments))))

(defun kemacs-kunit-arguments (subcommand &optional context filter config)
  "Build kunit.py arguments for SUBCOMMAND and CONTEXT.

SUBCOMMAND must be `run', `config', or `build'.  FILTER is an optional test
glob and is valid for `run' only.  CONFIG is an optional `.kunitconfig' file
or directory.  Profile architecture, cross compiler, compiler selection,
make options, job count, and build directory are forwarded automatically."
  (let* ((context (or context (kemacs-resolve-context)))
         (subcommand-name
          (if (symbolp subcommand) (symbol-name subcommand) subcommand))
         (arch (kemacs-context-arch context))
         (cross-compile (kemacs-context-cross-compile context))
         (jobs (kemacs-context-jobs context))
         (config (kemacs-kunit--config-path config context))
         (filter (kemacs-kunit--filter filter)))
    (unless (member subcommand-name '("run" "config" "build"))
      (user-error "Unsupported KUnit subcommand: %S" subcommand))
    (when (and filter (not (equal subcommand-name "run")))
      (user-error "A KUnit filter is only valid for the run subcommand"))
    (when arch
      (kemacs-test--nonempty-string arch "KUnit architecture"))
    (when cross-compile
      (kemacs-test--nonempty-string cross-compile
                                    "KUnit cross compiler"))
    (when (and jobs (not (and (integerp jobs) (> jobs 0))))
      (user-error "KUnit job count must be positive, got %S" jobs))
    (append
     (list subcommand-name
           (concat "--build_dir="
                   (directory-file-name
                    (kemacs-kunit-resolve-build-directory context))))
     (when config (list (concat "--kunitconfig=" config)))
     (when arch (list (concat "--arch=" arch)))
     (when cross-compile
       (list (concat "--cross_compile=" cross-compile)))
     (mapcar (lambda (option) (concat "--make_options=" option))
             (kemacs-kunit--make-options context))
     (when (and jobs (member subcommand-name '("run" "build")))
       (list (format "--jobs=%d" jobs)))
     (mapcar
      (lambda (argument)
        (kemacs-test--nonempty-string argument "KUnit extra argument"))
      kemacs-kunit-extra-arguments)
     (when filter (list filter)))))

(defun kemacs-kunit--script (context)
  "Return the readable KUnit script path for CONTEXT or signal an error."
  (let ((script (expand-file-name kemacs-kunit-script
                                  (kemacs-context-root context))))
    (unless (file-readable-p script)
      (user-error "Kernel tree does not provide KUnit runner %s" script))
    script))

(defun kemacs-kunit--start (subcommand label &optional filter config)
  "Start KUnit SUBCOMMAND asynchronously in a buffer named by LABEL.

FILTER and CONFIG are forwarded to `kemacs-kunit-arguments'."
  (let* ((context (kemacs-resolve-context))
         (python (kemacs-require-tool kemacs-kunit-python-program context))
         (script (kemacs-kunit--script context))
         (arguments
          (cons script
                (kemacs-kunit-arguments subcommand context filter config))))
    (let ((process-environment (kemacs-build-process-environment context)))
      (kemacs-start-command label python arguments
                            (kemacs-context-root context) nil
                            (kemacs-kunit-resolve-build-directory context)
                            context))))

;;;###autoload
(defun kemacs-kunit-run (&optional filter config)
  "Run the active profile's KUnit suite after configuring and building it.

FILTER defaults to `kemacs-kunit-filter'.  CONFIG defaults to
`kemacs-kunit-config'.  Both values are passed as individual arguments to
the kernel-provided kunit.py runner."
  (interactive)
  (kemacs-kunit--start 'run "kunit"
                       (or filter kemacs-kunit-filter)
                       (or config kemacs-kunit-config)))

;;;###autoload
(defun kemacs-kunit-run-filter (filter)
  "Prompt for FILTER and run matching KUnit suites or test cases."
  (interactive
   (list
    (read-string "KUnit test glob: " kemacs-kunit-filter
                 'kemacs-kunit-filter-history)))
  (kemacs-kunit-run
   (kemacs-test--nonempty-string filter "KUnit filter")))

;;;###autoload
(defun kemacs-kunit-run-config (config)
  "Prompt for CONFIG and run KUnit using that configuration fragment."
  (interactive
   (let* ((root (kemacs-root))
          (initial (and kemacs-kunit-config
                        (expand-file-name kemacs-kunit-config root))))
     (list
      (read-file-name "KUnit configuration: " root initial t nil
                      (lambda (path)
                        (or (file-directory-p path)
                            (file-readable-p path)))))))
  (add-to-history 'kemacs-kunit-config-history config)
  (kemacs-kunit-run nil config))

;;;###autoload
(defun kemacs-kunit-configure ()
  "Prepare the KUnit configuration for the active profile asynchronously."
  (interactive)
  (kemacs-kunit--start 'config "kunit-config" nil kemacs-kunit-config))

;;;###autoload
(defun kemacs-kunit-build ()
  "Configure and build the KUnit kernel for the active profile."
  (interactive)
  (kemacs-kunit--start 'build "kunit-build" nil kemacs-kunit-config))

(defun kemacs-kselftest-collections (&optional context)
  "Return Kselftest collection names declared by CONTEXT's kernel tree."
  (let* ((context (or context (kemacs-resolve-context)))
         (makefile (expand-file-name "tools/testing/selftests/Makefile"
                                     (kemacs-context-root context)))
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

(defun kemacs-kselftest--normalize-targets (targets)
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

(defun kemacs-kselftest-read-targets ()
  "Read one or more Kselftest collection names with completion."
  (let* ((context (kemacs-resolve-context))
         (candidates (kemacs-kselftest-collections context))
         (default (mapconcat #'identity kemacs-kselftest-default-targets ","))
         (selection
          (completing-read-multiple
           "Kselftest collections: " candidates nil nil nil
           'kemacs-kselftest-target-history
           (unless (string-empty-p default) default))))
    (kemacs-kselftest--normalize-targets selection)))

(defun kemacs-kselftest--start (targets label)
  "Build and run Kselftest TARGETS asynchronously under LABEL."
  (let* ((context (kemacs-resolve-context))
         (targets (kemacs-kselftest--normalize-targets targets))
         (program (kemacs-require-tool kemacs-build-make-program context))
         (extra-arguments
          (append
           (list (concat "TARGETS=" (string-join targets " ")))
           (when kemacs-kselftest-summary '("summary=1"))
           (when kemacs-kselftest-force-targets '("FORCE_TARGETS=1"))))
         (arguments
          (kemacs-build-make-arguments context '("kselftest")
                                       extra-arguments)))
    (let ((process-environment (kemacs-build-process-environment context)))
      (kemacs-start-command label program arguments
                            (kemacs-context-root context) nil
                            (kemacs-context-output context) context))))

;;;###autoload
(defun kemacs-kselftest-run (targets)
  "Prompt for Kselftest collection TARGETS, then build and run that subset.

The active build profile is honored, including its output directory and
toolchain.  The top-level kernel `kselftest' target invokes the runner scripts
provided by the checked-out kernel rather than a Kemacs-specific harness."
  (interactive (list (kemacs-kselftest-read-targets)))
  (kemacs-kselftest--start targets "kselftest"))

(defun kemacs-kselftest-current-collection (&optional context)
  "Return the Kselftest collection containing the current file in CONTEXT."
  (let ((relative (kemacs-file-in-root nil
                                       (or context
                                           (kemacs-resolve-context)))))
    (if (string-match
         "\\`tools/testing/selftests/\\([^/]+\\)\\(?:/\\|\\'\\)" relative)
        (match-string 1 relative)
      (user-error "Current file is not inside a Kselftest collection"))))

;;;###autoload
(defun kemacs-kselftest-run-current ()
  "Build and run the Kselftest collection containing the current file."
  (interactive)
  (let ((collection (kemacs-kselftest-current-collection)))
    (kemacs-kselftest--start (list collection)
                             (format "kselftest-%s" collection))))

(defun kemacs-kunit-available-p ()
  "Return non-nil when the active tree can run its KUnit tool."
  (let ((root (kemacs-root t)))
    (and root
         (let ((context (kemacs-resolve-context root)))
           (and (file-readable-p
                 (expand-file-name kemacs-kunit-script root))
                (kemacs-tool-path kemacs-kunit-python-program context))))))

(defun kemacs-kselftest-available-p ()
  "Return non-nil when the active tree provides Kselftest infrastructure."
  (let ((root (kemacs-root t)))
    (and root
         (file-readable-p
          (expand-file-name "tools/testing/selftests/Makefile" root))
         (kemacs-build-available-p))))

(defun kemacs-kselftest-current-available-p ()
  "Return non-nil when the current file belongs to a Kselftest collection."
  (and (kemacs-kselftest-available-p)
       buffer-file-name
       (condition-case nil
           (progn (kemacs-kselftest-current-collection) t)
         (error nil))))

(kemacs-register-action
 'kemacs-kunit-run "Run KUnit" "Test" #'kemacs-kunit-run
 :predicate #'kemacs-kunit-available-p
 :description "Configure, build, and run KUnit for the active profile")
(kemacs-register-action
 'kemacs-kunit-run-filter "Run filtered KUnit..." "Test"
 #'kemacs-kunit-run-filter
 :predicate #'kemacs-kunit-available-p
 :description "Run KUnit suites or cases matching a glob")
(kemacs-register-action
 'kemacs-kunit-run-config "Run KUnit config..." "Test"
 #'kemacs-kunit-run-config
 :predicate #'kemacs-kunit-available-p
 :description "Run KUnit with a selected configuration fragment")
(kemacs-register-action
 'kemacs-kunit-build "Build KUnit kernel" "Test" #'kemacs-kunit-build
 :predicate #'kemacs-kunit-available-p
 :description "Configure and build the profile's KUnit kernel")
(kemacs-register-action
 'kemacs-kselftest-run "Run Kselftest subset..." "Test"
 #'kemacs-kselftest-run
 :predicate #'kemacs-kselftest-available-p
 :description "Build and run selected Kselftest collections")
(kemacs-register-action
 'kemacs-kselftest-run-current "Run current Kselftest collection" "Test"
 #'kemacs-kselftest-run-current
 :predicate #'kemacs-kselftest-current-available-p
 :description "Run the collection containing the current file")

(provide 'kemacs-test)

;;; kemacs-test.el ends here
