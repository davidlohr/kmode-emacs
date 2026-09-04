;;; kemacs-mode.el --- The Linux kernel developer's Emacs cockpit -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Kemacs contributors
;; Maintainer: Davidlohr Bueso
;; Version: 0.1.0
;; Keywords: tools, c, linux
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/davidlohr/kemacs-mode

;;; Commentary:

;; Kemacs is a project minor mode and workflow layer for Linux kernel work.
;; It preserves the user's editor stack while making builds, navigation,
;; testing, review, and debugging agree on one explicit build profile.

;;; Code:

(require 'easymenu)
(require 'kemacs-core)
(require 'kemacs-build)
(require 'kemacs-analyze)
(require 'kemacs-test)
(require 'kemacs-navigate)
(require 'kemacs-review)
(require 'kemacs-flymake)
(require 'kemacs-impact)
(require 'kemacs-debug)
(require 'kemacs-virtme)
(require 'kemacs-kconfig)
(require 'kemacs-ui)

(defconst kemacs-version "0.1.0"
  "Current Kemacs package version.")

(defcustom kemacs-apply-kernel-c-style t
  "Apply the built-in Linux C style in Kemacs C buffers."
  :type 'boolean
  :group 'kemacs)

(defcustom kemacs-set-compile-command t
  "Keep `compile-command' synchronized with the active build profile."
  :type 'boolean
  :group 'kemacs)

(defvar-local kemacs--saved-locals nil
  "Local variable values saved before `kemacs-mode' changed them.")

(defun kemacs--save-local (variable)
  "Remember VARIABLE's current binding for mode teardown."
  (unless (assq variable kemacs--saved-locals)
    (push (list variable (local-variable-p variable)
                (and (boundp variable) (symbol-value variable)))
          kemacs--saved-locals)))

(defun kemacs--set-local (variable value)
  "Save VARIABLE and then bind it locally to VALUE."
  (kemacs--save-local variable)
  (set (make-local-variable variable) value))

(defun kemacs--restore-locals ()
  "Restore every buffer-local value changed by `kemacs-mode'."
  (dolist (entry kemacs--saved-locals)
    (let ((variable (nth 0 entry))
          (was-local (nth 1 entry))
          (value (nth 2 entry)))
      (if was-local
          (set variable value)
        (kill-local-variable variable))))
  (setq kemacs--saved-locals nil))

(defun kemacs--c-buffer-p ()
  "Return non-nil for a buffer in a C major mode."
  (or (derived-mode-p 'c-mode)
      (derived-mode-p 'c-ts-mode)))

(defun kemacs--apply-style ()
  "Apply kernel indentation without changing global C settings."
  (when (and kemacs-apply-kernel-c-style (kemacs--c-buffer-p))
    (require 'cc-mode)
    (dolist (variable (append
                       (and (boundp 'c-style-variables)
                            (symbol-value 'c-style-variables))
                       '(indent-tabs-mode tab-width c-basic-offset
                         c-ts-mode-indent-offset c-indentation-style)))
      (when (boundp variable)
        (kemacs--save-local variable)))
    (kemacs--set-local 'indent-tabs-mode t)
    (kemacs--set-local 'tab-width 8)
    (cond
     ((derived-mode-p 'c-mode)
      (c-set-style "linux")
      (setq-local c-basic-offset 8))
     ((boundp 'c-ts-mode-indent-offset)
      (setq-local c-ts-mode-indent-offset 8)))))

(defun kemacs-refresh-project-buffers ()
  "Refresh profile-derived state in every Kemacs buffer in this worktree."
  (interactive)
  (let ((root (kemacs-root)))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (bound-and-true-p kemacs-mode)
                   (equal root (kemacs-root t)))
          (when (and kemacs-set-compile-command
                     (kemacs-tool-path kemacs-build-make-program))
            (kemacs--save-local 'compile-command)
            (kemacs-refresh-compile-command)))))))

(add-hook 'kemacs-profile-changed-hook #'kemacs-refresh-project-buffers)

(defun kemacs--mode-line ()
  "Return the compact Kemacs mode-line indicator."
  (condition-case nil
      (format " K[%s]" (kemacs-current-profile-name (kemacs-root t)))
    (error " K")))

(defvar kemacs-navigation-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd ".") #'kemacs-navigation-dwim)
    (define-key map (kbd "d") #'kemacs-find-definition)
    (define-key map (kbd "r") #'kemacs-find-callers)
    (define-key map (kbd "b") #'kemacs-navigation-back)
    (define-key map (kbd "i") #'kemacs-follow-include)
    (define-key map (kbd "k") #'kemacs-find-kbuild)
    (define-key map (kbd "c") #'kemacs-find-config)
    (define-key map (kbd "u") #'kemacs-grep-config-users)
    (define-key map (kbd "h") #'kemacs-toggle-header-source)
    (define-key map (kbd "D") #'kemacs-grep-documentation)
    (define-key map (kbd "e") #'kemacs-eglot-ensure)
    map)
  "Prefix map for definitions, callers, and kernel-aware navigation.")

(defvar kemacs-vng-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "b") #'kemacs-vng-build)
    (define-key map (kbd "a") #'kemacs-vng-build-and-run)
    (define-key map (kbd "A") #'kemacs-vng-build-and-debug)
    (define-key map (kbd "r") #'kemacs-vng-run)
    (define-key map (kbd "e") #'kemacs-vng-run-command)
    (define-key map (kbd "p") #'kemacs-vng-preview)
    (define-key map (kbd "d") #'kemacs-vng-debug)
    (define-key map (kbd "g") #'kemacs-vng-gdb-attach)
    (define-key map (kbd "m") #'kemacs-vng-dump)
    (define-key map (kbd "x") #'kemacs-vng-stop)
    (define-key map (kbd "s") #'kemacs-vng-show-commands)
    map)
  "Prefix map for virtme-ng build, run, and debug commands.")

(defvar kemacs-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "k") #'kemacs-dashboard)
    (define-key map (kbd "SPC") #'kemacs-dispatch)
    (define-key map (kbd "?") #'kemacs-doctor)
    (define-key map (kbd "x") #'kemacs-cancel-job)
    (define-key map (kbd "p") #'kemacs-select-profile)
    (define-key map (kbd "b") #'kemacs-build)
    (define-key map (kbd "o") #'kemacs-build-current-object)
    (define-key map (kbd "n") kemacs-navigation-map)
    (define-key map (kbd "v") kemacs-vng-map)
    (define-key map (kbd "d") #'kemacs-navigation-dwim)
    (define-key map (kbd "c") #'kemacs-find-config)
    (define-key map (kbd "h") #'kemacs-toggle-header-source)
    (define-key map (kbd "r") #'kemacs-checkpatch-file)
    (define-key map (kbd "f") #'kemacs-checkpatch-flymake-mode)
    (define-key map (kbd "i") #'kemacs-impact-plan)
    (define-key map (kbd "m") #'kemacs-get-maintainers)
    (define-key map (kbd "t") #'kemacs-kunit-run-filter)
    (define-key map (kbd "s") #'kemacs-kselftest-run)
    (define-key map (kbd "l") #'kemacs-decode-stacktrace-buffer)
    (define-key map (kbd "q") #'kemacs-qemu-run)
    (define-key map (kbd "g") #'kemacs-gdb-attach)
    map)
  "Prefix keymap for kernel development commands.")

(defvar kemacs-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c k") kemacs-command-map)
    (define-key map [remap compile] #'kemacs-compile)
    map)
  "Keymap active in `kemacs-mode'.")

(easy-menu-define kemacs-mode-menu kemacs-mode-map
  "Menu for `kemacs-mode'."
  '("Kemacs"
    ["Flight deck" kemacs-dashboard t]
    ["Command dispatcher" kemacs-dispatch t]
    ["Doctor" kemacs-doctor t]
    "---"
    ["Build kernel" kemacs-build t]
    ["Build current object" kemacs-build-current-object buffer-file-name]
    ["Run KUnit filter" kemacs-kunit-run-filter t]
    ["Run Kselftest" kemacs-kselftest-run t]
    ("virtme-ng"
     ["Build, then boot" kemacs-vng-build-and-run t]
     ["Build, then boot for debugging" kemacs-vng-build-and-debug t]
     ["Build active output" kemacs-vng-build t]
     ["Boot active output" kemacs-vng-run t]
     ["Run guest command" kemacs-vng-run-command t]
     ["Preview resolved boot" kemacs-vng-preview t]
     ["Boot debug guest" kemacs-vng-debug t]
     ["Attach Emacs GDB" kemacs-vng-gdb-attach t]
     ["Dump guest memory" kemacs-vng-dump t]
     ["Stop guest" kemacs-vng-stop t]
     ["Show exact commands" kemacs-vng-show-commands t])
    "---"
    ["Navigate at point" kemacs-navigation-dwim t]
    ["Find definition" kemacs-find-definition t]
    ["Find references / callers" kemacs-find-callers t]
    ["Navigation back" kemacs-navigation-back t]
    ["Find CONFIG symbol" kemacs-find-config t]
    ["Toggle source/header" kemacs-toggle-header-source buffer-file-name]
    "---"
    ["Checkpatch file" kemacs-checkpatch-file buffer-file-name]
    ["Toggle live checkpatch" kemacs-checkpatch-flymake-mode
     buffer-file-name]
    ["Pre-submission flight check" kemacs-flight-check t]
    ["Plan staged change impact" kemacs-impact-plan t]
    ["Get maintainers" kemacs-get-maintainers buffer-file-name]
    "---"
    ["Decode stacktrace" kemacs-decode-stacktrace-buffer t]
    ["Run QEMU" kemacs-qemu-run t]
    ["Attach GDB" kemacs-gdb-attach t]
    "---"
    ["Select profile" kemacs-select-profile t]))

;;;###autoload
(define-minor-mode kemacs-mode
  "Turn the current buffer into a Linux kernel development cockpit.

Kemacs uses buffer-local editor settings and restores them when disabled.
All commands resolve through the selected worktree build profile."
  :lighter (:eval (kemacs--mode-line))
  :keymap kemacs-mode-map
  :group 'kemacs
  (if kemacs-mode
      (condition-case error-data
          (progn
            (kemacs-root)
            (kemacs--apply-style)
            (when (and kemacs-set-compile-command
                       (kemacs-tool-path kemacs-build-make-program))
              (kemacs--save-local 'compile-command)
              (kemacs-refresh-compile-command)))
        (error
         (setq kemacs-mode nil)
         (kemacs--restore-locals)
         (signal (car error-data) (cdr error-data))))
    (kemacs--restore-locals)))

(defun kemacs--maybe-enable ()
  "Enable `kemacs-mode' when the current buffer belongs to a kernel tree."
  (when (and (not (minibufferp))
             buffer-file-name
             (kemacs-root t))
    (kemacs-mode 1)))

;;;###autoload
(define-globalized-minor-mode kemacs-global-mode
  kemacs-mode kemacs--maybe-enable
  :group 'kemacs)

(defun kemacs-project-find (directory)
  "Return a Kemacs project rooted above DIRECTORY, when present."
  (when-let ((root (kemacs-locate-root directory)))
    (cons 'kemacs root)))

(cl-defmethod project-root ((project (head kemacs)))
  "Return the source root represented by PROJECT."
  (cdr project))

(add-hook 'project-find-functions #'kemacs-project-find t)

(kemacs-register-action
 'dashboard "Open kernel flight deck" "Project" #'kemacs-dashboard
 :description "See profile health and every available workflow")

(provide 'kemacs-mode)

;;; kemacs-mode.el ends here
