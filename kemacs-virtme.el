;;; kemacs-virtme.el --- virtme-ng kernel runs for Kemacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Kemacs contributors
;; Keywords: tools, c, linux, processes
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; First-class integration with virtme-ng's `vng' frontend.  The active
;; Kemacs profile remains the source of truth: builds write its output and
;; runs explicitly boot that absolute output directory.  Runtime processes
;; use a PTY, retain root/profile ownership after their buffer is killed, and
;; hold the build-output lock while a guest may consume modules.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'comint)
(require 'json)
(require 'kemacs-build)
(require 'kemacs-core)
(require 'kemacs-debug)
(require 'seq)
(require 'subr-x)

(defgroup kemacs-virtme nil
  "Build and run Linux kernels through virtme-ng."
  :group 'kemacs
  :prefix "kemacs-vng-")

(defcustom kemacs-vng-program "vng"
  "The virtme-ng frontend executable.

When this has its default value and `vng' is unavailable, Kemacs also
accepts the official `virtme-ng' executable alias."
  :type 'string
  :group 'kemacs-virtme)

(defcustom kemacs-vng-architecture-alist
  '(("x86_64" . "amd64")
    ("amd64" . "amd64")
    ("arm64" . "arm64")
    ("armhf" . "armhf")
    ("ppc64el" . "ppc64el")
    ("s390" . "s390x")
    ("s390x" . "s390x")
    ("riscv64" . "riscv64"))
  "Map unambiguous architecture names to public virtme-ng names.

Names such as kernel ARCH=x86, arm, powerpc, and riscv do not identify the
word size or byte order that vng requires.  Kemacs resolves those names only
from an explicit `:vng-arch', a recognized cross compiler, or the exact host
architecture."
  :type '(alist :key-type string :value-type string)
  :group 'kemacs-virtme)

(defcustom kemacs-vng-home-directory
  (file-name-as-directory (expand-file-name "~"))
  "Stable HOME used by managed vng processes and configuration checks.

Kemacs pins child HOME to this directory so vng reads the same configuration
that Kemacs inspected before launch."
  :type 'directory
  :group 'kemacs-virtme)

(defcustom kemacs-vng-trust-default-options nil
  "Allow a virtme-ng configuration containing `default_opts'.

virtme-ng applies those values after parsing the explicit command line, so
they can override Kemacs's profile, operation, and safety choices.  Leave
this nil for reproducible managed commands.  Set it non-nil only after
reviewing the vng configuration below `kemacs-vng-home-directory'."
  :type 'boolean
  :group 'kemacs-virtme)

(defcustom kemacs-vng-confirm-host-access t
  "Confirm vng options that expose writable host state or host services."
  :type 'boolean
  :group 'kemacs-virtme)

(defcustom kemacs-vng-gdb-target "localhost:1234"
  "Remote GDB endpoint created by the supported vng debug interface."
  :type 'string
  :group 'kemacs-virtme)

(defvar kemacs-vng-command-history nil
  "History of guest commands entered for virtme-ng runs.")

(defconst kemacs-vng--reserved-options
  '("--run" "-r" "--build" "-b" "--clean" "-x"
    "--dump" "-d" "--mcp" "--gdb" "--debug" "--dry-run"
    "--kconfig" "-k" "--commit" "-c" "--force"
    "--build-host" "--build-host-exec-prefix" "--build-host-vmlinux"
    "--arch" "--cross-compile" "--jobs" "-j" "--root"
    "--exec" "-e" "--version" "-V" "--help" "-h")
  "Options owned by Kemacs or deliberately unsupported by its vng adapter.")

(defconst kemacs-vng--dangerous-options
  '("--rw" "--rwdir" "--disk" "-D" "--vfio-pci" "--nvgpu"
    "--network" "-n" "--empty-passwords" "--ssh" "--ssh-client"
    "--console" "--console-client" "--systemd" "--qemu" "--qemu-opts")
  "Options that merit confirmation before a vng runtime launch.")

(defconst kemacs-vng--global-options
  '("--debug" "--pin" "-P" "--ssh" "--ssh-client"
    "--console" "--console-client")
  "Options whose public vng endpoints or host facilities are global.")

(defconst kemacs-vng--profile-option-specs
  '(("--no-virtme-ng-init" :dest no_virtme_ng_init :arity flag
     :scopes (runtime))
    ("--empty-passwords" :dest empty_passwords :arity flag
     :scopes (runtime) :dangerous t)
    ("--pin" :dest pin :arity optional :scopes (runtime) :global t)
    ("--snaps" :dest snaps :arity flag :scopes (runtime))
    ("--skip-modules" :dest skip_modules :arity flag
     :scopes (build runtime))
    ("--config" :dest config :arity list :scopes (build))
    ("--configitem" :dest configitem :arity list :scopes (build))
    ("--busybox" :dest busybox :arity string :scopes (runtime))
    ("--qemu" :dest qemu :arity string :scopes (runtime) :dangerous t)
    ("--name" :dest name :arity string :scopes (runtime))
    ("--user" :dest user :arity string :scopes (runtime))
    ("--shell" :dest shell :arity string :scopes (runtime))
    ("--rw" :dest rw :arity flag :scopes (runtime) :dangerous t)
    ("--no-root-posix-acl" :dest no_root_posix_acl :arity flag
     :scopes (runtime))
    ("--force-9p" :dest force_9p :arity flag :scopes (runtime))
    ("--disable-microvm" :dest disable_microvm :arity flag
     :scopes (runtime))
    ("--disable-kvm" :dest disable_kvm :arity flag :scopes (runtime))
    ("--disable-monitor" :dest disable_monitor :arity flag
     :scopes (runtime))
    ("--cwd" :dest cwd :arity string :scopes (runtime))
    ("--rodir" :dest rodir :arity list :scopes (runtime))
    ("--rwdir" :dest rwdir :arity list :scopes (runtime) :dangerous t)
    ("--overlay-rwdir" :dest overlay_rwdir :arity list :scopes (runtime))
    ("--cpus" :dest cpus :arity string :scopes (runtime))
    ("--memory" :dest memory :arity string :scopes (runtime))
    ("--numa" :dest numa :arity list :scopes (runtime))
    ("--numa-distance" :dest numa_distance :arity list :scopes (runtime))
    ("--balloon" :dest balloon :arity flag :scopes (runtime))
    ("--network" :dest network :arity list :scopes (runtime) :dangerous t)
    ("--no-dhcp" :dest no_dhcp :arity flag :scopes (runtime))
    ("--net-mac-address" :dest net_mac_address :arity string
     :scopes (runtime))
    ("--disk" :dest disk :arity list :scopes (runtime) :dangerous t)
    ("--force-initramfs" :dest force_initramfs :arity flag
     :scopes (runtime))
    ("--sound" :dest sound :arity flag :scopes (runtime))
    ("--graphics" :dest graphics :arity flag :scopes (runtime))
    ("--fb" :dest fb :arity flag :scopes (runtime))
    ("--verbose" :dest verbose :arity count :scopes (build runtime))
    ("--quiet" :dest quiet :arity flag :scopes (build runtime))
    ("--qemu-opts" :dest qemu_opts :arity list
     :scopes (runtime) :dangerous t)
    ("--nvgpu" :dest nvgpu :arity string :scopes (runtime) :dangerous t)
    ("--vfio-pci" :dest vfio_pci :arity list
     :scopes (runtime) :dangerous t)
    ("--console" :dest console :arity port :scopes (runtime)
     :dangerous t :global t)
    ("--console-client" :dest console_client :arity port :scopes (runtime)
     :dangerous t :global t)
    ("--ssh" :dest ssh :arity port :scopes (runtime)
     :dangerous t :global t)
    ("--ssh-client" :dest ssh_client :arity port :scopes (runtime)
     :dangerous t :global t)
    ("--ssh-tcp" :dest ssh_tcp :arity flag :scopes (runtime))
    ("--remote-cmd" :dest remote_cmd :arity string :scopes (runtime))
    ("--systemd" :dest systemd :arity flag :scopes (runtime) :dangerous t))
  "Exact long options profiles may pass to vng.

Each entry records upstream's argparse destination, value shape, valid
profile scopes, and safety traits.  Keeping this list explicit makes new or
abbreviated upstream options fail closed until Kemacs classifies them.")

(defconst kemacs-vng--default-only-option-specs
  '(("--debug" :dest debug :arity flag :scopes (runtime)
     :global t :debug t))
  "Safe configuration defaults that profiles may not pass explicitly.")

(defconst kemacs-vng--forbidden-default-destinations
  '(run build clean dump mcp gdb dry_run kconfig commit force
    build_host build_host_exec_prefix build_host_vmlinux arch cross_compile
    jobs root root_disk root_dev root_release exec append envs)
  "Upstream defaults that may not override Kemacs-owned state or actions.")

(defun kemacs-vng--home-directory ()
  "Return the validated HOME directory used for managed vng processes."
  (let ((home (file-name-as-directory
               (expand-file-name kemacs-vng-home-directory))))
    (unless (and (file-name-absolute-p home) (file-directory-p home))
      (user-error "kemacs-vng-home-directory must exist: %s" home))
    home))

(defun kemacs-vng-config-file ()
  "Return the first existing virtme-ng configuration file, or nil."
  (let ((home (kemacs-vng--home-directory)))
    (seq-find
     #'file-exists-p
     (list (expand-file-name ".config/virtme-ng/virtme-ng.conf" home)
           (expand-file-name ".virtme-ng.conf" home)
           "/etc/virtme-ng.conf"))))

(defun kemacs-vng--process-environment (context)
  "Return a sanitized vng environment pinned to HOME for CONTEXT."
  (let ((process-environment (kemacs-build-process-environment context)))
    (setenv "HOME" (directory-file-name (kemacs-vng--home-directory)))
    process-environment))

(defun kemacs-vng-default-options ()
  "Return configured virtme-ng default options as an alist.

Signal a user error when the selected JSON configuration cannot be read or
parsed.  Return nil when no configuration or no `default_opts' exists."
  (when-let ((file (kemacs-vng-config-file)))
    (unless (file-readable-p file)
      (user-error "Cannot read virtme-ng configuration %s" file))
    (condition-case error-data
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (let* ((configuration
                  (json-parse-buffer :object-type 'alist
                                     :array-type 'list
                                     :null-object nil
                                     :false-object nil))
                 (options (alist-get 'default_opts configuration)))
            (unless (or (null options) (listp options))
              (user-error "The default_opts in %s must be a JSON object" file))
            options))
      (json-parse-error
       (user-error "Invalid virtme-ng JSON in %s: %s"
                   file (error-message-string error-data))))))

(defun kemacs-vng--config-signature ()
  "Return the selected vng configuration path and content digest, or nil."
  (when-let ((file (kemacs-vng-config-file)))
    (condition-case error-data
        (with-temp-buffer
          (insert-file-contents-literally file)
          (cons (file-truename file)
                (secure-hash 'sha256 (current-buffer))))
      (file-error
       (user-error "Cannot fingerprint virtme-ng configuration %s: %s"
                   file (error-message-string error-data))))))

(defun kemacs-vng-config-safe-p ()
  "Return non-nil when virtme-ng defaults cannot override Kemacs."
  (condition-case nil
      (progn (kemacs-vng--assert-config-safe) t)
    (error nil)))

(defun kemacs-vng--option-spec-for-destination (destination)
  "Return the vng option specification for DESTINATION, or nil."
  (seq-find
   (lambda (spec) (eq destination (plist-get (cdr spec) :dest)))
   (append kemacs-vng--profile-option-specs
           kemacs-vng--default-only-option-specs)))

(defun kemacs-vng--default-destination (key)
  "Return KEY as an upstream argparse destination symbol."
  (cond
   ((symbolp key) key)
   ((stringp key) (intern key))
   (t (user-error "Virtme-ng default_opts key must be a string, got %S" key))))

(defun kemacs-vng--validate-default-value (spec value file)
  "Validate VALUE for default option SPEC read from FILE."
  (let* ((option (car spec))
         (properties (cdr spec))
         (arity (plist-get properties :arity))
         (runtime (memq 'runtime (plist-get properties :scopes)))
         (safe-string-p
          (lambda (item)
            (and (stringp item)
                 (not (string-empty-p item))
                 (not (string-match-p "[[:cntrl:]]" item))
                 (or (not runtime)
                     (kemacs-vng--upstream-shell-atom-p item))))))
    (unless
        (pcase arity
          ('flag (memq value '(nil t)))
          ('count (and (integerp value) (>= value 0)))
          ('port (or (null value)
                     (and (integerp value) (<= 1 value 65535))))
          ('optional (or (null value) (funcall safe-string-p value)))
          ('string (or (null value) (funcall safe-string-p value)))
          ('list (or (null value)
                     (and (listp value)
                          (seq-every-p safe-string-p value))))
          (_ nil))
      (user-error "Unsafe or invalid default_opts value for %s in %s: %S"
                  option file value))))

(defun kemacs-vng--validate-default-options (options)
  "Validate trusted default OPTIONS and return normalized entries.

The return value contains pairs of option specifications and configured
values.  Unknown destinations fail closed, and Kemacs-owned actions and
context fields remain forbidden even when the configuration is trusted."
  (let ((file (kemacs-vng-config-file))
        seen validated)
    (dolist (entry options (nreverse validated))
      (unless (consp entry)
        (user-error "Default_opts in %s must be a JSON object" file))
      (let* ((destination (kemacs-vng--default-destination (car entry)))
             (spec (kemacs-vng--option-spec-for-destination destination)))
        (when (memq destination seen)
          (user-error "Duplicate default_opts destination %s in %s"
                      destination file))
        (push destination seen)
        (when (memq destination kemacs-vng--forbidden-default-destinations)
          (user-error
           "Default_opts in %s cannot override Kemacs-owned %s"
           file destination))
        (unless spec
          (user-error
           "Unsupported default_opts destination %s in %s; Kemacs fails closed"
           destination file))
        (kemacs-vng--validate-default-value spec (cdr entry) file)
        (push (cons spec (cdr entry)) validated)))))

(defun kemacs-vng--assert-config-safe ()
  "Reject untrusted virtme-ng defaults that override explicit arguments."
  (let ((options (kemacs-vng-default-options)))
    (when (and options (not kemacs-vng-trust-default-options))
      (user-error
       (concat "virtme-ng default_opts in %s override explicit Kemacs "
               "arguments; review them, then customize "
               "kemacs-vng-trust-default-options")
       (kemacs-vng-config-file)))
    (and options (kemacs-vng--validate-default-options options))))

(defun kemacs-vng--enabled-default-specs-from (defaults)
  "Return specifications enabled in validated vng DEFAULTS."
  (delq nil
        (mapcar
         (lambda (entry)
           (let ((spec (car entry))
                 (value (cdr entry)))
             (when (pcase (plist-get (cdr spec) :arity)
                     ('flag (eq value t))
                     ('count (> value 0))
                     (_ (not (null value))))
               spec)))
         defaults)))

(defun kemacs-vng--enabled-default-specs ()
  "Return specifications for enabled, validated vng defaults."
  (kemacs-vng--enabled-default-specs-from
   (or (kemacs-vng--assert-config-safe) nil)))

(defun kemacs-vng--default-debug-value-from (fallback defaults)
  "Return effective debug state from FALLBACK and validated DEFAULTS."
  (let ((entry
         (seq-find
          (lambda (item)
            (eq (plist-get (cdr (car item)) :dest) 'debug))
          defaults)))
    (if entry (eq (cdr entry) t) fallback)))

(defun kemacs-vng--default-debug-value (fallback)
  "Return the effective trusted debug default, or FALLBACK when absent."
  (kemacs-vng--default-debug-value-from
   fallback (or (kemacs-vng--assert-config-safe) nil)))

(defun kemacs-vng-program-path (&optional context noerror)
  "Return the managed virtme-ng executable for CONTEXT.

With NOERROR non-nil, return nil instead of signaling when it is absent."
  (let* ((context (or context (kemacs-resolve-context)))
         (configured kemacs-vng-program)
         (program
          (or (kemacs-tool-path configured context)
              (and (equal configured "vng")
                   (kemacs-tool-path "virtme-ng" context)))))
    (cond
     (program program)
     (noerror nil)
     (t (user-error
         "Kemacs needs virtme-ng's `vng'; install it or customize kemacs-vng-program")))))

(defun kemacs-vng-version (&optional context)
  "Return the selected virtme-ng version string for CONTEXT, or nil."
  (let* ((context (or context (kemacs-resolve-context)))
         (program (kemacs-vng-program-path context t)))
    (when program
      (condition-case nil
          (let ((process-environment
                 (kemacs-vng--process-environment context)))
            (with-temp-buffer
              (when (zerop (process-file program nil t nil "--version"))
                (let ((version (string-trim (buffer-string))))
                  (unless (string-empty-p version) version)))))
        (error nil)))))

(defun kemacs-vng--strings (values property)
  "Validate VALUES as argv strings from profile PROPERTY."
  (unless (listp values)
    (user-error "%s must be a list of strings, got %S" property values))
  (mapcar
   (lambda (value)
     (unless (and (stringp value)
                  (not (string-empty-p value))
                  (not (string-match-p "[[:cntrl:]]" value)))
       (user-error "%s must contain non-empty strings without control characters, got %S"
                   property value))
     value)
   values))

(defun kemacs-vng--option-p (argument option)
  "Return non-nil if ARGUMENT is a selector for OPTION."
  (or (equal argument option)
      (and (string-prefix-p "--" option)
           (string-prefix-p (concat option "=") argument))))

(defun kemacs-vng--reserved-option-p (argument)
  "Return non-nil when ARGUMENT is managed rather than profile supplied."
  (or (member argument '("--" "-"))
      (seq-some (lambda (option)
                  (kemacs-vng--option-p argument option))
                kemacs-vng--reserved-options)
      (string-match-p "\\`-[rbxdkcejVh]" argument)
      (string-match-p "\\`-j[0-9]" argument)
      (string-match-p
       "\\`\\(?:O\\|KBUILD_OUTPUT\\|ARCH\\|CROSS_COMPILE\\|LLVM\\)="
       argument)))

(defun kemacs-vng--upstream-shell-atom-p (value)
  "Return non-nil when VALUE survives vng's internal shell reconstruction."
  (and (stringp value)
       (string-match-p "\\`[[:alnum:]_./+@%:,=-]+\\'" value)))

(defun kemacs-vng--long-option-parts (argument)
  "Return (NAME . ATTACHED-VALUE) for long option ARGUMENT.

ATTACHED-VALUE is the symbol `none' when no equals sign was present."
  (when (string-prefix-p "--" argument)
    (if-let ((equals (string-match "=" argument)))
        (cons (substring argument 0 equals)
              (substring argument (1+ equals)))
      (cons argument 'none))))

(defun kemacs-vng--profile-arguments (values property scope)
  "Return validated vng argument VALUES from profile PROPERTY.

SCOPE is `build' or `runtime'.  Only exact canonical long options in
`kemacs-vng--profile-option-specs' are accepted.  In particular, argparse
abbreviations, short options, compact short clusters, and free positional
arguments are rejected."
  (let ((arguments (kemacs-vng--strings values property))
        (remaining nil))
    (setq remaining arguments)
    (while remaining
      (let* ((argument (pop remaining))
             (parts (kemacs-vng--long-option-parts argument))
             (name (car-safe parts))
             (attached (cdr-safe parts))
             (spec (and name
                        (assoc-string name kemacs-vng--profile-option-specs)))
             (arity (and spec (plist-get (cdr spec) :arity)))
             parsed-value)
        (unless parts
          (user-error
           (if (string-prefix-p "-" argument)
               "%s must use canonical long vng options; rejected %S"
             "%s cannot contain positional vng argument %S")
           property argument))
        (unless spec
          (user-error "%s contains unsupported or managed vng option %S"
                      property name))
        (unless (memq scope (plist-get (cdr spec) :scopes))
          (user-error "%s cannot use %s in the %s scope"
                      property name scope))
        (pcase arity
          ((or 'flag 'count)
           (unless (eq attached 'none)
             (user-error "%s option %s does not take a value"
                         property name)))
          ((or 'string 'list)
           (if (eq attached 'none)
               (progn
                 (unless remaining
                   (user-error "%s option %s requires a value" property name))
                 (when (string-prefix-p "-" (car remaining))
                   (user-error
                    "%s option %s needs --option=value for a value beginning with -"
                    property name))
                 (setq parsed-value (pop remaining)))
             (when (string-empty-p attached)
               (user-error "%s option %s requires a non-empty value"
                           property name))
             (setq parsed-value attached)))
          ((or 'optional 'port)
           (if (eq attached 'none)
               (when (and remaining
                          (not (string-prefix-p "-" (car remaining))))
                 (setq parsed-value (pop remaining)))
             (when (string-empty-p attached)
               (user-error "%s option %s has an empty optional value"
                           property name))
             (setq parsed-value attached)))
          (_ (user-error "Kemacs has no parser for vng option %s" name)))
        (when (and (eq arity 'port) parsed-value
                   (not (and (string-match-p "\\`[0-9]+\\'" parsed-value)
                             (<= 1 (string-to-number parsed-value) 65535))))
          (user-error "%s option %s needs a port from 1 through 65535"
                      property name))))
    (when (and (eq scope 'runtime)
               (seq-find
                (lambda (argument)
                  (not (kemacs-vng--upstream-shell-atom-p argument)))
                arguments))
      (let ((argument
             (seq-find
              (lambda (item)
                (not (kemacs-vng--upstream-shell-atom-p item)))
              arguments)))
        (user-error
         (concat "%s contains %S, which is unsafe with vng's internal "
                 "shell command; use separate shell-safe argv atoms")
         property argument)))
    arguments))

(defun kemacs-vng--make-arguments (context)
  "Return validated vng-specific Make assignments from CONTEXT."
  (let ((arguments
         (kemacs-vng--strings (kemacs-context-vng-make-arguments context)
                              ":vng-make-arguments")))
    (dolist (argument arguments)
      (unless (string-match-p "\\`[[:alpha:]_][[:alnum:]_]*=.*\\'" argument)
        (user-error ":vng-make-arguments accepts assignments, got %S"
                    argument))
      (when (kemacs-vng--reserved-option-p argument)
        (user-error ":vng-make-arguments cannot override %S" argument)))
    arguments))

(defun kemacs-vng--native-architecture ()
  "Return the public virtme-ng architecture for this host, or nil."
  (let ((machine (downcase
                  (or (car (split-string system-configuration "-" t)) ""))))
    (cond
     ((member machine '("x86_64" "amd64")) "amd64")
     ((string-match-p "\\`aarch64" machine) "arm64")
     ((string-match-p "\\`armv7" machine) "armhf")
     ((string-match-p "\\`\\(?:powerpc64le\\|ppc64le\\)" machine) "ppc64el")
     ((string-match-p "\\`s390x" machine) "s390x")
     ((string-match-p "\\`riscv64" machine) "riscv64"))))

(defun kemacs-vng--cross-architecture (cross-compile)
  "Infer a public vng architecture from CROSS-COMPILE, or nil."
  (when cross-compile
    (unless (and (stringp cross-compile)
                 (not (string-empty-p cross-compile)))
      (user-error ":cross-compile must be a non-empty string, got %S"
                  cross-compile))
    (let ((compiler (downcase (file-name-nondirectory cross-compile))))
      (cond
       ((string-match-p "\\`\\(?:x86_64\\|amd64\\)[-_]" compiler) "amd64")
       ((string-match-p "\\`\\(?:aarch64\\|arm64\\)[-_]" compiler) "arm64")
       ((string-match-p "\\`arm.*gnueabihf" compiler) "armhf")
       ((string-match-p "\\`\\(?:powerpc64le\\|ppc64le\\)[-_]" compiler)
        "ppc64el")
       ((string-match-p "\\`s390x[-_]" compiler) "s390x")
       ((string-match-p "\\`riscv64[-_]" compiler) "riscv64")))))

(defun kemacs-vng--architecture-compatible-p (kernel-arch vng-arch)
  "Return non-nil when KERNEL-ARCH can describe VNG-ARCH."
  (or (equal (cdr (assoc-string kernel-arch
                                kemacs-vng-architecture-alist))
             vng-arch)
      (member kernel-arch
              (cdr (assoc-string
                    vng-arch
                    '(("amd64" "x86" "x86_64" "amd64")
                      ("arm64" "arm64" "aarch64")
                      ("armhf" "arm" "armhf")
                      ("ppc64el" "powerpc" "ppc64le" "ppc64el")
                      ("s390x" "s390" "s390x")
                      ("riscv64" "riscv" "riscv64")))))))

(defun kemacs-vng-architecture (&optional context)
  "Return the coherent public virtme-ng architecture for CONTEXT, or nil."
  (let* ((context (or context (kemacs-resolve-context)))
         (override (kemacs-context-vng-arch context))
         (kernel-arch (kemacs-context-arch context))
         (cross-compile (kemacs-context-cross-compile context))
         (cross-arch (kemacs-vng--cross-architecture cross-compile))
         (mapped (and kernel-arch
                      (cdr (assoc-string kernel-arch
                                         kemacs-vng-architecture-alist))))
         (native (kemacs-vng--native-architecture))
         (native-match (and (null cross-compile) kernel-arch native
                            (equal kernel-arch (kemacs-native-arch))
                            native))
         (known (delete-dups
                 (append (mapcar #'cdr kemacs-vng-architecture-alist)
                         '("amd64" "arm64" "armhf" "ppc64el"
                           "s390x" "riscv64")))))
    (when override
      (unless (and (stringp override) (member override known))
        (user-error "Unsupported :vng-arch %S; choose one of %s"
                    override (string-join known ", ")))
      (when (and kernel-arch
                 (not (kemacs-vng--architecture-compatible-p
                       kernel-arch override)))
        (user-error ":arch %s is incompatible with :vng-arch %s"
                    kernel-arch override)))
    (when (and cross-arch kernel-arch
               (not (kemacs-vng--architecture-compatible-p
                     kernel-arch cross-arch)))
      (user-error ":cross-compile %s conflicts with :arch %s"
                  cross-compile kernel-arch))
    (when (and override cross-arch (not (equal override cross-arch)))
      (user-error ":cross-compile %s implies %s, not :vng-arch %s"
                  cross-compile cross-arch override))
    (when (and cross-compile (null kernel-arch) (null override)
               (null cross-arch))
      (user-error
       "Cannot infer vng architecture from :cross-compile %s; set :arch or :vng-arch"
       cross-compile))
    (or override cross-arch mapped native-match
        (when kernel-arch
          (user-error
           (concat "ARCH=%s is ambiguous or unsupported by virtme-ng; "
                   "set :vng-arch or a recognizable :cross-compile")
           kernel-arch)))))

(defun kemacs-vng--root-arguments (context architecture)
  "Return validated root arguments for CONTEXT and ARCHITECTURE."
  (let ((root (kemacs-context-vng-root context))
        (native (kemacs-vng--native-architecture)))
    (when root
      (unless (and (file-directory-p root)
                   (file-readable-p root)
                   (file-executable-p root))
        (user-error
         (concat "virtme-ng root %s must already exist and be searchable; "
                 "Kemacs will not trigger its sudo/network root creation")
         root)))
    (when (and root
               (not (kemacs-vng--upstream-shell-atom-p
                     (directory-file-name root))))
      (user-error
       (concat "Virtme-ng root %s is unsafe because upstream reconstructs "
               "its runtime command through a shell")
       root))
    (when (and architecture
               (not (equal architecture native))
               (null root))
      (user-error
       "Virtme-ng architecture %s needs an existing :vng-root on this %s host"
       architecture (or native "unsupported")))
    (when root
      (list "--root" (directory-file-name root)))))

(defun kemacs-vng--architecture-arguments (context &optional build)
  "Return architecture arguments for CONTEXT.

When BUILD is non-nil, also include the cross compiler and job count."
  (let* ((architecture (kemacs-vng-architecture context))
         (cross-compile (kemacs-context-cross-compile context))
         (jobs (kemacs-context-jobs context)))
    (append
     (when architecture (list "--arch" architecture))
     (unless build
       (kemacs-vng--root-arguments context architecture))
     (when (and build cross-compile)
       (list "--cross-compile" cross-compile))
     (when (and build jobs)
       (list "--jobs" (number-to-string jobs))))))

(defun kemacs-vng--append-arguments (context)
  "Return repeated kernel command-line arguments for CONTEXT."
  (cl-mapcan (lambda (argument) (list "--append" argument))
             (kemacs-vng--strings (kemacs-context-vng-append context)
                                  ":vng-append")))

(defun kemacs-vng-command-arguments
    (operation &optional context guest-command allow-missing-output)
  "Return a safe argv list for vng OPERATION in CONTEXT.

OPERATION is one of `build', `run', `debug', `preview', or `exec'.
GUEST-COMMAND is required only for `exec' and is intentionally interpreted
by a shell inside the guest, never by the host shell.  Internal build/run
chains may set ALLOW-MISSING-OUTPUT while validating the future boot before
the build creates its output directory."
  (let* ((context (or context (kemacs-resolve-context)))
         (output (directory-file-name (kemacs-context-output context))))
    (unless (and (stringp output) (file-name-absolute-p output))
      (user-error "Virtme-ng needs an absolute profile output, got %S" output))
    (when (and (not (eq operation 'build))
               (not (kemacs-vng--upstream-shell-atom-p output)))
      (user-error
       (concat "Virtme-ng output %s is unsafe because upstream reconstructs "
               "its runtime command through a shell")
       output))
    (when (and (not (eq operation 'build))
               (not allow-missing-output)
               (not (file-directory-p output)))
      (user-error "No virtme-ng build output exists at %s; build it first"
                  output))
    (pcase operation
      ('build
       (append
        '("--build")
        (kemacs-vng--architecture-arguments context t)
        (kemacs-vng--profile-arguments
         (kemacs-context-vng-build-arguments context)
         ":vng-build-arguments" 'build)
        '("--")
        (list (concat "O=" output))
        (when (eq (kemacs-context-compiler context) 'clang) '("LLVM=1"))
        (kemacs-vng--make-arguments context)))
      ((or 'run 'debug 'preview 'exec)
       (when (eq operation 'exec)
         (unless (and (stringp guest-command)
                      (not (string-empty-p guest-command))
                      (not (string-match-p "[\n\r\0]" guest-command)))
           (user-error "Guest command must be one non-empty line")))
       (let ((common
              (kemacs-vng--profile-arguments
               (kemacs-context-vng-arguments context)
               ":vng-arguments" 'runtime))
             (debug-arguments
              (and (eq operation 'debug)
                   (kemacs-vng--profile-arguments
                    (kemacs-context-vng-debug-arguments context)
                    ":vng-debug-arguments" 'runtime))))
         (append
          (list "--run" output)
          (kemacs-vng--architecture-arguments context)
          common
          debug-arguments
          (kemacs-vng--append-arguments context)
          (pcase operation
            ('debug '("--debug"))
            ('preview '("--dry-run"))
            ('exec (list "--exec" guest-command))))))
      (_ (user-error "Unknown virtme-ng operation: %S" operation)))))

(defun kemacs-vng-command (operation &optional context guest-command)
  "Return a shell-display form for vng OPERATION.

CONTEXT and GUEST-COMMAND are passed to
`kemacs-vng-command-arguments'.  This value is shell quoted for display and
for Emacs's Compilation interface; interactive guests use direct argv."
  (let* ((context (or context (kemacs-resolve-context)))
         (program (or (kemacs-vng-program-path context t)
                      kemacs-vng-program)))
    (kemacs-shell-command
     program (kemacs-vng-command-arguments operation context guest-command))))

(defun kemacs-vng-profile-problem (&optional context operation)
  "Return why CONTEXT cannot perform vng OPERATION, or nil."
  (condition-case error-data
      (let ((context (or context (kemacs-resolve-context))))
        (kemacs-vng-program-path context)
        (kemacs-vng-command-arguments (or operation 'run) context)
        (kemacs-vng--assert-config-safe)
        nil)
    (error (error-message-string error-data))))

(defun kemacs-vng-available-p (&optional operation)
  "Return non-nil when vng OPERATION is ready in the active context."
  (null (kemacs-vng-profile-problem nil (or operation 'run))))

(defun kemacs-vng--matching-options (arguments options)
  "Return members of ARGUMENTS that select any of OPTIONS."
  (seq-filter
   (lambda (argument)
     (seq-some (lambda (option) (kemacs-vng--option-p argument option))
               options))
   arguments))

(defun kemacs-vng--host-sensitive-options (arguments defaults)
  "Return host-sensitive options in ARGUMENTS and validated DEFAULTS."
  (let* ((default-dangerous
          (mapcar #'car
                  (seq-filter
                   (lambda (spec) (plist-get (cdr spec) :dangerous))
                   (kemacs-vng--enabled-default-specs-from defaults)))))
    (delete-dups
     (append
      (kemacs-vng--matching-options arguments kemacs-vng--dangerous-options)
      default-dangerous))))

(defun kemacs-vng--confirm-host-access-with-defaults (arguments defaults)
  "Confirm host-sensitive ARGUMENTS and validated vng DEFAULTS."
  (let ((dangerous (kemacs-vng--host-sensitive-options arguments defaults)))
    (when (and dangerous kemacs-vng-confirm-host-access
               (not (yes-or-no-p
                     (format "Run vng with host-sensitive options %s? "
                             (string-join dangerous ", ")))))
      (user-error "Virtme-ng launch cancelled"))))

(defun kemacs-vng--confirm-host-access (arguments)
  "Confirm dangerous host access represented by ARGUMENTS."
  (kemacs-vng--confirm-host-access-with-defaults
   arguments (or (kemacs-vng--assert-config-safe) nil)))

(defun kemacs-vng--global-runtime-p-with-defaults (arguments defaults)
  "Return non-nil when ARGUMENTS or validated DEFAULTS are global."
  (let* ((explicit-debug
          (not (null (kemacs-vng--matching-options arguments '("--debug")))))
         (explicit-global
          (kemacs-vng--matching-options
           arguments (remove "--debug" kemacs-vng--global-options)))
         (default-global
          (seq-some (lambda (spec) (plist-get (cdr spec) :global))
                    (kemacs-vng--enabled-default-specs-from defaults))))
    (or explicit-global default-global
        (kemacs-vng--default-debug-value-from explicit-debug defaults))))

(defun kemacs-vng--global-runtime-p (arguments)
  "Return non-nil when ARGUMENTS use globally shared vng facilities."
  (kemacs-vng--global-runtime-p-with-defaults
   arguments (or (kemacs-vng--assert-config-safe) nil)))

(defun kemacs-vng--default-entry (defaults destination)
  "Return DESTINATION's validated entry from DEFAULTS, including a nil value."
  (seq-find
   (lambda (entry)
     (eq destination (plist-get (cdr (car entry)) :dest)))
   defaults))

(defun kemacs-vng--argument-port (arguments option)
  "Return the last effective port selected by OPTION in ARGUMENTS.

The public vng console and SSH server options default to port 2222 when
present without a value."
  (let ((remaining (copy-sequence arguments)) port)
    (while remaining
      (let ((argument (pop remaining)))
        (cond
         ((equal argument option)
          (setq port
                (if (and remaining
                         (string-match-p "\\`[0-9]+\\'" (car remaining)))
                    (number-to-string
                     (string-to-number (pop remaining)))
                  "2222")))
         ((string-prefix-p (concat option "=") argument)
          (setq port
                (number-to-string
                 (string-to-number
                  (substring argument (1+ (length option))))))))))
    port))

(defun kemacs-vng--effective-port (arguments defaults option destination)
  "Return OPTION's effective port from ARGUMENTS and DEFAULTS.

DESTINATION is the corresponding upstream argparse destination.  A trusted
default is applied after explicit arguments, matching the public frontend."
  (if-let ((entry (kemacs-vng--default-entry defaults destination)))
      (and (integerp (cdr entry)) (number-to-string (cdr entry)))
    (kemacs-vng--argument-port arguments option)))

(defun kemacs-vng--runtime-resources (arguments defaults debug)
  "Return named host resources used by ARGUMENTS, DEFAULTS, and DEBUG."
  (let (resources)
    (when debug
      (push "tcp-port:1234" resources)
      (push "tcp-port:3636" resources))
    (dolist (description '(("--console" console) ("--ssh" ssh)))
      (when-let ((port
                  (kemacs-vng--effective-port
                   arguments defaults (car description) (cadr description))))
        (push (concat "tcp-port:" port) resources)))
    (delete-dups (nreverse resources))))

(defun kemacs-vng--prepare-runtime
    (operation context &optional guest-command allow-missing-output)
  "Validate and confirm a vng runtime OPERATION for CONTEXT.

GUEST-COMMAND is forwarded to an `exec' operation.  ALLOW-MISSING-OUTPUT is
used only to preflight a boot before its chained build creates the directory.
The returned plan pins argv, context, environment, effective defaults, HOME,
and configuration."
  (let* ((context (copy-kemacs-context context))
         (home (kemacs-vng--home-directory))
         (trust-defaults kemacs-vng-trust-default-options)
         (signature-before (kemacs-vng--config-signature))
         (defaults (or (kemacs-vng--assert-config-safe) nil))
         (signature-after (kemacs-vng--config-signature))
         (program (kemacs-vng-program-path context))
         (arguments
          (kemacs-vng-command-arguments
           operation context guest-command allow-missing-output))
         (explicit-debug
          (not (null (kemacs-vng--matching-options arguments '("--debug")))))
         (debug (kemacs-vng--default-debug-value-from
                 explicit-debug defaults))
         (global (kemacs-vng--global-runtime-p-with-defaults
                  arguments defaults))
         (resources (kemacs-vng--runtime-resources
                     arguments defaults debug)))
    (unless (equal signature-before signature-after)
      (user-error "Virtme-ng configuration changed during preflight; retry"))
    (kemacs-vng--confirm-host-access-with-defaults arguments defaults)
    ;; A confirmation prompt permits recursive editing.  Revalidate every
    ;; external trust input before freezing the launch plan.
    (unless (and (equal signature-after (kemacs-vng--config-signature))
                 (equal defaults
                        (or (kemacs-vng--assert-config-safe) nil))
                 (equal home (kemacs-vng--home-directory))
                 (eq trust-defaults kemacs-vng-trust-default-options))
      (user-error
       "Virtme-ng configuration or HOME changed during confirmation; retry"))
    (kemacs-assert-resource-available (kemacs-context-output context))
    (kemacs-assert-runtime-resources-available resources)
    (when-let ((owner (and global (kemacs-vng--global-process))))
      (user-error "A vng guest already owns global debug/console facilities: %s"
                  (process-name owner)))
    (when (kemacs-vng-processes context)
      (user-error "A vng guest is already running for profile %s"
                  (kemacs-context-profile context)))
    (list :operation operation
          :context context
          :program program
          :arguments (copy-sequence arguments)
          :environment (kemacs-vng--process-environment context)
          :defaults (copy-tree defaults)
          :config-signature signature-after
          :home home
          :trust-defaults trust-defaults
          :debug debug
          :global (and global t)
          :resources (copy-sequence resources))))

(defun kemacs-vng--assert-runtime-plan-current (plan)
  "Reject prepared vng runtime PLAN if its trust inputs have changed."
  (let* ((signature-before (kemacs-vng--config-signature))
         (defaults (or (kemacs-vng--assert-config-safe) nil))
         (signature-after (kemacs-vng--config-signature)))
    (unless (and (equal signature-before signature-after)
                 (equal signature-after (plist-get plan :config-signature))
                 (equal defaults (plist-get plan :defaults))
                 (equal (kemacs-vng--home-directory)
                        (plist-get plan :home))
                 (eq kemacs-vng-trust-default-options
                     (plist-get plan :trust-defaults)))
      (user-error
       "Virtme-ng configuration or HOME changed after confirmation; retry"))))

(defun kemacs-vng--runtime-process-p (process)
  "Return non-nil when PROCESS is a live Kemacs-managed vng guest."
  (and (process-live-p process)
       (eq (process-get process 'kemacs-runtime-kind) 'vng)))

(defun kemacs-vng-processes (&optional context all-profiles)
  "Return live vng guests for CONTEXT.

With ALL-PROFILES non-nil, include every profile in the same worktree."
  (let* ((context (or context (kemacs-resolve-context)))
         (root (kemacs-context-root context))
         (profile (kemacs-context-profile context)))
    (seq-filter
     (lambda (process)
       (and (kemacs-vng--runtime-process-p process)
            (equal root (process-get process 'kemacs-root))
            (or all-profiles
                (equal profile (process-get process 'kemacs-profile)))))
     (process-list))))

(defun kemacs-vng--global-process ()
  "Return a live vng guest owning globally shared facilities, or nil."
  (seq-find
   (lambda (process)
     (and (kemacs-vng--runtime-process-p process)
          (process-get process 'kemacs-vng-global)))
   (process-list)))

(defun kemacs-vng--debug-process (&optional context all-profiles)
  "Return a vng debug guest for CONTEXT, or nil.

ALL-PROFILES has the meaning used by `kemacs-vng-processes'."
  (seq-find (lambda (process) (process-get process 'kemacs-vng-debug))
            (kemacs-vng-processes context all-profiles)))

(define-derived-mode kemacs-vng-mode comint-mode "Kemacs-vng"
  "Major mode for an interactive virtme-ng kernel guest."
  (add-hook 'comint-output-filter-functions
            #'ansi-color-process-output nil t)
  (compilation-shell-minor-mode 1))

(defun kemacs-vng--runtime-buffer-name (context debug)
  "Return the vng runtime buffer name for CONTEXT and DEBUG state."
  (format "*kemacs:%s:%s:%s*"
          (kemacs-root-id (kemacs-context-root context))
          (kemacs-context-profile context)
          (if debug "vng-debug" "vng")))

(defun kemacs-vng--start-runtime
    (operation context &optional guest-command plan no-select)
  "Start vng OPERATION for CONTEXT and optional GUEST-COMMAND.

PLAN, when non-nil, is a synchronously confirmed result from
`kemacs-vng--prepare-runtime'.  With NO-SELECT non-nil, start the guest
without selecting its buffer; this is used by build completion hooks."
  (let* ((plan (or plan
                   (kemacs-vng--prepare-runtime
                    operation context guest-command)))
         (_operation-check
         (unless (eq operation (plist-get plan :operation))
            (error "Prepared vng operation does not match %s" operation)))
         (context (plist-get plan :context))
         (debug (plist-get plan :debug))
         (program (plist-get plan :program))
         (arguments (plist-get plan :arguments))
         (root (kemacs-context-root context))
         (output (kemacs-context-output context))
         (runtime-resources (plist-get plan :resources))
         (global (plist-get plan :global))
         (base-buffer-name (kemacs-vng--runtime-buffer-name context debug))
         (buffer-name (generate-new-buffer-name base-buffer-name))
         (name (substring buffer-name 1 -1))
         (default-directory root)
         buffer process)
    (kemacs-vng--assert-runtime-plan-current plan)
    (unless (file-directory-p output)
      (user-error "No virtme-ng build output exists at %s; build it first"
                  output))
    (kemacs-assert-resource-available output)
    (kemacs-assert-runtime-resources-available runtime-resources)
    (when-let ((owner (and global (kemacs-vng--global-process))))
      (user-error "A vng guest already owns global debug/console facilities: %s"
                  (process-name owner)))
    (when (kemacs-vng-processes context)
      (user-error "A vng guest is already running for profile %s"
                  (kemacs-context-profile context)))
    (setq buffer (get-buffer-create buffer-name))
    (condition-case error-data
        (let ((process-environment
               (copy-sequence (plist-get plan :environment))))
          (with-current-buffer buffer
            (let ((inhibit-read-only t))
              (erase-buffer)))
          (apply #'make-comint-in-buffer name buffer program nil arguments)
          (setq process (get-buffer-process buffer))
          (unless (processp process)
            (error "Vng did not create a process"))
          (with-current-buffer buffer
            (kemacs-vng-mode))
          (kemacs-mark-process-context
           buffer root (kemacs-context-profile context))
          (kemacs-mark-process-resource buffer output)
          (process-put process 'kemacs-runtime-kind 'vng)
          (process-put process 'kemacs-vng-debug debug)
          (process-put process 'kemacs-vng-global global)
          (kemacs-mark-process-runtime-resources process runtime-resources)
          (process-put process 'kemacs-context (copy-kemacs-context context))
          (set-process-query-on-exit-flag process nil)
          buffer)
      (error
       (when (buffer-live-p buffer)
         (when-let ((failed-process
                     (or process (get-buffer-process buffer))))
           (ignore-errors (delete-process failed-process)))
         (kill-buffer buffer))
       (signal (car error-data) (cdr error-data))))
    (if no-select
        (message "vng guest started in %s" (buffer-name buffer))
      (pop-to-buffer buffer))
    buffer))

(defun kemacs-vng--start-managed
    (operation context &optional resource finish-function)
  "Start noninteractive vng OPERATION for CONTEXT and optional RESOURCE.

FINISH-FUNCTION is installed before the Compilation process starts."
  (let* ((program (kemacs-vng-program-path context))
         (arguments (kemacs-vng-command-arguments operation context))
         (process-environment (kemacs-vng--process-environment context)))
    (kemacs-vng--assert-config-safe)
    (kemacs-start-command
     (format "vng-%s" operation) program arguments
     (kemacs-context-root context) nil resource context finish-function)))

;;;###autoload
(defun kemacs-vng-build ()
  "Configure and build the active profile with virtme-ng."
  (interactive)
  (let ((context (kemacs-resolve-context)))
    (kemacs-vng--start-managed
     'build context (kemacs-context-output context))))

;;;###autoload
(defun kemacs-vng-run ()
  "Boot the active profile's existing output with virtme-ng."
  (interactive)
  (kemacs-vng--start-runtime 'run (kemacs-resolve-context)))

;;;###autoload
(defun kemacs-vng-run-command (command)
  "Boot the active profile, run guest shell COMMAND, and exit."
  (interactive
   (list (read-shell-command "Command inside vng guest: " nil
                             'kemacs-vng-command-history)))
  (kemacs-vng--start-runtime 'exec (kemacs-resolve-context) command))

;;;###autoload
(defun kemacs-vng-debug ()
  "Boot the active profile with vng's GDB and QMP endpoints enabled."
  (interactive)
  (kemacs-vng--start-runtime 'debug (kemacs-resolve-context)))

;;;###autoload
(defun kemacs-vng-preview ()
  "Ask vng to print the active profile's resolved boot command.

Upstream dry-run can still prepare modules under the output tree, so this
command participates in the output resource lock."
  (interactive)
  (let ((context (kemacs-resolve-context)))
    (kemacs-vng--start-managed
     'preview context (kemacs-context-output context))))

;;;###autoload
(defun kemacs-vng-build-and-run (&optional debug)
  "Build with virtme-ng and boot after a successful completion.

With prefix argument DEBUG, boot the guest in debug mode.  The original
context snapshot is used even if the selected profile changes meanwhile."
  (interactive "P")
  (let* ((context (copy-kemacs-context (kemacs-resolve-context)))
         (operation (if debug 'debug 'run))
         ;; Validate run-only settings and obtain host-access consent before a
         ;; potentially long build.  The output itself may not exist yet.
         (plan (kemacs-vng--prepare-runtime operation context nil t))
         (done nil)
         finish-function buffer)
    (setq finish-function
          (lambda (finished-buffer _status)
            (unless done
              (setq done t)
              (with-current-buffer finished-buffer
                (remove-hook 'compilation-finish-functions
                             finish-function t))
              (if (kemacs-compilation-succeeded-p finished-buffer)
                  (condition-case error-data
                      (kemacs-vng--start-runtime
                       operation context nil plan t)
                    (error
                     (message "vng build succeeded, but boot failed: %s"
                              (error-message-string error-data))))
                (message "vng build did not succeed; guest was not started")))))
    (setq buffer
          (kemacs-vng--start-managed
           'build context (kemacs-context-output context) finish-function))
    buffer))

;;;###autoload
(defun kemacs-vng-build-and-debug ()
  "Build with virtme-ng and boot a debug guest on success."
  (interactive)
  (kemacs-vng-build-and-run t))

(defun kemacs-vng--read-runtime-process ()
  "Read a live vng process from the current kernel worktree."
  (let* ((processes (kemacs-vng-processes nil t))
         (choices
          (mapcar
           (lambda (process)
             (cons
              (format "%s · %s · %s"
                      (process-get process 'kemacs-profile)
                      (if (process-get process 'kemacs-vng-debug)
                          "debug" "run")
                      (or (process-get process 'kemacs-process-resource) "output"))
              process))
           processes)))
    (unless choices
      (user-error "No vng guest is running in this kernel worktree"))
    (if (= (length choices) 1)
        (cdar choices)
      (cdr (assoc (completing-read "Stop vng guest: " choices nil t)
                  choices)))))

;;;###autoload
(defun kemacs-vng-stop (&optional process)
  "Interrupt vng PROCESS from the current kernel worktree."
  (interactive (list (kemacs-vng--read-runtime-process)))
  (setq process
        (or process (car (kemacs-vng-processes (kemacs-resolve-context)))))
  (unless (and (processp process) (kemacs-vng--runtime-process-p process))
    (user-error "That vng guest is no longer running"))
  (interrupt-process process)
  (message "Interrupted %s" (process-name process)))

(defun kemacs-vng--worktree-debug-process ()
  "Return the vng debug guest in the current worktree, or nil."
  (kemacs-vng--debug-process (kemacs-resolve-context) t))

;;;###autoload
(defun kemacs-vng-gdb-attach ()
  "Attach Emacs GDB/MI to this worktree's managed vng debug guest."
  (interactive)
  (let* ((process (kemacs-vng--worktree-debug-process))
         (context (and process (process-get process 'kemacs-context))))
    (unless (and process context)
      (user-error "Start a vng debug guest in this worktree first"))
    (kemacs-gdb-attach kemacs-vng-gdb-target context)))

;;;###autoload
(defun kemacs-vng-dump (file)
  "Ask this worktree's vng debug guest to write memory dump FILE."
  (interactive (list (read-file-name "Write vng memory dump: ")))
  (let* ((process (kemacs-vng--worktree-debug-process))
         (context (and process (process-get process 'kemacs-context)))
         (file (expand-file-name file))
         (directory (file-name-directory file)))
    (unless context
      (user-error "Start a vng debug guest in this worktree first"))
    (unless (and (file-directory-p directory) (file-writable-p directory))
      (user-error "Memory dump directory is not writable: %s" directory))
    (when (and (file-exists-p file)
               (not (yes-or-no-p (format "Overwrite %s? " file))))
      (user-error "Memory dump cancelled"))
    (let* ((program (kemacs-vng-program-path context))
           (process-environment (kemacs-vng--process-environment context)))
      (kemacs-vng--assert-config-safe)
      (kemacs-start-command
       "vng-dump" program (list "--dump" file)
       (kemacs-context-root context) nil nil context))))

;;;###autoload
(defun kemacs-vng-show-commands ()
  "Display exact build, run, preview, and debug commands for this profile."
  (interactive)
  (let* ((context (kemacs-resolve-context))
         (profile (kemacs-context-profile context))
         (commands
          (mapcar (lambda (operation)
                    (cons operation (kemacs-vng-command operation context)))
                  '(build run preview debug))))
    (with-help-window "*Kemacs vng commands*"
      (princ (format "virtme-ng commands for profile %s\n\n" profile))
      (dolist (entry commands)
        (princ (format "%-8s %s\n" (car entry) (cdr entry))))
      (princ
       (concat "\nGuest commands execute as direct argv; Compilation jobs and "
               "this display use distinct shell-quoted argv tokens.\n"
               "Profile arguments and trusted virtme-ng "
               "default_opts can execute or expose host resources.\n")))))

(kemacs-register-action
 'vng-build "Build with virtme-ng" "Run" #'kemacs-vng-build
 :predicate (lambda () (kemacs-vng-available-p 'build))
 :description "Generate virtme config and build the active output")
(kemacs-register-action
 'vng-build-run "Build, then boot with virtme-ng" "Run"
 #'kemacs-vng-build-and-run
 :predicate (lambda () (kemacs-vng-available-p 'build))
 :description "Boot only after a successful profile-pinned build")
(kemacs-register-action
 'vng-build-debug "Build, then debug with virtme-ng" "Debug"
 #'kemacs-vng-build-and-debug
 :predicate (lambda () (kemacs-vng-available-p 'build))
 :description "Build the pinned profile, then reserve GDB/QMP and boot")
(kemacs-register-action
 'vng-run "Boot with virtme-ng" "Run" #'kemacs-vng-run
 :predicate (lambda () (kemacs-vng-available-p 'run))
 :description "Run the active output in a copy-on-write host snapshot")
(kemacs-register-action
 'vng-exec "Run command in virtme-ng guest" "Run" #'kemacs-vng-run-command
 :predicate (lambda () (kemacs-vng-available-p 'run)))
(kemacs-register-action
 'vng-preview "Preview virtme-ng boot" "Run" #'kemacs-vng-preview
 :predicate (lambda () (kemacs-vng-available-p 'preview))
 :description "Ask vng for its resolved command without launching QEMU")
(kemacs-register-action
 'vng-debug "Boot virtme-ng debug guest" "Debug" #'kemacs-vng-debug
 :predicate (lambda () (kemacs-vng-available-p 'debug))
 :description "Reserve vng's GDB/QMP endpoints and boot with nokaslr")
(kemacs-register-action
 'vng-gdb "Attach GDB to virtme-ng" "Debug" #'kemacs-vng-gdb-attach
 :predicate
 (lambda ()
   (and (kemacs-vng--worktree-debug-process)
        (kemacs-tool-path kemacs-gdb-program)
        (file-readable-p
         (kemacs-vmlinux
          (process-get (kemacs-vng--worktree-debug-process) 'kemacs-context)))))
 :description "Use Emacs GDB/MI with the matching profile vmlinux")
(kemacs-register-action
 'vng-dump "Dump virtme-ng guest memory" "Debug" #'kemacs-vng-dump
 :predicate
 (lambda () (and (kemacs-vng--worktree-debug-process)
                 (kemacs-vng-program-path nil t))))
(kemacs-register-action
 'vng-stop "Stop virtme-ng guest" "Run" #'kemacs-vng-stop
 :predicate (lambda () (kemacs-vng-processes nil t)))
(kemacs-register-action
 'vng-commands "Show exact virtme-ng commands" "Run"
 #'kemacs-vng-show-commands
 :description "Inspect shell-quoted build/run/debug argv without executing")

(provide 'kemacs-virtme)

;;; kemacs-virtme.el ends here
