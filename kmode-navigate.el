;;; kmode-navigate.el --- Kernel-aware navigation for kmode-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: kmode-emacs contributors
;; Keywords: tools, c, linux
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Navigation commands which understand kernel includes, CONFIG symbols,
;; Kbuild ownership, and profile-specific clangd databases.

;;; Code:

(require 'cl-lib)
(require 'grep)
(require 'kmode-core)
(require 'subr-x)
(require 'thingatpt)
(require 'xref)

(declare-function eglot-ensure "eglot")
(declare-function eglot-current-server "eglot")
(declare-function eglot-shutdown "eglot" (server))

(defcustom kmode-stop-eglot-on-profile-change t
  "Stop kernel Eglot servers when the active build profile changes.

An index produced for one architecture and configuration is not a safe
semantic view of another.  kmode-emacs stops affected servers and leaves
restarting them explicit through `kmode-eglot-ensure'."
  :type 'boolean
  :group 'kmode)

(defcustom kmode-navigation-file-limit 24
  "Maximum number of source/header matches offered without narrowing."
  :type 'integer
  :group 'kmode)

(defun kmode--line-include ()
  "Return the include path on the current line, or nil."
  (save-excursion
    (beginning-of-line)
    (when (re-search-forward
           "^[[:space:]]*#[[:space:]]*include[[:space:]]*[<\"]\\([^>\"]+\\)[>\"]"
           (line-end-position) t)
      (match-string-no-properties 1))))

(defun kmode--config-at-point ()
  "Return the normalized Kconfig symbol at point, or nil."
  (let ((word (thing-at-point 'symbol t))
        (case-fold-search nil))
    (when word
      (setq word (string-remove-prefix "CONFIG_" word))
      (and (string-match-p "^[A-Z0-9_]+$" word) word))))

(defun kmode--search-lines-with-rg (regexp globs root)
  "Return rg matches for REGEXP and GLOBS below ROOT.

Each result is a list of file, line number, and line text."
  (when-let ((rg (kmode-tool-path "rg" (kmode-resolve-context root))))
    (with-temp-buffer
      (let ((default-directory root)
            (arguments (append '("--line-number" "--no-heading" "--color" "never")
                               (cl-mapcan (lambda (glob) (list "--glob" glob)) globs)
                               (list "--" regexp "."))))
        (let ((status (apply #'process-file rg nil t nil arguments)))
          (when (memq status '(0 1))
            (goto-char (point-min))
            (let (matches)
              (while (re-search-forward
                      "^\\([^:\n]+\\):\\([0-9]+\\):\\(.*\\)$" nil t)
                (push (list (expand-file-name (match-string 1) root)
                            (string-to-number (match-string 2))
                            (match-string-no-properties 3))
                      matches))
              (nreverse matches))))))))

(defun kmode--search-kconfig-fallback (symbol root)
  "Find definitions of SYMBOL below ROOT without an external search tool."
  (let ((regexp (format "^[ \t]*\\(?:menuconfig\\|config\\)[ \t]+%s\\_>"
                        (regexp-quote symbol)))
        matches)
    (dolist (file (directory-files-recursively
                   root "\\(?:^\\|/\\)Kconfig[^/]*\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward regexp nil t)
          (push (list file (line-number-at-pos)
                      (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position)))
                matches))))
    (nreverse matches)))

(defun kmode--read-location (prompt matches)
  "Read one of MATCHES with PROMPT and return its file/line pair."
  (unless matches
    (user-error "No matching kernel location found"))
  (if (= (length matches) 1)
      (car matches)
    (let* ((root (kmode-root))
           (candidates
            (mapcar (lambda (match)
                      (cons (format "%s:%d  %s"
                                    (file-relative-name (nth 0 match) root)
                                    (nth 1 match)
                                    (string-trim (nth 2 match)))
                            match))
                    matches)))
      (cdr (assoc (completing-read prompt candidates nil t) candidates)))))

(defun kmode--visit-location (location)
  "Visit a LOCATION returned by a kmode-emacs search function."
  (find-file (nth 0 location))
  (goto-char (point-min))
  (forward-line (1- (nth 1 location)))
  (back-to-indentation))

;;;###autoload
(defun kmode-find-config (symbol)
  "Jump to the Kconfig definition of SYMBOL.

At point, both `FOO' and `CONFIG_FOO' resolve to the Kconfig symbol FOO."
  (interactive
   (list (read-string "Kconfig symbol: " (kmode--config-at-point))))
  (setq symbol (string-remove-prefix "CONFIG_" symbol))
  (unless (string-match-p "^[A-Z0-9_]+$" symbol)
    (user-error "Not a Kconfig symbol: %s" symbol))
  (let* ((root (kmode-root))
         (regexp (format "^[[:space:]]*(menuconfig|config)[[:space:]]+%s([^[:alnum:]_]|$)"
                         (regexp-quote symbol)))
         (matches (or (kmode--search-lines-with-rg
                       regexp '("Kconfig" "Kconfig.*" "**/Kconfig" "**/Kconfig.*") root)
                      (kmode--search-kconfig-fallback symbol root))))
    (kmode--visit-location
     (kmode--read-location (format "%s definition: " symbol) matches))))

;;;###autoload
(defun kmode-grep-config-users (symbol)
  "Search the current kernel tree for users of Kconfig SYMBOL."
  (interactive
   (list (read-string "Kconfig symbol: " (kmode--config-at-point))))
  (setq symbol (string-remove-prefix "CONFIG_" symbol))
  (unless (string-match-p "^[A-Z0-9_]+$" symbol)
    (user-error "Not a Kconfig symbol: %s" symbol))
  (rgrep (concat "\\bCONFIG_" (regexp-quote symbol) "\\b")
         "*.c *.h *.S *.rs *.dts *.dtsi *.yaml" (kmode-root)))

(defun kmode--include-candidates (include context)
  "Return existing files that might satisfy INCLUDE in CONTEXT."
  (let* ((root (kmode-context-root context))
         (output (kmode-context-output context))
         (srcarch (kmode-srcarch (kmode-context-arch context)))
         (local (and buffer-file-name
                     (expand-file-name include
                                       (file-name-directory buffer-file-name))))
         (paths
          (delq nil
                (list local
                      (expand-file-name include root)
                      (expand-file-name include (expand-file-name "include" root))
                      (and srcarch
                           (expand-file-name
                            include (expand-file-name
                                     (format "arch/%s/include" srcarch) root)))
                      (expand-file-name include
                                        (expand-file-name "include/generated" output))
                      (and srcarch
                           (expand-file-name
                            include (expand-file-name
                                     (format "arch/%s/include/generated"
                                             srcarch)
                                     output)))))))
    (delete-dups (seq-filter #'file-regular-p paths))))

;;;###autoload
(defun kmode-follow-include (&optional include)
  "Visit INCLUDE from the current C source line.

Quoted includes, generated headers, and architecture headers from the
active profile are considered."
  (interactive)
  (let* ((include (or include (kmode--line-include)
                      (read-string "Kernel include: ")))
         (context (kmode-resolve-context))
         (matches (kmode--include-candidates include context)))
    (unless matches
      (user-error "Could not resolve kernel include: %s" include))
    (find-file
     (if (= (length matches) 1)
         (car matches)
       (completing-read "Include file: " matches nil t)))))

(defun kmode--rg-files (root)
  "Return source files below ROOT using rg when possible."
  (if-let ((rg (kmode-tool-path "rg" (kmode-resolve-context root))))
      (let ((default-directory root))
        (condition-case nil
            (process-lines rg "--files" "--color" "never")
          (error nil)))
    (mapcar (lambda (file) (file-relative-name file root))
            (directory-files-recursively
             root "\\.[chS]\\(?:pp\\)?\\'"))))

;;;###autoload
(defun kmode-toggle-header-source ()
  "Switch between the current kernel source file and a matching header."
  (interactive)
  (unless buffer-file-name
    (user-error "The current buffer has no file"))
  (let* ((root (kmode-root))
         (extension (downcase (or (file-name-extension buffer-file-name) "")))
         (wanted (if (member extension '("h" "hpp"))
                     '("c" "cc" "cpp" "s")
                   '("h" "hpp")))
         (base (file-name-base buffer-file-name))
         (regexp (format "\\(?:^\\|/\\)%s\\.\\(%s\\)\\'"
                         (regexp-quote base)
                         (mapconcat #'regexp-quote wanted "\\|")))
         (matches (seq-filter (lambda (file) (string-match-p regexp file))
                              (kmode--rg-files root))))
    (when (> (length matches) kmode-navigation-file-limit)
      (setq matches (seq-take matches kmode-navigation-file-limit)))
    (unless matches
      (user-error "No matching %s found for %s"
                  (if (equal wanted '("h" "hpp")) "header" "source") base))
    (find-file
     (expand-file-name
      (if (= (length matches) 1)
          (car matches)
        (completing-read "Kernel counterpart: " matches nil t))
      root))))

;;;###autoload
(defun kmode-find-kbuild ()
  "Visit the nearest Kbuild or Makefile that owns the current file."
  (interactive)
  (let* ((root (kmode-root))
         (directory (if buffer-file-name
                        (file-name-directory buffer-file-name)
                      default-directory))
         found)
    (while (and directory (file-in-directory-p directory root) (not found))
      (setq found
            (seq-find #'file-exists-p
                      (mapcar (lambda (name) (expand-file-name name directory))
                              '("Kbuild" "Makefile"))))
      (unless found
        (setq directory
              (let ((parent (file-name-directory
                             (directory-file-name directory))))
                (unless (equal parent directory) parent)))))
    (if found (find-file found)
      (user-error "No owning Kbuild or Makefile found"))))

;;;###autoload
(defun kmode-grep-documentation (term)
  "Search local kernel Documentation for TERM."
  (interactive (list (read-string "Kernel documentation search: "
                                  (thing-at-point 'symbol t))))
  (rgrep (regexp-quote term) "*.rst *.md *.txt"
         (expand-file-name "Documentation" (kmode-root))))

;;;###autoload
(defun kmode-navigation-dwim ()
  "Perform the kernel-aware navigation action most relevant at point."
  (interactive)
  (let* ((raw-symbol (thing-at-point 'symbol t))
         (config-symbol
          (and (or (derived-mode-p 'kmode-kconfig-mode)
                   (and raw-symbol (string-prefix-p "CONFIG_" raw-symbol)))
               (kmode--config-at-point))))
    (cond ((kmode--line-include) (kmode-follow-include))
        (config-symbol
         (condition-case nil
             (kmode-find-config config-symbol)
           (user-error
            (call-interactively #'xref-find-definitions))))
          (t (call-interactively #'xref-find-definitions)))))

;;;###autoload
(defun kmode-find-definition ()
  "Find the definition at point through the active Xref backend.

When Eglot manages the buffer this uses clangd's semantic index; otherwise
it uses the best Tags or major-mode backend available to Emacs."
  (interactive)
  (call-interactively #'xref-find-definitions))

;;;###autoload
(defun kmode-find-callers ()
  "Find references and call sites for the identifier at point.

With Eglot/clangd these are semantic references.  Other Xref backends may
provide a broader textual result set."
  (interactive)
  (call-interactively #'xref-find-references))

;;;###autoload
(defun kmode-navigation-back ()
  "Return to the location before the most recent Xref navigation."
  (interactive)
  (call-interactively
   (if (fboundp 'xref-go-back)
       #'xref-go-back
     ;; Keep the Emacs 28 fallback out of byte-compiled symbol references:
     ;; newer Emacsen mark this compatibility command obsolete.
     (intern "xref-pop-marker-stack"))))

(defun kmode--stop-eglot-after-profile-change ()
  "Stop Eglot servers whose kernel profile has just changed."
  (when (and kmode-stop-eglot-on-profile-change
             (featurep 'eglot)
             (fboundp 'eglot-current-server))
    (let ((root (kmode-root t)) servers)
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and root buffer-file-name
                     (file-in-directory-p buffer-file-name root))
            (when-let ((server (ignore-errors (eglot-current-server))))
              (cl-pushnew server servers :test #'eq)))))
      (dolist (server servers)
        (ignore-errors (eglot-shutdown server)))
      (when servers
        (message
         "Kmode-emacs stopped stale Eglot server(s); restart clangd for the new profile")))))

(add-hook 'kmode-profile-changed-hook
          #'kmode--stop-eglot-after-profile-change)

;;;###autoload
(defun kmode-eglot-ensure ()
  "Start Eglot/clangd using the active profile's compilation database."
  (interactive)
  (unless (require 'eglot nil t)
    (user-error "Eglot is not installed; install it or use tags/xref"))
  (let* ((context (kmode-resolve-context))
         (clangd (kmode-require-tool "clangd" context))
         (database-dir (kmode-context-output context))
         (database (expand-file-name "compile_commands.json" database-dir)))
    (unless (file-readable-p database)
      (user-error "No %s; run `kmode-build-compile-commands' first"
                  database))
    (setq-local eglot-server-programs
                (cons (cons major-mode
                            (list clangd
                                  (concat "--compile-commands-dir="
                                          (directory-file-name database-dir))))
                      (assq-delete-all major-mode eglot-server-programs)))
    (eglot-ensure)))

(kmode-register-action
 'navigate-dwim "Definition/include/config at point" "Navigate"
 #'kmode-navigation-dwim
 :description "Follow includes and CONFIG symbols before falling back to xref")
(kmode-register-action
 'find-definition "Find definition" "Navigate" #'kmode-find-definition
 :description "Use clangd/Eglot or the active Xref backend")
(kmode-register-action
 'find-callers "Find references / callers" "Navigate" #'kmode-find-callers
 :description "List semantic call sites when clangd is active")
(kmode-register-action
 'find-config "Find Kconfig symbol" "Navigate" #'kmode-find-config)
(kmode-register-action
 'grep-config "Find CONFIG users" "Navigate" #'kmode-grep-config-users)
(kmode-register-action
 'toggle-source "Toggle source/header" "Navigate" #'kmode-toggle-header-source)
(kmode-register-action
 'find-kbuild "Find owning Kbuild" "Navigate" #'kmode-find-kbuild)
(kmode-register-action
 'docs "Search Documentation/" "Navigate" #'kmode-grep-documentation)
(kmode-register-action
 'eglot "Start profile-aware clangd" "Navigate" #'kmode-eglot-ensure
 :predicate (lambda () (and (locate-library "eglot")
                            (kmode-tool-path "clangd"))))

(provide 'kmode-navigate)

;;; kmode-navigate.el ends here
