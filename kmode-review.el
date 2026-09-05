;;; kmode-review.el --- Kernel patch review workflows for kmode-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: kmode-emacs contributors
;; Keywords: tools, c, linux, vc
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Checkpatch, recipient discovery, range-diff, and a compact pre-submission
;; flight check.  Commands preview their exact work in compilation buffers;
;; nothing sends mail.

;;; Code:

(require 'cl-lib)
(require 'kmode-core)
(require 'subr-x)

(defcustom kmode-review-default-range "HEAD"
  "Default Git revision or range used by kernel review commands."
  :type 'string
  :group 'kmode)

(defcustom kmode-checkpatch-arguments '("--strict")
  "Additional arguments passed to the kernel checkpatch script."
  :type '(repeat string)
  :group 'kmode)

(defcustom kmode-get-maintainer-arguments
  '("--nogit-fallback" "--norolestats")
  "Additional arguments passed to the kernel get_maintainer script."
  :type '(repeat string)
  :group 'kmode)

(defcustom kmode-patch-output-directory "patches"
  "Default patch output directory, relative to the kernel source root."
  :type 'directory
  :group 'kmode)

(defun kmode-review--validate-range (range)
  "Validate and return one non-option Git revision or RANGE."
  (unless (and (stringp range)
               (not (string-empty-p range))
               (not (string-prefix-p "-" range))
               (not (string-match-p "[[:cntrl:][:space:]]" range)))
    (user-error "Unsafe or invalid Git revision/range: %S" range))
  range)

(defun kmode-review--file-argument (relative)
  "Return repository RELATIVE as a non-option script argument."
  (if (string-prefix-p "-" relative)
      (concat "./" relative)
    relative))

(defun kmode--git-path (&optional context)
  "Return the Git executable for CONTEXT."
  (kmode-require-tool "git" context))

(defun kmode--checkpatch-path (&optional context)
  "Return the current tree's checkpatch script for CONTEXT."
  (kmode-require-tool "scripts/checkpatch.pl" context))

(defun kmode--get-maintainer-path (&optional context)
  "Return the current tree's get_maintainer script for CONTEXT."
  (kmode-require-tool "scripts/get_maintainer.pl" context))

;;;###autoload
(defun kmode-checkpatch-file (&optional file)
  "Run checkpatch on FILE as source code."
  (interactive)
  (let* ((context (kmode-resolve-context))
         (relative (kmode-file-in-root file context)))
    (kmode-start-command
     "checkpatch-file" (kmode--checkpatch-path context)
     (append kmode-checkpatch-arguments
             (list "--no-tree" "--file"
                   (kmode-review--file-argument relative)))
     (kmode-context-root context) nil nil context)))

;;;###autoload
(defun kmode-checkpatch-range (range)
  "Run checkpatch on every commit in Git RANGE."
  (interactive
   (list (read-string "Check Git revision/range: "
                      kmode-review-default-range)))
  (setq range (kmode-review--validate-range range))
  (let ((context (kmode-resolve-context)))
    (kmode-start-command
     "checkpatch-range" (kmode--checkpatch-path context)
     (append kmode-checkpatch-arguments (list "--git" range))
     (kmode-context-root context) nil nil context)))

(defun kmode--write-git-diff (arguments)
  "Write a Git diff with ARGUMENTS to a temporary patch and return it."
  (let* ((context (kmode-resolve-context))
         (root (kmode-context-root context))
         (git (kmode--git-path context))
         (temporary (make-temp-file "kmode-" nil ".patch"))
         completed)
    (unwind-protect
        (progn
          (with-temp-buffer
            (let ((status (apply #'process-file git nil t nil
                                 "-C" root "diff" "--no-ext-diff"
                                 arguments)))
              (unless (and (integerp status) (zerop status))
                (user-error "Git diff failed with status %s" status))
              (when (= (buffer-size) 0)
                (user-error "The selected Git diff is empty"))
              (write-region (point-min) (point-max)
                            temporary nil 'silent)))
          (setq completed t)
          temporary)
      (unless completed
        (when (file-exists-p temporary)
          (delete-file temporary))))))

(defun kmode--checkpatch-temporary (label temporary)
  "Run checkpatch with LABEL on TEMPORARY and arrange cleanup."
  (let ((context (kmode-resolve-context))
        buffer
        lifecycle-installed)
    (unwind-protect
        (progn
          (setq buffer
                (kmode-start-command
                 label (kmode--checkpatch-path context)
                 (append kmode-checkpatch-arguments
                         (list "--no-tree" temporary))
                 (kmode-context-root context) nil nil context))
          (with-current-buffer buffer
            (add-hook 'kill-buffer-hook
                      (lambda ()
                        (when (file-exists-p temporary)
                          (delete-file temporary)))
                      nil t))
          (if-let ((process (get-buffer-process buffer)))
              (let ((old-sentinel (process-sentinel process)))
                (set-process-sentinel
                 process
                 (lambda (finished event)
                   (unwind-protect
                       (when old-sentinel
                         (funcall old-sentinel finished event))
                     (when (and (memq (process-status finished)
                                      '(exit signal closed failed))
                                (file-exists-p temporary))
                       (delete-file temporary)))))
                ;; A tiny patch can finish between `compilation-start' and
                ;; installing our sentinel.  The original sentinel has already
                ;; handled its output; only the temporary file remains ours.
                (when (and (memq (process-status process)
                                 '(exit signal closed failed))
                           (file-exists-p temporary))
                  (delete-file temporary)))
            ;; No process means Compilation has already finished (or failed)
            ;; before returning its buffer, so the child no longer needs the
            ;; patch snapshot.
            (when (file-exists-p temporary)
              (delete-file temporary)))
          (setq lifecycle-installed t)
          buffer)
      (unless lifecycle-installed
        (when (file-exists-p temporary)
          (delete-file temporary))))))

;;;###autoload
(defun kmode-checkpatch-staged ()
  "Run checkpatch on the staged Git diff."
  (interactive)
  (kmode--checkpatch-temporary
   "checkpatch-staged" (kmode--write-git-diff '("--cached" "--binary"))))

;;;###autoload
(defun kmode-checkpatch-region (begin end)
  "Run checkpatch on the patch text between BEGIN and END."
  (interactive "r")
  (unless (use-region-p)
    (user-error "Select patch text first"))
  (let ((temporary (make-temp-file "kmode-region-" nil ".patch"))
        handed-off)
    (unwind-protect
        (progn
          (write-region begin end temporary nil 'silent)
          (prog1 (kmode--checkpatch-temporary
                  "checkpatch-region" temporary)
            (setq handed-off t)))
      (unless handed-off
        (when (file-exists-p temporary)
          (delete-file temporary))))))

;;;###autoload
(defun kmode-get-maintainers (&optional file)
  "Show maintainers and lists responsible for FILE."
  (interactive)
  (let* ((context (kmode-resolve-context))
         (relative (kmode-file-in-root file context)))
    (kmode-start-command
     "maintainers" (kmode--get-maintainer-path context)
     (append kmode-get-maintainer-arguments
             (list (kmode-review--file-argument relative)))
     (kmode-context-root context) nil nil context)))

;;;###autoload
(defun kmode-copy-maintainers (&optional file)
  "Copy comma-separated maintainers and lists for FILE to the kill ring."
  (interactive)
  (let* ((context (kmode-resolve-context))
         (relative (kmode-file-in-root file context))
         (program (kmode--get-maintainer-path context))
         (default-directory (kmode-context-root context))
         output)
    (with-temp-buffer
        (let ((status (apply #'process-file program nil t nil
                           (append kmode-get-maintainer-arguments
                                   (list (kmode-review--file-argument
                                          relative))))))
        (unless (zerop status)
          (user-error "Get_maintainer.pl failed with status %s" status))
        (setq output
              (mapconcat #'string-trim
                         (split-string (buffer-string) "\n" t)
                         ", "))))
    (when (string-empty-p output)
      (user-error "Get_maintainer.pl returned no recipients for %s" relative))
    (kill-new output)
    (message "Copied kernel recipients: %s" output)))

;;;###autoload
(defun kmode-range-diff (old-range new-range)
  "Show the Git range-diff between OLD-RANGE and NEW-RANGE."
  (interactive
   (list (read-string "Old range: ")
         (read-string "New range: ")))
  (setq old-range (kmode-review--validate-range old-range)
        new-range (kmode-review--validate-range new-range))
  (let ((context (kmode-resolve-context)))
    (kmode-start-command
     "range-diff" (kmode--git-path context)
     (list "-C" (kmode-context-root context)
           "range-diff" "--color=always" old-range new-range)
     (kmode-context-root context) nil nil context)))

;;;###autoload
(defun kmode-format-patch (range directory)
  "Create a patch series for RANGE below DIRECTORY.

This command only writes patch files; it never invokes send-email."
  (interactive
   (let ((root (kmode-root)))
     (list (read-string "Format Git revision/range: "
                        kmode-review-default-range)
           (read-directory-name
            "Patch output directory: " root
            (expand-file-name kmode-patch-output-directory root)))))
  (setq range (kmode-review--validate-range range))
  (let* ((context (kmode-resolve-context))
         (root (kmode-context-root context))
         (directory (expand-file-name directory)))
    (unless (file-in-directory-p directory root)
      (unless (yes-or-no-p
               (format "Write kernel patches outside the source tree at %s? "
                       directory))
        (user-error "Patch export cancelled")))
    (make-directory directory t)
    (kmode-start-command
     "format-patch" (kmode--git-path context)
     (list "-C" root "format-patch" "--cover-letter"
           "--output-directory" directory range)
     root nil nil context)))

;;;###autoload
(defun kmode-flight-check (range)
  "Run a non-mutating pre-submission check for Git RANGE.

The flight check verifies whitespace with Git and then runs the current
kernel tree's strict checkpatch rules.  It is intentionally advisory."
  (interactive
   (list (read-string "Flight-check revision/range: "
                      kmode-review-default-range)))
  (setq range (kmode-review--validate-range range))
  (let* ((context (kmode-resolve-context))
         (root (kmode-context-root context))
         (git-command
          (kmode-shell-command
           (kmode--git-path context)
           (list "-C" root "diff" "--check" range)))
         (checkpatch-command
          (kmode-shell-command
           (kmode--checkpatch-path context)
           (append kmode-checkpatch-arguments (list "--git" range))))
         (script (format "%s && %s" git-command checkpatch-command)))
    (kmode-start-command
     "flight-check" (kmode-require-tool "sh" context)
     (list "-c" script) root nil nil context)))

;;;###autoload
(defun kmode-open-submission-guide ()
  "Open the kernel's local patch submission guide."
  (interactive)
  (let ((guide (expand-file-name
                "Documentation/process/submitting-patches.rst"
                (kmode-root))))
    (unless (file-readable-p guide)
      (user-error "This tree has no local submitting-patches guide"))
    (find-file guide)))

(kmode-register-action
 'checkpatch-file "Checkpatch current file" "Review" #'kmode-checkpatch-file
 :predicate (lambda () (and buffer-file-name
                            (kmode-tool-path "scripts/checkpatch.pl"))))
(kmode-register-action
 'checkpatch-staged "Checkpatch staged diff" "Review" #'kmode-checkpatch-staged
 :predicate (lambda () (kmode-tool-path "scripts/checkpatch.pl")))
(kmode-register-action
 'checkpatch-range "Checkpatch commit/range" "Review" #'kmode-checkpatch-range
 :predicate (lambda () (kmode-tool-path "scripts/checkpatch.pl")))
(kmode-register-action
 'maintainers "Show maintainers for file" "Review" #'kmode-get-maintainers
 :predicate (lambda () (and buffer-file-name
                            (kmode-tool-path "scripts/get_maintainer.pl"))))
(kmode-register-action
 'flight-check "Pre-submission flight check" "Review" #'kmode-flight-check
 :predicate (lambda () (kmode-tool-path "scripts/checkpatch.pl")))
(kmode-register-action
 'range-diff "Compare patch series" "Review" #'kmode-range-diff)
(kmode-register-action
 'format-patch "Export patch series" "Review" #'kmode-format-patch)
(kmode-register-action
 'submission-guide "Open submission guide" "Review"
 #'kmode-open-submission-guide)

(provide 'kmode-review)

;;; kmode-review.el ends here
