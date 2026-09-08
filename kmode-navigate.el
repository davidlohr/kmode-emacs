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
(declare-function cscope-find-this-symbol "xcscope" (symbol))
(declare-function cscope-find-global-definition "xcscope" (symbol))
(declare-function cscope-find-functions-calling-this-function
                  "xcscope" (symbol))
(declare-function cscope-find-called-functions "xcscope" (symbol))
(declare-function cscope-find-this-text-string "xcscope" (symbol))
(declare-function cscope-find-files-including-file "xcscope" (symbol))
(declare-function cscope-get-history-bounds-this-result "xcscope" (which))

(defvar cscope-database-file)
(defvar cscope-database-regexps)
(defvar cscope-initial-directory)
(defvar cscope-index-file)
(defvar cscope-option-disable-compression)
(defvar cscope-option-do-not-update-database)
(defvar cscope-option-include-directories)
(defvar cscope-option-kernel-mode)
(defvar cscope-option-other)
(defvar cscope-option-use-inverted-index)
(defvar cscope-output-buffer-name)
(defvar cscope-process)
(defvar cscope-program)
(defvar cscope-result-separator)

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

(defcustom kmode-clangd-arguments
  '("--background-index"
    "--completion-style=detailed"
    "--header-insertion=never")
  "Extra arguments passed to clangd after the active database directory.

The defaults keep a persistent semantic index, improve completion detail, and
prevent clangd from inserting unsuitable kernel headers automatically.  Add
`--clang-tidy' here when that cost and diagnostic policy suit your workflow."
  :type '(repeat string)
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

(defun kmode--cscope-database-directory (context)
  "Return CONTEXT's output directory when its cscope database is readable."
  (let* ((output (kmode-context-output context))
         (database (expand-file-name "cscope.out" output)))
    (and (file-regular-p database)
         (file-readable-p database)
         output)))

(defun kmode--cscope-inverted-index-p (directory)
  "Return non-nil when DIRECTORY has both cscope inverted-index files."
  (seq-every-p
   (lambda (name)
     (let ((file (expand-file-name name directory)))
       (and (file-regular-p file) (file-readable-p file))))
   '("cscope.in.out" "cscope.po.out")))

(defun kmode-cscope-available-p ()
  "Return non-nil when xcscope and a profile-local database are usable."
  (condition-case nil
      (let* ((root (kmode-root t))
             (context (and root (kmode-resolve-context root))))
        (and context
             (locate-library "xcscope")
             (kmode-tool-path "cscope" context)
             (kmode--cscope-database-directory context)))
    (error nil)))

(defun kmode--xcscope-profile-state (program directory)
  "Return xcscope bindings for PROGRAM and profile output DIRECTORY."
  `((cscope-database-file . "cscope.out")
    (cscope-database-regexps . nil)
    (cscope-index-file . "cscope.files")
    (cscope-program . ,program)
    (cscope-initial-directory . ,(directory-file-name directory))
    (cscope-option-disable-compression . nil)
    (cscope-option-do-not-update-database . t)
    (cscope-option-include-directories . nil)
    (cscope-option-kernel-mode . t)
    (cscope-option-other . nil)
    (cscope-option-use-inverted-index
     . ,(kmode--cscope-inverted-index-p directory))))

(defun kmode--with-xcscope-buffer-state (buffer state function)
  "Call FUNCTION while BUFFER has the xcscope bindings in STATE.

Every prior buffer-local value is restored, including the absence of a local
binding.  This prevents a kmode-emacs query from changing how a later,
ordinary xcscope query behaves."
  (let ((saved
         (with-current-buffer buffer
           (mapcar (lambda (binding)
                     (let ((variable (car binding)))
                       (list variable
                             (local-variable-p variable)
                             (symbol-value variable))))
                   state))))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (dolist (binding state)
              (set (make-local-variable (car binding)) (cdr binding))))
          (funcall function))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (dolist (binding saved)
            (if (nth 1 binding)
                (set (car binding) (nth 2 binding))
              (kill-local-variable (car binding)))))))))

(defun kmode--protect-xcscope-result-rerun
    (buffer start state &optional exact)
  "Make the xcscope result in BUFFER after START rerun with STATE.

When EXACT is non-nil, START itself must begin the result separator.  The
profile state is embedded only in that result's stored search form, so other
results and later non-kmode xcscope searches remain untouched."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-excursion
        (goto-char (min start (point-max)))
        (let ((beginning
               (if exact
                   (and (looking-at cscope-result-separator) (point))
                 (when (re-search-forward
                        (concat "^" cscope-result-separator) nil t)
                   (match-beginning 0)))))
          (when-let* ((beginning beginning)
                      (search (get-text-property
                               beginning 'cscope-stored-search)))
            (let ((end (or (next-single-property-change
                            beginning 'cscope-stored-search nil (point-max))
                           (point-max))))
              (with-silent-modifications
                (put-text-property
                 beginning end 'cscope-stored-search
                 `(kmode--xcscope-rerun
                   ',(copy-tree state) ',(copy-tree search)))))
            beginning))))))

(defun kmode--xcscope-rerun (state search)
  "Evaluate xcscope SEARCH with its saved profile STATE.

This is stored in a Kmode result's `cscope-stored-search' property and is
evaluated by xcscope's native `cscope-rerun-search-at-point' command."
  (let ((buffer (current-buffer))
        (start (point)))
    (unwind-protect
        (cl-progv (mapcar #'car state) (mapcar #'cdr state)
          (eval search))
      ;; xcscope deletes the old result before evaluating its stored search.
      ;; Protect the replacement as well, so repeated `r' commands are safe.
      (kmode--protect-xcscope-result-rerun buffer start state t))))

(defun kmode--call-xcscope (command)
  "Invoke xcscope COMMAND against the active kernel profile."
  (unless (require 'xcscope nil t)
    (user-error "Xcscope.el is unavailable; install xcscope for this adapter"))
  (let* ((context (kmode-resolve-context))
         (program (kmode-require-tool "cscope" context))
         (directory (kmode--cscope-database-directory context)))
    (unless directory
      (user-error "No cscope database for this profile; run kmode-build-cscope"))
    (unless (fboundp command)
      (user-error "Installed xcscope does not provide `%s'" command))
    (let* ((state (kmode--xcscope-profile-state program directory))
           (output-buffer (get-buffer-create cscope-output-buffer-name))
           (start (with-current-buffer output-buffer (point-max))))
      (when (with-current-buffer output-buffer cscope-process)
        (user-error "A cscope search is already in progress"))
      (kmode--with-xcscope-buffer-state
       output-buffer state
       (lambda ()
         (cl-progv (mapcar #'car state) (mapcar #'cdr state)
           (let ((default-directory (kmode-context-root context)))
             (call-interactively command)))))
      (kmode--protect-xcscope-result-rerun
       output-buffer start state))))

;;;###autoload
(defun kmode-cscope-find-symbol ()
  "Find a symbol with the optional profile-aware xcscope adapter."
  (interactive)
  (kmode--call-xcscope #'cscope-find-this-symbol))

;;;###autoload
(defun kmode-cscope-find-definition ()
  "Find a global definition with the profile-aware xcscope adapter."
  (interactive)
  (kmode--call-xcscope #'cscope-find-global-definition))

;;;###autoload
(defun kmode-cscope-find-callers ()
  "Find functions calling the function at point with xcscope."
  (interactive)
  (kmode--call-xcscope #'cscope-find-functions-calling-this-function))

;;;###autoload
(defun kmode-cscope-find-callees ()
  "Find functions called by the function at point with xcscope."
  (interactive)
  (kmode--call-xcscope #'cscope-find-called-functions))

;;;###autoload
(defun kmode-cscope-find-text ()
  "Find a text string in the active kernel profile with xcscope."
  (interactive)
  (kmode--call-xcscope #'cscope-find-this-text-string))

;;;###autoload
(defun kmode-cscope-find-includers ()
  "Find files including the file at point with xcscope."
  (interactive)
  (kmode--call-xcscope #'cscope-find-files-including-file))

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
                            (append
                             (list clangd
                                   (concat "--compile-commands-dir="
                                           (directory-file-name database-dir)))
                             kmode-clangd-arguments))
                      (cl-loop for entry in eglot-server-programs
                               unless (eq (car-safe entry) major-mode)
                               collect entry)))
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
(kmode-register-action
 'cscope-definition "Cscope: find definition" "Navigate"
 #'kmode-cscope-find-definition
 :predicate #'kmode-cscope-available-p
 :description "Use an existing profile-local database through xcscope.el")
(kmode-register-action
 'cscope-callers "Cscope: find callers" "Navigate"
 #'kmode-cscope-find-callers
 :predicate #'kmode-cscope-available-p
 :description "Find functions that call the symbol at point")
(kmode-register-action
 'cscope-callees "Cscope: find callees" "Navigate"
 #'kmode-cscope-find-callees
 :predicate #'kmode-cscope-available-p
 :description "Find functions called by the symbol at point")

(provide 'kmode-navigate)

;;; kmode-navigate.el ends here
