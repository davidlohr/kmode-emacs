;;; kmode-emacs.el --- The Linux kernel developer's Emacs cockpit -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: kmode-emacs contributors
;; Maintainer: Davidlohr Bueso
;; Version: 0.1.0
;; Keywords: tools, c, linux
;; Package-Requires: ((emacs "28.1"))
;; URL: https://github.com/davidlohr/kmode-emacs

;;; Commentary:

;; kmode-emacs is a project minor mode and workflow layer for Linux kernel work.
;; It preserves the user's editor stack while making builds, navigation,
;; testing, review, and debugging agree on one explicit build profile.

;;; Code:

(require 'easymenu)
(require 'kmode-core)
(require 'kmode-build)
(require 'kmode-analyze)
(require 'kmode-test)
(require 'kmode-navigate)
(require 'kmode-review)
(require 'kmode-flymake)
(require 'kmode-impact)
(require 'kmode-debug)
(require 'kmode-virtme)
(require 'kmode-kconfig)
(require 'kmode-ui)

(defconst kmode-version "0.1.0"
  "Current kmode-emacs package version.")

(defcustom kmode-apply-kernel-c-style t
  "Apply the built-in Linux C style in kmode-emacs C buffers."
  :type 'boolean
  :group 'kmode)

(defcustom kmode-set-compile-command t
  "Keep `compile-command' synchronized with the active build profile."
  :type 'boolean
  :group 'kmode)

(defvar-local kmode--saved-locals nil
  "Local variable values saved before `kmode-mode' changed them.")

(defun kmode--save-local (variable)
  "Remember VARIABLE's current binding for mode teardown."
  (unless (assq variable kmode--saved-locals)
    (push (list variable (local-variable-p variable)
                (and (boundp variable) (symbol-value variable)))
          kmode--saved-locals)))

(defun kmode--set-local (variable value)
  "Save VARIABLE and then bind it locally to VALUE."
  (kmode--save-local variable)
  (set (make-local-variable variable) value))

(defun kmode--restore-locals ()
  "Restore every buffer-local value changed by `kmode-mode'."
  (dolist (entry kmode--saved-locals)
    (let ((variable (nth 0 entry))
          (was-local (nth 1 entry))
          (value (nth 2 entry)))
      (if was-local
          (set variable value)
        (kill-local-variable variable))))
  (setq kmode--saved-locals nil))

(defun kmode--c-buffer-p ()
  "Return non-nil for a buffer in a C major mode."
  (or (derived-mode-p 'c-mode)
      (derived-mode-p 'c-ts-mode)))

(defun kmode--apply-style ()
  "Apply kernel indentation without changing global C settings."
  (when (and kmode-apply-kernel-c-style (kmode--c-buffer-p))
    (require 'cc-mode)
    (dolist (variable (append
                       (and (boundp 'c-style-variables)
                            (symbol-value 'c-style-variables))
                       '(indent-tabs-mode tab-width c-basic-offset
                         c-ts-mode-indent-offset c-indentation-style)))
      (when (boundp variable)
        (kmode--save-local variable)))
    (kmode--set-local 'indent-tabs-mode t)
    (kmode--set-local 'tab-width 8)
    (cond
     ((derived-mode-p 'c-mode)
      (c-set-style "linux")
      (setq-local c-basic-offset 8))
     ((boundp 'c-ts-mode-indent-offset)
      (setq-local c-ts-mode-indent-offset 8)))))

(defun kmode-refresh-project-buffers ()
  "Refresh profile-derived state in every kmode-emacs buffer in this worktree."
  (interactive)
  (let ((root (kmode-root)))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (bound-and-true-p kmode-mode)
                   (equal root (kmode-root t)))
          (when (and kmode-set-compile-command
                     (kmode-tool-path kmode-build-make-program))
            (kmode--save-local 'compile-command)
            (kmode-refresh-compile-command)))))))

(add-hook 'kmode-profile-changed-hook #'kmode-refresh-project-buffers)

(defun kmode--mode-line ()
  "Return the compact kmode-emacs mode-line indicator."
  (condition-case nil
      (format " K[%s]" (kmode-current-profile-name (kmode-root t)))
    (error " K")))

(defvar kmode-navigation-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd ".") #'kmode-navigation-dwim)
    (define-key map (kbd "d") #'kmode-find-definition)
    (define-key map (kbd "r") #'kmode-find-callers)
    (define-key map (kbd "b") #'kmode-navigation-back)
    (define-key map (kbd "i") #'kmode-follow-include)
    (define-key map (kbd "k") #'kmode-find-kbuild)
    (define-key map (kbd "c") #'kmode-find-config)
    (define-key map (kbd "u") #'kmode-grep-config-users)
    (define-key map (kbd "h") #'kmode-toggle-header-source)
    (define-key map (kbd "D") #'kmode-grep-documentation)
    (define-key map (kbd "e") #'kmode-eglot-ensure)
    map)
  "Prefix map for definitions, callers, and kernel-aware navigation.")

(defvar kmode-vng-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "b") #'kmode-vng-build)
    (define-key map (kbd "a") #'kmode-vng-build-and-run)
    (define-key map (kbd "A") #'kmode-vng-build-and-debug)
    (define-key map (kbd "r") #'kmode-vng-run)
    (define-key map (kbd "e") #'kmode-vng-run-command)
    (define-key map (kbd "p") #'kmode-vng-preview)
    (define-key map (kbd "d") #'kmode-vng-debug)
    (define-key map (kbd "g") #'kmode-vng-gdb-attach)
    (define-key map (kbd "m") #'kmode-vng-dump)
    (define-key map (kbd "x") #'kmode-vng-stop)
    (define-key map (kbd "s") #'kmode-vng-show-commands)
    map)
  "Prefix map for virtme-ng build, run, and debug commands.")

(defvar kmode-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "k") #'kmode-dashboard)
    (define-key map (kbd "SPC") #'kmode-dispatch)
    (define-key map (kbd "?") #'kmode-doctor)
    (define-key map (kbd "x") #'kmode-cancel-job)
    (define-key map (kbd "p") #'kmode-select-profile)
    (define-key map (kbd "b") #'kmode-build)
    (define-key map (kbd "o") #'kmode-build-current-object)
    (define-key map (kbd "n") kmode-navigation-map)
    (define-key map (kbd "v") kmode-vng-map)
    (define-key map (kbd "d") #'kmode-navigation-dwim)
    (define-key map (kbd "c") #'kmode-find-config)
    (define-key map (kbd "h") #'kmode-toggle-header-source)
    (define-key map (kbd "r") #'kmode-checkpatch-file)
    (define-key map (kbd "f") #'kmode-checkpatch-flymake-mode)
    (define-key map (kbd "i") #'kmode-impact-plan)
    (define-key map (kbd "m") #'kmode-get-maintainers)
    (define-key map (kbd "t") #'kmode-kunit-run-filter)
    (define-key map (kbd "s") #'kmode-kselftest-run)
    (define-key map (kbd "l") #'kmode-decode-stacktrace-buffer)
    (define-key map (kbd "q") #'kmode-qemu-run)
    (define-key map (kbd "g") #'kmode-gdb-attach)
    map)
  "Prefix keymap for kernel development commands.")

(defvar kmode-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c k") kmode-command-map)
    (define-key map [remap compile] #'kmode-compile)
    map)
  "Keymap active in `kmode-mode'.")

(easy-menu-define kmode-mode-menu kmode-mode-map
  "Menu for `kmode-mode'."
  '("kmode-emacs"
    ["Flight deck" kmode-dashboard t]
    ["Command dispatcher" kmode-dispatch t]
    ["Doctor" kmode-doctor t]
    "---"
    ["Build kernel" kmode-build t]
    ["Build current object" kmode-build-current-object buffer-file-name]
    ["Run KUnit filter" kmode-kunit-run-filter t]
    ["Run Kselftest" kmode-kselftest-run t]
    ("virtme-ng"
     ["Build, then boot" kmode-vng-build-and-run t]
     ["Build, then boot for debugging" kmode-vng-build-and-debug t]
     ["Build active output" kmode-vng-build t]
     ["Boot active output" kmode-vng-run t]
     ["Run guest command" kmode-vng-run-command t]
     ["Preview resolved boot" kmode-vng-preview t]
     ["Boot debug guest" kmode-vng-debug t]
     ["Attach Emacs GDB" kmode-vng-gdb-attach t]
     ["Dump guest memory" kmode-vng-dump t]
     ["Stop guest" kmode-vng-stop t]
     ["Show exact commands" kmode-vng-show-commands t])
    "---"
    ["Navigate at point" kmode-navigation-dwim t]
    ["Find definition" kmode-find-definition t]
    ["Find references / callers" kmode-find-callers t]
    ["Navigation back" kmode-navigation-back t]
    ["Find CONFIG symbol" kmode-find-config t]
    ["Toggle source/header" kmode-toggle-header-source buffer-file-name]
    "---"
    ["Checkpatch file" kmode-checkpatch-file buffer-file-name]
    ["Toggle live checkpatch" kmode-checkpatch-flymake-mode
     buffer-file-name]
    ["Pre-submission flight check" kmode-flight-check t]
    ["Plan staged change impact" kmode-impact-plan t]
    ["Get maintainers" kmode-get-maintainers buffer-file-name]
    "---"
    ["Decode stacktrace" kmode-decode-stacktrace-buffer t]
    ["Run QEMU" kmode-qemu-run t]
    ["Attach GDB" kmode-gdb-attach t]
    "---"
    ["Select profile" kmode-select-profile t]))

;;;###autoload
(define-minor-mode kmode-mode
  "Turn the current buffer into a Linux kernel development cockpit.

Kmode-emacs uses buffer-local editor settings and restores them when disabled.
All commands resolve through the selected worktree build profile."
  :lighter (:eval (kmode--mode-line))
  :keymap kmode-mode-map
  :group 'kmode
  (if kmode-mode
      (condition-case error-data
          (progn
            (kmode-root)
            (kmode--apply-style)
            (when (and kmode-set-compile-command
                       (kmode-tool-path kmode-build-make-program))
              (kmode--save-local 'compile-command)
              (kmode-refresh-compile-command)))
        (error
         (setq kmode-mode nil)
         (kmode--restore-locals)
         (signal (car error-data) (cdr error-data))))
    (kmode--restore-locals)))

(defun kmode--maybe-enable ()
  "Enable `kmode-mode' when the current buffer belongs to a kernel tree."
  (when (and (not (minibufferp))
             buffer-file-name
             (kmode-root t))
    (kmode-mode 1)))

;;;###autoload
(define-globalized-minor-mode kmode-global-mode
  kmode-mode kmode--maybe-enable
  :group 'kmode)

(defun kmode-project-find (directory)
  "Return a kmode-emacs project rooted above DIRECTORY, when present."
  (when-let ((root (kmode-locate-root directory)))
    (cons 'kmode root)))

(cl-defmethod project-root ((project (head kmode)))
  "Return the source root represented by PROJECT."
  (cdr project))

(add-hook 'project-find-functions #'kmode-project-find t)

(kmode-register-action
 'dashboard "Open kernel flight deck" "Project" #'kmode-dashboard
 :description "See profile health and every available workflow")

(provide 'kmode-emacs)

;;; kmode-emacs.el ends here
