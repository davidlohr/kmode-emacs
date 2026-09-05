# kmode-emacs

[![CI](https://github.com/davidlohr/kmode-emacs/actions/workflows/ci.yml/badge.svg)](https://github.com/davidlohr/kmode-emacs/actions/workflows/ci.yml)

`kmode-emacs` is a Linux-kernel development environment for Emacs.  It connects one
resolved kernel build profile to Kbuild, navigation, patch checks, tests,
kernel logs, QEMU, virtme-ng, and GDB while keeping the external commands
visible and reproducible.

`kmode-emacs` is pre-1.0.  Its public Lisp commands use the `kmode-` prefix.
This checkout has a top-level project minor mode and
globalized auto-enable mode, but there is not yet a packaged release or stable
compatibility promise.  This README labels future work as **planned**; command
tables describe only code present in the repository.

## Start here

New users should begin with the task-oriented
[getting-started guide](docs/getting-started.md).  It covers kernel-root
recognition, a safe out-of-tree profile, the first build, clangd/Eglot setup,
definition and caller shortcuts, and a first virtme-ng build/run/debug loop.

The shortest first session is:

1. Load `kmode-emacs` and enable `kmode-global-mode`.
2. Open a file below a Linux tree containing `Makefile`, `Kconfig`,
   `MAINTAINERS`, and `scripts/checkpatch.pl`.
3. Select an out-of-tree build profile with `C-c k p`.
4. Run the capability doctor with `C-c k ?`, then open the dashboard with
   `C-c k k`.
5. Build the current object with `C-c k o`; the built-in default profile is a
   native **in-tree** build, so configure `:output` first if that is not what
   you want.

For code navigation, `M-.` / `C-c k n d` finds an implementation, `M-?` /
`C-c k n r` finds references or callers, and `M-,` / `C-c k n b` returns.
Generate the selected profile's compile database and start clangd with
`C-c k n e` for semantic results.

Documentation map:

- [Getting started](docs/getting-started.md) — first build, navigation, and
  virtme-ng workflows.
- [Command and configuration reference](#command-reference) — every public
  command and the profile model.
- [Design and roadmap](docs/design.md) — architecture, invariants, extension
  boundaries, and planned work.
- [Contributing](CONTRIBUTING.md) and [changelog](CHANGELOG.md) — development
  gate and user-visible history.
- [Security policy](SECURITY.md) — private reporting route and the distinction
  between expected tool execution and a trust-boundary bypass.

## Implemented now

- Strict Linux source-root detection and named, per-worktree build profiles.
- Consistent `ARCH`, `CROSS_COMPILE`, compiler, `O=`, job count, and Make
  arguments across build and test commands, insulated from conflicting
  ambient Kbuild selector variables.
- Asynchronous Kbuild commands for the full/default target, an explicit
  target, current object, current directory, configuration, Sparse, cleanup,
  and `compile_commands.json`.
- Optional Kbuild analysis front ends for extra warning levels, Smatch,
  report-only Coccinelle, the kernel Clang analyzer, and checkstack.
- Kernel-aware include, Kconfig, Kbuild, source/header, Documentation, Xref,
  and Eglot/clangd navigation, with a dedicated `C-c k n` shortcut map.
- `checkpatch.pl`, `get_maintainer.pl`, `git range-diff`, patch export, and an
  advisory pre-submission flight check.  Nothing sends mail.
- Opt-in asynchronous Flymake diagnostics for unsaved C, assembly, and Rust
  buffers using checkpatch alongside existing backends such as Eglot.
- Profile-aware KUnit in isolated per-profile build directories and selected
  Kselftest collection runs.
- A read-only staged/range change-impact report with explicitly heuristic,
  clickable build, configuration, check, test, and review suggestions.
- Profile-driven QEMU and GDB startup, local dmesg/file viewing, incident
  navigation, and `decode_stacktrace.sh` integration.
- First-class virtme-ng (`vng`) profile builds, existing-output boots, guest
  commands, dry-run previews, debug guests, GDB attachment, memory dumps, and
  managed stopping through a dedicated `C-c k v` map.
- A completion dispatcher and profile/artifact dashboard backed by one
  extensible action registry, plus a capability doctor and live virtme-ng
  guest status.
- Active-profile and worktree-wide live-process discovery, worktree-wide
  cancellation, and distinct live-job counts in the dashboard.
- A project-scoped minor mode, `C-c k` command map with navigation and
  virtme-ng submaps, Linux C style, synchronized `compile-command`, Emacs
  Project integration, and a Kconfig major mode.
- ERT, byte-compilation, and Checkdoc checks via `make check`.

`kmode-mode` installs only its buffer-local `C-c k` prefix.  The optional
`kmode-global-mode` enables it automatically in recognized kernel-tree
buffers.

## Requirements and graceful degradation

The package requires GNU Emacs 28.1 or newer.  Its Lisp modules depend only on
libraries shipped with Emacs.  External capabilities are independent:

| Capability | Required component | Behavior when absent |
| --- | --- | --- |
| Kernel builds/config/compile DB | `make` and a configured kernel tree | Build actions are unavailable; editing/navigation still work |
| Fast file and Kconfig lookup | `rg` | Kconfig lookup and file discovery use slower Emacs fallbacks where implemented |
| Semantic C navigation | Eglot and `clangd` | Xref/grep/include/Kconfig navigation remains available |
| Review/live checks | executable tree-local `scripts/checkpatch.pl`, `scripts/get_maintainer.pl`, and Git as applicable | Only the affected actions fail or disappear |
| Sparse | `sparse` | `kmode-build-sparse` reports the missing executable |
| Extra warnings | Kbuild | Runs without an extra analyzer executable |
| Smatch | `smatch` | Only the Smatch action is unavailable |
| Coccinelle | `spatch` plus the tree's `coccicheck` script/target | Only Coccinelle reporting is unavailable |
| Clang analyzer | Clang profile, `clang-tidy`, Python, and the tree's helper/target | Only the Clang-analyzer action is unavailable |
| Checkstack | built `vmlinux`, Perl, tree script, and matching `objdump` | Only checkstack is unavailable |
| KUnit | Python and tree-local `tools/testing/kunit/kunit.py` | KUnit actions are unavailable |
| Kselftest | `make` and tree-local `tools/testing/selftests/Makefile` | Kselftest actions are unavailable |
| QEMU | a profile `:qemu-command`, its executable, and readable image/`vmlinux` artifacts referenced by `%i`/`%v` | Boot action is unavailable or reports the missing artifact |
| virtme-ng | `vng`, or its official `virtme-ng` executable alias, plus an operation-appropriate profile (and an existing guest root for non-native runtime) | Only virtme-ng actions are unavailable; custom QEMU, builds, logs, and navigation remain usable |
| GDB | GDB plus Emacs `gdb-mi` and a readable profile `vmlinux` | Attach reports the missing capability; QEMU/log features remain usable |
| Stack decoding | tree-local `scripts/decode_stacktrace.sh` and matching `vmlinux` | Raw log viewing remains usable |
| Local log streaming | configured `kmode-dmesg-command` (defaults to `dmesg`) | Saved log files can still be opened |

Bare executable names are resolved only through Emacs's `exec-path`.  An
absolute name or a name with a directory component is treated as an explicit
path; relative explicit paths resolve from the kernel source root.  Explicit
paths must be executable.  In a kernel context, bare lookup excludes empty,
relative, and checkout-contained search directories so a checkout cannot
shadow a host tool.  Managed build/test/QEMU/vng children receive the same
checkout-filtered `PATH`; `kmode-build-trusted-path-directories` is the
explicit absolute-directory escape hatch for deliberately trusted in-tree
tool shims.

No current command requires Magit, Notmuch, b4, Transient, or Dape.  Those are
possible future adapters, not hidden dependencies.

## Installation

Clone the public repository into a stable directory:

```sh
git clone https://github.com/davidlohr/kmode-emacs.git
```

Add that checkout to `load-path`, load the top-level module, and optionally
enable automatic activation:

```elisp
(add-to-list 'load-path "/path/to/kmode-emacs")
(require 'kmode-emacs)
(kmode-global-mode 1)
```

To opt in one buffer instead, run `M-x kmode-mode` from inside a recognized
kernel tree.  `kmode-mode` applies the built-in Linux style in C buffers,
keeps the buffer-local `compile-command` synchronized by default, and remaps
the standard `compile` command to the profile-owned `kmode-compile`.
Customize `kmode-apply-kernel-c-style` or `kmode-set-compile-command` to
disable styling or synchronization, respectively.  Disabling the mode
restores the local values it changed.

The built-in prefix is:

| Key | Command |
| --- | --- |
| `C-c k k` | `kmode-dashboard` |
| `C-c k SPC` | `kmode-dispatch` |
| `C-c k ?` | `kmode-doctor` |
| `C-c k p` | `kmode-select-profile` |
| `C-c k x` | `kmode-cancel-job` |
| `C-c k b` / `o` | `kmode-build` / `kmode-build-current-object` |
| `C-c k n` | Kernel navigation prefix map |
| `C-c k v` | virtme-ng build/run/debug prefix map |
| `C-c k d` / `c` / `h` | DWIM navigation / find Kconfig / source-header toggle |
| `C-c k r` / `f` | checkpatch current file / toggle live checkpatch diagnostics |
| `C-c k i` / `m` | impact plan / get maintainers |
| `C-c k t` / `s` | filtered KUnit / selected Kselftest |
| `C-c k l` / `q` / `g` | decode log / run QEMU / attach GDB |

The navigation map is:

| Key | Command |
| --- | --- |
| `C-c k n .` | `kmode-navigation-dwim` |
| `C-c k n d` | `kmode-find-definition` |
| `C-c k n r` | `kmode-find-callers` |
| `C-c k n b` | `kmode-navigation-back` |
| `C-c k n i` | `kmode-follow-include` |
| `C-c k n k` | `kmode-find-kbuild` |
| `C-c k n c` | `kmode-find-config` |
| `C-c k n u` | `kmode-grep-config-users` |
| `C-c k n h` | `kmode-toggle-header-source` |
| `C-c k n D` | `kmode-grep-documentation` |
| `C-c k n e` | `kmode-eglot-ensure` |

The virtme-ng map is:

| Key | Command |
| --- | --- |
| `C-c k v b` | `kmode-vng-build` |
| `C-c k v a` | `kmode-vng-build-and-run` |
| `C-c k v A` | `kmode-vng-build-and-debug` |
| `C-c k v r` | `kmode-vng-run` |
| `C-c k v e` | `kmode-vng-run-command` |
| `C-c k v p` | `kmode-vng-preview` |
| `C-c k v d` | `kmode-vng-debug` |
| `C-c k v g` | `kmode-vng-gdb-attach` |
| `C-c k v m` | `kmode-vng-dump` |
| `C-c k v x` | `kmode-vng-stop` |
| `C-c k v s` | `kmode-vng-show-commands` |

Only use process-running features in kernel trees and with profiles you trust.
Tree-local scripts, generated compiler commands, profile Make arguments, test
runners, QEMU command vectors, and virtme-ng profile/default options can all
execute code, expose host resources, or change build/runtime state.

## Profiles

A profile is one coherent interpretation of a kernel checkout.  Its
architecture, configuration/output tree, toolchain, generated headers,
`vmlinux`, boot image, and runtime recipe should agree.  Mixing artifacts from
profiles can produce plausible but wrong diagnostics and stack decoding.

The built-in profile is native and in-tree:

```elisp
("default"
 :description "Native toolchain, in-tree output"
 :compiler auto
 :jobs auto)
```

Here is a build-only cross-profile setup:

```elisp
(setq kmode-profiles
      '(("x86-clang-debug"
         :description "x86-64 debug kernel built with LLVM"
         :arch "x86_64"
         :compiler clang
         :output "../build/linux-x86-clang"
         :jobs auto
         :make-arguments ("W=1")
         :image "arch/x86/boot/bzImage"
         :vmlinux "vmlinux")
        ("arm64-gcc"
         :description "arm64 cross build"
         :arch "arm64"
         :cross-compile "aarch64-linux-gnu-"
         :compiler gcc
         :output "../build/linux-arm64"
         :jobs 12
         :image "arch/arm64/boot/Image"
         :vmlinux "vmlinux")))
```

`compiler` set to `clang` already adds `LLVM=1`; do not duplicate it in
`:make-arguments`.  Select a profile for the current worktree with
`M-x kmode-select-profile`.  The command updates the worktree's session-local
selection and refreshes profile-derived state in all enabled kmode-emacs buffers in
that worktree.  It does not set an explicit buffer-local `kmode-profile`.

Resolution precedence is explicit buffer-local override, the selected
worktree profile, then the package default.  The available overrides are:

- `kmode-profile`
- `kmode-output-directory`
- `kmode-arch`
- `kmode-cross-compile`
- `kmode-compiler`
- `kmode-jobs`
- `kmode-make-arguments`

Only `kmode-compiler` and `kmode-jobs` are declared safe file-local
variables.  The supported profile properties are `:arch`, `:cross-compile`,
`:compiler`, `:output`, `:jobs`, `:make-arguments`, `:image`, `:vmlinux`,
`:qemu-command`, `:gdb-target`, `:vng-arch`, `:vng-root`, `:vng-append`,
`:vng-arguments`, `:vng-debug-arguments`, `:vng-build-arguments`, and
`:vng-make-arguments`.  The examples also carry a human `:description`;
extensions can read it with `kmode-profile-property`, while the current
dashboard's compact profile description is derived from the operational
fields.

### virtme-ng profile example

The upstream project is named **virtme-ng** and its primary frontend is
`vng`; packaging also installs `virtme-ng` as an official executable alias.
There is no upstream `vng-ng` command.  `kmode-vng-program` defaults to
`"vng"` and falls back to the alias only while that default is unchanged.
[Upstream's entry points](https://github.com/arighi/virtme-ng/blob/main/setup.py)
and [README examples](https://github.com/arighi/virtme-ng/blob/main/README.md#examples)
use these names.

This native profile boots an already built output and can also ask vng to
configure/build it:

```elisp
(add-to-list
 'kmode-profiles
 '("x86-vng"
   :description "LLVM x86 kernel for virtme-ng"
   :arch "x86"
   :compiler clang
   :output "../build/linux-x86-vng"
   :jobs 16
   :vmlinux "vmlinux"
   :vng-append ("console=ttyS0" "panic=-1")
   :vng-arguments ("--cpus" "4" "--memory" "2G")
   :vng-debug-arguments ("--force-initramfs")
   :vng-build-arguments ("--skip-modules")
   :vng-make-arguments ("LOCALVERSION=-kmode")))
```

For a non-native guest, give vng its public architecture name and an existing
root directory:

```elisp
(add-to-list
 'kmode-profiles
 '("arm64-vng"
   :description "arm64 cross build and guest"
   :arch "arm64"
   :cross-compile "aarch64-linux-gnu-"
   :compiler gcc
   :output "../build/linux-arm64-vng"
   :jobs 12
   :vmlinux "vmlinux"
   :vng-arch "arm64"
   :vng-root "/opt/chroot/arm64"
   :vng-append ("console=ttyAMA0")))
```

The virtme-ng properties have deliberately separate scopes:

| Property | Meaning |
| --- | --- |
| `:vng-arch` | Explicit public vng architecture: `amd64`, `arm64`, `armhf`, `ppc64el`, `s390x`, or `riscv64`; it must agree with `:arch` and any architecture inferred from `:cross-compile` |
| `:vng-root` | Absolute or source-root-relative runtime guest root; a non-native run/debug/preview/exec requires it to exist and be readable/searchable; a build neither validates nor passes it |
| `:vng-append` | List emitted as repeated `--append VALUE` kernel-command-line arguments |
| `:vng-arguments` | Common vng-level arguments for run, guest-command, preview, and debug operations |
| `:vng-debug-arguments` | Additional vng-level arguments used only by debug boots |
| `:vng-build-arguments` | Additional vng-level arguments placed before `--` for a vng build |
| `:vng-make-arguments` | Make variable assignments placed after vng's managed `-- O=<output>` and optional `LLVM=1` |

kmode-emacs owns the vng action, absolute output, architecture, root, cross
compiler, job count, guest command, and dry-run/debug switches.  Profile
argument lists cannot replace those selectors, and `:vng-make-arguments`
accepts assignments rather than arbitrary Make goals/options.  Ordinary
`:make-arguments` are not forwarded to `kmode-vng-build`; put deliberate vng
build assignments in `:vng-make-arguments`.

The pass-through lists are allowlists, not arbitrary vng argv.  Only exact,
canonical long options are accepted; short flags, short-option clusters,
argparse abbreviations, positionals, unknown future flags, wrong scopes, and
wrong value shapes fail closed.  The build allowlist is `--skip-modules`,
`--config`, `--configitem`, `--verbose`, and `--quiet`.  The runtime allowlist
is `--no-virtme-ng-init`, `--empty-passwords`, `--pin`, `--snaps`,
`--skip-modules`, `--busybox`, `--qemu`, `--name`, `--user`, `--shell`,
`--rw`, `--no-root-posix-acl`, `--force-9p`, `--disable-microvm`,
`--disable-kvm`, `--disable-monitor`, `--cwd`, `--rodir`, `--rwdir`,
`--overlay-rwdir`, `--cpus`, `--memory`, `--numa`, `--numa-distance`,
`--balloon`, `--network`, `--no-dhcp`, `--net-mac-address`, `--disk`,
`--force-initramfs`, `--sound`, `--graphics`, `--fb`, `--verbose`, `--quiet`,
`--qemu-opts`, `--nvgpu`, `--vfio-pci`, `--console`, `--console-client`,
`--ssh`, `--ssh-client`, `--ssh-tcp`, `--remote-cmd`, and `--systemd`.
kmode-emacs owns `--debug` and the other operation/context selectors.

Generic kernel architecture names `x86`, `arm`, `powerpc`, and `riscv` do not
identify the vng word size or byte order.  kmode-emacs accepts an exact native-host
match, an unambiguous `:arch`, a recognized cross-compiler prefix, or explicit
`:vng-arch`, and rejects conflicts among them.  A pure cross build passes
architecture/cross compiler/jobs but deliberately omits `--root`; a
cross-architecture run, debug, preview, or guest command refuses to start
without an existing root, avoiding upstream's network/`sudo` auto-provisioning.
The chained build-and-run/debug commands perform that runtime check before the
build begins.

Profile or validated-default options selecting `--rw`, writable directories
or disks, a custom QEMU, device passthrough, networking, remote console/SSH,
empty passwords, or systemd trigger `yes-or-no-p` by default; customize
`kmode-vng-confirm-host-access` only if the profiles are already trusted.

Upstream configuration is another trust boundary.  The existing directory in
`kmode-vng-home-directory` (default: the user's home) becomes the fixed
`HOME` for every managed vng check and child.  kmode-emacs inspects exactly the
first existing upstream candidate, in order:

1. `<kmode-vng-home-directory>/.config/virtme-ng/virtme-ng.conf`
2. `<kmode-vng-home-directory>/.virtme-ng.conf`
3. `/etc/virtme-ng.conf`

Invalid/unreadable JSON and nonempty untrusted `default_opts` fail closed,
because upstream applies defaults after explicit CLI parsing.  After
`kmode-vng-trust-default-options` is enabled, kmode-emacs still validates each
argparse destination against its typed schema.  Unknown, duplicate, and
kmode-emacs-owned destinations, wrong booleans/counts/lists/strings, out-of-range
ports, and shell-unsafe runtime values remain errors.  Enabled dangerous,
global, and debug defaults participate in confirmation, locking, and effective
debug state.  Trust is therefore an opt-in to inspected, typed defaults, not a
way to bypass validation.

### QEMU/GDB profile example

`%i`, `%v`, `%o`, `%r`, and `%p` inside each QEMU argument expand to the
profile image, `vmlinux`, output directory, source root, and profile name.
Arguments are passed as an argv list, not parsed as a shell fragment.

```elisp
(add-to-list
 'kmode-profiles
 '("x86-qemu"
   :arch "x86_64"
   :compiler clang
   :output "../build/linux-x86-qemu"
   :image "arch/x86/boot/bzImage"
   :vmlinux "vmlinux"
   :qemu-command
   ("qemu-system-x86_64"
    "-machine" "q35" "-m" "2G"
    "-kernel" "%i"
    "-append" "console=ttyS0"
    "-nographic" "-s" "-S")
   :gdb-target ":1234"))
```

This example starts QEMU paused with its conventional TCP gdbstub.  It does
not provide a root filesystem or network and is only a starting point.  kmode-emacs
does not yet generate safe disk overlays or validate the security of a custom
QEMU vector.

## Command reference

All names in this section are implemented in the current checkout.

### Project, UI, and editing

| Command | Purpose |
| --- | --- |
| `kmode-mode` | Enable/disable the buffer-local kernel cockpit, style, prefix, and compile command |
| `kmode-global-mode` | Auto-enable `kmode-mode` in buffers under recognized kernel trees |
| `kmode-dashboard` | Open the worktree flight deck with Git/profile/artifact state and every registered action |
| `kmode-dashboard-refresh` | Refresh the current dashboard (`g` in its buffer) |
| `kmode-dashboard-select-profile` | Select a worktree profile from the dashboard (`p` in its buffer) |
| `kmode-dashboard-doctor` | Run the capability doctor from the dashboard (`d` in its buffer) |
| `kmode-dispatch` | Choose an available action with completion; a prefix includes unavailable actions |
| `kmode-doctor` | Report selected tools and profile artifacts with remediation text |
| `kmode-cancel-job` | Select and interrupt a live kmode-emacs process from any profile in the current worktree |
| `kmode-refresh-project-buffers` | Recompute profile-derived compile commands in enabled buffers of the worktree |
| `kmode-kconfig-mode` | Major mode automatically selected for `Kconfig` and `Kconfig.*` files |
| `kmode-kconfig-follow-source` | Follow the `source`/`rsource` family with root/containing-file bases and `ARCH`/`SRCARCH` expansion |

The dashboard reports timestamps, not freshness: `ready` means an artifact is
readable.  Doctor is a snapshot of selected executables and files, not a build
configuration validator.  `kmode-kconfig-mode` provides font lock,
eight-column `TAB` indentation through `kmode-kconfig-indent-line`, Imenu,
`C-c C-o` source following, and `M-.` Kconfig symbol lookup.  Following rejects
unresolved variables and targets outside the source tree (including symlink
escapes); it deliberately delegates broader configuration semantics to
Kbuild.

### Context and build

| Command | Purpose |
| --- | --- |
| `kmode-select-profile` | Select a named profile for the current worktree/session and refresh its enabled buffers |
| `kmode-clear-caches` | Clear positive and negative kernel-root discoveries |
| `kmode-refresh-compile-command` | Set buffer-local `compile-command` from the active profile |
| `kmode-compile` | Edit and run `compile-command` with profile ownership, sanitized Kbuild environment, and output serialization |
| `kmode-recompile` | Restart a kmode-emacs Compilation job after rechecking its output ownership (`g` in that buffer) |
| `kmode-build` | Build the profile's configured/default kernel target |
| `kmode-build-target` | Prompt for one validated Make target |
| `kmode-build-current-object` | Map current C/assembly/Rust source to its `.o` target and build it |
| `kmode-build-current-file` | Alias-style front end for the current object operation |
| `kmode-build-current-directory` | Build the current source directory target |
| `kmode-build-defconfig` | Run `defconfig` |
| `kmode-build-menuconfig` | Start `menuconfig` in a profile-specific Term buffer |
| `kmode-build-olddefconfig` | Run `olddefconfig` |
| `kmode-build-compile-commands` | Run the kernel's `compile_commands.json` target |
| `kmode-build-sparse` | Run the default target with `C=1` or `C=2` after checking for Sparse |
| `kmode-build-clean` | Run `make clean` after showing and confirming the resolved output directory |

Every Make argv is derived from the same context.  Managed build/test launches
remove ambient architecture, toolchain, output/configuration, compiler, and
Make-control variables that could override that context; intentional
overrides belong in trusted profile arguments.  User-entered Make targets are
deliberately restricted.  Resource-bearing jobs that resolve to the same
canonical output directory cannot overlap.  Generation of
`compile_commands.json` may cause substantial kernel build work, and the
current code does not fingerprint or detect a stale database.

### Static analysis

| Command | Purpose |
| --- | --- |
| `kmode-analyze-warning-build` | Build the current object, or default target, with validated `W=1`/`2`/`3` |
| `kmode-analyze-smatch` | Run the current/default build with `C=1`/`2` and `CHECK=<smatch> -p=kernel` |
| `kmode-analyze-coccinelle-report` | Run `coccicheck MODE=report`, optionally scoped to the current directory or one `.cocci` file |
| `kmode-analyze-clang-analyzer` | Run the kernel's `clang-analyzer` target for a Clang-selected/configured profile |
| `kmode-analyze-checkstack` | Run the kernel's `checkstack` target on built profile artifacts |

All five operations feature-check their relevant Kbuild target/tool before
the expensive job where applicable.  Coccinelle is deliberately fixed to
report mode: it does not request generated patch application.  It can still
run code embedded in a trusted semantic patch, and broad analyzer runs can be
slow/noisy.  Clang analysis can build/generate its compilation database;
checkstack requires a matching built `vmlinux`.

### Navigation

| Command | Purpose |
| --- | --- |
| `kmode-navigation-dwim` | Follow an include; resolve a `CONFIG_` symbol (or a symbol in Kconfig mode); otherwise use Xref |
| `kmode-find-definition` | Ask the active Xref backend for the definition at point |
| `kmode-find-callers` | Ask the active Xref backend for references/call sites |
| `kmode-navigation-back` | Return through Xref's navigation history |
| `kmode-find-config` | Find `config`/`menuconfig` declarations for a symbol |
| `kmode-grep-config-users` | Search common kernel source/data formats for `CONFIG_<symbol>` |
| `kmode-follow-include` | Resolve local, source, architecture, and generated include locations |
| `kmode-toggle-header-source` | Choose a same-basename source/header candidate |
| `kmode-find-kbuild` | Visit the nearest ancestor `Kbuild` or `Makefile` |
| `kmode-grep-documentation` | Search the tree's `Documentation/` |
| `kmode-eglot-ensure` | Start Eglot/clangd with `<profile-output>/compile_commands.json` |

The standard Xref keys remain available: `M-.` finds a definition, `M-?`
finds references/call sites, and `M-,` goes back.  `C-c k n d`, `C-c k n r`,
and `C-c k n b` are explicit kernel-prefix aliases for those same workflows.

Include and source/header commands are path/basename heuristics, not a C
preprocessor or Kbuild dependency analysis.  Source/header results are capped
by `kmode-navigation-file-limit` (24 by default).

When `kmode-stop-eglot-on-profile-change` is non-nil (the default), selecting
a worktree profile shuts down Eglot servers found in file buffers
under that root.  Restart explicitly with `kmode-eglot-ensure`; kmode-emacs does
not silently attach the new profile to an old clangd index.

### Review and patch preparation

| Command | Purpose |
| --- | --- |
| `kmode-checkpatch-file` | Run strict checkpatch on a source file |
| `kmode-checkpatch-range` | Run checkpatch's `--git` mode on a revision/range |
| `kmode-checkpatch-staged` | Check a temporary patch made from the staged diff |
| `kmode-checkpatch-region` | Check selected patch text through a temporary file |
| `kmode-get-maintainers` | Show `get_maintainer.pl` output for a file |
| `kmode-copy-maintainers` | Copy that output as a comma-separated kill-ring entry |
| `kmode-range-diff` | Run colorized `git range-diff` for two ranges |
| `kmode-format-patch` | Export a cover-letter patch series to a directory |
| `kmode-flight-check` | Run `git diff --check` then strict checkpatch for a range |
| `kmode-open-submission-guide` | Open the checkout's `submitting-patches.rst` |
| `kmode-impact-plan` | Show a heuristic action plan for the staged diff; a prefix prompts for a range |
| `kmode-impact-plan-range` | Prompt for and plan an explicit Git revision/range |
| `kmode-impact-refresh` | Recompute the diff and suggestions in the current impact report (`g`) |
| `kmode-checkpatch-flymake-mode` | Toggle asynchronous checkpatch diagnostics for the current unsaved source buffer |

The flight check is advisory and does not build or test.  Patch export writes
files but does not invoke `git send-email` or b4.  There is no mail-send command
in kmode-emacs.

The impact report reads NUL-delimited paths from Git without a shell,
classifies source/header/Kbuild/Kconfig/docs/device-tree/KUnit/Kselftest
changes, and offers capped path-specific plus broader actions.  It does not run
anything until a `[run]` button is activated.  Its targets are filename/path
heuristics, not dependency analysis, Kconfig evaluation, or proof that a test
is relevant.

Live checkpatch is disabled by default.  Its buffer-local mode appends one
backend without removing Eglot or other Flymake backends, snapshots current
buffer text to a temporary file, cancels superseded requests, maps
ERROR/WARNING/CHECK records back to source positions, and cleans its temporary
file/output.  If it enabled Flymake itself, disabling it turns Flymake back
off; otherwise the pre-existing Flymake state is preserved.

### Tests

| Command | Purpose |
| --- | --- |
| `kmode-kunit-run` | Configure, build, and run KUnit via the tree's `kunit.py` |
| `kmode-kunit-run-filter` | Run a prompted suite/test glob |
| `kmode-kunit-run-config` | Run with a selected KUnit config file/directory |
| `kmode-kunit-configure` | Prepare KUnit configuration only |
| `kmode-kunit-build` | Configure and build the KUnit kernel only |
| `kmode-kselftest-run` | Select, build, and run one or more Kselftest collections |
| `kmode-kselftest-run-current` | Run the collection containing the current file |

KUnit receives profile architecture, cross compiler, LLVM choice, Make
arguments, jobs, and an isolated/derived build directory.  By default that
directory is `<profile-output>/.kunit` for the default profile or a
profile-name/hash-suffixed sibling for another profile; it never reuses the
ordinary output directory itself.  Kselftest uses the normal profile Make
argv and the top-level `kselftest` target.  kmode-emacs does not
yet parse KTAP/TAP into a structured test dashboard, impose timeouts, or add a
privilege sandbox; understand the selected tests before running them.

### virtme-ng build, run, and debugging

| Command | Purpose |
| --- | --- |
| `kmode-vng-build` | Ask vng to configure and build the active profile into its absolute output directory |
| `kmode-vng-run` | Boot the active profile's existing output in an interactive `kmode-vng-mode` Comint buffer |
| `kmode-vng-run-command` | Boot that output, run one intentionally guest-shell-interpreted command, and exit |
| `kmode-vng-preview` | Run vng's `--dry-run` command preview without launching QEMU |
| `kmode-vng-debug` | Boot with vng's supported GDB/QMP debug facilities |
| `kmode-vng-build-and-run` | Build, then boot only after success, retaining the original context snapshot; a prefix requests debug |
| `kmode-vng-build-and-debug` | Non-prefix convenience command for the build-then-debug flow |
| `kmode-vng-gdb-attach` | Attach Emacs GDB/MI to the worktree's managed debug guest using its pinned profile context |
| `kmode-vng-dump` | Ask the managed debug guest to write a memory dump, confirming replacement of an existing file |
| `kmode-vng-stop` | Select and interrupt a live vng guest from any profile in the current worktree |
| `kmode-vng-show-commands` | Show shell-quoted build/run/preview/debug commands for inspection or copying; runtime vectors require an existing profile output |

kmode-emacs invokes the public `vng` frontend, not the deprecated underlying
`virtme-*` interfaces.  Builds run with the source root as their working
directory and use `--build -- O=<absolute-output>`; runs explicitly use
`--run <absolute-output>`, avoiding bare `vng -r` (which upstream defines as
the host kernel).  Architecture, cross compiler, jobs, and `LLVM=1` are
derived for builds; runtime operations additionally add the validated guest
root and repeated `--append` values.  Builds never pass `--root`.  Managed vng
processes use the same Kbuild-selector and checkout-`PATH` sanitization as
other profile jobs, pinning `HOME` to `kmode-vng-home-directory`.
[Upstream documents out-of-tree builds and directory runs](https://github.com/arighi/virtme-ng/blob/main/README.md#examples).

Arguments are constructed as lists.  Interactive guests start with direct
process argv and a PTY; Compilation-backed build, preview, and dump jobs quote
each item once at the shared process boundary.  The command entered through
`kmode-vng-run-command` is never evaluated by the host shell, but vng
intentionally passes it to a shell inside the guest.  Because current vng
reconstructs part of its runtime through a host shell, kmode-emacs additionally
rejects unsafe runtime output/root paths and common/debug argument atoms; a
direct Emacs spawn cannot remove that upstream boundary.

Builds, previews, and live guests own the canonical profile-output resource,
so they cannot overlap a kmode-emacs build, custom QEMU, or another consumer of the
same output.  Only one vng guest runs per root/profile.  Debug, pin, SSH, and
console options use a process-global vng runtime lock when selected explicitly
or through a validated trusted default.  Effective debug mode additionally
owns the named `tcp-port:1234` and `tcp-port:3636` resources; effective
`--console` and `--ssh` server ports are also named (port 2222 when the option
omits a value).  Raw QEMU `-s`, `-gdb`, and `-qmp` TCP endpoints use the same
port-resource names, so a managed QEMU/vng collision is rejected even across
kernel roots; recognized QEMU Unix endpoints are named and locked too, with
relative paths resolved from the source root.  The dashboard lists worktree
vng guests as `profile/run` or `profile/debug`, and Doctor reports executable resolution,
profile/root coherence, configuration trust, and optional KVM access.  Guest
discovery, stop, attach, and dashboard status are restricted to the current
kernel root; a global-facility lock can still block a conflicting guest from a
different root because the underlying host endpoint is shared.

`kmode-vng-preview` means “let vng resolve and print its command without
launching QEMU,” not “perform no writes.”  Upstream dry-run initialization can
still prepare modules under the output tree, which is why preview takes the
output lock.  `kmode-vng-show-commands` renders kmode-emacs's generated argv; it
does not flatten validated defaults that upstream later reads from the
fixed-HOME configuration.  On a brand-new out-of-tree profile, run
`kmode-vng-build` first: the display command validates all four vectors, and
the run/preview/debug vectors require the output directory to exist.  The
public debug flow uses `--debug`; upstream exposes GDB on
`localhost:1234`, QMP on `localhost:3636`, and adds `nokaslr`.
[The upstream debug example](https://github.com/arighi/virtme-ng/blob/main/README.md#examples)
and [frontend implementation](https://github.com/arighi/virtme-ng/blob/main/virtme_ng/run.py)
define that behavior.  kmode-emacs does not wait for debugger readiness, change
those public endpoints, or verify the running kernel against `vmlinux` beyond
retaining the launch context and requiring a readable debug image at attach.

Build-and-run/debug preflights the future runtime before starting the build,
including run-only architecture/root validation, host-access consent, program,
output and endpoint availability, fixed `HOME`, configuration digest, typed
defaults, trust setting, argv, environment, and effective debug mode.  That
launch plan and context are frozen.  The finish hook is installed before the
Compilation process starts; only that captured process's successful completion
can boot.  Immediately before spawn kmode-emacs rechecks the output, resource locks,
and config/HOME/trust inputs, refusing changed state.  An automatic post-build
guest opens in its buffer without selecting it, so a long build finishing does
not steal editor focus.

Neither `vng` nor its `virtme-ng` alias is installed in the development
environment used for this implementation, so no actual vng kernel build,
guest boot, GDB attachment, or dump was run here.  Real virtualization remains
an explicit integration smoke test; the absence of vng does not affect the
other kmode-emacs workflows.

### Runtime, logs, and debugging

| Command | Purpose |
| --- | --- |
| `kmode-qemu-run` | Start the active profile's expanded QEMU argv in a Comint buffer |
| `kmode-qemu-stop` | Send an interrupt to that profile's live QEMU process |
| `kmode-gdb-attach` | Open Emacs GDB on the profile `vmlinux` and attach to its remote target |
| `kmode-dmesg-follow` | Stream the configured local kernel-log command |
| `kmode-open-kernel-log` | Visit a saved file in `kmode-log-mode` |
| `kmode-decode-stacktrace-region` | Feed selected text to the tree's decode script |
| `kmode-decode-stacktrace-buffer` | Decode the whole current buffer |
| `kmode-log-next-incident` / `kmode-log-previous-incident` | Navigate common kernel incident markers |

`kmode-log-mode` binds `n`/`p` for incidents and `d` to decode the buffer.
QEMU launch verifies that any image or `vmlinux` referenced through `%i` or
`%v` is readable before starting the process.  It also recognizes `-s` and
explicit `-gdb`/`-qmp` TCP or Unix endpoints and reserves named resources;
TCP resources are keyed by port so spelling the bind address differently does
not evade collision detection, and relative Unix paths resolve from the source
root.

Current decoding trusts the selected profile; it checks for a readable
`vmlinux` but does not verify its release/build identity against the log.

## Extension API

The pre-1.0 cooperating-module surface is:

- `kmode-context-functions` to refine a newly resolved context and
  `kmode-profile-changed-hook` to react after a worktree selection changes;
- the `kmode-context-*` accessors and `kmode-resolve-context`;
- `kmode-register-action`, `kmode-actions`, and
  `kmode-action-available-p` for discoverable capabilities;
- `kmode-root`, `kmode-tool-path`, `kmode-require-tool`, and
  `kmode-file-in-root` for project/tool validation;
- `kmode-root-id`, `kmode-running-processes` (active profile by default or
  all worktree profiles on request), and `kmode-cancel-job` for
  collision-resistant display/process ownership;
- `kmode-start-command`, `kmode-start-shell-command`, and
  `kmode-shell-command` for visible asynchronous command output with optional
  canonical-resource ownership; and
- `kmode-vng-command-arguments`/`kmode-vng-command` for validated vng argv
  and display text, `kmode-vng-profile-problem` for capability explanations,
  and `kmode-vng-processes` for managed guest discovery.

Example:

```elisp
(defun my-kmode-ci-context (context)
  (when (string= (kmode-context-profile context) "ci")
    (setf (kmode-context-jobs context) 4))
  context)

(add-hook 'kmode-context-functions #'my-kmode-ci-context)

(defun my-kmode-smoke ()
  (interactive)
  (let ((context (kmode-resolve-context)))
    (kmode-start-command
     "smoke" (kmode-require-tool "make" context)
     (kmode-build-make-arguments
      context '("drivers/base/") '("W=1"))
     (kmode-context-root context))))

(kmode-register-action
 'my-kmode-smoke "Build drivers/base with W=1" "Check"
 #'my-kmode-smoke
 :predicate (lambda () (kmode-tool-path "make")))
```

Context hooks must be fast and noninteractive because availability checks can
resolve contexts repeatedly.  Action predicates are presentation hints, not
authorization boundaries; commands must validate again when invoked.  Prefer
the public accessors over the printed representation of either struct.

See [the design guide](docs/design.md) for architecture, exact semantics,
extension boundaries, and design constraints.

## Safety model

- Compilation/process buffers include the source-root ID (basename plus short
  path hash), profile, and operation so same-named worktrees/profiles do not
  silently share output.  Compilation commands display their exact command,
  and managed jobs sharing a canonical build directory are serialized.
- Managed build, KUnit, Kselftest, raw-QEMU, and vng processes remove ambient
  Kbuild selector variables and untrusted checkout-contained `PATH` entries before
  launch.  `kmode-build-trusted-path-directories` explicitly permits chosen
  absolute directories.  `kmode-compile` remains an editable shell command,
  so inspect it and trust any deliberate custom text before execution.
- User-entered Make targets, Kselftest collection names, and Git
  revisions/ranges are validated; trusted profile arguments remain powerful
  by design.
- Coccinelle UI uses `MODE=report` only and validates optional scope/semantic
  patch paths, but users must still trust the selected tree and `.cocci` file.
- `kmode-build-clean` confirms the resolved output path.  Patch export asks
  before writing outside the source tree.
- Patch checking may create temporary files; staged/region patch files are
  deleted on launch/write failure or process exit, with buffer kill as a
  fallback.
- Live checkpatch is explicit opt-in, uses direct argv, cancels stale
  subprocesses, and cleans snapshots.  Once enabled, normal Flymake triggers
  execute the checkout's checkpatch script, so the checkout must be trusted.
- QEMU is exactly the user-provided argv.  Current code does not create
  snapshots, protect disk images, allocate endpoints, or provide QMP lifecycle
  management.  It holds the profile output while live and reserves recognized
  `-s`/`-gdb`/`-qmp` TCP-port or Unix-socket names against other managed
  runtimes.
- virtme-ng operations pin the resolved context, construct managed selectors
  as argv, sanitize ambient Kbuild variables, and hold the canonical output
  during build/preview/runtime use.  Non-native guests require an existing
  readable/searchable `:vng-root`; kmode-emacs will not trigger vng's missing-root
  network/`sudo` provisioning.  Reserved profile arguments cannot replace
  the operation, output, architecture, root, toolchain, jobs, or guest command.
- Host-sensitive explicit or enabled-default vng options prompt by default.
  This is a review boundary, not a sandbox: profile arguments execute with the
  user's access.  Nonempty defaults are rejected until
  `kmode-vng-trust-default-options` is enabled after review, then still undergo
  destination, type, range, and shell-safety validation; their classified
  dangerous/global/debug effects drive confirmation and resource ownership.
- vng dry-run does not launch QEMU but can still initialize state or prepare
  modules, so preview is serialized on the output and is not advertised as
  side-effect-free.  Shared debug/console facilities are globally serialized.
- GDB and stack decoding use the active profile's `vmlinux`; current code does
  not prove that it matches the running/logged kernel.  vng attachment instead
  uses the debug process's pinned launch context, but still cannot prove build
  identity.
- `dmesg`, Kselftest, and custom test/runtime recipes may need privilege or
  have machine-specific side effects.  kmode-emacs does not itself invoke `sudo` or
  escalate privileges; a trusted external recipe or trusted vng defaults can
  still invoke tools with the user's authority.
- kmode-emacs never installs tools, edits Git history, applies patches, or sends
  email in the current implementation.

## Roadmap

The next high-impact work is:

1. Turn the existing flight deck into a durable job/result cockpit with clearer
   unavailable-capability explanations and action-specific help.
2. Add durable build job history/state, config and artifact fingerprints,
   compile-DB freshness, safe clangd reconnect, and richer diagnostics.
3. Add structured check/KTAP/TAP results and evolve the existing heuristic
   impact plan toward provenance-aware dependency/build/test planning.
4. b4-backed review worktrees, attestation/revision/trailer flows, validation
   manifests, and separately confirmed mail preview/send.
5. Unify custom-QEMU and virtme-ng run identity, add managed
   serial/QMP/gdbstub sockets where the frontend permits, protect disk images,
   verify crash symbolication, and load kernel GDB helpers.
6. Reproducible cross-profile validation, bisect, dynamic-debug, and ftrace
   workflows with explicit privileged-operation previews.

The design and acceptance criteria live in [docs/design.md](docs/design.md).

## Upstream foundations

kmode-emacs deliberately wraps upstream interfaces:

- [Linux Kbuild variables](https://docs.kernel.org/kbuild/kbuild.html)
- [Linux coding style and Emacs setup](https://docs.kernel.org/process/coding-style.html)
- [GNU Emacs Compilation mode](https://www.gnu.org/software/emacs/manual/html_node/emacs/Compilation.html), [Xref](https://www.gnu.org/software/emacs/manual/html_node/emacs/Xref.html), [Eglot](https://www.gnu.org/software/emacs/manual/html_node/eglot/), and [GDB UI](https://www.gnu.org/software/emacs/manual/html_node/emacs/GDB-Graphical-Interface.html)
- [GNU Flymake backend interface](https://www.gnu.org/software/emacs/manual/html_node/flymake/Backend-functions.html)
- [clangd compile-command model](https://clangd.llvm.org/design/compile-commands)
- [Kernel checkpatch](https://docs.kernel.org/dev-tools/checkpatch.html) and [submitting patches](https://docs.kernel.org/process/submitting-patches.html)
- [Sparse](https://docs.kernel.org/dev-tools/sparse.html), [Coccinelle](https://docs.kernel.org/dev-tools/coccinelle.html), and the [kernel submission checklist](https://www.kernel.org/doc/html/latest/process/submit-checklist.html)
- [KUnit](https://docs.kernel.org/dev-tools/kunit/) and [Kselftest](https://docs.kernel.org/dev-tools/kselftest.html)
- [Kernel bug hunting](https://docs.kernel.org/admin-guide/bug-hunting.html)
- [QEMU system debugging](https://www.qemu.org/docs/master/system/gdb.html)
- [virtme-ng README and workflows](https://github.com/arighi/virtme-ng/blob/main/README.md)
- [virtme-ng public `vng` parser](https://github.com/arighi/virtme-ng/blob/main/virtme_ng/run.py)
- [b4 documentation](https://b4.docs.kernel.org/en/latest/) for the planned patch-series layer

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md).  User-visible changes should update
[CHANGELOG.md](CHANGELOG.md), and roadmap behavior must not be described as
implemented.

No license file is present in this checkout.  Do not assume a license until
the project records one explicitly.
