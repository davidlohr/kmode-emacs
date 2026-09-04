;;; kemacs-flymake.el --- Live checkpatch diagnostics for Kemacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Kemacs contributors
;; Keywords: tools, c, linux
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; An opt-in asynchronous Flymake backend for checking the unsaved contents of
;; kernel C, assembly, and Rust buffers with the tree's checkpatch.pl.  The
;; backend adds its diagnostics alongside Eglot and other Flymake backends.

;;; Code:

(require 'cl-lib)
(require 'flymake)
(require 'kemacs-core)
(require 'subr-x)

(defgroup kemacs-flymake nil
  "Live kernel source diagnostics from checkpatch."
  :group 'kemacs
  :prefix "kemacs-checkpatch-flymake-")

(defcustom kemacs-checkpatch-flymake-arguments '("--strict")
  "Additional checkpatch arguments used for live diagnostics.

Each item is passed directly to checkpatch.pl as one process argument.  Kemacs
always adds `--no-tree', `--file', and the temporary source path."
  :type '(repeat string)
  :group 'kemacs-flymake)

(defcustom kemacs-checkpatch-flymake-extensions
  '(".c" ".h" ".S" ".s" ".rs")
  "Source extensions accepted by live checkpatch diagnostics."
  :type '(repeat string)
  :group 'kemacs-flymake)

(defvar-local kemacs-checkpatch-flymake--process nil
  "Current checkpatch process for this source buffer.")

(defvar-local kemacs-checkpatch-flymake--request nil
  "Identity token of the current live checkpatch request.")

(defvar-local kemacs-checkpatch-flymake--temporary-file nil
  "Temporary source snapshot used by the current checkpatch process.")

(defvar-local kemacs-checkpatch-flymake--output-buffer nil
  "Process output buffer used by the current checkpatch process.")

(defvar-local kemacs-checkpatch-flymake--report-function nil
  "Most recent Flymake report callback for this backend.")

(defvar-local kemacs-checkpatch-flymake--started-flymake nil
  "Non-nil when live checkpatch enabled `flymake-mode' itself.")

(defconst kemacs-checkpatch-flymake--heading-regexp
  "^[ \t]*\\(ERROR\\|WARNING\\|CHECK\\)[ \t]*:[ \t]*\\(.*\\)$"
  "Regexp matching a checkpatch diagnostic heading.")

(defconst kemacs-checkpatch-flymake--location-regexp
  (concat "^[ \t]*\\(?:#[0-9]+:[ \t]*\\)?"
          "FILE:[ \t]*\\(.+?\\):\\([0-9]+\\)"
          "\\(?::\\([0-9]+\\)\\)?:[ \t]*$")
  "Regexp matching a checkpatch FILE location line.")

(defun kemacs-checkpatch-flymake--source-extension ()
  "Return a suitable temporary-file extension for the current buffer."
  (let ((extension (and buffer-file-name
                        (file-name-extension buffer-file-name t))))
    (cond
     ((member extension kemacs-checkpatch-flymake-extensions) extension)
     ((memq major-mode '(rust-mode rust-ts-mode)) ".rs")
     ((derived-mode-p 'asm-mode) ".S")
     ((or (derived-mode-p 'c-mode) (derived-mode-p 'c-ts-mode)) ".c"))))

(defun kemacs-checkpatch-flymake--tool (context)
  "Return CONTEXT's executable in-tree checkpatch path, or nil."
  (let ((tool (expand-file-name "scripts/checkpatch.pl"
                                (kemacs-context-root context))))
    (and (file-executable-p tool) tool)))

(defun kemacs-checkpatch-flymake--require-tool (context)
  "Return CONTEXT's in-tree checkpatch path or signal an actionable error."
  (or (kemacs-checkpatch-flymake--tool context)
      (user-error
       "Live checkpatch needs executable scripts/checkpatch.pl in this kernel tree")))

(defun kemacs-checkpatch-flymake--diagnostic-type (severity)
  "Return the Flymake diagnostic type corresponding to SEVERITY."
  (pcase severity
    ("ERROR" :error)
    ("WARNING" :warning)
    (_ :note)))

(defun kemacs-checkpatch-flymake--make-diagnostic
    (source line column severity message)
  "Create a SOURCE diagnostic at LINE and COLUMN for SEVERITY and MESSAGE."
  (let* ((region (or (flymake-diag-region source line column)
                     (flymake-diag-region source line)))
         (text (if (string-empty-p message)
                   (format "checkpatch %s" severity)
                 (format "checkpatch %s: %s" severity message))))
    (when region
      (flymake-make-diagnostic source (car region) (cdr region)
                               (kemacs-checkpatch-flymake--diagnostic-type
                                severity)
                               text))))

(defun kemacs-checkpatch-flymake--parse-output (output source)
  "Parse checkpatch OUTPUT into Flymake diagnostics for SOURCE."
  (let (pending-severity pending-message diagnostics)
    (when (and (buffer-live-p output) (buffer-live-p source))
      (with-current-buffer output
        (save-excursion
          (save-match-data
            (let ((case-fold-search nil))
              (goto-char (point-min))
              (while (not (eobp))
                (cond
                 ((looking-at kemacs-checkpatch-flymake--heading-regexp)
                  (setq pending-severity (match-string-no-properties 1)
                        pending-message
                        (string-trim (match-string-no-properties 2))))
                 ((and pending-severity
                       (looking-at
                        kemacs-checkpatch-flymake--location-regexp))
                  (let* ((line (string-to-number
                                (match-string-no-properties 2)))
                         (column-text (match-string-no-properties 3))
                         (column (and column-text
                                      (string-to-number column-text)))
                         (diagnostic
                          (kemacs-checkpatch-flymake--make-diagnostic
                           source line column pending-severity
                           pending-message)))
                    (when diagnostic
                      (push diagnostic diagnostics))
                    (setq pending-severity nil
                          pending-message nil))))
                (forward-line 1)))))))
    (nreverse diagnostics)))

(defun kemacs-checkpatch-flymake--cleanup-files (temporary output)
  "Delete TEMPORARY and kill the process OUTPUT buffer when they exist."
  (when (and temporary (file-exists-p temporary))
    (ignore-errors (delete-file temporary)))
  (when (buffer-live-p output)
    (kill-buffer output)))

(defun kemacs-checkpatch-flymake--cancel ()
  "Cancel and clean the current buffer's live checkpatch request."
  (let ((process kemacs-checkpatch-flymake--process)
        (temporary kemacs-checkpatch-flymake--temporary-file)
        (output kemacs-checkpatch-flymake--output-buffer))
    ;; Clear identity first so a queued sentinel can never report stale data.
    (setq kemacs-checkpatch-flymake--request nil
          kemacs-checkpatch-flymake--process nil
          kemacs-checkpatch-flymake--temporary-file nil
          kemacs-checkpatch-flymake--output-buffer nil)
    (when (processp process)
      (set-process-sentinel process #'ignore)
      (when (process-live-p process)
        (delete-process process)))
    (kemacs-checkpatch-flymake--cleanup-files temporary output)))

(defun kemacs-checkpatch-flymake--report-panic (report-function explanation)
  "Call REPORT-FUNCTION with a Flymake panic and EXPLANATION."
  (funcall report-function :panic :explanation explanation))

(defun kemacs-checkpatch-flymake--sentinel
    (process _event source report-function request temporary output)
  "Handle PROCESS completion for SOURCE using REPORT-FUNCTION.

REQUEST identifies the invocation that owns TEMPORARY and OUTPUT."
  (when (memq (process-status process) '(exit signal closed failed))
    (unwind-protect
        (when (buffer-live-p source)
          (with-current-buffer source
            (when (eq request kemacs-checkpatch-flymake--request)
              (setq kemacs-checkpatch-flymake--request nil
                    kemacs-checkpatch-flymake--process nil
                    kemacs-checkpatch-flymake--temporary-file nil
                    kemacs-checkpatch-flymake--output-buffer nil)
              (if (eq (process-status process) 'signal)
                  (kemacs-checkpatch-flymake--report-panic
                   report-function "Live checkpatch process was interrupted")
                ;; checkpatch normally exits nonzero when it found diagnostics,
                ;; so its parsed output, rather than its status, is authoritative.
                (funcall report-function
                         (kemacs-checkpatch-flymake--parse-output
                          output source))))))
      (kemacs-checkpatch-flymake--cleanup-files temporary output))))

(defun kemacs-checkpatch-flymake (report-function &rest _arguments)
  "Run asynchronous checkpatch and call REPORT-FUNCTION with diagnostics."
  (setq kemacs-checkpatch-flymake--report-function report-function)
  (kemacs-checkpatch-flymake--cancel)
  (let ((source (current-buffer))
        (extension (kemacs-checkpatch-flymake--source-extension))
        request
        temporary
        output)
    (condition-case error-data
        (let* ((context (kemacs-resolve-context))
               (root (kemacs-context-root context))
               (tool (kemacs-checkpatch-flymake--require-tool context)))
          (unless extension
            (user-error "Live checkpatch supports only C, assembly, and Rust buffers"))
          (unless (and (listp kemacs-checkpatch-flymake-arguments)
                       (cl-every #'stringp
                                 kemacs-checkpatch-flymake-arguments))
            (user-error
             "kemacs-checkpatch-flymake-arguments must contain only strings"))
          (setq temporary
                (make-temp-file "kemacs-checkpatch-" nil extension)
                output
                (generate-new-buffer " *kemacs-checkpatch-flymake*"))
          (let ((coding-system-for-write buffer-file-coding-system))
            (save-restriction
              (widen)
              (write-region (point-min) (point-max)
                            temporary nil 'silent)))
          ;; Install request ownership before spawning.  A very short-lived
          ;; process may run its sentinel from inside `make-process'.
          (setq request (make-symbol "kemacs-checkpatch-request")
                kemacs-checkpatch-flymake--request request
                kemacs-checkpatch-flymake--process nil
                kemacs-checkpatch-flymake--temporary-file temporary
                kemacs-checkpatch-flymake--output-buffer output)
          (let* ((default-directory root)
                 (command
                  (append (list tool "--no-tree")
                          kemacs-checkpatch-flymake-arguments
                          (list "--file" temporary)))
                 process)
            (setq process
                  (make-process
                   :name (format "kemacs-checkpatch:%s" (buffer-name source))
                   :buffer output
                   :command command
                   :connection-type 'pipe
                   :coding 'utf-8-unix
                   :noquery t
                   :sentinel
                   (lambda (finished-process event)
                     (kemacs-checkpatch-flymake--sentinel
                      finished-process event source report-function
                      request temporary output))))
            (if (eq request kemacs-checkpatch-flymake--request)
                (setq kemacs-checkpatch-flymake--process process)
              ;; Completion or cancellation won the race while spawning.
              (when (processp process)
                (set-process-sentinel process #'ignore)
                (when (process-live-p process)
                  (delete-process process)))
              (kemacs-checkpatch-flymake--cleanup-files temporary output))))
      (quit
       (when (or (null request)
                 (eq request kemacs-checkpatch-flymake--request))
         (setq kemacs-checkpatch-flymake--request nil
               kemacs-checkpatch-flymake--process nil
               kemacs-checkpatch-flymake--temporary-file nil
               kemacs-checkpatch-flymake--output-buffer nil))
       (kemacs-checkpatch-flymake--cleanup-files temporary output)
       (signal 'quit nil))
      (error
       (let ((owns-request
              (or (null request)
                  (eq request kemacs-checkpatch-flymake--request))))
         (when (and request owns-request)
           (setq kemacs-checkpatch-flymake--request nil
                 kemacs-checkpatch-flymake--process nil
                 kemacs-checkpatch-flymake--temporary-file nil
                 kemacs-checkpatch-flymake--output-buffer nil))
         (kemacs-checkpatch-flymake--cleanup-files temporary output)
         ;; Do not emit a second report if a synchronous sentinel already
         ;; completed this request before `make-process' returned.
         (when owns-request
           (kemacs-checkpatch-flymake--report-panic
            report-function (error-message-string error-data))))))))

(defun kemacs-checkpatch-flymake-available-p ()
  "Return non-nil when live checkpatch can run in the current buffer."
  (or (bound-and-true-p kemacs-checkpatch-flymake-mode)
      (and (kemacs-checkpatch-flymake--source-extension)
           (condition-case nil
               (when-let ((root (kemacs-root t)))
                 (kemacs-checkpatch-flymake--tool
                  (kemacs-resolve-context root)))
             (error nil)))))

;;;###autoload
(define-minor-mode kemacs-checkpatch-flymake-mode
  "Toggle live checkpatch diagnostics in the current kernel source buffer.

This mode adds one asynchronous backend to `flymake-diagnostic-functions'.
It preserves other backends, including Eglot, and is disabled by default."
  :lighter " CP"
  :group 'kemacs-flymake
  (if kemacs-checkpatch-flymake-mode
      (condition-case error-data
          (progn
            (let* ((root (kemacs-root))
                   (context (kemacs-resolve-context root)))
              (kemacs-checkpatch-flymake--require-tool context))
            (unless (kemacs-checkpatch-flymake--source-extension)
              (user-error
               "Live checkpatch supports only C, assembly, and Rust buffers"))
            (add-hook 'flymake-diagnostic-functions
                      #'kemacs-checkpatch-flymake t t)
            (add-hook 'kill-buffer-hook
                      #'kemacs-checkpatch-flymake--cancel nil t)
            (setq kemacs-checkpatch-flymake--started-flymake
                  (not flymake-mode))
            (if flymake-mode
                (flymake-start nil t)
              (flymake-mode 1)))
        ((error quit)
         (setq kemacs-checkpatch-flymake-mode nil)
         (remove-hook 'flymake-diagnostic-functions
                      #'kemacs-checkpatch-flymake t)
         (remove-hook 'kill-buffer-hook
                      #'kemacs-checkpatch-flymake--cancel t)
         (kemacs-checkpatch-flymake--cancel)
         (when kemacs-checkpatch-flymake--started-flymake
           (setq kemacs-checkpatch-flymake--started-flymake nil)
           (when flymake-mode
             (flymake-mode -1)))
         (signal (car error-data) (cdr error-data))))
    (when kemacs-checkpatch-flymake--report-function
      (ignore-errors
        (funcall kemacs-checkpatch-flymake--report-function nil)))
    (setq kemacs-checkpatch-flymake--report-function nil)
    (remove-hook 'flymake-diagnostic-functions
                 #'kemacs-checkpatch-flymake t)
    (remove-hook 'kill-buffer-hook
                 #'kemacs-checkpatch-flymake--cancel t)
    (kemacs-checkpatch-flymake--cancel)
    (when kemacs-checkpatch-flymake--started-flymake
      (setq kemacs-checkpatch-flymake--started-flymake nil)
      (when flymake-mode
        (flymake-mode -1)))))

(kemacs-register-action
 'checkpatch-flymake "Toggle live checkpatch" "Check"
 #'kemacs-checkpatch-flymake-mode
 :predicate #'kemacs-checkpatch-flymake-available-p
 :description "Check unsaved C, assembly, and Rust buffers with checkpatch")

(provide 'kemacs-flymake)

;;; kemacs-flymake.el ends here
