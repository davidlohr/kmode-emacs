;;; kmode-ui.el --- Dispatcher, dashboard, and doctor for kmode-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: kmode-emacs contributors
;; Keywords: tools, c, linux
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; A dependency-free command surface.  The dashboard exposes the same action
;; registry as the completing-read dispatcher, so extension packages only need
;; to register an action once.

;;; Code:

(require 'button)
(require 'kmode-core)
(require 'kmode-virtme)
(require 'seq)
(require 'subr-x)

(defvar-local kmode-dashboard-root nil
  "Kernel source root represented by the current dashboard.")

(defvar-local kmode-dashboard-origin nil
  "Buffer from which the current dashboard was opened.")

(defun kmode--dashboard-live-origin ()
  "Return the dashboard origin when it still belongs to this worktree."
  (let ((origin kmode-dashboard-origin)
        (root kmode-dashboard-root))
    (and (buffer-live-p origin)
         (with-current-buffer origin
           (equal root (kmode-root t)))
         origin)))

(defun kmode--dashboard-context ()
  "Resolve the context used by the current dashboard's actions."
  (let ((origin (kmode--dashboard-live-origin))
        (root kmode-dashboard-root))
    (if (buffer-live-p origin)
        (with-current-buffer origin
          (kmode-resolve-context root))
      (kmode-resolve-context root))))

(defun kmode--action-label (action)
  "Return the completion label for ACTION."
  (format "%-12s  %s"
          (kmode-action-group action)
          (kmode-action-title action)))

;;;###autoload
(defun kmode-dispatch (&optional include-unavailable)
  "Choose and invoke a registered kmode-emacs action.

With prefix argument INCLUDE-UNAVAILABLE, show unavailable actions too
and explain if the selected action cannot run."
  (interactive "P")
  (kmode-root)
  (let* ((actions (kmode-actions include-unavailable))
         (candidates (mapcar (lambda (action)
                               (cons (kmode--action-label action) action))
                             actions))
         (choice (completing-read "Kmode-emacs action: " candidates nil t))
         (action (cdr (assoc choice candidates))))
    (unless action
      (user-error "No kmode-emacs action selected"))
    (unless (kmode-action-available-p action)
      (user-error "%s is unavailable; run kmode-doctor for details"
                  (kmode-action-title action)))
    (call-interactively (kmode-action-command action))))

(defun kmode--git-string (root &rest arguments)
  "Return trimmed Git output in ROOT for ARGUMENTS, or nil."
  (when-let ((git (kmode-tool-path "git" (kmode-resolve-context root))))
    (with-temp-buffer
      (when (zerop (apply #'process-file git nil t nil
                          "-C" root arguments))
        (string-trim (buffer-string))))))

(defun kmode--artifact-status (path)
  "Describe the existence and age of PATH."
  (if (file-readable-p path)
      (format "ready · %s"
              (format-time-string "%Y-%m-%d %H:%M"
                                  (file-attribute-modification-time
                                   (file-attributes path))))
    "missing"))

(defun kmode--insert-field (name value &optional face)
  "Insert a dashboard field NAME with VALUE and optional FACE."
  (insert (propertize (format "  %-14s" name) 'face 'font-lock-comment-face))
  (insert (propertize (format "%s" value) 'face face) "\n"))

(defun kmode--dashboard-call (command)
  "Invoke dashboard button COMMAND interactively."
  (if-let ((origin (kmode--dashboard-live-origin)))
      (with-current-buffer origin
        (call-interactively command))
    (call-interactively command)))

(defun kmode--dashboard-action-available-p (action)
  "Return whether ACTION is available in the dashboard's origin buffer."
  (if-let ((origin (kmode--dashboard-live-origin)))
      (with-current-buffer origin
        (kmode-action-available-p action))
    (kmode-action-available-p action)))

(defun kmode--insert-action-button (action)
  "Insert a button for ACTION."
  (let ((available (kmode--dashboard-action-available-p action)))
    (insert "  ")
    (if available
        (insert-text-button
         (kmode-action-title action)
         'follow-link t
         'kmode-command (kmode-action-command action)
         'help-echo (or (kmode-action-description action)
                        (format "Run %s" (kmode-action-command action)))
         'action (lambda (button)
                   (kmode--dashboard-call
                    (button-get button 'kmode-command))))
      (insert (propertize (kmode-action-title action)
                          'face 'shadow)))
    (when-let ((description (kmode-action-description action)))
      (insert (propertize (concat " — " description) 'face 'shadow)))
    (insert "\n")))

(defun kmode-dashboard-refresh ()
  "Refresh the current kmode-emacs dashboard."
  (interactive)
  (let* ((root (or kmode-dashboard-root (kmode-root)))
         (default-directory root)
         (context (kmode--dashboard-context))
         (output (kmode-context-output context))
         (config (expand-file-name ".config" output))
         (database (expand-file-name "compile_commands.json" output))
         (clangd-index (expand-file-name ".cache/clangd/index" output))
         (tags (expand-file-name "TAGS" output))
         (cscope (expand-file-name "cscope.out" output))
         (vmlinux (expand-file-name "vmlinux" output))
         (jobs (kmode-running-processes context))
         (worktree-jobs (kmode-running-processes context t))
         (vng-guests (kmode-vng-processes context t))
         (branch (or (kmode--git-string root "branch" "--show-current")
                     "detached / not Git"))
         (dirty (or (kmode--git-string root "status" "--short") ""))
         (inhibit-read-only t)
         (actions (kmode-actions t))
         last-group)
    (erase-buffer)
    (insert (propertize "KMODE // KERNEL FLIGHT DECK\n"
                        'face '(:height 1.35 :weight bold)))
    (insert (propertize "One worktree. One coherent build context.\n\n"
                        'face 'shadow))
    (kmode--insert-field "Root" (abbreviate-file-name root))
    (kmode--insert-field "Git" (concat branch (if (string-empty-p dirty)
                                                   " · clean"
                                                 " · modified"))
                          (unless (string-empty-p dirty) 'warning))
    (kmode--insert-field "Profile" (kmode-profile-description context)
                          'font-lock-keyword-face)
    (kmode--insert-field "Output" (abbreviate-file-name output))
    (kmode--insert-field ".config" (kmode--artifact-status config)
                          (unless (file-readable-p config) 'warning))
    (kmode--insert-field "Compile DB" (kmode--artifact-status database)
                          (unless (file-readable-p database) 'warning))
    (kmode--insert-field "clangd index" (kmode--artifact-status clangd-index)
                          (unless (file-readable-p clangd-index) 'warning))
    (kmode--insert-field "TAGS" (kmode--artifact-status tags)
                          (unless (file-readable-p tags) 'warning))
    (kmode--insert-field "cscope" (kmode--artifact-status cscope)
                          (unless (file-readable-p cscope) 'warning))
    (kmode--insert-field "vmlinux" (kmode--artifact-status vmlinux)
                          (unless (file-readable-p vmlinux) 'warning))
    (kmode--insert-field
     "Live jobs"
     (if (= (length jobs) (length worktree-jobs))
         (number-to-string (length jobs))
       (format "%d active profile · %d worktree"
               (length jobs) (length worktree-jobs)))
     (when worktree-jobs 'success))
    (kmode--insert-field
     "virtme-ng"
     (if vng-guests
         (mapconcat
          (lambda (process)
            (format "%s/%s"
                    (process-get process 'kmode-profile)
                    (if (process-get process 'kmode-vng-debug)
                        "debug" "run")))
          vng-guests ", ")
       "idle")
     (when vng-guests 'success))
    (insert "\n")
    (insert-text-button "Switch profile"
                        'follow-link t
                        'action (lambda (_button)
                                  (kmode--dashboard-call
                                   #'kmode-select-profile)
                                  (kmode-dashboard-refresh)))
    (insert "    ")
    (insert-text-button "Run doctor"
                        'follow-link t
                        'action (lambda (_button)
                                  (kmode--dashboard-call #'kmode-doctor)))
    (insert "    ")
    (insert-text-button "Refresh"
                        'follow-link t
                        'action (lambda (_button)
                                  (kmode-dashboard-refresh)))
    (insert "\n")
    (dolist (action actions)
      (unless (equal last-group (kmode-action-group action))
        (setq last-group (kmode-action-group action))
        (insert "\n" (propertize last-group
                                  'face '(:weight bold :underline t)) "\n"))
      (kmode--insert-action-button action))
    (goto-char (point-min))))

(defvar kmode-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'kmode-dashboard-refresh)
    (define-key map (kbd "p") #'kmode-dashboard-select-profile)
    (define-key map (kbd "d") #'kmode-dashboard-doctor)
    map)
  "Keymap for `kmode-dashboard-mode'.")

(defun kmode-dashboard-select-profile ()
  "Select a profile through the dashboard origin and refresh the display."
  (interactive)
  (kmode--dashboard-call #'kmode-select-profile)
  (kmode-dashboard-refresh))

(defun kmode-dashboard-doctor ()
  "Open the capability doctor in the dashboard origin's context."
  (interactive)
  (kmode--dashboard-call #'kmode-doctor))

(define-derived-mode kmode-dashboard-mode special-mode "kmode-emacs"
  "Major mode for the kmode-emacs kernel flight deck.")

;;;###autoload
(defun kmode-dashboard (&optional force-root-selection)
  "Open the flight deck for a Linux kernel worktree.

Inside a kernel buffer, use that buffer's worktree.  Elsewhere, reuse
the last selected tree or `kmode-default-root', prompting when needed.
With prefix argument FORCE-ROOT-SELECTION, always prompt for a tree."
  (interactive "P")
  (let* ((root (kmode-command-root force-root-selection))
         (origin (if (derived-mode-p 'kmode-dashboard-mode)
                     kmode-dashboard-origin
                   (current-buffer)))
         (buffer (get-buffer-create
                  (format "*kmode:%s*" (kmode-root-id root)))))
    (with-current-buffer buffer
      (kmode-dashboard-mode)
      (setq-local kmode-dashboard-root root)
      (setq-local kmode-dashboard-origin origin)
      (setq-local kmode-root-override root)
      (setq default-directory root)
      (kmode-dashboard-refresh))
    (pop-to-buffer buffer)))

(defun kmode--doctor-row (label available detail remedy)
  "Insert a doctor row for LABEL, AVAILABLE, DETAIL, and REMEDY."
  (insert (propertize (if available "  [OK] " "  [--] ")
                      'face (if available 'success 'warning)))
  (insert (format "%-18s %s\n" label detail))
  (unless available
    (insert (propertize (format "       %s\n" remedy) 'face 'shadow))))

;;;###autoload
(defun kmode-doctor ()
  "Inspect the active kernel profile and explain missing capabilities."
  (interactive)
  (let* ((context (kmode-resolve-context))
         (root (kmode-context-root context))
         (output (kmode-context-output context))
         (buffer (get-buffer-create "*kmode-doctor*"))
         (vng-path (kmode-vng-program-path context t))
         (vng-version (and vng-path (kmode-vng-version context)))
         (vng-problem (kmode-vng-profile-problem context 'run))
         (vng-config (kmode-vng-config-file))
         (vng-config-safe (kmode-vng-config-safe-p))
         (checks
          (append
           (list
           (list "GNU make" (kmode-tool-path "make" context) "kernel builds"
                 "Install GNU make.")
           (list "Git" (kmode-tool-path "git" context) "patch workflows"
                 "Install Git.")
           (list "ripgrep" (kmode-tool-path "rg" context) "fast tree search"
                 "Install ripgrep; kmode-emacs has slower fallbacks.")
           (list "Etags" (kmode-tool-path "etags" context)
                 "kernel-native TAGS/Xref fallback"
                 "Install Etags to use the kernel's make TAGS target.")
           (list "cscope" (kmode-tool-path "cscope" context)
                 "optional caller/callee database"
                 "Install cscope, then run kmode-build-cscope.")
           (list "xcscope.el" (locate-library "xcscope")
                 "optional Emacs cscope frontend"
                 "Install xcscope.el to use Kmode's cscope adapter.")
           (list "clangd" (kmode-tool-path "clangd" context) "semantic navigation"
                 "Install clangd, generate compile_commands.json, then start Eglot.")
           (list "sparse" (kmode-tool-path "sparse" context) "kernel static analysis"
                 "Install sparse to use C=1/C=2 builds.")
           (list "Smatch" (kmode-tool-path "smatch" context) "flow analysis"
                 "Install Smatch to run kernel-profile flow checks.")
           (list "Coccinelle" (kmode-tool-path "spatch" context) "semantic patches"
                 "Install Coccinelle to run coccicheck.")
           (list "clang-tidy" (kmode-tool-path "clang-tidy" context)
                 "Clang static analyzer"
                 "Install clang-tidy for the kernel clang-analyzer target.")
           (list "GDB" (kmode-tool-path
                         (if (boundp 'kmode-gdb-program)
                             (symbol-value 'kmode-gdb-program)
                           "gdb")
                         context)
                 "runtime debugging"
                 "Install GDB or customize kmode-gdb-program.")
           (list "b4" (kmode-tool-path "b4" context) "mailing-list series"
                 "Install b4 for future mailing-list adapters.")
           (list "checkpatch"
                 (kmode-tool-path "scripts/checkpatch.pl" context)
                 "tree-local style policy"
                 "Use a complete kernel source tree.")
           (list "get_maintainer"
                 (kmode-tool-path "scripts/get_maintainer.pl" context)
                 "recipient discovery"
                 "Use a complete kernel source tree."))
           (list
            (list "virtme-ng" vng-path
                  (or vng-version vng-path
                      "fast copy-on-write kernel runs")
                  "Install virtme-ng or customize kmode-vng-program.")
            (list "vng profile" (and vng-path (null vng-problem))
                  (or vng-problem "architecture, output, and rootfs are coherent")
                  (or vng-problem
                      "Configure :vng-arch/:vng-root for this profile."))
            (list "vng defaults" vng-config-safe
                  (if vng-config
                      (abbreviate-file-name vng-config)
                    "no overriding default_opts")
                  (concat "Review default_opts, then customize "
                          "kmode-vng-trust-default-options."))
            (list "KVM access"
                  (and (file-exists-p "/dev/kvm")
                       (file-readable-p "/dev/kvm")
                       (file-writable-p "/dev/kvm"))
                  "optional virtme-ng acceleration"
                  "vng can emulate; enable KVM access for much faster boots.")))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "KMODE DOCTOR\n" 'face '(:height 1.3 :weight bold)))
        (insert (format "%s\n\n" (kmode-profile-description context)))
        (dolist (check checks)
          (kmode--doctor-row (nth 0 check) (nth 1 check)
                              (nth 2 check) (nth 3 check)))
        (insert "\nArtifacts\n")
        (dolist
            (artifact
             (list
              (list ".config" (expand-file-name ".config" output)
                    "Run defconfig, olddefconfig, or menuconfig for this profile.")
              (list "compile_commands.json"
                    (expand-file-name "compile_commands.json" output)
                    "Run kmode-build-compile-commands for this profile.")
              (list "clangd index"
                    (expand-file-name ".cache/clangd/index" output)
                    "Build the compile database, start Eglot/clangd, and let background indexing finish.")
              (list "TAGS" (expand-file-name "TAGS" output)
                    "Run kmode-build-tags for this profile.")
              (list "cscope.out" (expand-file-name "cscope.out" output)
                    "Install cscope, then run kmode-build-cscope for this profile.")
              (list "vmlinux" (expand-file-name "vmlinux" output)
                    "Build vmlinux for this profile.")))
          (kmode--doctor-row (nth 0 artifact)
                              (file-readable-p (nth 1 artifact))
                              (abbreviate-file-name (nth 1 artifact))
                              (nth 2 artifact)))
        (insert "\nRoot: " (abbreviate-file-name root) "\n")
        (goto-char (point-min)))
      (special-mode))
    (pop-to-buffer buffer)))

(kmode-register-action
 'doctor "Inspect tools and artifacts" "Project" #'kmode-doctor
 :description "Explain exactly which kernel capabilities are ready")
(kmode-register-action
 'select-profile "Switch build profile" "Project" #'kmode-select-profile)
(kmode-register-action
 'cancel-job "Interrupt a running job" "Project" #'kmode-cancel-job
 :predicate (lambda () (kmode-running-processes nil t))
 :description "Choose a live build, test, log, or VM process in this worktree")

(provide 'kmode-ui)

;;; kmode-ui.el ends here
