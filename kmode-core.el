;;; kmode-core.el --- Kernel project contexts and process plumbing -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: kmode-emacs contributors
;; Keywords: tools, c, linux
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Shared primitives for kmode-emacs.  This module deliberately depends only on
;; packages shipped with Emacs so the higher-level integrations can remain
;; optional and capability-driven.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'compile)
(require 'project)
(require 'seq)
(require 'subr-x)

(defgroup kmode nil
  "A focused Linux kernel development environment."
  :group 'tools
  :prefix "kmode-")

(defcustom kmode-root-markers
  '("Makefile" "Kconfig" "MAINTAINERS" "scripts/checkpatch.pl")
  "Files that together identify the root of a Linux kernel source tree."
  :type '(repeat string)
  :group 'kmode)

(defcustom kmode-profiles
  '(("default"
     :description "Native toolchain, in-tree output"
     :compiler auto
     :jobs auto))
  "Named kernel build profiles.

Each value is a property list.  Supported properties are `:arch',
`:cross-compile', `:compiler', `:output', `:jobs', `:make-arguments',
`:image', `:vmlinux', `:qemu-command', `:gdb-target', `:vng-arch',
`:vng-root', `:vng-append', `:vng-arguments',
`:vng-debug-arguments', `:vng-build-arguments', and
`:vng-make-arguments'.  Relative output and virtme-ng root paths are
resolved from the source root; runtime modules resolve relative image
and vmlinux paths from the output tree."
  :type '(alist :key-type string :value-type sexp)
  :group 'kmode)

(defcustom kmode-default-profile "default"
  "Name of the build profile selected for a new kernel worktree."
  :type 'string
  :group 'kmode)

(defcustom kmode-default-jobs 'auto
  "Default number of concurrent build jobs.

The value `auto' uses the number of processors reported by Emacs.  A
positive integer requests exactly that many jobs.  Nil omits the `-j'
option."
  :type '(choice (const :tag "Processor count" auto)
                 (const :tag "Let make decide" nil)
                 (integer :tag "Jobs"))
  :group 'kmode)

(defcustom kmode-compilation-scroll-output 'first-error
  "How kmode-emacs compilation buffers should scroll.

This has the same meaning as `compilation-scroll-output'."
  :type '(choice (const :tag "Do not scroll" nil)
                 (const :tag "First error" first-error)
                 (const :tag "Follow output" t))
  :group 'kmode)

(defcustom kmode-context-functions nil
  "Functions allowed to refine a newly resolved `kmode-context'.

Each function receives a context object and should return either that
object, a replacement context, or nil to leave it unchanged."
  :type 'hook
  :group 'kmode)

(defcustom kmode-profile-changed-hook nil
  "Hook run after selecting a profile for the current kernel worktree."
  :type 'hook
  :group 'kmode)

(defvar-local kmode-root-override nil
  "Explicit kernel source root for the current buffer.")

(defvar-local kmode-profile nil
  "Explicit kmode-emacs profile name for the current buffer.")

(defvar-local kmode-output-directory nil
  "Build output override for the current buffer.")

(defvar-local kmode-arch nil
  "Kernel ARCH override for the current buffer.")

(defvar-local kmode-cross-compile nil
  "Kernel CROSS_COMPILE override for the current buffer.")

(defvar-local kmode-compiler nil
  "Compiler override for the current buffer.

Supported values are `auto', `gcc', and `clang'.")

(defvar-local kmode-jobs nil
  "Parallel build job override for the current buffer.")

(defvar-local kmode-make-arguments nil
  "Extra make arguments for the current buffer's kernel profile.")

(defvar-local kmode-process-resource nil
  "Canonical build resource owned by the process in this buffer.")

(defvar-local kmode-process-root nil
  "Kernel source root associated with the process in this buffer.")

(defvar-local kmode-process-profile nil
  "Kmode-emacs profile associated with the process in this buffer.")

(defvar-local kmode-compilation-process nil
  "Most recent Compilation process started in this kmode-emacs buffer.")

;; Compilation mode is reinitialized by `recompile'.  Preserve ownership long
;; enough for its start hook to guard and tag the replacement process.
(put 'kmode-process-resource 'permanent-local t)
(put 'kmode-process-root 'permanent-local t)
(put 'kmode-process-profile 'permanent-local t)

(put 'kmode-compiler 'safe-local-variable
     (lambda (value) (memq value '(auto gcc clang))))
(put 'kmode-jobs 'safe-local-variable
     (lambda (value) (or (null value)
                         (eq value 'auto)
                         (and (integerp value) (> value 0)))))

(cl-defstruct (kmode-context
               (:constructor kmode--make-context))
  "Resolved settings for one operation in a kernel worktree."
  root profile output arch cross-compile compiler jobs make-arguments
  image vmlinux qemu-command gdb-target
  vng-arch vng-root vng-append vng-arguments vng-debug-arguments
  vng-build-arguments vng-make-arguments)

(cl-defstruct (kmode-action
               (:constructor kmode--make-action))
  "A command exposed by the kmode-emacs dispatcher and dashboard."
  id title group command predicate description)

(defvar kmode--root-cache (make-hash-table :test #'equal)
  "Cache mapping directories to kernel roots or the symbol `none'.")

(defvar kmode--selected-profiles (make-hash-table :test #'equal)
  "Session-local profile selection for each kernel root.")

(defvar kmode--actions nil
  "Registered `kmode-action' objects.")

(defconst kmode--srcarch-aliases
  '(("i386" . "x86") ("x86_64" . "x86")
    ("sparc32" . "sparc") ("sparc64" . "sparc")
    ("sh64" . "sh") ("parisc64" . "parisc"))
  "Kernel ARCH names whose source directory uses another SRCARCH.")

(defun kmode-native-arch ()
  "Return the kernel ARCH spelling inferred for the Emacs host."
  (let ((machine (or (car (split-string system-configuration "-" t)) "")))
    (cond
     ((string-match-p "\\`\\(?:i.86\\|x86_64\\|amd64\\)\\'" machine) "x86")
     ((string-match-p "\\`aarch64" machine) "arm64")
     ((string-match-p "\\`arm" machine) "arm")
     ((string-match-p "\\`riscv" machine) "riscv")
     ((string-match-p "\\`\\(?:ppc\\|powerpc\\)" machine) "powerpc")
     ((string-match-p "\\`mips" machine) "mips")
     ((string-match-p "\\`s390" machine) "s390")
     ((string-match-p "\\`parisc" machine) "parisc")
     ((string-match-p "\\`sh[234]" machine) "sh")
     ((string-match-p "\\`loongarch" machine) "loongarch")
     ((string-match-p "\\`sun4u" machine) "sparc64")
     ((string-empty-p machine) "x86")
     (t machine))))

(defun kmode-srcarch (&optional arch)
  "Return the kernel SRCARCH directory corresponding to ARCH.

When ARCH is nil, infer the native kernel architecture."
  (let ((arch (or arch (kmode-native-arch))))
    (or (cdr (assoc arch kmode--srcarch-aliases)) arch)))

(defun kmode-kernel-root-p (directory)
  "Return non-nil when DIRECTORY is a Linux kernel source root."
  (and directory
       (file-directory-p directory)
       (cl-every (lambda (marker)
                   (file-exists-p (expand-file-name marker directory)))
                 kmode-root-markers)))

(defun kmode-clear-caches ()
  "Clear cached kernel roots and rediscover context on the next command."
  (interactive)
  (clrhash kmode--root-cache)
  (message "Kmode-emacs project cache cleared"))

(defun kmode-locate-root (&optional directory)
  "Find the kernel source root containing DIRECTORY.

DIRECTORY defaults to `default-directory'.  Return nil if the location
is not inside a recognizable kernel tree."
  (let* ((override (and kmode-root-override
                        (file-name-as-directory
                         (expand-file-name kmode-root-override))))
         (start (expand-file-name (or directory default-directory)))
         (start (if (file-directory-p start)
                    (file-name-as-directory start)
                  (file-name-directory start)))
         (cached (gethash start kmode--root-cache 'missing)))
    (if override
        (when (kmode-kernel-root-p override) override)
      (if (not (eq cached 'missing))
          (unless (eq cached 'none) cached)
        (let ((root (locate-dominating-file start #'kmode-kernel-root-p)))
          (setq root (and root (file-name-as-directory
                               (expand-file-name root))))
          (puthash start (or root 'none) kmode--root-cache)
          root)))))

(defun kmode-root (&optional noerror)
  "Return the current kernel source root.

When NOERROR is non-nil, return nil outside a kernel tree.  Otherwise
signal a `user-error'."
  (let ((root (kmode-locate-root)))
    (cond (root root)
          (noerror nil)
          (t (user-error "This buffer is not inside a Linux kernel source tree")))))

(defun kmode--profile-entry (name)
  "Return the configured profile entry named NAME."
  (or (assoc name kmode-profiles)
      (user-error "Unknown kmode-emacs profile: %s" name)))

(defun kmode-current-profile-name (&optional root)
  "Return the selected build profile name for ROOT."
  (or kmode-profile
      (gethash (or root (kmode-root t)) kmode--selected-profiles)
      kmode-default-profile))

(defun kmode-profile-property (property &optional context)
  "Return PROPERTY from CONTEXT's selected profile.

When CONTEXT is nil, resolve the profile for the current buffer."
  (let* ((root (if context
                   (kmode-context-root context)
                 (kmode-root)))
         (name (if context
                   (kmode-context-profile context)
                 (kmode-current-profile-name root))))
    (plist-get (cdr (kmode--profile-entry name)) property)))

(defun kmode--positive-jobs (value)
  "Normalize build job VALUE."
  (pcase value
    ('auto (max 1 (num-processors)))
    ((pred null) nil)
    ((and (pred integerp) n)
     (if (> n 0) n
       (user-error "Kmode-emacs job count must be positive: %s" n)))
    (_ (user-error "Invalid kmode-emacs job count: %S" value))))

(defun kmode--expand-profile-path (path root)
  "Expand profile PATH relative to ROOT, preserving nil."
  (and path
       (file-name-as-directory
        (expand-file-name path root))))

(defun kmode-resolve-context (&optional root)
  "Resolve and return the active `kmode-context' for ROOT.

Buffer-local overrides take precedence over properties in the selected
profile.  Functions in `kmode-context-functions' run last."
  (let* ((root (file-name-as-directory (expand-file-name (or root (kmode-root)))))
         (profile-name (kmode-current-profile-name root))
         (profile-data (cdr (kmode--profile-entry profile-name)))
         (output-value (or kmode-output-directory
                           (plist-get profile-data :output)))
         (compiler-value (or kmode-compiler
                             (plist-get profile-data :compiler)
                             'auto))
         (jobs-value (if kmode-jobs
                         kmode-jobs
                       (if (plist-member profile-data :jobs)
                           (plist-get profile-data :jobs)
                         kmode-default-jobs)))
         (context
          (kmode--make-context
           :root root
           :profile profile-name
           :output (or (kmode--expand-profile-path output-value root) root)
           :arch (or kmode-arch (plist-get profile-data :arch))
           :cross-compile (or kmode-cross-compile
                              (plist-get profile-data :cross-compile))
           :compiler compiler-value
           :jobs (kmode--positive-jobs jobs-value)
           :make-arguments (append kmode-make-arguments
                                   (plist-get profile-data :make-arguments))
           :image (plist-get profile-data :image)
           :vmlinux (plist-get profile-data :vmlinux)
           :qemu-command (plist-get profile-data :qemu-command)
           :gdb-target (plist-get profile-data :gdb-target)
           :vng-arch (plist-get profile-data :vng-arch)
           :vng-root
           (kmode--expand-profile-path
            (plist-get profile-data :vng-root) root)
           :vng-append (copy-tree (plist-get profile-data :vng-append))
           :vng-arguments
           (copy-tree (plist-get profile-data :vng-arguments))
           :vng-debug-arguments
           (copy-tree (plist-get profile-data :vng-debug-arguments))
           :vng-build-arguments
           (copy-tree (plist-get profile-data :vng-build-arguments))
           :vng-make-arguments
           (copy-tree (plist-get profile-data :vng-make-arguments)))))
    (dolist (function kmode-context-functions context)
      (setq context (or (funcall function context) context)))))

(defun kmode-select-profile (profile)
  "Select PROFILE for the current kernel worktree for this session."
  (interactive
   (list (completing-read "Kernel build profile: "
                          (mapcar #'car kmode-profiles)
                          nil t nil nil
                          (kmode-current-profile-name))))
  (kmode--profile-entry profile)
  (let ((root (kmode-root)))
    (puthash root profile kmode--selected-profiles)
    (run-hooks 'kmode-profile-changed-hook)
    (message "Kmode-emacs profile for %s: %s"
             (file-name-nondirectory (directory-file-name root)) profile)))

(defun kmode-profile-description (&optional context)
  "Return a compact human-readable description of CONTEXT."
  (let* ((context (or context (kmode-resolve-context)))
         (root (kmode-context-root context))
         (output (kmode-context-output context)))
    (format "%s · %s · %s · %s · -j%s"
            (kmode-context-profile context)
            (or (kmode-context-arch context) "native")
            (pcase (kmode-context-compiler context)
              ('clang "clang/LLVM")
              ('gcc "GCC")
              (_ "toolchain:auto"))
            (if (equal root output)
                "in-tree"
              (abbreviate-file-name (directory-file-name output)))
            (or (kmode-context-jobs context) "make"))))

(defun kmode-root-id (&optional root)
  "Return a short display identifier unique to kernel ROOT."
  (let* ((root (file-name-as-directory
                (expand-file-name (or root (kmode-root)))))
         (name (file-name-nondirectory (directory-file-name root)))
         (digest (substring (secure-hash 'sha1 root) 0 6)))
    (format "%s@%s" name digest)))

(defun kmode-running-processes (&optional context all-profiles)
  "Return live kmode-emacs processes belonging to CONTEXT.

By default, include only the active profile.  When ALL-PROFILES is non-nil,
include every profile in the same kernel worktree."
  (let* ((context (or context (kmode-resolve-context)))
         (prefix (if all-profiles
                     (format "*kmode:%s:"
                             (kmode-root-id
                              (kmode-context-root context)))
                   (format "*kmode:%s:%s:"
                           (kmode-root-id
                            (kmode-context-root context))
                           (kmode-context-profile context)))))
    (seq-filter
     (lambda (process)
       (let ((buffer (process-buffer process))
             (process-root (process-get process 'kmode-root))
             (process-profile (process-get process 'kmode-profile)))
         (and (process-live-p process)
              (or (and process-root
                       (equal (kmode-context-root context) process-root)
                       (or all-profiles
                           (equal (kmode-context-profile context)
                                  process-profile)))
                  (and (buffer-live-p buffer)
                       (string-prefix-p prefix (buffer-name buffer)))))))
     (process-list))))

(defun kmode-mark-process-context (buffer root profile)
  "Mark BUFFER's current process as belonging to ROOT and PROFILE."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq-local kmode-process-root root)
      (setq-local kmode-process-profile profile)
      (when-let ((process (get-buffer-process buffer)))
        (process-put process 'kmode-root root)
        (process-put process 'kmode-profile profile)
        process))))

(defun kmode-process-resource-key (directory)
  "Return a canonical resource key for build DIRECTORY."
  (let ((expanded (directory-file-name (expand-file-name directory))))
    (condition-case nil
        (directory-file-name (file-truename expanded))
      (file-error expanded))))

(defun kmode-resource-process (directory &optional except)
  "Return a live process owning build DIRECTORY, other than EXCEPT.

Ownership may be recorded on the process or its buffer so ordinary
`recompile' remains discoverable."
  (let ((key (kmode-process-resource-key directory)))
    (seq-find
     (lambda (process)
       (let ((buffer (process-buffer process)))
         (and (not (eq process except))
              (process-live-p process)
              (equal key
                     (or (process-get process 'kmode-process-resource)
                         (and (buffer-live-p buffer)
                              (buffer-local-value
                               'kmode-process-resource buffer)))))))
     (process-list))))

(defun kmode-assert-resource-available (directory &optional except)
  "Signal a user error if another process owns build DIRECTORY.

EXCEPT, when non-nil, is ignored.  Return the canonical resource key."
  (let* ((key (kmode-process-resource-key directory))
         (process (kmode-resource-process key except)))
    (when process
      (user-error "Build output %s is busy in %s; wait or cancel that job"
                  key
                  (if-let ((buffer (process-buffer process)))
                      (buffer-name buffer)
                    (process-name process))))
    key))

(defun kmode-mark-process-resource (buffer directory)
  "Mark BUFFER's current process as owning build DIRECTORY."
  (let ((key (kmode-process-resource-key directory)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq-local kmode-process-resource key)
        (when-let ((process (get-buffer-process buffer)))
          (process-put process 'kmode-process-resource key))))
    key))

(defun kmode-runtime-resource-process (resource &optional except)
  "Return a live process owning named runtime RESOURCE, other than EXCEPT."
  (seq-find
   (lambda (process)
     (and (not (eq process except))
          (process-live-p process)
          (member resource
                  (process-get process 'kmode-runtime-resources))))
   (process-list)))

(defun kmode-assert-runtime-resources-available (resources &optional except)
  "Signal when a named runtime resource in RESOURCES is owned by a process.

EXCEPT, when non-nil, is ignored.  Return a de-duplicated copy of RESOURCES."
  (let ((resources (delete-dups (copy-sequence resources))))
    (dolist (resource resources)
      (unless (and (stringp resource) (not (string-empty-p resource)))
        (user-error "Runtime resource names must be non-empty strings: %S"
                    resource))
      (when-let ((process (kmode-runtime-resource-process resource except)))
        (user-error "Runtime resource %s is busy in %s"
                    resource
                    (if-let ((buffer (process-buffer process)))
                        (buffer-name buffer)
                      (process-name process)))))
    resources))

(defun kmode-mark-process-runtime-resources (process resources)
  "Mark PROCESS as owning the named runtime RESOURCES.

Return the normalized resource list."
  (unless (processp process)
    (user-error "Cannot assign runtime resources without a process"))
  (let ((resources
         (kmode-assert-runtime-resources-available resources process)))
    (process-put process 'kmode-runtime-resources resources)
    resources))

;;;###autoload
(defun kmode-cancel-job (process)
  "Interrupt a live kmode-emacs PROCESS from the current kernel worktree."
  (interactive
   (let* ((processes (kmode-running-processes nil t))
          (choices (mapcar (lambda (item)
                             (cons (format "%s  (%s)"
                                           (if-let ((buffer
                                                     (process-buffer item)))
                                               (buffer-name buffer)
                                             (process-name item))
                                           (process-status item))
                                   item))
                           processes)))
     (unless choices
       (user-error "No kmode-emacs process is running for this kernel worktree"))
     (list (cdr (assoc (completing-read "Interrupt kmode-emacs job: "
                                        choices nil t)
                       choices)))))
  (unless (and (processp process) (process-live-p process))
    (user-error "That kmode-emacs process is no longer running"))
  (interrupt-process process)
  (message "Interrupted %s" (process-name process)))

(defun kmode-register-action (id title group command &rest properties)
  "Register an action with ID, TITLE, GROUP, and interactive COMMAND.

PROPERTIES recognizes `:predicate' and `:description'.  A predicate is
called with no arguments whenever the dispatcher or dashboard needs to
know whether the action is currently usable."
  (setq kmode--actions
        (cl-delete id kmode--actions :key #'kmode-action-id :test #'eq))
  (push (kmode--make-action
         :id id :title title :group group :command command
         :predicate (plist-get properties :predicate)
         :description (plist-get properties :description))
        kmode--actions)
  id)

(defun kmode-action-available-p (action)
  "Return non-nil if ACTION is usable in the current context."
  (let ((predicate (kmode-action-predicate action)))
    (condition-case nil
        (or (null predicate) (funcall predicate))
      (error nil))))

(defun kmode-actions (&optional include-unavailable)
  "Return registered actions sorted by group and title.

Unless INCLUDE-UNAVAILABLE is non-nil, omit actions whose predicates
currently fail."
  (sort (seq-filter (lambda (action)
                      (or include-unavailable
                          (kmode-action-available-p action)))
                    (copy-sequence kmode--actions))
        (lambda (left right)
          (string-lessp
           (format "%s/%s" (kmode-action-group left)
                   (kmode-action-title left))
           (format "%s/%s" (kmode-action-group right)
                   (kmode-action-title right))))))

(defun kmode-tool-path (tool &optional context)
  "Return a usable path for TOOL, or nil.

Bare executable names are resolved only through the variable
`exec-path'.  TOOL may also be an absolute path or an explicit path
containing a directory component; a relative explicit path is resolved
from CONTEXT's kernel source root."
  (let* ((context (or context (and (kmode-root t) (kmode-resolve-context))))
         (root (and context (kmode-context-root context)))
         (explicit-path (and (stringp tool)
                             (or (file-name-absolute-p tool)
                                 (file-name-directory tool))))
         (resolved (and explicit-path
                        (expand-file-name tool (or root default-directory)))))
    (if explicit-path
        (and (file-executable-p resolved) resolved)
      (when (stringp tool)
        ;; Empty/relative PATH entries resolve from `default-directory'.  Do
        ;; not let an untrusted checkout shadow a bare system tool even when
        ;; the user's ambient PATH contains `.'.
        (let* ((exec-path
                (if root
                    (seq-filter
                     (lambda (directory)
                       (and (stringp directory)
                            (file-name-absolute-p directory)
                            (not (file-in-directory-p directory root))))
                     exec-path)
                  exec-path))
               (candidate (executable-find tool)))
          (and candidate
               (or (null root)
                   (not (file-in-directory-p candidate root)))
               candidate))))))

(defun kmode-require-tool (tool &optional context)
  "Return TOOL's path or signal an actionable error.

CONTEXT is passed to `kmode-tool-path'."
  (or (kmode-tool-path tool context)
      (user-error "Kmode-emacs needs `%s'; install it or use a kernel tree that provides it"
                  tool)))

(defun kmode-shell-command (program arguments)
  "Build a safely shell-quoted command from PROGRAM and ARGUMENTS."
  (mapconcat #'shell-quote-argument (cons program arguments) " "))

(defvar kmode-compilation-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map compilation-mode-map)
    (define-key map (kbd "g") #'kmode-recompile)
    map)
  "Keymap used by `kmode-compilation-mode'.")

(defun kmode--mark-recompiled-resource (&optional process)
  "Restore kmode-emacs ownership on a newly started Compilation PROCESS.

PROCESS defaults to the current buffer's process when this is called outside
  `compilation-start-hook'."
  (let ((process (or process (get-buffer-process (current-buffer)))))
    (setq-local kmode-compilation-process process)
    (condition-case error-data
        (progn
          (when kmode-process-resource
            (kmode-assert-resource-available
             kmode-process-resource process))
          (when kmode-process-root
            (kmode-mark-process-context (current-buffer)
                                         kmode-process-root
                                         kmode-process-profile))
          (when kmode-process-resource
            (kmode-mark-process-resource (current-buffer)
                                          kmode-process-resource)))
      (error
       (when (process-live-p process)
         (delete-process process))
       (signal (car error-data) (cdr error-data))))))

(defun kmode-compilation-succeeded-p (buffer)
  "Return non-nil when BUFFER's just-finished kmode-emacs process exited zero.

This is intended for `compilation-finish-functions', where Emacs 28 has
already made `get-buffer-process' return nil even though the process object is
still available to finish hooks."
  (and (buffer-live-p buffer)
       (let ((process
              (buffer-local-value 'kmode-compilation-process buffer)))
         (and (processp process)
              (eq (process-status process) 'exit)
              (zerop (process-exit-status process))))))

;;;###autoload
(defun kmode-recompile ()
  "Recompile the current kmode-emacs job without racing its build output."
  (interactive)
  (unless (derived-mode-p 'compilation-mode)
    (user-error "This is not a compilation buffer"))
  (when kmode-process-resource
    (kmode-assert-resource-available
     kmode-process-resource (get-buffer-process (current-buffer))))
  (recompile)
  (kmode--mark-recompiled-resource))

(define-compilation-mode kmode-compilation-mode "kmode-emacs-Compile"
  "Compilation mode used for kernel commands started by kmode-emacs."
  (setq-local compilation-scroll-output kmode-compilation-scroll-output)
  (add-hook 'compilation-filter-hook #'ansi-color-compilation-filter nil t)
  (add-hook 'compilation-start-hook #'kmode--mark-recompiled-resource nil t)
  (setq-local compilation-error-regexp-alist
              (cons 'kmode-checkpatch compilation-error-regexp-alist)))

(add-to-list 'compilation-error-regexp-alist-alist
             '(kmode-checkpatch
               "^\\(?:FILE: \\)?\\([^:\n]+\\):\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?:"
               1 2 3))

(defun kmode-start-shell-command
    (label command &optional directory mode resource context finish-function)
  "Run shell COMMAND asynchronously in a kmode-emacs compilation buffer.

LABEL names the buffer, DIRECTORY defaults to the kernel source root,
and MODE defaults to `kmode-compilation-mode'.  When RESOURCE names a build
directory, refuse to overlap another kmode-emacs process using that directory.
CONTEXT, when non-nil, pins the root/profile identity to a previously resolved
`kmode-context'.  FINISH-FUNCTION, when non-nil, is installed buffer-locally
before the process starts and receives the usual compilation buffer and status
arguments.  Return the compilation buffer."
  (unless (and (stringp command) (not (string-empty-p command)))
    (user-error "Kmode-emacs command must be a non-empty string"))
  (let* ((current-root (kmode-root t))
         (context-root (and context (kmode-context-root context)))
         (working-directory
          (file-name-as-directory
           (expand-file-name (or directory context-root current-root
                                 default-directory))))
         (directory-root
          (when directory
            ;; An explicit directory is authoritative even when the invoking
            ;; buffer has a root override for a different worktree.
            (let ((kmode-root-override nil))
              (kmode-locate-root working-directory))))
         (root (or context-root directory-root current-root working-directory))
         (default-directory working-directory)
         (profile (if context
                      (kmode-context-profile context)
                    (if (equal root current-root)
                        (kmode-current-profile-name root)
                      (or (gethash root kmode--selected-profiles)
                          kmode-default-profile))))
         (buffer-name (format "*kmode:%s:%s:%s*"
                              (kmode-root-id root) profile label))
         (resource-key (and resource
                            (kmode-process-resource-key resource)))
         (inherited-setup compilation-process-setup-function)
         (compilation-process-setup-function
          (if (or inherited-setup finish-function)
              (lambda ()
                (when inherited-setup
                  (funcall inherited-setup))
                (when finish-function
                  (add-hook 'compilation-finish-functions
                            finish-function nil t)))
            compilation-process-setup-function))
         (compilation-buffer-name-function (lambda (_mode) buffer-name)))
    (when resource-key
      (kmode-assert-resource-available resource-key))
    ;; `compilation-start' may reuse and reinitialize a finished buffer.  Seed
    ;; the desired permanent locals so its start hook cannot act on stale
    ;; output/profile ownership from the previous invocation.
    (when-let ((existing-buffer (get-buffer buffer-name)))
      (with-current-buffer existing-buffer
        (setq-local kmode-process-root root)
        (setq-local kmode-process-profile profile)
        (setq-local kmode-process-resource resource-key)))
    (let ((buffer
           (compilation-start command (or mode 'kmode-compilation-mode)
                              (lambda (_mode) buffer-name))))
      (kmode-mark-process-context buffer root profile)
      (when resource-key
        (kmode-mark-process-resource buffer resource-key))
      buffer)))

(defun kmode-start-command
    (label program arguments
           &optional directory mode resource context finish-function)
  "Run PROGRAM with ARGUMENTS asynchronously in a compilation buffer.

LABEL, DIRECTORY, MODE, RESOURCE, CONTEXT, and FINISH-FUNCTION have the
meanings documented by `kmode-start-shell-command'.  PROGRAM and each item in
ARGUMENTS are shell quoted as distinct argv tokens."
  (kmode-start-shell-command
   label (kmode-shell-command program arguments)
   directory mode resource context finish-function))

(defun kmode-file-in-root (&optional file context)
  "Return FILE relative to CONTEXT's root, or signal a user error."
  (let* ((context (or context (kmode-resolve-context)))
         (root (kmode-context-root context))
         (file (expand-file-name (or file
                                     buffer-file-name
                                     (user-error "The current buffer has no file")))))
    (unless (file-in-directory-p file root)
      (user-error "%s is outside kernel tree %s" file root))
    (file-relative-name file root)))

(provide 'kmode-core)

;;; kmode-core.el ends here
