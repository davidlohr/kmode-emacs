;;; kmode-lore.el --- Lore mailing-list context for kmode-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: kmode-emacs contributors
;; Keywords: tools, c, linux, mail
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Explicit, read-only searches of lore.kernel.org.  Results are presented
;; inside Emacs and cached outside the kernel worktree.  Merely moving point
;; never performs network I/O.

;;; Code:

(require 'browse-url)
(require 'cl-lib)
(require 'dom)
(require 'eww)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'thingatpt)
(require 'url)
(require 'url-http)
(require 'url-parse)
(require 'url-util)
(require 'xml)
(require 'kmode-core)

(defvar url-http-end-of-headers)
(defvar url-http-response-status)
(defvar url-request-extra-headers)
(defvar url-request-method)
(defvar url-user-agent)

(defcustom kmode-lore-base-url "https://lore.kernel.org/all/"
  "Public-inbox URL used for kernel mailing-list searches."
  :type 'string
  :group 'kmode)

(defcustom kmode-lore-default-date-range "5.years.ago.."
  "Default public-inbox receipt-time range.

Set this to nil to search the entire archive.  Commands never widen the range
silently; edit the query or customize this option when older context matters."
  :type '(choice (const :tag "All time" nil) string)
  :group 'kmode)

(defcustom kmode-lore-result-limit 20
  "Number of Lore threads requested per result page."
  :type 'integer
  :group 'kmode)

(defcustom kmode-lore-cache-directory
  (expand-file-name "kmode-emacs/lore/" user-emacs-directory)
  "Directory for compact, parsed Lore search-result caches.

This cache is independent of kernel build profiles and symbol indexes."
  :type 'directory
  :group 'kmode)

(defcustom kmode-lore-cache-ttl 900
  "Seconds for which a Lore search cache entry is fresh."
  :type 'integer
  :group 'kmode)

(defcustom kmode-lore-max-cache-entries 64
  "Maximum number of Lore search pages retained on disk."
  :type 'integer
  :group 'kmode)

(defcustom kmode-lore-request-timeout 30
  "Seconds before an in-flight Lore search is cancelled."
  :type 'integer
  :group 'kmode)

(defcustom kmode-lore-max-response-bytes (* 4 1024 1024)
  "Maximum accepted size of one Lore Atom response."
  :type 'integer
  :group 'kmode)

(defcustom kmode-lore-max-query-length 1024
  "Maximum number of characters accepted in a custom Lore query."
  :type 'integer
  :group 'kmode)

(defcustom kmode-lore-user-agent
  "kmode-emacs/0.1.0 (+https://github.com/davidlohr/kmode-emacs)"
  "User-Agent sent for explicit Lore requests."
  :type 'string
  :group 'kmode)

(defcustom kmode-lore-open-function #'eww
  "Function used to read a selected Lore message inside Emacs."
  :type 'function
  :group 'kmode)

(cl-defstruct (kmode-lore-result
               (:constructor kmode-lore--make-result))
  "One compact Lore search result."
  message-id subject author date url scope)

(defconst kmode-lore--cache-schema 1
  "On-disk Lore search-cache schema.")

(defvar-local kmode-lore--query nil)
(defvar-local kmode-lore--scope nil)
(defvar-local kmode-lore--offset 0)
(defvar-local kmode-lore--order 'date)
(defvar-local kmode-lore--results nil)
(defvar-local kmode-lore--status "idle")
(defvar-local kmode-lore--fetched-at nil)
(defvar-local kmode-lore--generation 0)
(defvar-local kmode-lore--request-buffer nil)
(defvar-local kmode-lore--timeout-timer nil)
(defvar-local kmode-lore--root nil)

(defun kmode-lore--quote-term (value)
  "Return VALUE as a quoted public-inbox search term."
  (let ((escaped
         (mapconcat
          (lambda (character)
            (cond ((eq character ?\\) "\\\\")
                  ((eq character ?\") "\\\"")
                  (t (char-to-string character))))
          (string-to-list value) "")))
    (concat "\"" escaped "\"")))

(defun kmode-lore--validate-query (query)
  "Return trimmed QUERY or signal a user-facing validation error."
  (setq query (string-trim (or query "")))
  (when (string-empty-p query)
    (user-error "Lore query cannot be empty"))
  (when (> (length query) kmode-lore-max-query-length)
    (user-error "Lore query exceeds %d characters"
                kmode-lore-max-query-length))
  (when (string-match-p "[[:cntrl:]]" query)
    (user-error "Lore query cannot contain control characters"))
  query)

(defun kmode-lore--validate-symbol (symbol)
  "Return normalized kernel SYMBOL or signal a user-facing error."
  (unless (stringp symbol)
    (user-error "Kernel symbol must be a string"))
  (setq symbol (string-trim symbol))
  (unless (string-match-p
           "\\`[[:alpha:]_][[:alnum:]_]*\\'" symbol)
    (user-error "Invalid or empty kernel symbol: %S" symbol))
  symbol)

(defun kmode-lore--with-date-range (query)
  "Apply the configured receipt-time range to QUERY."
  (if (and kmode-lore-default-date-range
           (not (string-empty-p kmode-lore-default-date-range)))
      (format "(%s) AND rt:%s" query kmode-lore-default-date-range)
    query))

(defun kmode-lore--symbol-query (symbol)
  "Return a discussion-and-diff query for SYMBOL."
  (let ((term (kmode-lore--quote-term (kmode-lore--validate-symbol symbol))))
    (kmode-lore--with-date-range
     (format
      "(s:%s OR nq:%s OR dfhh:%s OR dfa:%s OR dfb:%s OR dfctx:%s)"
      term term term term term term))))

(defun kmode-lore--file-query (relative)
  "Return a patch-history query for repository-relative path RELATIVE."
  (kmode-lore--with-date-range
   (format "dfn:%s" (kmode-lore--quote-term relative))))

(defun kmode-lore--context-query (symbol relative)
  "Return a combined Lore query for SYMBOL and RELATIVE file."
  (cond
   ((and symbol relative)
    (let ((term (kmode-lore--quote-term
                 (kmode-lore--validate-symbol symbol)))
          (file (kmode-lore--quote-term relative)))
      (kmode-lore--with-date-range
       (format
        "((dfn:%s AND (dfhh:%s OR dfa:%s OR dfb:%s OR dfctx:%s)) OR s:%s OR nq:%s)"
        file term term term term term term))))
   (symbol (kmode-lore--symbol-query symbol))
   (relative (kmode-lore--file-query relative))
   (t (user-error "No symbol or kernel file is available for Lore context"))))

(defun kmode-lore--identifier-at-point ()
  "Return a useful C-like identifier at point, including type tags."
  (if (use-region-p)
      (let ((selection
             (string-trim
              (buffer-substring-no-properties
               (region-beginning) (region-end)))))
        (and (string-match-p
              "\\`[[:alpha:]_][[:alnum:]_]*\\'" selection)
             selection))
    (save-excursion
      (let ((identifier (thing-at-point 'symbol t))
            (keywords '("struct" "union" "enum" "typedef")))
        (while (and identifier (member identifier keywords))
          (goto-char (cdr (bounds-of-thing-at-point 'symbol)))
          (skip-syntax-forward " ")
          (setq identifier (thing-at-point 'symbol t)))
        identifier))))

(defun kmode-lore--relative-file ()
  "Return the current file relative to its kernel root."
  (unless buffer-file-name
    (user-error "The current buffer has no kernel source file"))
  (kmode-file-in-root buffer-file-name (kmode-resolve-context)))

(defun kmode-lore--search-url (query offset order)
  "Build the Lore Atom URL for QUERY, OFFSET, and ORDER."
  (format "%s?q=%s&x=A&l=%d&o=%d&t=1%s"
          (file-name-as-directory kmode-lore-base-url)
          (url-hexify-string query)
          kmode-lore-result-limit
          offset
          (if (eq order 'relevance) "&r=1" "")))

(defun kmode-lore--message-id-from-url (url)
  "Extract and decode the Message-ID path component from URL."
  (let* ((parsed (url-generic-parse-url url))
         (path (string-remove-suffix "/" (or (url-filename parsed) "")))
         (component (file-name-nondirectory path)))
    (unless (string-empty-p component)
      (url-unhex-string component))))

(defun kmode-lore--parse-atom (start end scope)
  "Parse Lore Atom XML between START and END and label it with SCOPE."
  (let* ((document (car (xml-parse-region start end)))
         (entries (and document (dom-by-tag document 'entry))))
    (unless (and document (eq (dom-tag document) 'feed))
      (error "Lore response is not an Atom feed"))
    (mapcar
     (lambda (entry)
       (let* ((title-node (car (dom-by-tag entry 'title)))
              (author-node (car (dom-by-tag entry 'author)))
              (name-node (and author-node
                              (car (dom-by-tag author-node 'name))))
              (updated-node (car (dom-by-tag entry 'updated)))
              (link-node
               (seq-find
                (lambda (node)
                  (and (dom-attr node 'href)
                       (let ((relation (dom-attr node 'rel)))
                         (or (null relation)
                             (equal relation "alternate")))))
                (dom-by-tag entry 'link)))
              (url (and link-node (dom-attr link-node 'href))))
         (when url
           (kmode-lore--make-result
            :message-id (kmode-lore--message-id-from-url url)
            :subject (string-trim (or (and title-node
                                           (dom-text title-node))
                                      "(no subject)"))
            :author (string-trim (or (and name-node (dom-text name-node))
                                     "(unknown)"))
            :date (string-trim (or (and updated-node
                                         (dom-text updated-node))
                                    ""))
            :url url
            :scope scope))))
     (seq-filter
      (lambda (entry)
        (seq-some (lambda (node) (dom-attr node 'href))
                  (dom-by-tag entry 'link)))
      entries))))

(defun kmode-lore--cache-key ()
  "Return the cache identity for the current Lore result page."
  (secure-hash
   'sha256
   (format "%d\0%s\0%s\0%s\0%d\0%d\0%s"
           kmode-lore--cache-schema
           kmode-lore-base-url
           kmode-lore--scope
           kmode-lore--query
           kmode-lore--offset
           kmode-lore-result-limit
           kmode-lore--order)))

(defun kmode-lore--cache-file ()
  "Return the cache filename for the current Lore result page."
  (expand-file-name
   (format "kmode-lore-%s.json" (kmode-lore--cache-key))
   kmode-lore-cache-directory))

(defun kmode-lore--result-json (result)
  "Return a JSON-ready alist for RESULT."
  `((message-id . ,(kmode-lore-result-message-id result))
    (subject . ,(kmode-lore-result-subject result))
    (author . ,(kmode-lore-result-author result))
    (date . ,(kmode-lore-result-date result))
    (url . ,(kmode-lore-result-url result))
    (scope . ,(kmode-lore-result-scope result))))

(defun kmode-lore--json-result (object)
  "Return a Lore result decoded from JSON alist OBJECT."
  (kmode-lore--make-result
   :message-id (alist-get 'message-id object)
   :subject (alist-get 'subject object)
   :author (alist-get 'author object)
   :date (alist-get 'date object)
   :url (alist-get 'url object)
   :scope (alist-get 'scope object)))

(defun kmode-lore--cache-read ()
  "Return the current page's decoded cache entry, or nil."
  (let ((file (kmode-lore--cache-file)))
    (when (and (file-regular-p file)
               (not (file-symlink-p file)))
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file)
            (let* ((object
                    (json-parse-buffer :object-type 'alist
                                       :array-type 'list
                                       :null-object nil
                                       :false-object nil))
                   (schema (alist-get 'schema object))
                   (fetched (alist-get 'fetched object))
                   (items (alist-get 'results object)))
              (when (and (= schema kmode-lore--cache-schema)
                         (numberp fetched)
                         (listp items))
                (list :fetched fetched
                      :fresh (< (- (float-time) fetched)
                                kmode-lore-cache-ttl)
                      :results (mapcar #'kmode-lore--json-result items)))))
        (error nil)))))

(defun kmode-lore--cache-prune ()
  "Prune old Kmode Lore cache files to the configured entry limit."
  (when (file-directory-p kmode-lore-cache-directory)
    (let* ((files
            (seq-filter
             (lambda (file)
               (and (file-regular-p file)
                    (not (file-symlink-p file))))
             (directory-files
              kmode-lore-cache-directory t
              "\\`kmode-lore-[[:xdigit:]]\\{64\\}\\.json\\'")))
           (ordered
            (sort files
                  (lambda (left right)
                    (time-less-p
                     (file-attribute-modification-time
                      (file-attributes left))
                     (file-attribute-modification-time
                      (file-attributes right)))))))
      (dolist (file (seq-take
                     ordered
                     (max 0 (- (length ordered)
                               kmode-lore-max-cache-entries))))
        (delete-file file)))))

(defun kmode-lore--cache-write (results)
  "Atomically cache RESULTS for the current Lore page."
  (make-directory kmode-lore-cache-directory t)
  (set-file-modes kmode-lore-cache-directory #o700)
  (let* ((file (kmode-lore--cache-file))
         (temporary
          (make-temp-file
           (expand-file-name ".kmode-lore-" kmode-lore-cache-directory)))
         (payload
          `((schema . ,kmode-lore--cache-schema)
            (fetched . ,(float-time))
            (results . ,(vconcat
                         (mapcar #'kmode-lore--result-json results))))))
    (unwind-protect
        (progn
          (with-temp-file temporary
            (insert (json-encode payload) "\n"))
          (set-file-modes temporary #o600)
          (rename-file temporary file t)
          (setq temporary nil)
          (kmode-lore--cache-prune))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun kmode-lore--status-with-results (source results)
  "Return result SOURCE status with an actionable hint for empty RESULTS."
  (if results source
    (format "%s — no matches; press s to edit or widen the query" source)))

(defun kmode-lore--fetched-label ()
  "Return a UTC freshness label for the current Lore result page."
  (and (numberp kmode-lore--fetched-at)
       (format-time-string
        "%Y-%m-%d %H:%M UTC" (seconds-to-time kmode-lore--fetched-at) t)))

(defun kmode-lore--status-header ()
  "Return a compact header for the current Lore result buffer."
  (format " Lore  %s%s  | page %d  | %s  | %s"
          kmode-lore--status
          (if-let ((fetched (kmode-lore--fetched-label)))
              (format "  | fetched %s" fetched)
            "")
          (1+ (/ kmode-lore--offset (max 1 kmode-lore-result-limit)))
          (symbol-name kmode-lore--order)
          (truncate-string-to-width (or kmode-lore--query "") 100 nil nil "…")))

(defun kmode-lore--render ()
  "Render the current buffer's Lore results and status."
  (setq tabulated-list-entries
        (mapcar
         (lambda (result)
           (list
            (kmode-lore-result-url result)
            (vector
             (let ((date (kmode-lore-result-date result)))
               (if (>= (length date) 10) (substring date 0 10) date))
             (or (kmode-lore-result-scope result) "search")
             (kmode-lore-result-author result)
             (kmode-lore-result-subject result))))
         kmode-lore--results)
        header-line-format (kmode-lore--status-header))
  (tabulated-list-print t)
  (force-mode-line-update t))

(defun kmode-lore--cancel-request ()
  "Cancel the current result buffer's request and timeout."
  (when (timerp kmode-lore--timeout-timer)
    (cancel-timer kmode-lore--timeout-timer))
  (setq kmode-lore--timeout-timer nil)
  (when (buffer-live-p kmode-lore--request-buffer)
    (when-let ((process (get-buffer-process kmode-lore--request-buffer)))
      (when (process-live-p process)
        (delete-process process)))
    (kill-buffer kmode-lore--request-buffer))
  (setq kmode-lore--request-buffer nil))

(defun kmode-lore--request-failed (target generation message stale)
  "Report MESSAGE for TARGET request GENERATION, using STALE cache."
  (when (buffer-live-p target)
    (with-current-buffer target
      (when (= generation kmode-lore--generation)
        (when (timerp kmode-lore--timeout-timer)
          (cancel-timer kmode-lore--timeout-timer))
        (setq kmode-lore--timeout-timer nil
              kmode-lore--request-buffer nil)
        (if stale
            (setq kmode-lore--results (plist-get stale :results)
                  kmode-lore--fetched-at (plist-get stale :fetched)
                  kmode-lore--status (format "STALE — %s" message))
          (setq kmode-lore--results nil
                kmode-lore--fetched-at nil
                kmode-lore--status (format "ERROR — %s" message)))
        (kmode-lore--render)))))

(defun kmode-lore--response-body-start ()
  "Return the start of the current URL response body."
  (cond
   ((markerp url-http-end-of-headers)
    (marker-position url-http-end-of-headers))
   ((integerp url-http-end-of-headers)
    url-http-end-of-headers)
   (t
    (goto-char (point-min))
    (when (re-search-forward "\r?\n\r?\n" nil t)
      (point)))))

(defun kmode-lore--response (status target generation stale)
  "Handle a Lore URL response with STATUS for TARGET and GENERATION.

STALE is the prior cache entry, if one was available."
  (let ((response (current-buffer)))
    (unwind-protect
        (if (not (buffer-live-p target))
            nil
          (with-current-buffer target
            (when (= generation kmode-lore--generation)
              (cond
               ((plist-get status :error)
                (kmode-lore--request-failed
                 target generation
                 (format "%s" (plist-get status :error)) stale))
               ((with-current-buffer response
                  (not (eq url-http-response-status 200)))
                (kmode-lore--request-failed
                 target generation
                 (format "HTTP %s"
                         (with-current-buffer response
                           url-http-response-status))
                 stale))
               (t
                (condition-case error-data
                    (let ((results
                           (with-current-buffer response
                             (let ((start (kmode-lore--response-body-start)))
                               (unless start
                                 (error "Lore response has no body"))
                               (when (> (- (point-max) start)
                                        kmode-lore-max-response-bytes)
                                 (error "Lore response exceeds %d bytes"
                                        kmode-lore-max-response-bytes))
                               (kmode-lore--parse-atom
                                start (point-max) (buffer-local-value (quote kmode-lore--scope) target))))))
                      (when (timerp kmode-lore--timeout-timer)
                        (cancel-timer kmode-lore--timeout-timer))
                      (setq kmode-lore--timeout-timer nil
                            kmode-lore--request-buffer nil
                            kmode-lore--results (delq nil results)
                            kmode-lore--fetched-at (float-time)
                            kmode-lore--status
                            (kmode-lore--status-with-results "live" results))
                      (condition-case cache-error
                          (kmode-lore--cache-write kmode-lore--results)
                        (error
                         (message "Kmode Lore cache write failed: %s"
                                  (error-message-string cache-error))))
                      (kmode-lore--render))
                  (error
                   (kmode-lore--request-failed
                    target generation
                    (error-message-string error-data) stale))))))))
      (when (buffer-live-p response)
        (kill-buffer response)))))

(defun kmode-lore--timeout (target generation stale)
  "Cancel TARGET request GENERATION and fall back to STALE."
  (when (buffer-live-p target)
    (with-current-buffer target
      (when (= generation kmode-lore--generation)
        (when (buffer-live-p kmode-lore--request-buffer)
          (when-let ((process
                      (get-buffer-process kmode-lore--request-buffer)))
            (when (process-live-p process)
              (delete-process process)))
          (kill-buffer kmode-lore--request-buffer))
        (setq kmode-lore--request-buffer nil
              kmode-lore--timeout-timer nil)
        (kmode-lore--request-failed
         target generation "request timed out" stale)))))

(defun kmode-lore--request (&optional force)
  "Load the current Lore page, bypassing a fresh cache when FORCE is non-nil."
  (kmode-lore--cancel-request)
  (cl-incf kmode-lore--generation)
  (let* ((target (current-buffer))
         (generation kmode-lore--generation)
         (cache (kmode-lore--cache-read))
         (fresh (and cache (plist-get cache :fresh))))
    (if (and fresh (not force))
        (progn
          (setq kmode-lore--results (plist-get cache :results)
                kmode-lore--fetched-at (plist-get cache :fetched)
                kmode-lore--status
                (kmode-lore--status-with-results "cached" (plist-get cache :results)))
          (kmode-lore--render))
      (when cache
        (setq kmode-lore--results (plist-get cache :results)
              kmode-lore--fetched-at (plist-get cache :fetched)))
      (setq kmode-lore--status (if cache "STALE — refreshing" "loading"))
      (kmode-lore--render)
      (let ((url-request-method "GET")
            (url-user-agent kmode-lore-user-agent)
            (url-request-extra-headers
             '(("Accept" . "application/atom+xml"))))
        (condition-case error-data
            (let ((request
                   (url-retrieve
                    (kmode-lore--search-url
                     kmode-lore--query kmode-lore--offset kmode-lore--order)
                    #'kmode-lore--response
                    (list target generation cache) t t)))
              (unless (buffer-live-p request)
                (error "Lore request did not start"))
              (setq kmode-lore--request-buffer request
                    kmode-lore--timeout-timer
                    (run-at-time
                     kmode-lore-request-timeout nil
                     #'kmode-lore--timeout target generation cache)))
          (error
           (kmode-lore--request-failed
            target generation (error-message-string error-data) cache)))))))

(defvar kmode-lore-results-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'kmode-lore-open-message)
    (define-key map (kbd "o") #'kmode-lore-browse-message)
    (define-key map (kbd "T") #'kmode-lore-browse-thread)
    (define-key map (kbd "w") #'kmode-lore-copy-url)
    (define-key map (kbd "m") #'kmode-lore-copy-message-id)
    (define-key map (kbd "g") #'kmode-lore-refresh)
    (define-key map (kbd "s") #'kmode-lore-edit-search)
    (define-key map (kbd "N") #'kmode-lore-next-page)
    (define-key map (kbd "P") #'kmode-lore-previous-page)
    (define-key map (kbd "r") #'kmode-lore-toggle-order)
    map)
  "Keymap for Kmode Lore search results.")

(define-derived-mode kmode-lore-results-mode
  tabulated-list-mode "kmode-emacs-Lore"
  "Display explicit, read-only Lore mailing-list search results."
  (setq tabulated-list-format
        [("Date" 12 t)
         ("Match" 10 t)
         ("From" 24 t)
         ("Subject" 0 t)]
        tabulated-list-padding 2)
  (tabulated-list-init-header)
  (add-hook 'kill-buffer-hook #'kmode-lore--cancel-request nil t))

(defun kmode-lore--clear-displayed-page ()
  "Clear rows and freshness belonging to a previous result identity."
  (setq kmode-lore--results nil
        kmode-lore--fetched-at nil))

(defun kmode-lore--start-search (query scope &optional force)
  "Show QUERY results labelled SCOPE.

When FORCE is non-nil, bypass a fresh cache."
  (let ((root (kmode-root t))
        (origin-directory default-directory)
        (query (kmode-lore--validate-query query))
        (buffer (get-buffer-create "*kmode Lore*")))
    (pop-to-buffer buffer)
    (unless (derived-mode-p 'kmode-lore-results-mode)
      (kmode-lore-results-mode))
    (setq default-directory (or root origin-directory)
          kmode-root-override root
          kmode-lore--root root
          kmode-lore--query query
          kmode-lore--scope scope
          kmode-lore--offset 0
          kmode-lore--order 'date)
    (kmode-lore--clear-displayed-page)
    (kmode-lore--request force)))

;;;###autoload
(defun kmode-lore-search (query)
  "Search all Lore kernel archives for public-inbox QUERY."
  (interactive (list (read-string "Lore query: ")))
  (kmode-lore--start-search query "query"))

;;;###autoload
(defun kmode-lore-search-symbol (&optional symbol)
  "Search Lore discussions and patches for SYMBOL at point."
  (interactive)
  (setq symbol (or symbol (kmode-lore--identifier-at-point)
                   (read-string "Kernel symbol: ")))
  (kmode-lore--start-search (kmode-lore--symbol-query symbol) "symbol"))

;;;###autoload
(defun kmode-lore-search-file (&optional file)
  "Search Lore patch history for kernel source FILE."
  (interactive)
  (let* ((context (kmode-resolve-context))
         (relative (kmode-file-in-root (or file buffer-file-name) context)))
    (kmode-lore--start-search (kmode-lore--file-query relative) "file")))

;;;###autoload
(defun kmode-lore-search-directory ()
  "Search Lore patch history for the current kernel source directory."
  (interactive)
  (let* ((context (kmode-resolve-context))
         (root (kmode-context-root context))
         (directory (if buffer-file-name
                        (file-name-directory buffer-file-name)
                      default-directory))
         (relative (file-relative-name directory root))
         (prefix (if (equal relative "./")
                     ""
                   (file-name-as-directory relative))))
    (unless (file-in-directory-p directory root)
      (user-error "Current directory is outside the kernel tree"))
    (kmode-lore--start-search
     (kmode-lore--file-query (concat prefix "*")) "directory")))

;;;###autoload
(defun kmode-lore-context-at-point ()
  "Search Lore using the identifier at point and valid kernel file context."
  (interactive)
  (let* ((symbol (kmode-lore--identifier-at-point))
         (root (kmode-root t))
         (relative
          (and root buffer-file-name
               (file-in-directory-p buffer-file-name root)
               (file-relative-name buffer-file-name root))))
    (kmode-lore--start-search
     (kmode-lore--context-query symbol relative) "context")))

(defun kmode-lore--git-output (arguments)
  "Return Git output for ARGUMENTS in the active kernel context."
  (let* ((context (kmode-resolve-context))
         (root (kmode-context-root context))
         (git (kmode-require-tool "git" context)))
    (with-temp-buffer
      (let ((status
             (apply #'process-file git nil t nil
                    (append (list "-C" root) arguments))))
        (unless (and (integerp status) (zerop status))
          (user-error "Git failed while resolving Lore provenance"))
        (buffer-string)))))

(defun kmode-lore--trusted-origin-url (value)
  "Normalize trusted kernel mailing-list origin URL VALUE.

Native lore.kernel.org HTTPS links are returned unchanged.  Legacy
lkml.kernel.org `/r/' redirects are converted to stable Lore `/all/' message
URLs.  Return nil for every other scheme or host."
  (condition-case nil
      (let* ((value (string-trim value "[<[:space:]]+"
                                 "[>),.;[:space:]]+"))
             (parsed (url-generic-parse-url value))
             (scheme (url-type parsed))
             (host (url-host parsed))
             (path (url-filename parsed)))
        (cond
         ((and (equal scheme "https")
               (equal host "lore.kernel.org")
               (string-prefix-p "/" (or path "")))
          value)
         ((and (equal scheme "https")
               (equal host "lkml.kernel.org")
               (string-prefix-p "/r/" (or path "")))
          (let* ((encoded (car (split-string
                                (substring path (length "/r/")) "[?#]")))
                 (message-id
                  (string-trim (url-unhex-string encoded) "<" ">")))
            (when (and (not (string-empty-p message-id))
                       (not (string-match-p "[?#[:cntrl:]]" message-id)))
              (format "https://lore.kernel.org/all/%s/"
                      (url-hexify-string message-id)))))))
    (error nil)))

(defun kmode-lore--origin-links ()
  "Return trusted mailing-list Link trailers for the current source line."
  (let* ((relative (kmode-lore--relative-file))
         (line (line-number-at-pos))
         (blame
          (kmode-lore--git-output
           (list "blame" "--porcelain"
                 "-L" (format "%d,%d" line line) "--" relative)))
         (commit
          (and (string-match
                "\\`\\([[:xdigit:]]\\{40,64\\}\\)\\(?:[ \n]\\)" blame)
               (match-string 1 blame))))
    (when (and commit (not (string-match-p "\\`0+\\'" commit)))
      (let ((message
             (kmode-lore--git-output
              (list "show" "-s" "--format=%B" commit)))
            (case-fold-search t)
            links)
        (with-temp-buffer
          (insert message)
          (goto-char (point-min))
          (while (re-search-forward
                  "^Link:[ \t]+\\(<?https://[^ \t\r\n]+>?\\)"
                  nil t)
            (when-let ((url
                        (kmode-lore--trusted-origin-url
                         (match-string-no-properties 1))))
              (cl-pushnew url links :test #'equal))))
        (nreverse links)))))

;;;###autoload
(defun kmode-lore-why ()
  "Open the trusted Lore origin for this line, or search contextual history."
  (interactive)
  (let (links fallback)
    (if (buffer-modified-p)
        (setq fallback "buffer has unsaved changes")
      (condition-case error-data
          (setq links (kmode-lore--origin-links))
        (error
         (setq fallback (error-message-string error-data)))))
    (if links
        (let ((url
               (if (= (length links) 1)
                   (car links)
                 (completing-read "Originating Lore thread: " links nil t))))
          (funcall kmode-lore-open-function url)
          (message "Opened the commit's Lore Link trailer"))
      (message "No exact Lore origin (%s); searching by symbol and file"
               (or fallback "commit has no trusted Link trailer"))
      (kmode-lore-context-at-point))))

(defun kmode-lore--current-result ()
  "Return the Lore result on the current row."
  (let ((url (tabulated-list-get-id)))
    (or (seq-find
         (lambda (result)
           (equal url (kmode-lore-result-url result)))
         kmode-lore--results)
        (user-error "No Lore result on this row"))))

;;;###autoload
(defun kmode-lore-open-message ()
  "Read the selected Lore message inside Emacs."
  (interactive)
  (funcall kmode-lore-open-function
           (kmode-lore-result-url (kmode-lore--current-result))))

;;;###autoload
(defun kmode-lore-browse-message ()
  "Open the selected Lore message with the configured external browser."
  (interactive)
  (browse-url (kmode-lore-result-url (kmode-lore--current-result))))

;;;###autoload
(defun kmode-lore-browse-thread ()
  "Open the selected Lore message's nested thread view."
  (interactive)
  (browse-url
   (concat
    (string-remove-suffix
     "/" (kmode-lore-result-url (kmode-lore--current-result)))
    "/t/#u")))

;;;###autoload
(defun kmode-lore-copy-url ()
  "Copy the selected Lore message URL."
  (interactive)
  (let ((url (kmode-lore-result-url (kmode-lore--current-result))))
    (kill-new url)
    (message "Copied %s" url)))

;;;###autoload
(defun kmode-lore-copy-message-id ()
  "Copy the selected Lore Message-ID with angle brackets."
  (interactive)
  (let ((message-id
         (kmode-lore-result-message-id (kmode-lore--current-result))))
    (kill-new (format "<%s>" message-id))
    (message "Copied <%s>" message-id)))

;;;###autoload
(defun kmode-lore-refresh ()
  "Force a live refresh of the current Lore result page."
  (interactive)
  (kmode-lore--request t))

;;;###autoload
(defun kmode-lore-next-page ()
  "Load the next Lore result page."
  (interactive)
  (cl-incf kmode-lore--offset kmode-lore-result-limit)
  (kmode-lore--clear-displayed-page)
  (kmode-lore--request))

;;;###autoload
(defun kmode-lore-previous-page ()
  "Load the previous Lore result page."
  (interactive)
  (when (zerop kmode-lore--offset)
    (user-error "Already on the first Lore page"))
  (setq kmode-lore--offset
        (max 0 (- kmode-lore--offset kmode-lore-result-limit)))
  (kmode-lore--clear-displayed-page)
  (kmode-lore--request))

;;;###autoload
(defun kmode-lore-toggle-order ()
  "Toggle Lore results between date and relevance order."
  (interactive)
  (setq kmode-lore--order
        (if (eq kmode-lore--order 'date) 'relevance 'date)
        kmode-lore--offset 0)
  (kmode-lore--clear-displayed-page)
  (kmode-lore--request))

;;;###autoload
(defun kmode-lore-edit-search ()
  "Edit and rerun the current public-inbox query."
  (interactive)
  (setq kmode-lore--query
        (kmode-lore--validate-query
         (read-string "Lore query: " kmode-lore--query))
        kmode-lore--offset 0)
  (kmode-lore--clear-displayed-page)
  (kmode-lore--request))

;;;###autoload
(defun kmode-lore-clear-cache ()
  "Delete only regular Kmode Lore search-cache files."
  (interactive)
  (let ((count 0))
    (when (file-directory-p kmode-lore-cache-directory)
      (dolist
          (file
           (directory-files
            kmode-lore-cache-directory t
            "\\`kmode-lore-[[:xdigit:]]\\{64\\}\\.json\\'"))
        (when (and (file-regular-p file)
                   (not (file-symlink-p file)))
          (delete-file file)
          (cl-incf count))))
    (message "Deleted %d Kmode Lore cache file%s"
             count (if (= count 1) "" "s"))))

(kmode-register-action
 'lore-context "Lore context at point" "Review" #'kmode-lore-context-at-point
 :predicate (lambda () (and buffer-file-name (kmode-root t)))
 :description "Search mailing-list discussion by symbol and kernel path")
(kmode-register-action
 'lore-why "Lore: why is this line here?" "Review" #'kmode-lore-why
 :predicate (lambda () (and buffer-file-name (kmode-root t)
                            (kmode-tool-path "git")))
 :description "Follow the blamed commit's Lore Link trailer or search context")
(kmode-register-action
 'lore-file "Lore history for current file" "Review" #'kmode-lore-search-file
 :predicate (lambda () (and buffer-file-name (kmode-root t)))
 :description "Find patches and discussion touching this kernel source file")
(kmode-register-action
 'lore-search "Search Lore query" "Review" #'kmode-lore-search
 :description "Run an explicit public-inbox query across kernel archives")

(provide 'kmode-lore)

;;; kmode-lore.el ends here
