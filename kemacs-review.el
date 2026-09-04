;;; kemacs-review.el --- Kernel patch review workflows for Kemacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Kemacs contributors
;; Keywords: tools, c, linux, vc
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Checkpatch, recipient discovery, range-diff, and a compact pre-submission
;; flight check.  Commands preview their exact work in compilation buffers;
;; nothing sends mail.

;;; Code:

(require 'cl-lib)
(require 'kemacs-core)
(require 'subr-x)

(defcustom kemacs-review-default-range "HEAD"
  "Default Git revision or range used by kernel review commands."
  :type 'string
  :group 'kemacs)

(defcustom kemacs-checkpatch-arguments '("--strict")
  "Additional arguments passed to the kernel checkpatch script."
  :type '(repeat string)
  :group 'kemacs)

(defcustom kemacs-get-maintainer-arguments
  '("--nogit-fallback" "--norolestats")
  "Additional arguments passed to the kernel get_maintainer script."
  :type '(repeat string)
  :group 'kemacs)

(defcustom kemacs-patch-output-directory "patches"
  "Default patch output directory, relative to the kernel source root."
  :type 'directory
  :group 'kemacs)

(defun kemacs-review--validate-range (range)
  "Validate and return one non-option Git revision or RANGE."
  (unless (and (stringp range)
               (not (string-empty-p range))
               (not (string-prefix-p "-" range))
               (not (string-match-p "[[:cntrl:][:space:]]" range)))
    (user-error "Unsafe or invalid Git revision/range: %S" range))
  range)

(defun kemacs-review--file-argument (relative)
  "Return repository RELATIVE as a non-option script argument."
  (if (string-prefix-p "-" relative)
      (concat "./" relative)
    relative))

(defun kemacs--git-path (&optional context)
  "Return the Git executable for CONTEXT."
  (kemacs-require-tool "git" context))

(defun kemacs--checkpatch-path (&optional context)
  "Return the current tree's checkpatch script for CONTEXT."
  (kemacs-require-tool "scripts/checkpatch.pl" context))

(defun kemacs--get-maintainer-path (&optional context)
  "Return the current tree's get_maintainer script for CONTEXT."
  (kemacs-require-tool "scripts/get_maintainer.pl" context))

;;;###autoload
(defun kemacs-checkpatch-file (&optional file)
  "Run checkpatch on FILE as source code."
  (interactive)
  (let* ((context (kemacs-resolve-context))
         (relative (kemacs-file-in-root file context)))
    (kemacs-start-command
     "checkpatch-file" (kemacs--checkpatch-path context)
     (append kemacs-checkpatch-arguments
             (list "--no-tree" "--file"
                   (kemacs-review--file-argument relative)))
     (kemacs-context-root context) nil nil context)))

;;;###autoload
(defun kemacs-checkpatch-range (range)
  "Run checkpatch on every commit in Git RANGE."
  (interactive
   (list (read-string "Check Git revision/range: "
                      kemacs-review-default-range)))
  (setq range (kemacs-review--validate-range range))
  (let ((context (kemacs-resolve-context)))
    (kemacs-start-command
     "checkpatch-range" (kemacs--checkpatch-path context)
     (append kemacs-checkpatch-arguments (list "--git" range))
     (kemacs-context-root context) nil nil context)))

(defun kemacs--write-git-diff (arguments)
  "Write a Git diff with ARGUMENTS to a temporary patch and return it."
  (let* ((context (kemacs-resolve-context))
         (root (kemacs-context-root context))
         (git (kemacs--git-path context))
         (temporary (make-temp-file "kemacs-" nil ".patch"))
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

(defun kemacs--checkpatch-temporary (label temporary)
  "Run checkpatch with LABEL on TEMPORARY and arrange cleanup."
  (let ((context (kemacs-resolve-context))
        buffer
        lifecycle-installed)
    (unwind-protect
        (progn
          (setq buffer
                (kemacs-start-command
                 label (kemacs--checkpatch-path context)
                 (append kemacs-checkpatch-arguments
                         (list "--no-tree" temporary))
                 (kemacs-context-root context) nil nil context))
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
(defun kemacs-checkpatch-staged ()
  "Run checkpatch on the staged Git diff."
  (interactive)
  (kemacs--checkpatch-temporary
   "checkpatch-staged" (kemacs--write-git-diff '("--cached" "--binary"))))

;;;###autoload
(defun kemacs-checkpatch-region (begin end)
  "Run checkpatch on the patch text between BEGIN and END."
  (interactive "r")
  (unless (use-region-p)
    (user-error "Select patch text first"))
  (let ((temporary (make-temp-file "kemacs-region-" nil ".patch"))
        handed-off)
    (unwind-protect
        (progn
          (write-region begin end temporary nil 'silent)
          (prog1 (kemacs--checkpatch-temporary
                  "checkpatch-region" temporary)
            (setq handed-off t)))
      (unless handed-off
        (when (file-exists-p temporary)
          (delete-file temporary))))))

;;;###autoload
(defun kemacs-get-maintainers (&optional file)
  "Show maintainers and lists responsible for FILE."
  (interactive)
  (let* ((context (kemacs-resolve-context))
         (relative (kemacs-file-in-root file context)))
    (kemacs-start-command
     "maintainers" (kemacs--get-maintainer-path context)
     (append kemacs-get-maintainer-arguments
             (list (kemacs-review--file-argument relative)))
     (kemacs-context-root context) nil nil context)))

;;;###autoload
(defun kemacs-copy-maintainers (&optional file)
  "Copy comma-separated maintainers and lists for FILE to the kill ring."
  (interactive)
  (let* ((context (kemacs-resolve-context))
         (relative (kemacs-file-in-root file context))
         (program (kemacs--get-maintainer-path context))
         (default-directory (kemacs-context-root context))
         output)
    (with-temp-buffer
        (let ((status (apply #'process-file program nil t nil
                           (append kemacs-get-maintainer-arguments
                                   (list (kemacs-review--file-argument
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
(defun kemacs-range-diff (old-range new-range)
  "Show the Git range-diff between OLD-RANGE and NEW-RANGE."
  (interactive
   (list (read-string "Old range: ")
         (read-string "New range: ")))
  (setq old-range (kemacs-review--validate-range old-range)
        new-range (kemacs-review--validate-range new-range))
  (let ((context (kemacs-resolve-context)))
    (kemacs-start-command
     "range-diff" (kemacs--git-path context)
     (list "-C" (kemacs-context-root context)
           "range-diff" "--color=always" old-range new-range)
     (kemacs-context-root context) nil nil context)))

;;;###autoload
(defun kemacs-format-patch (range directory)
  "Create a patch series for RANGE below DIRECTORY.

This command only writes patch files; it never invokes send-email."
  (interactive
   (let ((root (kemacs-root)))
     (list (read-string "Format Git revision/range: "
                        kemacs-review-default-range)
           (read-directory-name
            "Patch output directory: " root
            (expand-file-name kemacs-patch-output-directory root)))))
  (setq range (kemacs-review--validate-range range))
  (let* ((context (kemacs-resolve-context))
         (root (kemacs-context-root context))
         (directory (expand-file-name directory)))
    (unless (file-in-directory-p directory root)
      (unless (yes-or-no-p
               (format "Write kernel patches outside the source tree at %s? "
                       directory))
        (user-error "Patch export cancelled")))
    (make-directory directory t)
    (kemacs-start-command
     "format-patch" (kemacs--git-path context)
     (list "-C" root "format-patch" "--cover-letter"
           "--output-directory" directory range)
     root nil nil context)))

;;;###autoload
(defun kemacs-flight-check (range)
  "Run a non-mutating pre-submission check for Git RANGE.

The flight check verifies whitespace with Git and then runs the current
kernel tree's strict checkpatch rules.  It is intentionally advisory."
  (interactive
   (list (read-string "Flight-check revision/range: "
                      kemacs-review-default-range)))
  (setq range (kemacs-review--validate-range range))
  (let* ((context (kemacs-resolve-context))
         (root (kemacs-context-root context))
         (git-command
          (kemacs-shell-command
           (kemacs--git-path context)
           (list "-C" root "diff" "--check" range)))
         (checkpatch-command
          (kemacs-shell-command
           (kemacs--checkpatch-path context)
           (append kemacs-checkpatch-arguments (list "--git" range))))
         (script (format "%s && %s" git-command checkpatch-command)))
    (kemacs-start-command
     "flight-check" (kemacs-require-tool "sh" context)
     (list "-c" script) root nil nil context)))

;;;###autoload
(defun kemacs-open-submission-guide ()
  "Open the kernel's local patch submission guide."
  (interactive)
  (let ((guide (expand-file-name
                "Documentation/process/submitting-patches.rst"
                (kemacs-root))))
    (unless (file-readable-p guide)
      (user-error "This tree has no local submitting-patches guide"))
    (find-file guide)))

(kemacs-register-action
 'checkpatch-file "Checkpatch current file" "Review" #'kemacs-checkpatch-file
 :predicate (lambda () (and buffer-file-name
                            (kemacs-tool-path "scripts/checkpatch.pl"))))
(kemacs-register-action
 'checkpatch-staged "Checkpatch staged diff" "Review" #'kemacs-checkpatch-staged
 :predicate (lambda () (kemacs-tool-path "scripts/checkpatch.pl")))
(kemacs-register-action
 'checkpatch-range "Checkpatch commit/range" "Review" #'kemacs-checkpatch-range
 :predicate (lambda () (kemacs-tool-path "scripts/checkpatch.pl")))
(kemacs-register-action
 'maintainers "Show maintainers for file" "Review" #'kemacs-get-maintainers
 :predicate (lambda () (and buffer-file-name
                            (kemacs-tool-path "scripts/get_maintainer.pl"))))
(kemacs-register-action
 'flight-check "Pre-submission flight check" "Review" #'kemacs-flight-check
 :predicate (lambda () (kemacs-tool-path "scripts/checkpatch.pl")))
(kemacs-register-action
 'range-diff "Compare patch series" "Review" #'kemacs-range-diff)
(kemacs-register-action
 'format-patch "Export patch series" "Review" #'kemacs-format-patch)
(kemacs-register-action
 'submission-guide "Open submission guide" "Review"
 #'kemacs-open-submission-guide)

(provide 'kemacs-review)

;;; kemacs-review.el ends here
