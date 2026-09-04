;;; kemacs-impact.el --- Heuristic kernel change-impact plans -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Kemacs contributors
;; Keywords: tools, c, linux, vc
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Build a read-only, actionable impact report for a staged Git diff or an
;; explicitly selected revision range.  Recommendations are intentionally
;; heuristic: the report explains why each command may be useful and never
;; runs a build, test, or review check until its button is activated.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'kemacs-core)
(require 'kemacs-build)
(require 'kemacs-test)
(require 'kemacs-review)

(declare-function kemacs-vng-available-p "kemacs-virtme" (&optional operation))
(declare-function kemacs-vng-run "kemacs-virtme" ())

(defgroup kemacs-impact nil
  "Heuristic impact planning for kernel changes."
  :group 'kemacs
  :prefix "kemacs-impact-")

(defcustom kemacs-impact-max-specific-builds 24
  "Maximum number of path-specific build recommendations in one report.

Broad build, configuration, test, and review recommendations are not counted
against this limit."
  :type 'integer
  :group 'kemacs-impact)

(defvar kemacs-impact-range-history nil
  "History of Git ranges entered for impact plans.")

(defvar-local kemacs-impact-root nil
  "Kernel source root represented by the current impact report.")

(defvar-local kemacs-impact-range nil
  "Git range represented by the current impact report.

Nil means the staged index diff.")

(defvar-local kemacs-impact-origin nil
  "Source buffer whose context owns the current impact report.")

(defvar-local kemacs-impact-context nil
  "Resolved context snapshot used to create the current impact report.")

(cl-defstruct (kemacs-impact-suggestion
               (:constructor kemacs-impact--make-suggestion))
  "One heuristic action in a change-impact report."
  id group label rationale function arguments)

(defconst kemacs-impact--category-labels
  '((c-source . "C/source")
    (object . "object")
    (header . "header")
    (kconfig . "Kconfig")
    (kbuild . "Kbuild")
    (documentation . "documentation")
    (dt-binding . "DT binding")
    (dts . "DTS")
    (kunit . "KUnit")
    (selftest . "Kselftest")
    (other . "other"))
  "Human-readable labels for impact categories.")

(defun kemacs-impact--validate-range (range)
  "Validate and return Git RANGE, preserving nil for the staged diff."
  (when range
    (unless (and (stringp range)
                 (not (string-empty-p range))
                 (not (string-prefix-p "-" range))
                 (not (string-match-p "[[:cntrl:][:space:]]" range)))
      (user-error "Unsafe or invalid Git revision/range: %S" range)))
  range)

(defun kemacs-impact--selection-label (range)
  "Return a display label for Git RANGE or the staged diff."
  (if range
      (format "Git range %s" range)
    "staged index diff"))

(defun kemacs-impact-changed-paths (&optional range context)
  "Return changed paths from Git RANGE in CONTEXT.

Nil RANGE selects the staged index diff.  Git emits NUL-delimited names, so
paths containing whitespace, quotes, or newlines remain single values.
`process-file' receives every Git option as a separate argument; no shell is
used."
  (setq range (kemacs-impact--validate-range range))
  (let* ((context (or context (kemacs-resolve-context)))
         (root (kemacs-context-root context))
         (git (kemacs-require-tool "git" context))
         (arguments
          (append
           (list "-C" root "diff" "--no-ext-diff" "--name-only" "-z"
                 "--no-textconv" "--diff-filter=ACMRDTUXB")
           (if range (list range "--") '("--cached" "--")))))
    (with-temp-buffer
      (let ((status (apply #'process-file git nil t nil arguments)))
        (unless (and (integerp status) (zerop status))
          (user-error "Git could not inspect %s: %s"
                      (kemacs-impact--selection-label range)
                      (string-trim (buffer-string))))
        (split-string (buffer-string) "\0" t)))))

(defun kemacs-impact-classify-path (path)
  "Return kernel change categories that apply to repository-relative PATH."
  (let ((case-fold-search nil)
        categories)
    (when (string-match-p "\\.\\(?:c\\|S\\|s\\|rs\\)\\'" path)
      (push 'c-source categories))
    (when (string-match-p "\\.o\\'" path)
      (push 'object categories))
    (when (string-match-p "\\.h\\'" path)
      (push 'header categories))
    (when (or (string-match-p
               "\\(?:\\`\\|/\\)Kconfig\\(?:[._-][^/]*\\)?\\'" path)
              (string-match-p "\\`arch/[^/]+/configs/" path))
      (push 'kconfig categories))
    (when (string-match-p
           "\\(?:\\`\\|/\\)\\(?:Kbuild\\|Makefile\\)\\(?:[._-][^/]*\\)?\\'"
           path)
      (push 'kbuild categories))
    (when (or (string-prefix-p "Documentation/" path)
              (string-match-p "\\.rst\\'" path))
      (push 'documentation categories))
    (when (string-prefix-p "Documentation/devicetree/bindings/" path)
      (push 'dt-binding categories))
    (when (string-match-p
           "\\`arch/[^/]+/boot/dts/.*\\.dts\\(?:i\\|o\\)?\\'" path)
      (push 'dts categories))
    (when (or (string-prefix-p "tools/testing/kunit/" path)
              (string-match-p "\\(?:\\`\\|/\\)kunit\\(?:/\\|[_-]\\)" path)
              (string-match-p "_kunit\\.c\\'" path)
              (string-match-p "\\(?:\\`\\|/\\)\\.kunitconfig\\'" path))
      (push 'kunit categories))
    (when (string-prefix-p "tools/testing/selftests/" path)
      (push 'selftest categories))
    (or (nreverse (delete-dups categories)) '(other))))

(defun kemacs-impact--category-label (category)
  "Return the display label for impact CATEGORY."
  (or (alist-get category kemacs-impact--category-labels)
      (symbol-name category)))

(defun kemacs-impact--object-target (path)
  "Return the direct Kbuild object target corresponding to PATH, or nil."
  (let ((extension (file-name-extension path)))
    (cond
     ((equal extension "o") path)
     ((member extension '("c" "S" "s" "rs"))
      (concat (file-name-sans-extension path) ".o")))))

(defun kemacs-impact--directory-target (path)
  "Return PATH's repository-relative Kbuild directory target, or nil."
  (when-let ((directory (file-name-directory path)))
    (unless (equal directory "./") directory)))

(defun kemacs-impact--dtb-target (path)
  "Return the direct DTB build target for a DTS or DTSO PATH.

Return nil for an included DTSI file."
  (cond
   ((string-suffix-p ".dts" path)
    (concat (file-name-sans-extension path) ".dtb"))
   ((string-suffix-p ".dtso" path)
    (concat (file-name-sans-extension path) ".dtbo"))))

(defun kemacs-impact--kunit-filter (path)
  "Return a heuristic KUnit filter derived from test source PATH."
  (when (string-match-p "_kunit\\.c\\'" path)
    (concat
     (replace-regexp-in-string
      "_kunit\\'" "" (file-name-base path))
     "*")))

(defun kemacs-impact--selftest-collection (path)
  "Return the top-level Kselftest collection containing PATH, or nil."
  (when (string-match
         "\\`tools/testing/selftests/\\([^/]+\\)/" path)
    (let ((collection (match-string 1 path)))
      (unless (equal collection "kselftest") collection))))

(defun kemacs-impact-suggestions (paths range)
  "Return heuristic command suggestions for changed PATHS and Git RANGE."
  (let ((seen (make-hash-table :test #'equal))
        suggestions
        (specific-builds 0)
        code-changed
        header-changed
        kbuild-changed
        kconfig-changed
        documentation-changed
        binding-changed
        dts-changed
        kunit-changed
        selftest-selection-needed)
    (cl-labels
        ((add (id group label rationale function &optional arguments)
           (unless (gethash id seen)
             (puthash id t seen)
             (push (kemacs-impact--make-suggestion
                    :id id :group group :label label :rationale rationale
                    :function function :arguments arguments)
                   suggestions)))
         (add-build-target (target rationale)
           (when target
             (let ((id (concat "build:" target)))
               (when (and (not (gethash id seen))
                          (< specific-builds
                             kemacs-impact-max-specific-builds))
                 (cl-incf specific-builds)
                 (add id "Build" (format "Build %s" target) rationale
                      #'kemacs-build-target (list target)))))))
      (dolist (path paths)
        (let ((categories (kemacs-impact-classify-path path)))
          (when (and (or (memq 'c-source categories)
                         (memq 'object categories))
                     (not (memq 'selftest categories)))
            (setq code-changed t)
            (add-build-target
             (kemacs-impact--object-target path)
             "Changed compiled source; a direct object build catches local compiler errors.")
            (add-build-target
             (kemacs-impact--directory-target path)
             "The containing Kbuild directory may expose sibling or linkage effects."))
          (when (and (memq 'header categories)
                     (not (memq 'selftest categories)))
            (setq header-changed t))
          (when (and (memq 'kbuild categories)
                     (not (memq 'selftest categories)))
            (setq kbuild-changed t)
            (add-build-target
             (kemacs-impact--directory-target path)
             "Kbuild metadata changed; rebuild the owning directory."))
          (when (memq 'kconfig categories)
            (setq kconfig-changed t))
          (when (and (memq 'documentation categories)
                     (not (memq 'selftest categories)))
            (setq documentation-changed t))
          (when (memq 'dt-binding categories)
            (setq binding-changed t))
          (when (memq 'dts categories)
            (setq dts-changed t)
            (add-build-target
             (kemacs-impact--dtb-target path)
             "A changed board DTS can often be validated by building its DTB directly."))
          (when (memq 'kunit categories)
            (setq kunit-changed t)
            (when-let ((filter (kemacs-impact--kunit-filter path)))
              (add (concat "kunit:" filter) "Test"
                   (format "Run KUnit filter %s" filter)
                   "The filter is inferred from the changed _kunit.c filename and may need adjustment."
                   #'kemacs-kunit-run (list filter))))
          (when (memq 'selftest categories)
            (if-let ((collection
                      (kemacs-impact--selftest-collection path)))
                (add (concat "selftest:" collection) "Test"
                     (format "Run Kselftest collection %s" collection)
                     "The changed path belongs to this top-level selftest collection."
                     #'kemacs-kselftest-run (list (list collection)))
              (setq selftest-selection-needed t)))))
      (when (or code-changed header-changed kbuild-changed kconfig-changed
                dts-changed)
        (add "build:default" "Build" "Build active kernel profile"
             (cond
              (header-changed
               "Headers may affect consumers outside their own directory; a profile build checks dependents.")
              (kbuild-changed
               "Build graph metadata changed; the active profile exercises the resulting graph.")
              (t
               "A profile build checks integration beyond path-specific targets."))
             #'kemacs-build))
      (when (and (or code-changed header-changed kbuild-changed
                     kconfig-changed dts-changed)
                 (fboundp 'kemacs-vng-available-p)
                 (kemacs-vng-available-p 'run))
        (add "test:vng-boot" "Test" "Boot with virtme-ng"
             (concat "Compiled kernel changes should survive an actual boot; "
                     "virtme-ng provides the active profile's fast smoke test.")
             #'kemacs-vng-run))
      (when (or code-changed header-changed)
        (add "check:sparse" "Check" "Run sparse"
             "Changed C-facing code may benefit from kernel sparse type and address-space checks."
             #'kemacs-build-sparse))
      (when kconfig-changed
        (add "config:olddefconfig" "Configure" "Run olddefconfig"
             "Kconfig changes should resolve cleanly against the active profile's existing configuration."
             #'kemacs-build-olddefconfig)
        (add "config:menuconfig" "Configure" "Inspect with menuconfig"
             "Interactive inspection can expose prompts, dependencies, and unexpected visibility changes."
             #'kemacs-build-menuconfig))
      (when documentation-changed
        (add "build:htmldocs" "Check" "Build kernel HTML documentation"
             "Documentation changes may introduce Sphinx or cross-reference failures."
             #'kemacs-build-target '("htmldocs")))
      (when binding-changed
        (add "check:dt-binding" "Check" "Run dt_binding_check"
             "Devicetree binding YAML should pass schema and example validation."
             #'kemacs-build-target '("dt_binding_check"))
        (add "check:dtbs" "Check" "Run dtbs_check"
             "Binding changes can affect validation of in-tree devicetrees."
             #'kemacs-build-target '("dtbs_check")))
      (when dts-changed
        (add "build:dtbs" "Build" "Build devicetrees (dtbs)"
             "DTS and DTSI changes should compile across the active architecture's devicetrees."
             #'kemacs-build-target '("dtbs")))
      (when kunit-changed
        (add "test:kunit" "Test" "Run configured KUnit suite"
             "KUnit infrastructure or tests changed; run the active profile's KUnit configuration."
             #'kemacs-kunit-run))
      (when selftest-selection-needed
        (add "test:selftest-select" "Test" "Choose Kselftest collections..."
             "Shared Kselftest infrastructure changed, so select the affected collections manually."
             #'call-interactively (list #'kemacs-kselftest-run)))
      (when paths
        (if range
            (add "review:checkpatch-range" "Review" "Checkpatch selected range"
                 "Kernel style and patch metadata checks apply to the selected Git range."
                 #'kemacs-checkpatch-range (list range))
          (add "review:checkpatch-staged" "Review" "Checkpatch staged diff"
               "Kernel style and patch metadata checks apply to the staged patch."
               #'kemacs-checkpatch-staged)))
      (nreverse suggestions))))

(defun kemacs-impact--group-rank (group)
  "Return the preferred display rank for suggestion GROUP."
  (or (cl-position group '("Build" "Configure" "Test" "Check" "Review")
                   :test #'equal)
      99))

(defun kemacs-impact--sort-suggestions (suggestions)
  "Return SUGGESTIONS sorted by workflow group and label."
  (sort (copy-sequence suggestions)
        (lambda (left right)
          (let* ((left-group (kemacs-impact-suggestion-group left))
                 (right-group (kemacs-impact-suggestion-group right))
                 (left-rank (kemacs-impact--group-rank left-group))
                 (right-rank (kemacs-impact--group-rank right-group)))
            (if (= left-rank right-rank)
                (string-lessp (kemacs-impact-suggestion-label left)
                              (kemacs-impact-suggestion-label right))
              (< left-rank right-rank))))))

(defun kemacs-impact--run-button (button)
  "Run the Kemacs command represented by BUTTON."
  (let ((function (button-get button 'kemacs-impact-function))
        (arguments (button-get button 'kemacs-impact-arguments))
        (origin kemacs-impact-origin)
        (expected-context kemacs-impact-context)
        (root kemacs-impact-root))
    (unless (functionp function)
      (user-error "This impact recommendation has no command"))
    (unless (buffer-live-p origin)
      (user-error "The impact report's source buffer is gone; reopen the report"))
    (with-current-buffer origin
      (unless (equal root (kemacs-root t))
        (user-error "The impact report's source buffer moved; reopen the report"))
      (unless (equal expected-context (kemacs-resolve-context root))
        (user-error "Kernel context changed; refresh the impact report before running actions"))
      (apply function arguments))))

(defun kemacs-impact--visit-path-button (button)
  "Visit the repository path represented by BUTTON."
  (find-file (button-get button 'kemacs-impact-path)))

(defun kemacs-impact--display-path (path)
  "Return a report-safe form of PATH, escaping control characters."
  (if (string-match-p "[[:cntrl:]]" path)
      (let ((print-escape-newlines t)
            (print-escape-control-characters t))
        (prin1-to-string path))
    path))

(defun kemacs-impact--insert-suggestion (suggestion)
  "Insert one clickable heuristic SUGGESTION into the current report."
  (insert "  " (propertize "HEURISTIC" 'face 'warning) "  ")
  (insert-text-button
   (format "[run] %s" (kemacs-impact-suggestion-label suggestion))
   'follow-link t
   'help-echo (kemacs-impact-suggestion-rationale suggestion)
   'kemacs-impact-function (kemacs-impact-suggestion-function suggestion)
   'kemacs-impact-arguments (kemacs-impact-suggestion-arguments suggestion)
   'action #'kemacs-impact--run-button)
  (insert "\n      "
          (propertize (kemacs-impact-suggestion-rationale suggestion)
                      'face 'shadow)
          "\n"))

(defun kemacs-impact--insert-path (path root)
  "Insert changed PATH and its classifications relative to ROOT."
  (let* ((absolute (expand-file-name path root))
         (display-path (kemacs-impact--display-path path))
         (categories (kemacs-impact-classify-path path))
         (labels (mapconcat #'kemacs-impact--category-label categories ", ")))
    (insert "  ")
    (if (file-exists-p absolute)
        (insert-text-button display-path
                            'follow-link t
                            'help-echo "Visit changed path"
                            'kemacs-impact-path absolute
                            'action #'kemacs-impact--visit-path-button)
      (insert display-path
              (propertize "  (deleted or unavailable)" 'face 'shadow)))
    (insert (propertize (format "  [%s]" labels)
                        'face 'font-lock-comment-face)
            "\n")))

(defun kemacs-impact--render (paths)
  "Render an impact report for changed PATHS in the current buffer."
  (let* ((root kemacs-impact-root)
         (range kemacs-impact-range)
         (suggestions
          (kemacs-impact--sort-suggestions
           (kemacs-impact-suggestions paths range)))
         (inhibit-read-only t)
         last-group)
    (erase-buffer)
    (insert (propertize "KEMACS // CHANGE IMPACT PLAN\n"
                        'face '(:height 1.3 :weight bold)))
    (insert (propertize
             "Advisory only: every recommendation is heuristic and nothing below has run yet.\n\n"
             'face 'warning))
    (insert (format "Root:      %s\n" (abbreviate-file-name root)))
    (insert (format "Profile:   %s\n"
                    (kemacs-profile-description kemacs-impact-context)))
    (insert (format "Selection: %s\n"
                    (kemacs-impact--selection-label range)))
    (insert (format "Changed:   %d path%s\n"
                    (length paths) (if (= (length paths) 1) "" "s")))
    (insert "\nSuggested actions\n"
            (propertize
             "These targets are inferred from paths, not dependency-perfect analysis.\n"
             'face 'shadow))
    (dolist (suggestion suggestions)
      (unless (equal last-group (kemacs-impact-suggestion-group suggestion))
        (setq last-group (kemacs-impact-suggestion-group suggestion))
        (insert "\n" (propertize last-group
                                   'face '(:weight bold :underline t)) "\n"))
      (kemacs-impact--insert-suggestion suggestion))
    (insert "\nChanged paths\n")
    (dolist (path (sort (copy-sequence paths) #'string-lessp))
      (kemacs-impact--insert-path path root))
    (insert "\n"
            (propertize "Press g to recompute this read-only plan."
                        'face 'shadow)
            "\n")
    (goto-char (point-min))))

(defun kemacs-impact-refresh ()
  "Recompute the Git diff and refresh the current impact report."
  (interactive)
  (unless (derived-mode-p 'kemacs-impact-mode)
    (user-error "This is not a Kemacs impact report"))
  (let ((origin kemacs-impact-origin)
        (root kemacs-impact-root)
        (range kemacs-impact-range))
    (unless (buffer-live-p origin)
      (user-error "The impact report's source buffer is gone; reopen the report"))
    (let* ((context (with-current-buffer origin
                      (unless (equal root (kemacs-root t))
                        (user-error
                         "The impact report's source buffer moved; reopen the report"))
                      (kemacs-resolve-context root)))
           (paths (kemacs-impact-changed-paths range context)))
    (unless paths
      (user-error "The %s is empty"
                    (kemacs-impact--selection-label range)))
      (setq-local kemacs-impact-context context)
      (kemacs-impact--render paths))))

(defvar kemacs-impact-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'kemacs-impact-refresh)
    map)
  "Keymap used by `kemacs-impact-mode'.")

(define-derived-mode kemacs-impact-mode special-mode "Kemacs-Impact"
  "Major mode for read-only Kemacs change-impact reports."
  (setq-local truncate-lines nil))

;;;###autoload
(defun kemacs-impact-plan (&optional range)
  "Show a heuristic change-impact plan for Git RANGE.

Nil RANGE analyzes the staged index diff.  Interactively, use a prefix
argument to prompt for a revision or range; entering an empty value keeps the
staged default.  Gathering and rendering are read-only.  Suggested commands
run only when their report buttons are activated."
  (interactive
   (list
    (when current-prefix-arg
      (let ((value (read-string
                    "Git revision/range (empty for staged): "
                    nil 'kemacs-impact-range-history
                    kemacs-review-default-range)))
        (unless (string-empty-p value) value)))))
  (setq range (kemacs-impact--validate-range range))
  (let* ((origin (if (derived-mode-p 'kemacs-impact-mode)
                     (or kemacs-impact-origin
                         (user-error "This impact report has no source buffer"))
                   (current-buffer)))
         (context (with-current-buffer origin
                    (kemacs-resolve-context)))
         (root (kemacs-context-root context))
         (paths (kemacs-impact-changed-paths range context))
         (buffer (get-buffer-create
                  (format "*kemacs-impact:%s*" (kemacs-root-id root)))))
    (unless paths
      (user-error "The %s is empty" (kemacs-impact--selection-label range)))
    (with-current-buffer buffer
      (kemacs-impact-mode)
      (setq-local kemacs-impact-root root)
      (setq-local kemacs-impact-range range)
      (setq-local kemacs-impact-origin origin)
      (setq-local kemacs-impact-context context)
      (setq-local kemacs-root-override root)
      (setq default-directory root)
      (kemacs-impact--render paths))
    (pop-to-buffer buffer)))

;;;###autoload
(defun kemacs-impact-plan-range (range)
  "Prompt for Git RANGE and show its heuristic change-impact plan."
  (interactive
   (list (read-string "Git revision/range: " kemacs-review-default-range
                      'kemacs-impact-range-history)))
  (kemacs-impact-plan range))

(defun kemacs-impact-available-p ()
  "Return non-nil when impact planning is available in the current tree."
  (let ((root (kemacs-root t)))
    (and root
         (file-exists-p (expand-file-name ".git" root))
         (kemacs-tool-path "git" (kemacs-resolve-context root)))))

(kemacs-register-action
 'kemacs-impact-plan "Plan staged change impact" "Review"
 #'kemacs-impact-plan
 :predicate #'kemacs-impact-available-p
 :description "Show heuristic build, configuration, test, and review targets")

(provide 'kemacs-impact)

;;; kemacs-impact.el ends here
