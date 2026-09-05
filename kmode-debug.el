;;; kmode-debug.el --- Kernel logs, QEMU, and GDB for kmode-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: kmode-emacs contributors
;; Keywords: tools, c, linux, processes
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Profile-aware runtime tools.  kmode-emacs does not invent VM images or privileged
;; policy: users describe a QEMU argv in a profile, while this module resolves
;; the exact kernel image and vmlinux belonging to that profile.

;;; Code:

(require 'cl-lib)
(require 'comint)
(require 'kmode-build)
(require 'kmode-core)
(require 'seq)
(require 'subr-x)

(declare-function gdb "gdb-mi" (command-line))

(defcustom kmode-gdb-program "gdb"
  "GDB executable used for kernel debugging."
  :type 'string
  :group 'kmode)

(defcustom kmode-default-gdb-target ":1234"
  "Default GDB remote target when a profile does not provide one."
  :type 'string
  :group 'kmode)

(defcustom kmode-dmesg-command '("dmesg" "--follow" "--human" "--decode")
  "Program and arguments used to stream the local kernel log."
  :type '(repeat string)
  :group 'kmode)

(defcustom kmode-architecture-images
  '(("x86" . "arch/x86/boot/bzImage")
    ("x86_64" . "arch/x86/boot/bzImage")
    ("i386" . "arch/x86/boot/bzImage")
    ("arm64" . "arch/arm64/boot/Image")
    ("arm" . "arch/arm/boot/zImage")
    ("riscv" . "arch/riscv/boot/Image")
    ("powerpc" . "vmlinux"))
  "Default kernel image path for each ARCH, relative to profile output."
  :type '(alist :key-type string :value-type string)
  :group 'kmode)

(defcustom kmode-log-incident-regexp
  (concat "\\b\\(?:BUG:\\|WARNING:\\|Oops:\\|Kernel panic\\|"
          "KASAN:\\|KCSAN:\\|UBSAN:\\|INFO: task .* blocked\\|"
          "possible circular locking dependency\\)")
  "Regexp identifying the start of a serious kernel log incident."
  :type 'regexp
  :group 'kmode)

(defvar kmode-log-font-lock-keywords
  (list
   (cons kmode-log-incident-regexp 'font-lock-warning-face)
   '("\\b\\(?:Call Trace:\\|RIP:\\|PC is at\\|Tainted:\\)\\b"
     . font-lock-keyword-face)
   '("\\b\\(?:error\\|failed\\|failure\\|panic\\|corruption\\)\\b"
     . font-lock-warning-face)
   '("\\b\\(?:passed\\|ok\\|success\\)\\b" . font-lock-constant-face))
  "Font-lock rules for kmode-emacs kernel log buffers.")

(define-derived-mode kmode-log-mode kmode-compilation-mode "kmode-emacs-Log"
  "Major mode for decoded or streaming Linux kernel logs."
  (setq-local font-lock-defaults '(kmode-log-font-lock-keywords t))
  (setq-local compilation-scroll-output t))

(defun kmode-vmlinux (&optional context must-exist)
  "Return the profile's vmlinux path.

CONTEXT defaults to the active context.  If MUST-EXIST is non-nil,
signal a user error when no readable vmlinux is present."
  (let* ((context (or context (kmode-resolve-context)))
         (configured (kmode-context-vmlinux context))
         (path (if (and configured (file-name-absolute-p configured))
                   configured
                 (expand-file-name (or configured "vmlinux")
                                   (kmode-context-output context)))))
    (when (and must-exist (not (file-readable-p path)))
      (user-error "No vmlinux for profile %s at %s; build the profile first"
                  (kmode-context-profile context) path))
    path))

(defun kmode-kernel-image (&optional context must-exist)
  "Return the bootable kernel image belonging to CONTEXT.

If MUST-EXIST is non-nil, signal a user error when it is missing."
  (let* ((context (or context (kmode-resolve-context)))
         (configured (kmode-context-image context))
         (arch (or (kmode-context-arch context) "x86_64"))
         (relative (or configured (cdr (assoc arch kmode-architecture-images))))
         (path (and relative
                    (if (file-name-absolute-p relative)
                        relative
                      (expand-file-name relative
                                        (kmode-context-output context))))))
    (unless path
      (user-error "No default image is known for ARCH=%s; add :image to the profile"
                  arch))
    (when (and must-exist (not (file-readable-p path)))
      (user-error "No kernel image for profile %s at %s; build it first"
                  (kmode-context-profile context) path))
    path))

(defun kmode--expand-runtime-token (token context)
  "Expand kmode-emacs placeholders in TOKEN using CONTEXT."
  (let ((replacements
         (list
          (cons "%i" (lambda () (kmode-kernel-image context)))
          (cons "%v" (lambda () (kmode-vmlinux context)))
          (cons "%o" (lambda ()
                         (directory-file-name
                          (kmode-context-output context))))
          (cons "%r" (lambda ()
                         (directory-file-name
                          (kmode-context-root context))))
          (cons "%p" (lambda () (kmode-context-profile context))))))
    (dolist (replacement replacements token)
      (when (string-match-p (regexp-quote (car replacement)) token)
        (setq token
              (replace-regexp-in-string
               (regexp-quote (car replacement))
               (funcall (cdr replacement)) token t t))))))

(defun kmode-qemu-arguments (&optional context)
  "Return the expanded QEMU argv for CONTEXT.

The profile property :qemu-command must be a list whose first item is
the executable.  Supported placeholders are %i (image), %v (vmlinux),
%o (output), %r (source root), and %p (profile name)."
  (let* ((context (or context (kmode-resolve-context)))
         (command (kmode-context-qemu-command context)))
    (unless (and (listp command) (stringp (car command)))
      (user-error "Profile %s has no :qemu-command argv"
                  (kmode-context-profile context)))
    (mapcar (lambda (token)
              (unless (stringp token)
                (user-error "Every :qemu-command item must be a string"))
              (kmode--expand-runtime-token token context))
            command)))

(defun kmode--qemu-endpoint-resource (endpoint)
  "Return a named runtime resource for QEMU ENDPOINT, or nil."
  (when (stringp endpoint)
    (let ((address (car (split-string endpoint "," t))))
      (cond
       ((and (string-prefix-p "tcp:" address)
             (string-match ":\\([0-9]+\\)\\'" address))
        (concat "tcp-port:"
                (number-to-string
                 (string-to-number (match-string 1 address)))))
       ((string-prefix-p "unix:" address)
        (concat "unix-socket:"
                (expand-file-name (string-remove-prefix "unix:" address))))))))

(defun kmode-qemu-runtime-resources (arguments &optional directory)
  "Return endpoint resources reserved by QEMU ARGUMENTS.

The common `-s' shorthand and explicit `-gdb' and `-qmp' TCP or Unix
endpoints are recognized.  TCP ownership is conservatively keyed by port so
different bind-address spellings cannot race one another.  Relative Unix
socket paths are resolved from DIRECTORY, or `default-directory'."
  (let ((default-directory (or directory default-directory))
        (remaining (copy-sequence arguments))
        resources)
    (while remaining
      (let ((argument (pop remaining)))
        (cond
         ((equal argument "-s")
          (push "tcp-port:1234" resources))
         ((member argument '("-gdb" "-qmp"))
          (when remaining
            (when-let ((resource
                        (kmode--qemu-endpoint-resource (pop remaining))))
              (push resource resources))))
         ((string-match "\\`-\\(?:gdb\\|qmp\\)=\\(.+\\)\\'" argument)
          (when-let ((resource
                      (kmode--qemu-endpoint-resource (match-string 1 argument))))
            (push resource resources))))))
    (delete-dups (nreverse resources))))

(defun kmode--runtime-buffer-name (kind context)
  "Return a process buffer name for KIND and CONTEXT."
  (format "*kmode:%s:%s:%s*"
          (kmode-root-id (kmode-context-root context))
          (kmode-context-profile context) kind))

(defun kmode--runtime-process (kind context)
  "Return the live KIND process tagged for CONTEXT, or nil."
  (seq-find
   (lambda (process)
     (and (process-live-p process)
          (eq kind (process-get process 'kmode-runtime-kind))
          (equal (kmode-context-root context)
                 (process-get process 'kmode-root))
          (equal (kmode-context-profile context)
                 (process-get process 'kmode-profile))))
   (process-list)))

;;;###autoload
(defun kmode-qemu-run ()
  "Boot the QEMU command configured by the active profile."
  (interactive)
  (let* ((context (kmode-resolve-context))
         (raw-command (kmode-context-qemu-command context))
         (command (kmode-qemu-arguments context))
         (_image (when (seq-some (lambda (token)
                                   (and (stringp token)
                                        (string-match-p "%i" token)))
                                 raw-command)
                   (kmode-kernel-image context t)))
         (_vmlinux (when (seq-some (lambda (token)
                                     (and (stringp token)
                                          (string-match-p "%v" token)))
                                   raw-command)
                     (kmode-vmlinux context t)))
         (program (kmode-require-tool (car command) context))
         (arguments (cdr command))
         (runtime-resources
          (kmode-qemu-runtime-resources
           arguments (kmode-context-root context)))
         (output (kmode-context-output context))
         (base-buffer-name (kmode--runtime-buffer-name "qemu" context))
         (old-buffer (get-buffer base-buffer-name))
         (existing (or (and old-buffer (get-buffer-process old-buffer))
                       (kmode--runtime-process 'qemu context)))
         (buffer-name (generate-new-buffer-name base-buffer-name))
         (name (substring buffer-name 1 -1))
         (default-directory (kmode-context-root context))
         (process-environment (kmode-build-process-environment context))
         buffer process)
    (when (process-live-p existing)
      (user-error "QEMU is already running for profile %s"
                  (kmode-context-profile context)))
    (kmode-assert-resource-available output)
    (kmode-assert-runtime-resources-available runtime-resources)
    (setq buffer (get-buffer-create buffer-name))
    (condition-case error-data
        (progn
          (with-current-buffer buffer
            (let ((inhibit-read-only t))
              (erase-buffer)))
          (apply #'make-comint-in-buffer name buffer program nil arguments)
          (setq process (get-buffer-process buffer))
          (unless (processp process)
            (error "QEMU did not create a process"))
          (kmode-mark-process-context buffer
                                       (kmode-context-root context)
                                       (kmode-context-profile context))
          (kmode-mark-process-resource buffer output)
          (process-put process 'kmode-runtime-kind 'qemu)
          (process-put process 'kmode-context (copy-kmode-context context))
          (kmode-mark-process-runtime-resources process runtime-resources)
          (set-process-query-on-exit-flag process nil)
          (with-current-buffer buffer
            (setq-local comint-prompt-read-only t))
          (pop-to-buffer buffer)
          buffer)
      (error
       (when (buffer-live-p buffer)
         (when-let ((failed-process
                     (or process (get-buffer-process buffer))))
           (ignore-errors (delete-process failed-process)))
         (kill-buffer buffer))
       (signal (car error-data) (cdr error-data))))))

;;;###autoload
(defun kmode-qemu-stop ()
  "Interrupt the active profile's QEMU process."
  (interactive)
  (let* ((context (kmode-resolve-context))
         (buffer (get-buffer (kmode--runtime-buffer-name "qemu" context)))
         (process (or (and buffer (get-buffer-process buffer))
                      (kmode--runtime-process 'qemu context))))
    (unless (process-live-p process)
      (user-error "No QEMU process is running for profile %s"
                  (kmode-context-profile context)))
    (interrupt-process process)
    (message "Sent interrupt to %s" (process-name process))))

;;;###autoload
(defun kmode-gdb-attach (&optional target context)
  "Open Emacs GDB and attach to a profile's remote stub.

TARGET overrides the profile endpoint.  CONTEXT defaults to the active
kernel context; callers can pass a runtime's pinned context to guarantee
that GDB uses the matching vmlinux."
  (interactive)
  (unless (require 'gdb-mi nil t)
    (user-error "This Emacs has no GDB graphical interface"))
  (let* ((context (or context (kmode-resolve-context)))
         (program (kmode-require-tool kmode-gdb-program context))
         (vmlinux (kmode-vmlinux context t))
         (target (or target
                     (kmode-context-gdb-target context)
                     kmode-default-gdb-target))
         (_target-check
          (unless (and (stringp target)
                       (not (string-empty-p target))
                       (not (string-match-p
                             "[[:cntrl:][:space:]]" target)))
            (user-error "GDB target must be one non-empty endpoint, got %S"
                        target)))
         (command (kmode-shell-command
                   program
                   (list "-i=mi" vmlinux "-ex"
                         (concat "target remote " target)))))
    (gdb command)))

(defun kmode--decode-stacktrace (text)
  "Decode kernel stacktrace TEXT with artifacts from the active profile."
  (let* ((context (kmode-resolve-context))
         (root (kmode-context-root context))
         (script (kmode-require-tool "scripts/decode_stacktrace.sh" context))
         (vmlinux (kmode-vmlinux context t))
         (name (kmode--runtime-buffer-name "decoded-log" context))
         (buffer (get-buffer name))
         (existing (or (and buffer (get-buffer-process buffer))
                       (kmode--runtime-process 'decode-stacktrace context)))
         (default-directory root)
         process)
    (when (process-live-p existing)
      (user-error "A stacktrace decode is already running for profile %s"
                  (kmode-context-profile context)))
    (setq buffer (or buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer))
      (kmode-log-mode))
    (setq process
          (make-process
           :name (substring name 1 -1)
           :buffer buffer
           :command (list script vmlinux root)
           :connection-type 'pipe
           :noquery t))
    (process-put process 'kmode-root root)
    (process-put process 'kmode-profile
                 (kmode-context-profile context))
    (process-put process 'kmode-runtime-kind 'decode-stacktrace)
    (process-send-string process text)
    (process-send-eof process)
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun kmode-decode-stacktrace-region (begin end)
  "Decode the kernel stacktrace between BEGIN and END."
  (interactive "r")
  (unless (use-region-p)
    (user-error "Select a kernel stacktrace first"))
  (kmode--decode-stacktrace
   (buffer-substring-no-properties begin end)))

;;;###autoload
(defun kmode-decode-stacktrace-buffer ()
  "Decode the kernel stacktrace in the current buffer."
  (interactive)
  (kmode--decode-stacktrace
   (buffer-substring-no-properties (point-min) (point-max))))

;;;###autoload
(defun kmode-dmesg-follow ()
  "Stream the local kernel log in a clickable kmode-emacs log buffer."
  (interactive)
  (unless (and (listp kmode-dmesg-command)
               (stringp (car kmode-dmesg-command))
               (not (string-empty-p (car kmode-dmesg-command)))
               (cl-every #'stringp kmode-dmesg-command))
    (user-error "Set kmode-dmesg-command to a program argv list"))
  (let* ((context (kmode-resolve-context))
         (program (kmode-require-tool (car kmode-dmesg-command) context)))
    (kmode-start-command
     "dmesg" program (cdr kmode-dmesg-command)
     (kmode-context-root context) 'kmode-log-mode nil context)))

;;;###autoload
(defun kmode-open-kernel-log (file)
  "Visit kernel log FILE using kmode-emacs incident highlighting."
  (interactive "fKernel log file: ")
  (find-file file)
  (kmode-log-mode))

;;;###autoload
(defun kmode-log-next-incident (&optional count)
  "Move to the next kernel incident, repeating COUNT times."
  (interactive "p")
  (let ((count (or count 1)))
    (dotimes (_ count)
      (end-of-line)
      (unless (re-search-forward kmode-log-incident-regexp nil t)
        (user-error "No later kernel incident"))
      (beginning-of-line))))

;;;###autoload
(defun kmode-log-previous-incident (&optional count)
  "Move to the previous kernel incident, repeating COUNT times."
  (interactive "p")
  (let ((count (or count 1)))
    (dotimes (_ count)
      (beginning-of-line)
      (unless (re-search-backward kmode-log-incident-regexp nil t)
        (user-error "No earlier kernel incident"))
      (beginning-of-line))))

(define-key kmode-log-mode-map (kbd "n") #'kmode-log-next-incident)
(define-key kmode-log-mode-map (kbd "p") #'kmode-log-previous-incident)
(define-key kmode-log-mode-map (kbd "d") #'kmode-decode-stacktrace-buffer)

(kmode-register-action
 'decode-log "Decode stacktrace buffer" "Debug" #'kmode-decode-stacktrace-buffer
 :predicate (lambda () (and (kmode-tool-path "scripts/decode_stacktrace.sh")
                            (file-readable-p (kmode-vmlinux nil nil)))))
(kmode-register-action
 'dmesg "Follow local dmesg" "Debug" #'kmode-dmesg-follow
 :predicate (lambda () (and kmode-dmesg-command
                            (kmode-tool-path (car kmode-dmesg-command)))))
(kmode-register-action
 'qemu "Boot active QEMU profile" "Debug" #'kmode-qemu-run
 :predicate (lambda ()
              (condition-case nil
                  (let* ((context (kmode-resolve-context))
                         (command (kmode-qemu-arguments context)))
                    (kmode-tool-path (car command) context))
                (error nil))))
(kmode-register-action
 'gdb "Attach GDB to kernel" "Debug" #'kmode-gdb-attach
 :predicate (lambda () (kmode-tool-path kmode-gdb-program)))

(provide 'kmode-debug)

;;; kmode-debug.el ends here
