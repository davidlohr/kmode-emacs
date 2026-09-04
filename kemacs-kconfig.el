;;; kemacs-kconfig.el --- Major mode for Linux Kconfig files -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Kemacs contributors
;; Keywords: languages, c, linux
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Lightweight Kconfig syntax, indentation, navigation, and imenu support.
;; It intentionally leaves configuration semantics to the kernel's own tools.

;;; Code:

(require 'kemacs-core)
(require 'kemacs-navigate)
(require 'subr-x)

(defcustom kemacs-kconfig-indent-width 8
  "Indentation width for Kconfig properties and help text."
  :type 'integer
  :group 'kemacs)

(defvar kemacs-kconfig-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?# "<" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?_ "w" table)
    table)
  "Syntax table for Kconfig files.")

(defconst kemacs-kconfig--property-keywords
  '("bool" "tristate" "string" "hex" "int" "prompt" "default"
    "def_bool" "def_tristate" "depends on" "select" "imply" "range"
    "visible if" "option" "optional" "help")
  "Kconfig keywords describing a symbol or choice.")

(defvar kemacs-kconfig-font-lock-keywords
  (list
   '("^[ \t]*\\(config\\|menuconfig\\)[ \t]+\\([A-Z0-9_]+\\)"
     (1 font-lock-keyword-face) (2 font-lock-function-name-face))
   '("^[ \t]*\\(menu\\|comment\\)[ \t]+\\(\"[^\"]*\"\\)"
     (1 font-lock-keyword-face) (2 font-lock-string-face))
   (cons
    (concat "^[ \t]*\\("
            (regexp-opt
             '("if" "endif" "menu" "endmenu" "choice" "endchoice"
               "source" "rsource" "osource" "orsource" "mainmenu"))
            "\\)\\_>")
    'font-lock-keyword-face)
   (cons
    (concat "^[ \t]*\\("
            (regexp-opt kemacs-kconfig--property-keywords)
            "\\)\\_>")
    'font-lock-builtin-face)
   '("\\_<\\(y\\|m\\|n\\)\\_>" . font-lock-constant-face)
   '("\\_<\\([A-Z][A-Z0-9_]+\\)\\_>" . font-lock-variable-name-face)
   '("\\$(\\([A-Za-z0-9_]+\\))" (1 font-lock-variable-name-face)))
  "Font-lock rules for Kconfig files.")

(defvar kemacs-kconfig-imenu-generic-expression
  '(("Symbols" "^[ \t]*\\(?:menuconfig\\|config\\)[ \t]+\\([A-Z0-9_]+\\)" 1)
    ("Menus" "^[ \t]*menu[ \t]+\"\\([^\"]+\\)\"" 1))
  "Imenu expression used in Kemacs Kconfig mode.")

(defun kemacs-kconfig--line-kind ()
  "Classify the current Kconfig line."
  (back-to-indentation)
  (cond
   ((looking-at "\\(?:endif\\|endmenu\\|endchoice\\)\\_>") 'close)
   ((looking-at "\\(?:if\\|menu\\|choice\\)\\_>") 'open)
   ((looking-at "\\(?:config\\|menuconfig\\)\\_>") 'symbol)
   ((looking-at
     (concat "\\(?:" (regexp-opt kemacs-kconfig--property-keywords)
             "\\)\\_>"))
    'property)
   ((looking-at
     "\\(?:source\\|rsource\\|osource\\|orsource\\|comment\\|mainmenu\\)\\_>")
    'top)
   ((looking-at "#\\|$") 'empty)
   (t 'body)))

(defun kemacs-kconfig--indent-state ()
  "Return indentation state immediately before the current line.

The result is a list of block depth, whether a symbol is active, and
whether the scanner is inside a help paragraph."
  (let ((limit (line-beginning-position))
        (depth 0)
        symbol-active
        help-active)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) limit)
        (pcase (kemacs-kconfig--line-kind)
          ('close
           (setq depth (max 0 (1- depth))
                 symbol-active nil
                 help-active nil))
          ('open
           (setq depth (1+ depth)
                 symbol-active nil
                 help-active nil))
          ('symbol
           (setq symbol-active t
                 help-active nil))
          ('property
           (back-to-indentation)
           (setq help-active (looking-at "help\\_>")))
          ('top
           (setq symbol-active nil
                 help-active nil)))
        (forward-line 1)))
    (list depth symbol-active help-active)))

(defun kemacs-kconfig-calculate-indent ()
  "Return the appropriate indentation column for the current line."
  (let* ((state (kemacs-kconfig--indent-state))
         (depth (nth 0 state))
         (symbol-active (nth 1 state))
         (help-active (nth 2 state))
         (kind (save-excursion (kemacs-kconfig--line-kind))))
    (* kemacs-kconfig-indent-width
       (pcase kind
         ('close (max 0 (1- depth)))
         ((or 'open 'symbol 'top) depth)
         ('property (1+ depth))
         ('body (+ depth (if help-active 2 (if symbol-active 1 0))))
         (_ 0)))))

(defun kemacs-kconfig-indent-line ()
  "Indent the current Kconfig line while preserving point."
  (interactive)
  (let ((offset (- (current-column) (current-indentation)))
        (indent (kemacs-kconfig-calculate-indent)))
    (indent-line-to indent)
    (when (> offset 0)
      (move-to-column (+ indent offset)))))

(defun kemacs-kconfig--source-statement-at-point ()
  "Return the Kconfig source directive and path at point, or nil."
  (save-excursion
    (beginning-of-line)
    (when (re-search-forward
           (concat "^[ \t]*\\(o?r?source\\)[ \t]+"
                   "\\(?:\"\\([^\"]+\\)\"\\|\\([^# \t\n]+\\)\\)")
           (line-end-position) t)
      (cons (intern (match-string-no-properties 1))
            (or (match-string-no-properties 2)
                (match-string-no-properties 3))))))

(defun kemacs-kconfig--source-at-point ()
  "Return the Kconfig source path on the current line, or nil."
  (cdr (kemacs-kconfig--source-statement-at-point)))

(defun kemacs-kconfig--expand-source-variable (path name value)
  "Expand Kconfig variable NAME to VALUE in PATH."
  (dolist (token (list (format "$(%s)" name)
                       (format "${%s}" name)
                       (format "$%s" name))
                 path)
    (setq path (string-replace token value path))))

(defun kemacs-kconfig--expand-source-path (source context)
  "Expand supported Kconfig variables in SOURCE for CONTEXT."
  (let* ((arch (or (kemacs-context-arch context) (kemacs-native-arch)))
         (srcarch (kemacs-srcarch arch))
         (expanded (kemacs-kconfig--expand-source-variable
                    source "SRCARCH" srcarch)))
    (setq expanded
          (kemacs-kconfig--expand-source-variable expanded "ARCH" arch))
    (dolist (prefix '("$srctree/" "$(srctree)/" "${srctree}/"))
      (when (string-prefix-p prefix expanded)
        (setq expanded (string-remove-prefix prefix expanded))))
    (when (string-match-p "\\$\\(?:[[:alpha:]_]\\|[({]\\)" expanded)
      (user-error "Cannot resolve Kconfig source variables in %s" source))
    expanded))

;;;###autoload
(defun kemacs-kconfig-follow-source ()
  "Visit the Kconfig file named by the source statement at point."
  (interactive)
  (let* ((statement
          (or (kemacs-kconfig--source-statement-at-point)
              (user-error "Point is not on a Kconfig source statement")))
         (directive (car statement))
         (source (cdr statement))
         (context (kemacs-resolve-context))
         (root (kemacs-context-root context))
         (expanded (kemacs-kconfig--expand-source-path source context))
         (base (if (memq directive '(rsource orsource))
                   (or (and buffer-file-name
                            (file-name-directory buffer-file-name))
                       default-directory)
                 root))
         (path (expand-file-name expanded base)))
    (unless (file-in-directory-p path root)
      (user-error "Kconfig source escapes the kernel tree: %s" path))
    (unless (file-readable-p path)
      (user-error "Kconfig source does not exist for this profile: %s" path))
    (find-file path)))

(defvar kemacs-kconfig-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-o") #'kemacs-kconfig-follow-source)
    (define-key map (kbd "M-.") #'kemacs-find-config)
    map)
  "Keymap for Kemacs Kconfig mode.")

;;;###autoload
(define-derived-mode kemacs-kconfig-mode prog-mode "Kconfig"
  "Major mode for Linux kernel Kconfig language files."
  :syntax-table kemacs-kconfig-mode-syntax-table
  (setq-local font-lock-defaults '(kemacs-kconfig-font-lock-keywords))
  (setq-local indent-line-function #'kemacs-kconfig-indent-line)
  (setq-local indent-tabs-mode t)
  (setq-local tab-width kemacs-kconfig-indent-width)
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local imenu-generic-expression
              kemacs-kconfig-imenu-generic-expression))

;;;###autoload
(add-to-list 'auto-mode-alist
             '("/Kconfig\\(?:\\.[^/]+\\)?\\'" . kemacs-kconfig-mode))

(provide 'kemacs-kconfig)

;;; kemacs-kconfig.el ends here
