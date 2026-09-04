;;; kemacs-debug.el --- Kernel logs, QEMU, and GDB for Kemacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Kemacs contributors
;; Keywords: tools, c, linux, processes
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Profile-aware runtime tools.  Kemacs does not invent VM images or privileged
;; policy: users describe a QEMU argv in a profile, while this module resolves
;; the exact kernel image and vmlinux belonging to that profile.

;;; Code:

(require 'cl-lib)
(require 'comint)
(require 'kemacs-build)
(require 'kemacs-core)
(require 'seq)
(require 'subr-x)

(declare-function gdb "gdb-mi" (command-line))

(defcustom kemacs-gdb-program "gdb"
  "GDB executable used for kernel debugging."
  :type 'string
  :group 'kemacs)

(defcustom kemacs-default-gdb-target ":1234"
  "Default GDB remote target when a profile does not provide one."
  :type 'string
  :group 'kemacs)

(defcustom kemacs-dmesg-command '("dmesg" "--follow" "--human" "--decode")
  "Program and arguments used to stream the local kernel log."
  :type '(repeat string)
  :group 'kemacs)

(defcustom kemacs-architecture-images
  '(("x86" . "arch/x86/boot/bzImage")
    ("x86_64" . "arch/x86/boot/bzImage")
    ("i386" . "arch/x86/boot/bzImage")
    ("arm64" . "arch/arm64/boot/Image")
    ("arm" . "arch/arm/boot/zImage")
    ("riscv" . "arch/riscv/boot/Image")
    ("powerpc" . "vmlinux"))
  "Default kernel image path for each ARCH, relative to profile output."
  :type '(alist :key-type string :value-type string)
  :group 'kemacs)

(defcustom kemacs-log-incident-regexp
  (concat "\\b\\(?:BUG:\\|WARNING:\\|Oops:\\|Kernel panic\\|"
          "KASAN:\\|KCSAN:\\|UBSAN:\\|INFO: task .* blocked\\|"
          "possible circular locking dependency\\)")
  "Regexp identifying the start of a serious kernel log incident."
  :type 'regexp
  :group 'kemacs)

(defvar kemacs-log-font-lock-keywords
  (list
   (cons kemacs-log-incident-regexp 'font-lock-warning-face)
   '("\\b\\(?:Call Trace:\\|RIP:\\|PC is at\\|Tainted:\\)\\b"
     . font-lock-keyword-face)
   '("\\b\\(?:error\\|failed\\|failure\\|panic\\|corruption\\)\\b"
     . font-lock-warning-face)
   '("\\b\\(?:passed\\|ok\\|success\\)\\b" . font-lock-constant-face))
  "Font-lock rules for Kemacs kernel log buffers.")

(define-derived-mode kemacs-log-mode kemacs-compilation-mode "Kemacs-Log"
  "Major mode for decoded or streaming Linux kernel logs."
  (setq-local font-lock-defaults '(kemacs-log-font-lock-keywords t))
  (setq-local compilation-scroll-output t))

(defun kemacs-vmlinux (&optional context must-exist)
  "Return the profile's vmlinux path.

CONTEXT defaults to the active context.  If MUST-EXIST is non-nil,
signal a user error when no readable vmlinux is present."
  (let* ((context (or context (kemacs-resolve-context)))
         (configured (kemacs-context-vmlinux context))
         (path (if (and configured (file-name-absolute-p configured))
                   configured
                 (expand-file-name (or configured "vmlinux")
                                   (kemacs-context-output context)))))
    (when (and must-exist (not (file-readable-p path)))
      (user-error "No vmlinux for profile %s at %s; build the profile first"
                  (kemacs-context-profile context) path))
    path))

(defun kemacs-kernel-image (&optional context must-exist)
  "Return the bootable kernel image belonging to CONTEXT.

If MUST-EXIST is non-nil, signal a user error when it is missing."
  (let* ((context (or context (kemacs-resolve-context)))
         (configured (kemacs-context-image context))
         (arch (or (kemacs-context-arch context) "x86_64"))
         (relative (or configured (cdr (assoc arch kemacs-architecture-images))))
         (path (and relative
                    (if (file-name-absolute-p relative)
                        relative
                      (expand-file-name relative
                                        (kemacs-context-output context))))))
    (unless path
      (user-error "No default image is known for ARCH=%s; add :image to the profile"
                  arch))
    (when (and must-exist (not (file-readable-p path)))
      (user-error "No kernel image for profile %s at %s; build it first"
                  (kemacs-context-profile context) path))
    path))

(defun kemacs--expand-runtime-token (token context)
  "Expand Kemacs placeholders in TOKEN using CONTEXT."
  (let ((replacements
         (list
          (cons "%i" (lambda () (kemacs-kernel-image context)))
          (cons "%v" (lambda () (kemacs-vmlinux context)))
          (cons "%o" (lambda ()
                         (directory-file-name
                          (kemacs-context-output context))))
          (cons "%r" (lambda ()
                         (directory-file-name
                          (kemacs-context-root context))))
          (cons "%p" (lambda () (kemacs-context-profile context))))))
    (dolist (replacement replacements token)
      (when (string-match-p (regexp-quote (car replacement)) token)
        (setq token
              (replace-regexp-in-string
               (regexp-quote (car replacement))
               (funcall (cdr replacement)) token t t))))))

(defun kemacs-qemu-arguments (&optional context)
  "Return the expanded QEMU argv for CONTEXT.

The profile property :qemu-command must be a list whose first item is
the executable.  Supported placeholders are %i (image), %v (vmlinux),
%o (output), %r (source root), and %p (profile name)."
  (let* ((context (or context (kemacs-resolve-context)))
         (command (kemacs-context-qemu-command context)))
    (unless (and (listp command) (stringp (car command)))
      (user-error "Profile %s has no :qemu-command argv"
                  (kemacs-context-profile context)))
    (mapcar (lambda (token)
              (unless (stringp token)
                (user-error "Every :qemu-command item must be a string"))
              (kemacs--expand-runtime-token token context))
            command)))

(defun kemacs--qemu-endpoint-resource (endpoint)
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

(defun kemacs-qemu-runtime-resources (arguments &optional directory)
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
                        (kemacs--qemu-endpoint-resource (pop remaining))))
              (push resource resources))))
         ((string-match "\\`-\\(?:gdb\\|qmp\\)=\\(.+\\)\\'" argument)
          (when-let ((resource
                      (kemacs--qemu-endpoint-resource (match-string 1 argument))))
            (push resource resources))))))
    (delete-dups (nreverse resources))))

(defun kemacs--runtime-buffer-name (kind context)
  "Return a process buffer name for KIND and CONTEXT."
  (format "*kemacs:%s:%s:%s*"
          (kemacs-root-id (kemacs-context-root context))
          (kemacs-context-profile context) kind))

(defun kemacs--runtime-process (kind context)
  "Return the live KIND process tagged for CONTEXT, or nil."
  (seq-find
   (lambda (process)
     (and (process-live-p process)
          (eq kind (process-get process 'kemacs-runtime-kind))
          (equal (kemacs-context-root context)
                 (process-get process 'kemacs-root))
          (equal (kemacs-context-profile context)
                 (process-get process 'kemacs-profile))))
   (process-list)))

;;;###autoload
(defun kemacs-qemu-run ()
  "Boot the QEMU command configured by the active profile."
  (interactive)
  (let* ((context (kemacs-resolve-context))
         (raw-command (kemacs-context-qemu-command context))
         (command (kemacs-qemu-arguments context))
         (_image (when (seq-some (lambda (token)
                                   (and (stringp token)
                                        (string-match-p "%i" token)))
                                 raw-command)
                   (kemacs-kernel-image context t)))
         (_vmlinux (when (seq-some (lambda (token)
                                     (and (stringp token)
                                          (string-match-p "%v" token)))
                                   raw-command)
                     (kemacs-vmlinux context t)))
         (program (kemacs-require-tool (car command) context))
         (arguments (cdr command))
         (runtime-resources
          (kemacs-qemu-runtime-resources
           arguments (kemacs-context-root context)))
         (output (kemacs-context-output context))
         (base-buffer-name (kemacs--runtime-buffer-name "qemu" context))
         (old-buffer (get-buffer base-buffer-name))
         (existing (or (and old-buffer (get-buffer-process old-buffer))
                       (kemacs--runtime-process 'qemu context)))
         (buffer-name (generate-new-buffer-name base-buffer-name))
         (name (substring buffer-name 1 -1))
         (default-directory (kemacs-context-root context))
         (process-environment (kemacs-build-process-environment context))
         buffer process)
    (when (process-live-p existing)
      (user-error "QEMU is already running for profile %s"
                  (kemacs-context-profile context)))
    (kemacs-assert-resource-available output)
    (kemacs-assert-runtime-resources-available runtime-resources)
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
          (kemacs-mark-process-context buffer
                                       (kemacs-context-root context)
                                       (kemacs-context-profile context))
          (kemacs-mark-process-resource buffer output)
          (process-put process 'kemacs-runtime-kind 'qemu)
          (process-put process 'kemacs-context (copy-kemacs-context context))
          (kemacs-mark-process-runtime-resources process runtime-resources)
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
(defun kemacs-qemu-stop ()
  "Interrupt the active profile's QEMU process."
  (interactive)
  (let* ((context (kemacs-resolve-context))
         (buffer (get-buffer (kemacs--runtime-buffer-name "qemu" context)))
         (process (or (and buffer (get-buffer-process buffer))
                      (kemacs--runtime-process 'qemu context))))
    (unless (process-live-p process)
      (user-error "No QEMU process is running for profile %s"
                  (kemacs-context-profile context)))
    (interrupt-process process)
    (message "Sent interrupt to %s" (process-name process))))

;;;###autoload
(defun kemacs-gdb-attach (&optional target context)
  "Open Emacs GDB and attach to a profile's remote stub.

TARGET overrides the profile endpoint.  CONTEXT defaults to the active
kernel context; callers can pass a runtime's pinned context to guarantee
that GDB uses the matching vmlinux."
  (interactive)
  (unless (require 'gdb-mi nil t)
    (user-error "This Emacs has no GDB graphical interface"))
  (let* ((context (or context (kemacs-resolve-context)))
         (program (kemacs-require-tool kemacs-gdb-program context))
         (vmlinux (kemacs-vmlinux context t))
         (target (or target
                     (kemacs-context-gdb-target context)
                     kemacs-default-gdb-target))
         (_target-check
          (unless (and (stringp target)
                       (not (string-empty-p target))
                       (not (string-match-p
                             "[[:cntrl:][:space:]]" target)))
            (user-error "GDB target must be one non-empty endpoint, got %S"
                        target)))
         (command (kemacs-shell-command
                   program
                   (list "-i=mi" vmlinux "-ex"
                         (concat "target remote " target)))))
    (gdb command)))

(defun kemacs--decode-stacktrace (text)
  "Decode kernel stacktrace TEXT with artifacts from the active profile."
  (let* ((context (kemacs-resolve-context))
         (root (kemacs-context-root context))
         (script (kemacs-require-tool "scripts/decode_stacktrace.sh" context))
         (vmlinux (kemacs-vmlinux context t))
         (name (kemacs--runtime-buffer-name "decoded-log" context))
         (buffer (get-buffer name))
         (existing (or (and buffer (get-buffer-process buffer))
                       (kemacs--runtime-process 'decode-stacktrace context)))
         (default-directory root)
         process)
    (when (process-live-p existing)
      (user-error "A stacktrace decode is already running for profile %s"
                  (kemacs-context-profile context)))
    (setq buffer (or buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer))
      (kemacs-log-mode))
    (setq process
          (make-process
           :name (substring name 1 -1)
           :buffer buffer
           :command (list script vmlinux root)
           :connection-type 'pipe
           :noquery t))
    (process-put process 'kemacs-root root)
    (process-put process 'kemacs-profile
                 (kemacs-context-profile context))
    (process-put process 'kemacs-runtime-kind 'decode-stacktrace)
    (process-send-string process text)
    (process-send-eof process)
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun kemacs-decode-stacktrace-region (begin end)
  "Decode the kernel stacktrace between BEGIN and END."
  (interactive "r")
  (unless (use-region-p)
    (user-error "Select a kernel stacktrace first"))
  (kemacs--decode-stacktrace
   (buffer-substring-no-properties begin end)))

;;;###autoload
(defun kemacs-decode-stacktrace-buffer ()
  "Decode the kernel stacktrace in the current buffer."
  (interactive)
  (kemacs--decode-stacktrace
   (buffer-substring-no-properties (point-min) (point-max))))

;;;###autoload
(defun kemacs-dmesg-follow ()
  "Stream the local kernel log in a clickable Kemacs log buffer."
  (interactive)
  (unless (and (listp kemacs-dmesg-command)
               (stringp (car kemacs-dmesg-command))
               (not (string-empty-p (car kemacs-dmesg-command)))
               (cl-every #'stringp kemacs-dmesg-command))
    (user-error "Set kemacs-dmesg-command to a program argv list"))
  (let* ((context (kemacs-resolve-context))
         (program (kemacs-require-tool (car kemacs-dmesg-command) context)))
    (kemacs-start-command
     "dmesg" program (cdr kemacs-dmesg-command)
     (kemacs-context-root context) 'kemacs-log-mode nil context)))

;;;###autoload
(defun kemacs-open-kernel-log (file)
  "Visit kernel log FILE using Kemacs incident highlighting."
  (interactive "fKernel log file: ")
  (find-file file)
  (kemacs-log-mode))

;;;###autoload
(defun kemacs-log-next-incident (&optional count)
  "Move to the next kernel incident, repeating COUNT times."
  (interactive "p")
  (let ((count (or count 1)))
    (dotimes (_ count)
      (end-of-line)
      (unless (re-search-forward kemacs-log-incident-regexp nil t)
        (user-error "No later kernel incident"))
      (beginning-of-line))))

;;;###autoload
(defun kemacs-log-previous-incident (&optional count)
  "Move to the previous kernel incident, repeating COUNT times."
  (interactive "p")
  (let ((count (or count 1)))
    (dotimes (_ count)
      (beginning-of-line)
      (unless (re-search-backward kemacs-log-incident-regexp nil t)
        (user-error "No earlier kernel incident"))
      (beginning-of-line))))

(define-key kemacs-log-mode-map (kbd "n") #'kemacs-log-next-incident)
(define-key kemacs-log-mode-map (kbd "p") #'kemacs-log-previous-incident)
(define-key kemacs-log-mode-map (kbd "d") #'kemacs-decode-stacktrace-buffer)

(kemacs-register-action
 'decode-log "Decode stacktrace buffer" "Debug" #'kemacs-decode-stacktrace-buffer
 :predicate (lambda () (and (kemacs-tool-path "scripts/decode_stacktrace.sh")
                            (file-readable-p (kemacs-vmlinux nil nil)))))
(kemacs-register-action
 'dmesg "Follow local dmesg" "Debug" #'kemacs-dmesg-follow
 :predicate (lambda () (and kemacs-dmesg-command
                            (kemacs-tool-path (car kemacs-dmesg-command)))))
(kemacs-register-action
 'qemu "Boot active QEMU profile" "Debug" #'kemacs-qemu-run
 :predicate (lambda ()
              (condition-case nil
                  (let* ((context (kemacs-resolve-context))
                         (command (kemacs-qemu-arguments context)))
                    (kemacs-tool-path (car command) context))
                (error nil))))
(kemacs-register-action
 'gdb "Attach GDB to kernel" "Debug" #'kemacs-gdb-attach
 :predicate (lambda () (kemacs-tool-path kemacs-gdb-program)))

(provide 'kemacs-debug)

;;; kemacs-debug.el ends here
