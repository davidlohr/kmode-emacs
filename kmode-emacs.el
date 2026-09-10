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
(require 'etags)
(require 'kmode-core)
(require 'kmode-build)
(require 'kmode-analyze)
(require 'kmode-test)
(require 'kmode-navigate)
(require 'kmode-review)
(require 'kmode-lore)
(require 'kmode-flymake)
(require 'kmode-impact)
(require 'kmode-debug)
(require 'kmode-virtme)
(require 'kmode-kconfig)
(require 'kmode-ui)

(declare-function c-langelem-pos "cc-engine" (langelem))
(declare-function c-langelem-2nd-pos "cc-engine" (langelem))
(declare-function initialize-new-tags-table "etags" ())

(defvar c-basic-offset)
(defvar c-syntactic-element)
(defvar tags-completion-table)
(defvar tags-table-computed-list)
(defvar tags-table-computed-list-for)
(defvar tags-table-list-pointer)
(defvar tags-table-list-started-at)
(defvar tags-table-set-list)

(defconst kmode-version "0.1.0"
  "Current kmode-emacs package version.")

(defcustom kmode-apply-kernel-c-style t
  "Apply the Linux kernel's documented CC Mode style in C buffers."
  :type 'boolean
  :group 'kmode)

(defcustom kmode-set-compile-command t
  "Keep `compile-command' synchronized with the active build profile."
  :type 'boolean
  :group 'kmode)

(defcustom kmode-auto-activate-tags t
  "Use an active profile's existing TAGS table in kmode-emacs buffers.

The binding is buffer-local, does not displace Eglot, and is restored when
`kmode-mode' is disabled.  Generate the table with `kmode-build-tags'."
  :type 'boolean
  :group 'kmode)

(defcustom kmode-kernel-fill-column 80
  "Preferred fill column in kernel C buffers managed by kmode-emacs."
  :type 'integer
  :group 'kmode)

(defcustom kmode-show-trailing-whitespace t
  "Show trailing whitespace in kernel C buffers managed by kmode-emacs."
  :type 'boolean
  :group 'kmode)

(defcustom kmode-require-final-newline t
  "Require a final newline in kernel C buffers managed by kmode-emacs."
  :type 'boolean
  :group 'kmode)

(defvar-local kmode--saved-locals nil
  "Local variable values saved before `kmode-mode' changed them.")

(defun kmode--save-local (variable &optional preserve-identity)
  "Remember VARIABLE's current binding for mode teardown.

When PRESERVE-IDENTITY is non-nil, retain the exact value object so related
variables which share list structure are restored with that topology intact."
  (unless (assq variable kmode--saved-locals)
    (push (list variable (local-variable-p variable)
                (and (boundp variable)
                     (let ((value (symbol-value variable)))
                       (if preserve-identity value (copy-tree value)))))
          kmode--saved-locals)))

(defun kmode--set-local (variable value &optional preserve-identity)
  "Save VARIABLE and then bind it locally to VALUE.

PRESERVE-IDENTITY is forwarded to `kmode--save-local'."
  (kmode--save-local variable preserve-identity)
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

(defun kmode--c-lineup-arglist-tabs-only (_ignored)
  "Return a tab-stop argument-list offset for the current C construct."
  (let* ((anchor (c-langelem-pos c-syntactic-element))
         (column (c-langelem-2nd-pos c-syntactic-element))
         (offset (- (1+ column) anchor))
         (steps (floor offset c-basic-offset)))
    (* (max steps 1) c-basic-offset)))

(defconst kmode--kernel-c-offsets
  '((arglist-close . kmode--c-lineup-arglist-tabs-only)
    (arglist-cont-nonempty
     c-lineup-gcc-asm-reg kmode--c-lineup-arglist-tabs-only)
    (arglist-intro . +)
    (brace-list-intro . +)
    (c . c-lineup-C-comments)
    (case-label . 0)
    (comment-intro . c-lineup-comment)
    (cpp-define-intro . +)
    (cpp-macro . -1000)
    (cpp-macro-cont . +)
    (defun-block-intro . +)
    (else-clause . 0)
    (func-decl-cont . +)
    (inclass . +)
    (inher-cont . c-lineup-multi-inher)
    (knr-argdecl-intro . 0)
    (label . -1000)
    (statement . 0)
    (statement-block-intro . +)
    (statement-case-intro . +)
    (statement-cont . +)
    (substatement . +))
  "CC Mode offsets from the Linux kernel's editor guidance.")

(defun kmode--apply-style ()
  "Apply kernel indentation without changing global C settings."
  (when (and kmode-apply-kernel-c-style (kmode--c-buffer-p))
    (require 'cc-mode)
    (dolist (variable (append
                       (and (boundp 'c-style-variables)
                            (symbol-value 'c-style-variables))
                       '(indent-tabs-mode tab-width c-basic-offset
                         c-label-minimum-indentation fill-column
                         show-trailing-whitespace require-final-newline
                         c-ts-mode-indent-offset c-indentation-style)))
      (when (boundp variable)
        (kmode--save-local variable)))
    (kmode--set-local 'indent-tabs-mode t)
    (kmode--set-local 'tab-width 8)
    (kmode--set-local 'fill-column kmode-kernel-fill-column)
    (kmode--set-local 'show-trailing-whitespace
                      kmode-show-trailing-whitespace)
    (kmode--set-local 'require-final-newline kmode-require-final-newline)
    (cond
     ((derived-mode-p 'c-mode)
      (c-set-style "linux")
      (setq-local c-basic-offset 8)
      (setq-local c-label-minimum-indentation 0)
      (dolist (offset kmode--kernel-c-offsets)
        (c-set-offset (car offset) (cdr offset))))
     ((boundp 'c-ts-mode-indent-offset)
      (setq-local c-ts-mode-indent-offset 8)))))

(defun kmode-tags-file (&optional context)
  "Return the readable TAGS file for CONTEXT's profile, or nil."
  (let* ((context (or context (kmode-resolve-context)))
         (file (expand-file-name "TAGS" (kmode-context-output context))))
    (and (file-regular-p file) (file-readable-p file) file)))

(defun kmode--refresh-tags-file-buffer (file)
  "Refresh an unmodified buffer visiting generated TAGS FILE.

Kill the unmodified visiting buffer when FILE no longer exists.  Never
discard user modifications."
  (when-let ((buffer (get-file-buffer file)))
    (with-current-buffer buffer
      (unless (buffer-modified-p)
        (if (and (file-regular-p file) (file-readable-p file))
            (unless (verify-visited-file-modtime buffer)
              (revert-buffer t t)
              (require 'etags)
              (initialize-new-tags-table))
          (kill-buffer buffer))))))

(defconst kmode--tags-traversal-variables
  '(tags-completion-table
    tags-table-computed-list
    tags-table-computed-list-for
    tags-table-list-pointer
    tags-table-list-started-at
    tags-table-set-list)
  "Etags search state which must not leak between build profiles.")

(defun kmode--reset-tags-traversal-state ()
  "Save and clear this buffer's Etags traversal state."
  (dolist (variable kmode--tags-traversal-variables)
    (kmode--set-local variable nil t)))

(defun kmode-refresh-tags-table (&optional context)
  "Refresh this buffer's profile-local TAGS binding from CONTEXT.

When the active profile has no table, retain an unrelated user binding unless
kmode-emacs previously installed one in this buffer."
  (interactive)
  (let ((file (and kmode-auto-activate-tags
                   (kmode-tags-file context))))
    (cond
     (file
      (kmode--refresh-tags-file-buffer file)
      (kmode--set-local 'tags-file-name file t)
      (kmode--set-local 'tags-table-list nil t)
      (kmode--reset-tags-traversal-state))
     ((or (assq 'tags-file-name kmode--saved-locals)
          (assq 'tags-table-list kmode--saved-locals)
          (cl-some (lambda (variable)
                     (assq variable kmode--saved-locals))
                   kmode--tags-traversal-variables))
      (kmode--set-local 'tags-file-name nil t)
      (kmode--set-local 'tags-table-list nil t)
      (kmode--reset-tags-traversal-state)))
    (when (called-interactively-p 'interactive)
      (if file
          (message "Kmode-emacs TAGS table: %s"
                   (abbreviate-file-name file))
        (message
         "No TAGS table for the active profile; run kmode-build-tags")))
    file))

(defun kmode-refresh-project-buffers (&optional root)
  "Refresh profile-derived state in kmode-emacs buffers below ROOT.

ROOT defaults to the current kernel worktree."
  (interactive)
  (let ((root (or root (kmode-root))))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (bound-and-true-p kmode-mode)
                   (equal root (kmode-root t)))
          (kmode-refresh-tags-table)
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

(defvar kmode-cscope-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "b") #'kmode-build-cscope)
    (define-key map (kbd "d") #'kmode-cscope-find-definition)
    (define-key map (kbd "r") #'kmode-cscope-find-callers)
    (define-key map (kbd "c") #'kmode-cscope-find-callees)
    (define-key map (kbd "s") #'kmode-cscope-find-symbol)
    (define-key map (kbd "t") #'kmode-cscope-find-text)
    (define-key map (kbd "i") #'kmode-cscope-find-includers)
    map)
  "Prefix map for the optional xcscope navigation adapter.")

(defvar kmode-navigation-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd ".") #'kmode-navigation-dwim)
    (define-key map (kbd "d") #'kmode-find-definition)
    (define-key map (kbd "r") #'kmode-find-usages)
    (define-key map (kbd "a") #'kmode-find-function-callers)
    (define-key map (kbd "b") #'kmode-navigation-back)
    (define-key map (kbd "i") #'kmode-follow-include)
    (define-key map (kbd "k") #'kmode-find-kbuild)
    (define-key map (kbd "c") #'kmode-find-config)
    (define-key map (kbd "u") #'kmode-grep-config-users)
    (define-key map (kbd "h") #'kmode-toggle-header-source)
    (define-key map (kbd "D") #'kmode-grep-documentation)
    (define-key map (kbd "e") #'kmode-eglot-ensure)
    (define-key map (kbd "l") #'kmode-lore-context-at-point)
    (define-key map (kbd "t") #'kmode-build-tags)
    (define-key map (kbd "C") kmode-cscope-map)
    map)
  "Prefix map for definitions, callers, and kernel-aware navigation.")

(defvar kmode-lore-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd ".") #'kmode-lore-context-at-point)
    (define-key map (kbd "s") #'kmode-lore-search-symbol)
    (define-key map (kbd "f") #'kmode-lore-search-file)
    (define-key map (kbd "d") #'kmode-lore-search-directory)
    (define-key map (kbd "q") #'kmode-lore-search)
    (define-key map (kbd "w") #'kmode-lore-why)
    (define-key map (kbd "c") #'kmode-lore-clear-cache)
    map)
  "Prefix map for explicit Lore mailing-list context searches.")

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
    (define-key map (kbd "R") #'kmode-select-root)
    (define-key map (kbd "SPC") #'kmode-dispatch)
    (define-key map (kbd "?") #'kmode-doctor)
    (define-key map (kbd "x") #'kmode-cancel-job)
    (define-key map (kbd "p") #'kmode-select-profile)
    (define-key map (kbd "b") #'kmode-build)
    (define-key map (kbd "o") #'kmode-build-current-object)
    (define-key map (kbd "n") kmode-navigation-map)
    (define-key map (kbd "v") kmode-vng-map)
    (define-key map (kbd "L") kmode-lore-map)
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

(defvar kmode-global-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c k") kmode-command-map)
    map)
  "Keymap active while `kmode-global-mode' is enabled.

This exposes the kmode-emacs command prefix in every buffer without
installing a permanent binding in `global-map'.")

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
    ["Find usages / callers" kmode-find-usages t]
    ["Find function callers" kmode-find-function-callers t]
    ["Navigation back" kmode-navigation-back t]
    ["Find CONFIG symbol" kmode-find-config t]
    ["Toggle source/header" kmode-toggle-header-source buffer-file-name]
    ["Generate/refresh TAGS" kmode-build-tags t]
    ("Cscope (optional)"
     ["Generate/refresh database" kmode-build-cscope t]
     ["Find definition" kmode-cscope-find-definition t]
     ["Find callers" kmode-cscope-find-callers t]
     ["Find callees" kmode-cscope-find-callees t]
     ["Find symbol" kmode-cscope-find-symbol t]
     ["Find text" kmode-cscope-find-text t]
     ["Find includers" kmode-cscope-find-includers t])
    ("Lore mailing-list context"
     ["Context for symbol and file" kmode-lore-context-at-point buffer-file-name]
     ["Why is this line here?" kmode-lore-why buffer-file-name]
     ["Search symbol" kmode-lore-search-symbol t]
     ["Search current file" kmode-lore-search-file buffer-file-name]
     ["Search current directory" kmode-lore-search-directory t]
     ["Custom public-inbox query" kmode-lore-search t]
     ["Clear Lore cache" kmode-lore-clear-cache t])
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
            (setq kmode--last-root (kmode-root))
            (kmode--apply-style)
            (kmode-refresh-tags-table)
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
  :keymap kmode-global-mode-map
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
