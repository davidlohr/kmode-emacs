;;; kemacs-navigate.el --- Kernel-aware navigation for Kemacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Kemacs contributors
;; Keywords: tools, c, linux
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Navigation commands which understand kernel includes, CONFIG symbols,
;; Kbuild ownership, and profile-specific clangd databases.

;;; Code:

(require 'cl-lib)
(require 'grep)
(require 'kemacs-core)
(require 'subr-x)
(require 'thingatpt)
(require 'xref)

(declare-function eglot-ensure "eglot")
(declare-function eglot-current-server "eglot")
(declare-function eglot-shutdown "eglot" (server))

(defcustom kemacs-stop-eglot-on-profile-change t
  "Stop kernel Eglot servers when the active build profile changes.

An index produced for one architecture and configuration is not a safe
semantic view of another.  Kemacs stops affected servers and leaves
restarting them explicit through `kemacs-eglot-ensure'."
  :type 'boolean
  :group 'kemacs)

(defcustom kemacs-navigation-file-limit 24
  "Maximum number of source/header matches offered without narrowing."
  :type 'integer
  :group 'kemacs)

(defun kemacs--line-include ()
  "Return the include path on the current line, or nil."
  (save-excursion
    (beginning-of-line)
    (when (re-search-forward
           "^[[:space:]]*#[[:space:]]*include[[:space:]]*[<\"]\\([^>\"]+\\)[>\"]"
           (line-end-position) t)
      (match-string-no-properties 1))))

(defun kemacs--config-at-point ()
  "Return the normalized Kconfig symbol at point, or nil."
  (let ((word (thing-at-point 'symbol t))
        (case-fold-search nil))
    (when word
      (setq word (string-remove-prefix "CONFIG_" word))
      (and (string-match-p "^[A-Z0-9_]+$" word) word))))

(defun kemacs--search-lines-with-rg (regexp globs root)
  "Return rg matches for REGEXP and GLOBS below ROOT.

Each result is a list of file, line number, and line text."
  (when-let ((rg (kemacs-tool-path "rg" (kemacs-resolve-context root))))
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

(defun kemacs--search-kconfig-fallback (symbol root)
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

(defun kemacs--read-location (prompt matches)
  "Read one of MATCHES with PROMPT and return its file/line pair."
  (unless matches
    (user-error "No matching kernel location found"))
  (if (= (length matches) 1)
      (car matches)
    (let* ((root (kemacs-root))
           (candidates
            (mapcar (lambda (match)
                      (cons (format "%s:%d  %s"
                                    (file-relative-name (nth 0 match) root)
                                    (nth 1 match)
                                    (string-trim (nth 2 match)))
                            match))
                    matches)))
      (cdr (assoc (completing-read prompt candidates nil t) candidates)))))

(defun kemacs--visit-location (location)
  "Visit a LOCATION returned by a Kemacs search function."
  (find-file (nth 0 location))
  (goto-char (point-min))
  (forward-line (1- (nth 1 location)))
  (back-to-indentation))

;;;###autoload
(defun kemacs-find-config (symbol)
  "Jump to the Kconfig definition of SYMBOL.

At point, both `FOO' and `CONFIG_FOO' resolve to the Kconfig symbol FOO."
  (interactive
   (list (read-string "Kconfig symbol: " (kemacs--config-at-point))))
  (setq symbol (string-remove-prefix "CONFIG_" symbol))
  (unless (string-match-p "^[A-Z0-9_]+$" symbol)
    (user-error "Not a Kconfig symbol: %s" symbol))
  (let* ((root (kemacs-root))
         (regexp (format "^[[:space:]]*(menuconfig|config)[[:space:]]+%s([^[:alnum:]_]|$)"
                         (regexp-quote symbol)))
         (matches (or (kemacs--search-lines-with-rg
                       regexp '("Kconfig" "Kconfig.*" "**/Kconfig" "**/Kconfig.*") root)
                      (kemacs--search-kconfig-fallback symbol root))))
    (kemacs--visit-location
     (kemacs--read-location (format "%s definition: " symbol) matches))))

;;;###autoload
(defun kemacs-grep-config-users (symbol)
  "Search the current kernel tree for users of Kconfig SYMBOL."
  (interactive
   (list (read-string "Kconfig symbol: " (kemacs--config-at-point))))
  (setq symbol (string-remove-prefix "CONFIG_" symbol))
  (unless (string-match-p "^[A-Z0-9_]+$" symbol)
    (user-error "Not a Kconfig symbol: %s" symbol))
  (rgrep (concat "\\bCONFIG_" (regexp-quote symbol) "\\b")
         "*.c *.h *.S *.rs *.dts *.dtsi *.yaml" (kemacs-root)))

(defun kemacs--include-candidates (include context)
  "Return existing files that might satisfy INCLUDE in CONTEXT."
  (let* ((root (kemacs-context-root context))
         (output (kemacs-context-output context))
         (srcarch (kemacs-srcarch (kemacs-context-arch context)))
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
(defun kemacs-follow-include (&optional include)
  "Visit INCLUDE from the current C source line.

Quoted includes, generated headers, and architecture headers from the
active profile are considered."
  (interactive)
  (let* ((include (or include (kemacs--line-include)
                      (read-string "Kernel include: ")))
         (context (kemacs-resolve-context))
         (matches (kemacs--include-candidates include context)))
    (unless matches
      (user-error "Could not resolve kernel include: %s" include))
    (find-file
     (if (= (length matches) 1)
         (car matches)
       (completing-read "Include file: " matches nil t)))))

(defun kemacs--rg-files (root)
  "Return source files below ROOT using rg when possible."
  (if-let ((rg (kemacs-tool-path "rg" (kemacs-resolve-context root))))
      (let ((default-directory root))
        (condition-case nil
            (process-lines rg "--files" "--color" "never")
          (error nil)))
    (mapcar (lambda (file) (file-relative-name file root))
            (directory-files-recursively
             root "\\.[chS]\\(?:pp\\)?\\'"))))

;;;###autoload
(defun kemacs-toggle-header-source ()
  "Switch between the current kernel source file and a matching header."
  (interactive)
  (unless buffer-file-name
    (user-error "The current buffer has no file"))
  (let* ((root (kemacs-root))
         (extension (downcase (or (file-name-extension buffer-file-name) "")))
         (wanted (if (member extension '("h" "hpp"))
                     '("c" "cc" "cpp" "s")
                   '("h" "hpp")))
         (base (file-name-base buffer-file-name))
         (regexp (format "\\(?:^\\|/\\)%s\\.\\(%s\\)\\'"
                         (regexp-quote base)
                         (mapconcat #'regexp-quote wanted "\\|")))
         (matches (seq-filter (lambda (file) (string-match-p regexp file))
                              (kemacs--rg-files root))))
    (when (> (length matches) kemacs-navigation-file-limit)
      (setq matches (seq-take matches kemacs-navigation-file-limit)))
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
(defun kemacs-find-kbuild ()
  "Visit the nearest Kbuild or Makefile that owns the current file."
  (interactive)
  (let* ((root (kemacs-root))
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
(defun kemacs-grep-documentation (term)
  "Search local kernel Documentation for TERM."
  (interactive (list (read-string "Kernel documentation search: "
                                  (thing-at-point 'symbol t))))
  (rgrep (regexp-quote term) "*.rst *.md *.txt"
         (expand-file-name "Documentation" (kemacs-root))))

;;;###autoload
(defun kemacs-navigation-dwim ()
  "Perform the kernel-aware navigation action most relevant at point."
  (interactive)
  (let* ((raw-symbol (thing-at-point 'symbol t))
         (config-symbol
          (and (or (derived-mode-p 'kemacs-kconfig-mode)
                   (and raw-symbol (string-prefix-p "CONFIG_" raw-symbol)))
               (kemacs--config-at-point))))
    (cond ((kemacs--line-include) (kemacs-follow-include))
        (config-symbol
         (condition-case nil
             (kemacs-find-config config-symbol)
           (user-error
            (call-interactively #'xref-find-definitions))))
          (t (call-interactively #'xref-find-definitions)))))

;;;###autoload
(defun kemacs-find-definition ()
  "Find the definition at point through the active Xref backend.

When Eglot manages the buffer this uses clangd's semantic index; otherwise
it uses the best Tags or major-mode backend available to Emacs."
  (interactive)
  (call-interactively #'xref-find-definitions))

;;;###autoload
(defun kemacs-find-callers ()
  "Find references and call sites for the identifier at point.

With Eglot/clangd these are semantic references.  Other Xref backends may
provide a broader textual result set."
  (interactive)
  (call-interactively #'xref-find-references))

;;;###autoload
(defun kemacs-navigation-back ()
  "Return to the location before the most recent Xref navigation."
  (interactive)
  (call-interactively
   (if (fboundp 'xref-go-back)
       #'xref-go-back
     #'xref-pop-marker-stack)))

(defun kemacs--stop-eglot-after-profile-change ()
  "Stop Eglot servers whose kernel profile has just changed."
  (when (and kemacs-stop-eglot-on-profile-change
             (featurep 'eglot)
             (fboundp 'eglot-current-server))
    (let ((root (kemacs-root t)) servers)
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and root buffer-file-name
                     (file-in-directory-p buffer-file-name root))
            (when-let ((server (ignore-errors (eglot-current-server))))
              (cl-pushnew server servers :test #'eq)))))
      (dolist (server servers)
        (ignore-errors (eglot-shutdown server)))
      (when servers
        (message "Kemacs stopped stale Eglot server(s); restart clangd for the new profile")))))

(add-hook 'kemacs-profile-changed-hook
          #'kemacs--stop-eglot-after-profile-change)

;;;###autoload
(defun kemacs-eglot-ensure ()
  "Start Eglot/clangd using the active profile's compilation database."
  (interactive)
  (unless (require 'eglot nil t)
    (user-error "Eglot is not installed; install it or use tags/xref"))
  (let* ((context (kemacs-resolve-context))
         (clangd (kemacs-require-tool "clangd" context))
         (database-dir (kemacs-context-output context))
         (database (expand-file-name "compile_commands.json" database-dir)))
    (unless (file-readable-p database)
      (user-error "No %s; run `kemacs-build-compile-commands' first"
                  database))
    (setq-local eglot-server-programs
                (cons (cons major-mode
                            (list clangd
                                  (concat "--compile-commands-dir="
                                          (directory-file-name database-dir))))
                      (assq-delete-all major-mode eglot-server-programs)))
    (eglot-ensure)))

(kemacs-register-action
 'navigate-dwim "Definition/include/config at point" "Navigate"
 #'kemacs-navigation-dwim
 :description "Follow includes and CONFIG symbols before falling back to xref")
(kemacs-register-action
 'find-definition "Find definition" "Navigate" #'kemacs-find-definition
 :description "Use clangd/Eglot or the active Xref backend")
(kemacs-register-action
 'find-callers "Find references / callers" "Navigate" #'kemacs-find-callers
 :description "List semantic call sites when clangd is active")
(kemacs-register-action
 'find-config "Find Kconfig symbol" "Navigate" #'kemacs-find-config)
(kemacs-register-action
 'grep-config "Find CONFIG users" "Navigate" #'kemacs-grep-config-users)
(kemacs-register-action
 'toggle-source "Toggle source/header" "Navigate" #'kemacs-toggle-header-source)
(kemacs-register-action
 'find-kbuild "Find owning Kbuild" "Navigate" #'kemacs-find-kbuild)
(kemacs-register-action
 'docs "Search Documentation/" "Navigate" #'kemacs-grep-documentation)
(kemacs-register-action
 'eglot "Start profile-aware clangd" "Navigate" #'kemacs-eglot-ensure
 :predicate (lambda () (and (locate-library "eglot")
                            (kemacs-tool-path "clangd"))))

(provide 'kemacs-navigate)

;;; kemacs-navigate.el ends here
