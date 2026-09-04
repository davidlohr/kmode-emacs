;;; kemacs-ui.el --- Dispatcher, dashboard, and doctor for Kemacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Kemacs contributors
;; Keywords: tools, c, linux
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; A dependency-free command surface.  The dashboard exposes the same action
;; registry as the completing-read dispatcher, so extension packages only need
;; to register an action once.

;;; Code:

(require 'button)
(require 'kemacs-core)
(require 'kemacs-virtme)
(require 'seq)
(require 'subr-x)

(defvar-local kemacs-dashboard-root nil
  "Kernel source root represented by the current dashboard.")

(defvar-local kemacs-dashboard-origin nil
  "Buffer from which the current dashboard was opened.")

(defun kemacs--dashboard-live-origin ()
  "Return the dashboard origin when it still belongs to this worktree."
  (let ((origin kemacs-dashboard-origin)
        (root kemacs-dashboard-root))
    (and (buffer-live-p origin)
         (with-current-buffer origin
           (equal root (kemacs-root t)))
         origin)))

(defun kemacs--dashboard-context ()
  "Resolve the context used by the current dashboard's actions."
  (let ((origin (kemacs--dashboard-live-origin))
        (root kemacs-dashboard-root))
    (if (buffer-live-p origin)
        (with-current-buffer origin
          (kemacs-resolve-context root))
      (kemacs-resolve-context root))))

(defun kemacs--action-label (action)
  "Return the completion label for ACTION."
  (format "%-12s  %s"
          (kemacs-action-group action)
          (kemacs-action-title action)))

;;;###autoload
(defun kemacs-dispatch (&optional include-unavailable)
  "Choose and invoke a registered Kemacs action.

With prefix argument INCLUDE-UNAVAILABLE, show unavailable actions too
and explain if the selected action cannot run."
  (interactive "P")
  (kemacs-root)
  (let* ((actions (kemacs-actions include-unavailable))
         (candidates (mapcar (lambda (action)
                               (cons (kemacs--action-label action) action))
                             actions))
         (choice (completing-read "Kemacs action: " candidates nil t))
         (action (cdr (assoc choice candidates))))
    (unless action
      (user-error "No Kemacs action selected"))
    (unless (kemacs-action-available-p action)
      (user-error "%s is unavailable; run kemacs-doctor for details"
                  (kemacs-action-title action)))
    (call-interactively (kemacs-action-command action))))

(defun kemacs--git-string (root &rest arguments)
  "Return trimmed Git output in ROOT for ARGUMENTS, or nil."
  (when-let ((git (kemacs-tool-path "git" (kemacs-resolve-context root))))
    (with-temp-buffer
      (when (zerop (apply #'process-file git nil t nil
                          "-C" root arguments))
        (string-trim (buffer-string))))))

(defun kemacs--artifact-status (path)
  "Describe the existence and age of PATH."
  (if (file-readable-p path)
      (format "ready · %s"
              (format-time-string "%Y-%m-%d %H:%M"
                                  (file-attribute-modification-time
                                   (file-attributes path))))
    "missing"))

(defun kemacs--insert-field (name value &optional face)
  "Insert a dashboard field NAME with VALUE and optional FACE."
  (insert (propertize (format "  %-14s" name) 'face 'font-lock-comment-face))
  (insert (propertize (format "%s" value) 'face face) "\n"))

(defun kemacs--dashboard-call (command)
  "Invoke dashboard button COMMAND interactively."
  (if-let ((origin (kemacs--dashboard-live-origin)))
      (with-current-buffer origin
        (call-interactively command))
    (call-interactively command)))

(defun kemacs--dashboard-action-available-p (action)
  "Return whether ACTION is available in the dashboard's origin buffer."
  (if-let ((origin (kemacs--dashboard-live-origin)))
      (with-current-buffer origin
        (kemacs-action-available-p action))
    (kemacs-action-available-p action)))

(defun kemacs--insert-action-button (action)
  "Insert a button for ACTION."
  (let ((available (kemacs--dashboard-action-available-p action)))
    (insert "  ")
    (if available
        (insert-text-button
         (kemacs-action-title action)
         'follow-link t
         'kemacs-command (kemacs-action-command action)
         'help-echo (or (kemacs-action-description action)
                        (format "Run %s" (kemacs-action-command action)))
         'action (lambda (button)
                   (kemacs--dashboard-call
                    (button-get button 'kemacs-command))))
      (insert (propertize (kemacs-action-title action)
                          'face 'shadow)))
    (when-let ((description (kemacs-action-description action)))
      (insert (propertize (concat " — " description) 'face 'shadow)))
    (insert "\n")))

(defun kemacs-dashboard-refresh ()
  "Refresh the current Kemacs dashboard."
  (interactive)
  (let* ((root (or kemacs-dashboard-root (kemacs-root)))
         (default-directory root)
         (context (kemacs--dashboard-context))
         (output (kemacs-context-output context))
         (config (expand-file-name ".config" output))
         (database (expand-file-name "compile_commands.json" output))
         (vmlinux (expand-file-name "vmlinux" output))
         (jobs (kemacs-running-processes context))
         (worktree-jobs (kemacs-running-processes context t))
         (vng-guests (kemacs-vng-processes context t))
         (branch (or (kemacs--git-string root "branch" "--show-current")
                     "detached / not Git"))
         (dirty (or (kemacs--git-string root "status" "--short") ""))
         (inhibit-read-only t)
         (actions (kemacs-actions t))
         last-group)
    (erase-buffer)
    (insert (propertize "KEMACS // KERNEL FLIGHT DECK\n"
                        'face '(:height 1.35 :weight bold)))
    (insert (propertize "One worktree. One coherent build context.\n\n"
                        'face 'shadow))
    (kemacs--insert-field "Root" (abbreviate-file-name root))
    (kemacs--insert-field "Git" (concat branch (if (string-empty-p dirty)
                                                   " · clean"
                                                 " · modified"))
                          (unless (string-empty-p dirty) 'warning))
    (kemacs--insert-field "Profile" (kemacs-profile-description context)
                          'font-lock-keyword-face)
    (kemacs--insert-field "Output" (abbreviate-file-name output))
    (kemacs--insert-field ".config" (kemacs--artifact-status config)
                          (unless (file-readable-p config) 'warning))
    (kemacs--insert-field "Compile DB" (kemacs--artifact-status database)
                          (unless (file-readable-p database) 'warning))
    (kemacs--insert-field "vmlinux" (kemacs--artifact-status vmlinux)
                          (unless (file-readable-p vmlinux) 'warning))
    (kemacs--insert-field
     "Live jobs"
     (if (= (length jobs) (length worktree-jobs))
         (number-to-string (length jobs))
       (format "%d active profile · %d worktree"
               (length jobs) (length worktree-jobs)))
     (when worktree-jobs 'success))
    (kemacs--insert-field
     "virtme-ng"
     (if vng-guests
         (mapconcat
          (lambda (process)
            (format "%s/%s"
                    (process-get process 'kemacs-profile)
                    (if (process-get process 'kemacs-vng-debug)
                        "debug" "run")))
          vng-guests ", ")
       "idle")
     (when vng-guests 'success))
    (insert "\n")
    (insert-text-button "Switch profile"
                        'follow-link t
                        'action (lambda (_button)
                                  (kemacs--dashboard-call
                                   #'kemacs-select-profile)
                                  (kemacs-dashboard-refresh)))
    (insert "    ")
    (insert-text-button "Run doctor"
                        'follow-link t
                        'action (lambda (_button)
                                  (kemacs--dashboard-call #'kemacs-doctor)))
    (insert "    ")
    (insert-text-button "Refresh"
                        'follow-link t
                        'action (lambda (_button)
                                  (kemacs-dashboard-refresh)))
    (insert "\n")
    (dolist (action actions)
      (unless (equal last-group (kemacs-action-group action))
        (setq last-group (kemacs-action-group action))
        (insert "\n" (propertize last-group
                                  'face '(:weight bold :underline t)) "\n"))
      (kemacs--insert-action-button action))
    (goto-char (point-min))))

(defvar kemacs-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'kemacs-dashboard-refresh)
    (define-key map (kbd "p") #'kemacs-dashboard-select-profile)
    (define-key map (kbd "d") #'kemacs-dashboard-doctor)
    map)
  "Keymap for `kemacs-dashboard-mode'.")

(defun kemacs-dashboard-select-profile ()
  "Select a profile through the dashboard origin and refresh the display."
  (interactive)
  (kemacs--dashboard-call #'kemacs-select-profile)
  (kemacs-dashboard-refresh))

(defun kemacs-dashboard-doctor ()
  "Open the capability doctor in the dashboard origin's context."
  (interactive)
  (kemacs--dashboard-call #'kemacs-doctor))

(define-derived-mode kemacs-dashboard-mode special-mode "Kemacs"
  "Major mode for the Kemacs kernel flight deck.")

;;;###autoload
(defun kemacs-dashboard ()
  "Open the flight deck for the current kernel worktree."
  (interactive)
  (let* ((root (kemacs-root))
         (origin (if (derived-mode-p 'kemacs-dashboard-mode)
                     kemacs-dashboard-origin
                   (current-buffer)))
         (buffer (get-buffer-create
                  (format "*kemacs:%s*" (kemacs-root-id root)))))
    (with-current-buffer buffer
      (kemacs-dashboard-mode)
      (setq-local kemacs-dashboard-root root)
      (setq-local kemacs-dashboard-origin origin)
      (setq-local kemacs-root-override root)
      (setq default-directory root)
      (kemacs-dashboard-refresh))
    (pop-to-buffer buffer)))

(defun kemacs--doctor-row (label available detail remedy)
  "Insert a doctor row for LABEL, AVAILABLE, DETAIL, and REMEDY."
  (insert (propertize (if available "  [OK] " "  [--] ")
                      'face (if available 'success 'warning)))
  (insert (format "%-18s %s\n" label detail))
  (unless available
    (insert (propertize (format "       %s\n" remedy) 'face 'shadow))))

;;;###autoload
(defun kemacs-doctor ()
  "Inspect the active kernel profile and explain missing capabilities."
  (interactive)
  (let* ((context (kemacs-resolve-context))
         (root (kemacs-context-root context))
         (output (kemacs-context-output context))
         (buffer (get-buffer-create "*kemacs-doctor*"))
         (vng-path (kemacs-vng-program-path context t))
         (vng-version (and vng-path (kemacs-vng-version context)))
         (vng-problem (kemacs-vng-profile-problem context 'run))
         (vng-config (kemacs-vng-config-file))
         (vng-config-safe (kemacs-vng-config-safe-p))
         (checks
          (append
           (list
           (list "GNU make" (kemacs-tool-path "make" context) "kernel builds"
                 "Install GNU make.")
           (list "Git" (kemacs-tool-path "git" context) "patch workflows"
                 "Install Git.")
           (list "ripgrep" (kemacs-tool-path "rg" context) "fast tree search"
                 "Install ripgrep; Kemacs has slower fallbacks.")
           (list "clangd" (kemacs-tool-path "clangd" context) "semantic navigation"
                 "Install clangd, generate compile_commands.json, then start Eglot.")
           (list "sparse" (kemacs-tool-path "sparse" context) "kernel static analysis"
                 "Install sparse to use C=1/C=2 builds.")
           (list "Smatch" (kemacs-tool-path "smatch" context) "flow analysis"
                 "Install Smatch to run kernel-profile flow checks.")
           (list "Coccinelle" (kemacs-tool-path "spatch" context) "semantic patches"
                 "Install Coccinelle to run coccicheck.")
           (list "clang-tidy" (kemacs-tool-path "clang-tidy" context)
                 "Clang static analyzer"
                 "Install clang-tidy for the kernel clang-analyzer target.")
           (list "GDB" (kemacs-tool-path
                         (if (boundp 'kemacs-gdb-program)
                             (symbol-value 'kemacs-gdb-program)
                           "gdb")
                         context)
                 "runtime debugging"
                 "Install GDB or customize kemacs-gdb-program.")
           (list "b4" (kemacs-tool-path "b4" context) "mailing-list series"
                 "Install b4 for future mailing-list adapters.")
           (list "checkpatch"
                 (kemacs-tool-path "scripts/checkpatch.pl" context)
                 "tree-local style policy"
                 "Use a complete kernel source tree.")
           (list "get_maintainer"
                 (kemacs-tool-path "scripts/get_maintainer.pl" context)
                 "recipient discovery"
                 "Use a complete kernel source tree."))
           (list
            (list "virtme-ng" vng-path
                  (or vng-version vng-path
                      "fast copy-on-write kernel runs")
                  "Install virtme-ng or customize kemacs-vng-program.")
            (list "vng profile" (and vng-path (null vng-problem))
                  (or vng-problem "architecture, output, and rootfs are coherent")
                  (or vng-problem
                      "Configure :vng-arch/:vng-root for this profile."))
            (list "vng defaults" vng-config-safe
                  (if vng-config
                      (abbreviate-file-name vng-config)
                    "no overriding default_opts")
                  (concat "Review default_opts, then customize "
                          "kemacs-vng-trust-default-options."))
            (list "KVM access"
                  (and (file-exists-p "/dev/kvm")
                       (file-readable-p "/dev/kvm")
                       (file-writable-p "/dev/kvm"))
                  "optional virtme-ng acceleration"
                  "vng can emulate; enable KVM access for much faster boots.")))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "KEMACS DOCTOR\n" 'face '(:height 1.3 :weight bold)))
        (insert (format "%s\n\n" (kemacs-profile-description context)))
        (dolist (check checks)
          (kemacs--doctor-row (nth 0 check) (nth 1 check)
                              (nth 2 check) (nth 3 check)))
        (insert "\nArtifacts\n")
        (dolist (artifact
                 (list (cons ".config" (expand-file-name ".config" output))
                       (cons "compile_commands.json"
                             (expand-file-name "compile_commands.json" output))
                       (cons "vmlinux" (expand-file-name "vmlinux" output))))
          (kemacs--doctor-row (car artifact) (file-readable-p (cdr artifact))
                              (abbreviate-file-name (cdr artifact))
                              "Build or generate this artifact for the active profile."))
        (insert "\nRoot: " (abbreviate-file-name root) "\n")
        (goto-char (point-min)))
      (special-mode))
    (pop-to-buffer buffer)))

(kemacs-register-action
 'doctor "Inspect tools and artifacts" "Project" #'kemacs-doctor
 :description "Explain exactly which kernel capabilities are ready")
(kemacs-register-action
 'select-profile "Switch build profile" "Project" #'kemacs-select-profile)
(kemacs-register-action
 'cancel-job "Interrupt a running job" "Project" #'kemacs-cancel-job
 :predicate (lambda () (kemacs-running-processes nil t))
 :description "Choose a live build, test, log, or VM process in this worktree")

(provide 'kemacs-ui)

;;; kemacs-ui.el ends here
