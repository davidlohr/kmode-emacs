# kmode-emacs design

This document records both the architecture present in the source tree and the
intended architecture for later milestones.  Labels are strict:

- **Implemented** means the behavior exists in this checkout.
- **Planned** means design work only; it is not available to users yet.
- **Optional integration** means kmode-emacs should remain useful when that package
  or executable is missing.

kmode-emacs is pre-1.0.  Extension interfaces are documented so that the internal
boundaries are reviewable, but compatibility is not yet guaranteed.

## Product goal

The unit of work in kernel development is not just a file.  It is a source
revision interpreted under one architecture, Kconfig, compiler, output tree,
and runtime target.  kmode-emacs therefore treats a **profile-resolved kernel
context** as the unit behind navigation, builds, checks, tests, review,
symbolication, boot, and debugging.

The desired loop is:

```text
edit -> build/check -> boot/test -> capture/decode -> navigate/debug -> patch/review
          ^                                                        |
          +---------------- reproducible profile ------------------+
```

The editor should shorten that loop while preserving the exact external
commands, artifacts, and human decisions involved.

## Scope and non-goals

kmode-emacs is an umbrella environment.  It adds a project-aware minor mode and
purpose-built views; it should not replace `c-mode`, `c-ts-mode`, Xref,
Eglot, Compilation mode, GDB, Magit, Notmuch, b4, Kbuild, or the kernel's own
scripts.

It covers kernel C, assembly, Rust, Kconfig, Kbuild Makefiles, device tree,
YAML bindings, and Documentation where the underlying Emacs modes support
them.  It does not attempt to parse or compile the Linux kernel in Emacs Lisp.

Remote development, hardware deployment, multi-VM test networks, perf data,
and record/replay are worthwhile later capabilities, but they must not distort
the local build-and-debug foundation.

## Architecture present today

### Core contexts

**Implemented in `kmode-core.el`.**

`kmode-context` is a `cl-defstruct` with these slots:

| Slot | Meaning |
| --- | --- |
| `root` | Expanded source-tree directory, with trailing slash |
| `profile` | Selected profile name |
| `output` | Build output directory; defaults to the source root |
| `arch` | Kbuild `ARCH`, or nil for the native/default architecture |
| `cross-compile` | Kbuild `CROSS_COMPILE` prefix |
| `compiler` | `auto`, `gcc`, or `clang` |
| `jobs` | Positive parallel job count, or nil |
| `make-arguments` | Additional arguments retained for build commands |
| `image` | Boot-image path consumed by the debug/runtime module |
| `vmlinux` | Debug-image path consumed by GDB and stack decoding |
| `qemu-command` | QEMU argv consumed by the runtime module |
| `gdb-target` | Remote target consumed by the GDB command |
| `vng-arch` | Optional public virtme-ng architecture override |
| `vng-root` | Optional, expanded guest-root directory for virtme-ng |
| `vng-append` | Repeated kernel-command-line values for vng |
| `vng-arguments` | Common vng-level runtime arguments |
| `vng-debug-arguments` | Additional vng-level debug arguments |
| `vng-build-arguments` | Additional vng-level build arguments before `--` |
| `vng-make-arguments` | Make assignments after vng's managed `-- O=` boundary |

The resolver precedence is:

1. buffer-local operation overrides;
2. properties in the selected named profile;
3. package defaults.

Profile selection itself is an explicit buffer-local `kmode-profile`, then
the session-local selection stored for the root, then
`kmode-default-profile`.  `kmode-select-profile` updates the root's session
choice, refreshes `compile-command`, and runs `kmode-profile-changed-hook`; it
does not set `kmode-profile` in the selecting buffer.  The top-level module's
hook refreshes every enabled kmode-emacs buffer in the same worktree.  Selections
are not persisted across Emacs sessions.

Relative `:output` values are expanded against the source root.  The runtime
module interprets a relative `:image` and `:vmlinux` against the resolved
output tree.  It expands `%i`, `%v`, `%o`, `%r`, and `%p` independently in each
`:qemu-command` string and uses `:gdb-target` as the operand of GDB's
`target remote`.  A relative `:vng-root` is expanded against the source root;
the other vng lists are copied into the context and validated by
`kmode-virtme.el`.  Core itself does not interpret their argv semantics.

`kmode-root-markers` defaults to all four of:

```text
Makefile
Kconfig
MAINTAINERS
scripts/checkpatch.pl
```

A directory is considered a kernel root only when every marker exists.
Discovery results, including misses, are cached by starting directory.
`kmode-clear-caches` invalidates that cache.

### External process plumbing

**Implemented in `kmode-core.el`.**

`kmode-start-command` constructs a shell-quoted command and starts it through
`compilation-start`.  `kmode-root-id` combines the root basename with the
first six hex digits of a hash of its absolute path; buffers are named
`*kmode:<root-id>:<profile>:<label>*`.  `kmode-compilation-mode`:

- inherits Compilation mode;
- binds `g` to `recompile`;
- applies ANSI colors through a buffer-local compilation filter;
- prepends a terse checkpatch location matcher to the buffer-local error
  regexp list; and
- honors `kmode-compilation-scroll-output`.

`kmode-running-processes` filters Emacs's live process list by process
ownership metadata or the root-ID/profile buffer prefix.  It returns only the
active profile by default and every profile in the same worktree when its
`all-profiles` argument is non-nil.  `kmode-cancel-job` completion exposes the
worktree-wide view, rechecks liveness, and sends an interrupt.

Callers may assign a canonical build-directory resource to a process.  A new
resource-bearing job is rejected while another live kmode-emacs process owns that
directory, including when two profiles resolve to the same output.  This
ownership also survives `kmode-recompile`.  The process layer does not keep
finished-job history or distinguish a graceful cancellation protocol from an
ordinary interrupt.

Processes can also own arbitrary named runtime resources.  The current
runtime modules use canonical `tcp-port:<port>` and `unix-socket:<absolute>`
names to reject endpoint collisions across profiles and worktrees within this
Emacs process.

Build, review, test, and debug modules use this plumbing for commands whose
output benefits from Compilation mode.  QEMU and interactive virtme-ng guests
use Comint processes directly; vng build, preview, and dump operations use the
shared Compilation path.  Both QEMU and vng guests hold the canonical profile
output while live, and Emacs's GDB interface owns the debugger process.

`kmode-tool-path` resolves a bare executable name only through `exec-path`.
In a kernel context it removes empty, relative, and source-tree-contained
search entries before lookup, preventing an ambient `.` or checkout directory
from shadowing host tools.  An absolute name or a name with a directory
component is an explicit path; a relative explicit path is resolved against
the kernel source root.  Explicit paths must be executable.
`kmode-require-tool` converts a miss into an actionable `user-error`.
Consequently, checked-out helper scripts used directly by current modules must
have their executable bit set.

`kmode-build-process-environment` also strips ambient Kbuild selectors and,
when given a context, empty/relative/checkout-contained child `PATH` entries.
`kmode-build-trusted-path-directories` accepts absolute directories as an
explicit escape hatch for trusted in-tree shims needed by Make, raw QEMU, or
vng children; it does not change bare `kmode-tool-path` lookup.  Dashboard
Git probes, Doctor tool checks, and dmesg availability use the same
checkout-safe executable lookup.

### Project mode and editing policy

**Implemented in `kmode-emacs.el`.**

The top-level module loads every current feature module and defines the
buffer-local `kmode-mode`.  Enabling it first requires a recognized kernel
root, adds the `C-c k` command map/menu (including `C-c k x` cancellation and
`C-c k f` live-checkpatch toggling), dedicated `C-c k n` navigation and
`C-c k v` virtme-ng maps, and a profile mode-line indicator.  By default it
derives a buffer-local `compile-command` from the active profile.  It remaps
the standard `compile` command to `kmode-compile`, which preserves
profile/process ownership for an edited command.  In
`c-mode` it applies CC Mode's `linux` style with eight-column tabs; in
`c-ts-mode` it applies the available eight-column indentation setting.  Values
changed by the mode are saved and restored on disable.  The two behaviors can
be disabled independently with `kmode-apply-kernel-c-style` and
`kmode-set-compile-command`.

`kmode-global-mode` is a globalized minor mode whose activation function
enables the local mode only when `kmode-root` succeeds.  The package also
adds a project finder which returns a `(kmode . ROOT)` project for recognized
trees, so Emacs Project commands use the kernel source root.  This finder and
Kconfig's auto-mode association are global registrations; buffer styling,
bindings, and compilation state remain local.

The two nested maps are implemented as follows:

| Navigation key | Command | virtme-ng key | Command |
| --- | --- | --- | --- |
| `C-c k n .` | `kmode-navigation-dwim` | `C-c k v b` | `kmode-vng-build` |
| `C-c k n d` | `kmode-find-definition` | `C-c k v a` | `kmode-vng-build-and-run` |
| `C-c k n r` | `kmode-find-callers` | `C-c k v A` | `kmode-vng-build-and-debug` |
| `C-c k n b` | `kmode-navigation-back` | `C-c k v r` | `kmode-vng-run` |
| `C-c k n i` | `kmode-follow-include` | `C-c k v e` | `kmode-vng-run-command` |
| `C-c k n k` | `kmode-find-kbuild` | `C-c k v p` | `kmode-vng-preview` |
| `C-c k n c` | `kmode-find-config` | `C-c k v d` | `kmode-vng-debug` |
| `C-c k n u` | `kmode-grep-config-users` | `C-c k v g` | `kmode-vng-gdb-attach` |
| `C-c k n h` | `kmode-toggle-header-source` | `C-c k v m` | `kmode-vng-dump` |
| `C-c k n D` | `kmode-grep-documentation` | `C-c k v x` | `kmode-vng-stop` |
| `C-c k n e` | `kmode-eglot-ensure` | `C-c k v s` | `kmode-vng-show-commands` |

### Dispatcher, dashboard, and doctor

**Implemented in `kmode-ui.el`.**

`kmode-dispatch` uses `completing-read` over the action registry.  Normally it
omits unavailable actions; a prefix argument includes them, but selection
still rechecks the predicate and refuses invocation.  It has no Transient or
third-party completion dependency.

The read-only flight deck has one buffer per `kmode-root-id` and remembers the
origin buffer so action availability/invocation keeps its buffer context.  It
shows source root, Git branch/dirty state, profile
description, output tree, and readability/mtime for `.config`,
`compile_commands.json`, and `vmlinux`, plus active-profile and worktree-wide
live-process counts when they differ.
It also lists live vng guests across the worktree as profile plus run/debug
state.  It then renders every registered action by group: available actions
are buttons and unavailable actions are dimmed.  `g`, `p`, and `d` refresh,
select a profile, and open doctor.  Artifact age is informational; the
dashboard does not currently fingerprint or prove freshness.

`kmode-doctor` reports a fixed initial set of executable/tree-tool checks
(Make, Git, ripgrep, clangd, Sparse, Coccinelle, GDB, b4, checkpatch, and
get_maintainer), the three profile artifacts above, vng/official-alias
resolution, vng profile/root coherence, the `default_opts` trust state, and
optional KVM access.  It offers remediation text but does not install
anything, start a vng build/guest, query every module-specific capability, run
compatibility tests, or validate kernel configuration options.  Executable
vng discovery does issue its read-only `--version` probe.

### Kconfig editing

**Implemented in `kmode-kconfig.el`.**

`kmode-kconfig-mode` is automatically associated with `Kconfig` and
`Kconfig.*`.  It supplies syntax/font lock, symbol/menu Imenu entries,
eight-column block/property/help indentation, `M-.` Kconfig-symbol lookup, and
`C-c C-o` source following.  Source following recognizes the
`source`/`osource` and `rsource`/`orsource` variants.  The first pair resolves
from the source root; the relative pair resolves from the containing Kconfig
file.  `ARCH` and `SRCARCH` forms are expanded distinctly from the profile,
with native architecture inference and the kernel's common source-directory
aliases when needed, and supported `srctree` prefixes are removed.  Unresolved
variables, unreadable targets, and paths outside the source tree are rejected;
the containment check also follows symlinks.  The implementation does not
evaluate general Kconfig variables, conditions, globbing, or symbol dependency
semantics.

### Action registry

**Implemented in `kmode-core.el` and consumed by `kmode-ui.el`.**

An action has an ID, title, group, interactive command, optional availability
predicate, and optional description.  Registering an existing ID replaces it.
`kmode-actions` returns a group/title-sorted copy and normally removes actions
whose predicates fail.  Predicate errors are treated as unavailable rather
than breaking the dispatcher or dashboard.

The current modules register the following action IDs.  Some interactive
commands intentionally have no action entry yet.

| ID | Group/title |
| --- | --- |
| `dashboard` | Project / Open kernel flight deck |
| `doctor` | Project / Inspect tools and artifacts |
| `select-profile` | Project / Switch build profile |
| `cancel-job` | Project / Interrupt a running job |
| `navigate-dwim` | Navigate / Definition/include/config at point |
| `find-definition` | Navigate / Find definition |
| `find-callers` | Navigate / Find references / callers |
| `find-config` | Navigate / Find Kconfig symbol |
| `grep-config` | Navigate / Find CONFIG users |
| `toggle-source` | Navigate / Toggle source/header |
| `find-kbuild` | Navigate / Find owning Kbuild |
| `docs` | Navigate / Search Documentation/ |
| `eglot` | Navigate / Start profile-aware clangd |
| `kmode-build` | Build / Build kernel |
| `kmode-compile` | Build / Compile edited command... |
| `kmode-build-target` | Build / Build target... |
| `kmode-build-current-file` | Build / Build current object |
| `kmode-build-current-directory` | Build / Build current directory |
| `kmode-build-compile-commands` | Build / Generate compile database |
| `kmode-build-clean` | Build / Clean build output |
| `kmode-build-sparse` | Check / Run sparse |
| `kmode-analyze-warning-build` | Check / Build with extra warnings |
| `kmode-analyze-smatch` | Check / Run Smatch |
| `kmode-analyze-coccinelle` | Check / Run Coccinelle report |
| `kmode-analyze-clang` | Check / Run Clang analyzer |
| `kmode-analyze-checkstack` | Check / Run checkstack |
| `checkpatch-flymake` | Check / Toggle live checkpatch |
| `kmode-build-defconfig` | Configure / Generate defconfig |
| `kmode-build-menuconfig` | Configure / Open menuconfig |
| `kmode-build-olddefconfig` | Configure / Run olddefconfig |
| `checkpatch-file` | Review / Checkpatch current file |
| `checkpatch-staged` | Review / Checkpatch staged diff |
| `checkpatch-range` | Review / Checkpatch commit/range |
| `maintainers` | Review / Show maintainers for file |
| `flight-check` | Review / Pre-submission flight check |
| `range-diff` | Review / Compare patch series |
| `format-patch` | Review / Export patch series |
| `submission-guide` | Review / Open submission guide |
| `kmode-impact-plan` | Review / Plan staged change impact |
| `kmode-kunit-run` | Test / Run KUnit |
| `kmode-kunit-run-filter` | Test / Run filtered KUnit... |
| `kmode-kunit-run-config` | Test / Run KUnit config... |
| `kmode-kunit-build` | Test / Build KUnit kernel |
| `kmode-kselftest-run` | Test / Run Kselftest subset... |
| `kmode-kselftest-run-current` | Test / Run current Kselftest collection |
| `decode-log` | Debug / Decode stacktrace buffer |
| `dmesg` | Debug / Follow local dmesg |
| `qemu` | Debug / Boot active QEMU profile |
| `gdb` | Debug / Attach GDB to kernel |
| `vng-build` | Run / Build with virtme-ng |
| `vng-build-run` | Run / Build, then boot with virtme-ng |
| `vng-build-debug` | Debug / Build, then boot for debugging with virtme-ng |
| `vng-run` | Run / Boot with virtme-ng |
| `vng-exec` | Run / Run command in virtme-ng guest |
| `vng-preview` | Run / Preview virtme-ng boot |
| `vng-stop` | Run / Stop virtme-ng guest |
| `vng-commands` | Run / Show exact virtme-ng commands |
| `vng-debug` | Debug / Boot virtme-ng debug guest |
| `vng-gdb` | Debug / Attach GDB to virtme-ng |
| `vng-dump` | Debug / Dump virtme-ng guest memory |

The Eglot action predicate requires both an Eglot library and a discoverable
`clangd` executable.

### Kernel-aware navigation

**Implemented in `kmode-navigate.el`.**

`kmode-navigation-dwim` chooses an operation in this order:

1. follow an include found on the current line;
2. find a Kconfig definition for a `CONFIG_FOO` symbol, or for a normalized
   uppercase symbol when the buffer uses `kmode-kconfig-mode`; if that fails,
   ask Xref for a definition;
3. otherwise ask Xref for a definition.

kmode-emacs does not replace Xref's standard navigation keys: `M-.` finds a
definition, `M-?` finds references/call sites, and `M-,` returns through Xref
history.  `C-c k n d`, `C-c k n r`, and `C-c k n b` expose the same operations
inside the dedicated kernel prefix.

Kconfig definition lookup uses ripgrep when available.  Its fallback scans
`Kconfig*` files and looks for `config` and `menuconfig` declarations.  The
fallback is synchronous and can be expensive in a large or remote tree.

Include lookup checks, in order, the current file's directory, source root,
source `include/`, profile architecture `arch/<arch>/include/`, output
`include/generated/`, and output `arch/<arch>/include/generated/`.  It offers a
choice when multiple existing regular files match.  This is a path heuristic;
it does not evaluate preprocessor include paths.

Source/header toggling searches tracked/visible files reported by `rg --files`
when possible and falls back to recursive source-file enumeration.  It matches
basenames, not semantic declarations or Kbuild ownership, and truncates the
candidate list to `kmode-navigation-file-limit`.

`kmode-find-kbuild` walks ancestors inside the kernel tree and chooses the
first existing `Kbuild` or `Makefile`.  It finds the nearest build description;
it does not prove that the current file is named by that file.

`kmode-eglot-ensure` requires a readable
`<resolved-output>/compile_commands.json`, adds a buffer-local Eglot server
entry for the current major mode, passes clangd the resolved
`--compile-commands-dir`, and calls `eglot-ensure`.  It does not generate or
validate the database, detect staleness, or manage Rust Analyzer.  By default,
`kmode-stop-eglot-on-profile-change` makes a profile selection collect and
shut down Eglot servers found in file buffers under that worktree; users must
explicitly call `kmode-eglot-ensure` to start clangd for the new profile.

### Profile-aware Kbuild

**Implemented in `kmode-build.el`.**

`kmode-build-make-arguments` is the central Kbuild argv constructor.  In
order, it adds a positive `-j`, `ARCH=`, `CROSS_COMPILE=`, `LLVM=1` for a
`clang` profile, `O=` when output differs from the source root, trusted profile
arguments, trusted per-call arguments, and validated goals.  Minibuffer Make
goals accept only a deliberately narrow set of target characters and cannot
start with `-`; this guard does not make configured `:make-arguments` untrusted
data safe.

Managed build, menuconfig, edited-compile, KUnit, and Kselftest launches remove
ambient `ARCH`, `SRCARCH`, `CROSS_COMPILE`, `LLVM`, `LLVM_IAS`, `O`,
`KBUILD_OUTPUT`, `KBUILD_SRC`, `KCONFIG_CONFIG`, `CC`, `HOSTCC`, `HOSTCXX`,
`MAKEFLAGS`, `MFLAGS`, and `GNUMAKEFLAGS`.  This prevents an inherited shell
environment from silently overriding the resolved context; deliberate
overrides belong in the profile's trusted `:make-arguments`.

The public build commands cover the profile default, a prompted target, the
current source's inferred `.o`, the current directory target, `defconfig`,
`menuconfig`, `olddefconfig`, `compile_commands.json`, Sparse `C=1`/`C=2`, and
confirmed `clean`.  Current-object mapping supports C, assembly, Rust, and
object file names by changing the extension to `.o`.  It does not inspect
Kbuild membership, composite objects, generated files, or whether that target
exists.  Directory mapping is likewise a relative-directory heuristic.

`kmode-compile` prompts from the synchronized `compile-command`, accepts an
edited shell command, applies the sanitized environment, and runs it as an
active-profile job owning the profile output.  It is the buffer-local remap
target for the standard `compile` command while `kmode-mode` is enabled; the
edited command remains trusted user input.

Every noninteractive operation reuses `kmode-start-command`, so it has an
inspectable quoted command and a root/profile/label-specific output buffer.
`menuconfig` instead runs under `term-mode`/character mode in a similarly
named buffer.  Build and edited-command jobs mark their canonical output as a
resource, so a second job targeting that directory is rejected even if it has
a different profile or label.  The implementation does not yet keep a durable
job record, give non-resource jobs unique run IDs, fingerprint artifacts, or
warn that the compile-database target can perform a large build.

### Optional static analysis

**Implemented in `kmode-analyze.el`.**

All analysis commands reuse the profile-aware Kbuild argv and asynchronous
Compilation output:

- `kmode-analyze-warning-build` adds validated `W=1`, `W=2`, or `W=3` to the
  inferred current object or configured/default build;
- `kmode-analyze-smatch` requires the configured Smatch executable and adds
  validated `C=1`/`C=2` plus `CHECK=<program> -p=kernel`;
- `kmode-analyze-coccinelle-report` requires `spatch`, executable tree-local
  `scripts/coccicheck`, and a detected `coccicheck` target, and always invokes
  `MODE=report`; a prefix can add a root-contained current-directory `M=` and/or
  one readable `COCCI=` file (an outside-tree semantic patch is allowed after
  validation);
- `kmode-analyze-clang-analyzer` requires the kernel target/helper, Python,
  clang-tidy, and a `clang` profile or `.config` containing
  `CONFIG_CC_IS_CLANG=y`; and
- `kmode-analyze-checkstack` requires a readable profile `vmlinux`, the
  kernel target/script, Perl, and the profile's GNU or LLVM objdump.

Kbuild target discovery is a lightweight textual search of the top-level
Makefile, not a Make database query.  Analysis may be full-tree, slow, and
noisy.  The Coccinelle UI does not expose `MODE=patch`, but a selected semantic
patch and the checked-out build scripts remain executable trusted input.  The
module does not parse results into a common issue model, compare findings with
a baseline, or add resource/time limits.

### Opt-in live checkpatch

**Implemented in `kmode-flymake.el`.**

`kmode-checkpatch-flymake-mode` is a buffer-local, disabled-by-default
integration for C/header, assembly, and Rust source.  It appends
`kmode-checkpatch-flymake` to the local
`flymake-diagnostic-functions`, preserving Eglot and other existing backends.
If Flymake was off, it starts it and later stops only the Flymake instance it
started; otherwise it preserves the user's Flymake state.

Each check cancels and cleans any superseded request, writes the current
(possibly unsaved) buffer text to a temporary source file, and starts the
tree-local checkpatch with a direct argv containing `--no-tree`, configured
arguments, and `--file`.  The asynchronous sentinel treats checkpatch output,
not its normally nonzero finding status, as authoritative.  It parses
ERROR/WARNING/CHECK headings followed by FILE locations into Flymake
error/warning/note diagnostics mapped to the source buffer, rejects stale
process reports, and deletes the snapshot and private output buffer on
completion/cancellation/teardown.

This backend intentionally checks style only.  It neither saves the file nor
uses Kbuild compiler flags, and its parser covers the expected heading/location
shape rather than every historical checkpatch output variant.  Once the user
opts in, ordinary Flymake edit/save triggers execute the checked-out tree's
script; use it only with a trusted checkout.

### Patch checks and preparation

**Implemented in `kmode-review.el`.**

The module uses tools from the current source tree where appropriate:

- checkpatch on a source file, Git revision/range, staged diff, or selected
  patch text;
- `get_maintainer.pl` display and kill-ring copying for a file;
- colorized `git range-diff`;
- `git format-patch --cover-letter` to a selected directory;
- an advisory flight check composed from `git diff --check` followed by strict
  checkpatch; and
- direct opening of the tree's patch-submission guide.

User-entered Git revisions/ranges must be nonempty, cannot start with `-`, and
cannot contain whitespace or control characters.  Staged and region checks
write a temporary patch and delete it on launch/write failure or when
checkpatch exits; killing the result buffer is a fallback cleanup path.  Patch
export creates its destination and asks for confirmation when that directory
is outside the source root.  It writes mail
files only: the module does not retrieve, apply, attest, reroll, or send a
series and has no current b4 integration.  The flight check does not build or
test and a clean checkpatch result is not a correctness verdict.

### Heuristic change-impact plan

**Implemented in `kmode-impact.el`.**

`kmode-impact-plan` reads the staged index diff by default; with a prefix, or
through `kmode-impact-plan-range`, it accepts a validated Git revision/range.
It calls `git diff --name-only -z` without a shell, so unusual path bytes remain
path boundaries, and renders a read-only per-root report.  Control characters
are escaped for display and deleted/unavailable paths remain visible.

The planner classifies names as compiled source/object, header, Kconfig,
Kbuild, Documentation, device-tree binding/source, KUnit, Kselftest, or other.
From those categories it can suggest direct object/directory/DTB and broader
kernel/DT/docs builds, `olddefconfig`/`menuconfig`, Sparse, KUnit filters,
Kselftest collections, and staged/range checkpatch.  Each suggestion explains
its rationale and is a `[run]` button; gathering/rendering runs none of them.
Path-specific build suggestions are capped by
`kmode-impact-max-specific-builds` (24 by default).

This is explicitly a filename/path heuristic.  It does not parse Kbuild
conditions, compute header consumers, evaluate Kconfig, map maintainers, rank
architectures, inspect changed hunks, or prove a target/test is applicable.
Suggestion buttons are not prefiltered through action capability predicates;
the invoked command performs its normal validation and may report a missing
tool or target.  The report stores only one staged/range view per source root
and has no saved manifest or multi-profile executor.

### KUnit and Kselftest

**Implemented in `kmode-test.el`.**

KUnit commands call the checked-out tree's `tools/testing/kunit/kunit.py` with
an explicitly discovered Python interpreter.  They forward profile
architecture, cross prefix, LLVM selection, Make options, positive job count,
optional KUnit configuration, optional filter, and a derived build directory.
The default profile uses `<profile-output>/.kunit`; another profile uses a
safe profile-name plus six-digit profile-hash suffix under its output.  Thus
the derived directory never equals the ordinary profile output and cannot
replace its `.config` or normal artifacts.  An absolute
`kmode-kunit-build-directory` override is used directly and a relative
override resolves from the source root.  Public operations run, run with a
filter/config, configure only, or build only.  KUnit jobs serialize on their
resolved KUnit build directory.

Kselftest collection completion is derived from `TARGETS +=`/`TARGETS =`
lines in `tools/testing/selftests/Makefile`.  The runner validates selected
names, passes them in `TARGETS=`, optionally adds `summary=1` and
`FORCE_TARGETS=1`, and invokes the top-level `kselftest` target through the
same profile Make argv.  It serializes on the profile output.  A
current-collection command recognizes files below
`tools/testing/selftests/<collection>/`.

Both integrations currently present raw output through Compilation mode.
They do not parse KTAP/TAP into structured results, retain run manifests,
apply timeouts, retry failures, or distinguish tests that need root or special
hardware.

### Logs, custom QEMU, and GDB

**Implemented in `kmode-debug.el`.**

`kmode-log-mode` derives from the kmode-emacs compilation mode, highlights common
incident/result terms, and binds `n`, `p`, and `d` to incident navigation and
whole-buffer decoding.  Logs can be visited from a file or streamed from the
configured local argv (by default `dmesg --follow --human --decode`).  Region
or buffer decoding pipes raw text to the checked-out tree's
`scripts/decode_stacktrace.sh`, using the profile's readable `vmlinux` and
source root.

The runtime command requires a profile `:qemu-command` list and verifies a
readable kernel image or `vmlinux` whenever the configured argv references it
through `%i` or `%v`.  Each argv token expands `%i`, `%v`, `%o`, `%r`, and
`%p`; QEMU runs directly in a profile-named Comint buffer, and a second live
process for that root/profile is rejected.  Stop sends an interrupt to that
process.  No shell evaluates the QEMU argv.  The live process owns the
canonical profile output, so it cannot overlap a managed build or vng guest
using the same artifacts.  kmode-emacs recognizes `-s` and explicit `-gdb`/`-qmp`
TCP or Unix endpoints and owns canonical named resources while QEMU is live.
TCP identity is the port, regardless of bind-address spelling.  Relative Unix
socket paths are resolved from the kernel source root.

GDB startup requires Emacs's built-in `gdb-mi`, a discoverable GDB, and a
readable profile `vmlinux`; it opens the graphical GDB interface and executes
`target remote` for the configured or default target.

This is a minimal runtime layer, not the managed cockpit in the roadmap.  It
does not generally validate QEMU options, protect disks, create endpoints,
wait for guest readiness, provide QMP control, identify a run, load kernel GDB
helpers, or verify that a log/running guest matches `vmlinux`.  Named endpoint
ownership covers only recognized managed processes in this Emacs instance.
The local log command is not automatically privileged.

### First-class virtme-ng integration

**Implemented in `kmode-virtme.el`, with context fields in `kmode-core.el`,
bindings/menu in `kmode-emacs.el`, and status checks in `kmode-ui.el`.**

kmode-emacs targets virtme-ng's public `vng` frontend.  `kmode-vng-program`
defaults to `vng`; while unchanged, executable discovery falls back to the
official `virtme-ng` alias.  It does not probe `vng-ng` or call the deprecated
underlying `virtme-*` commands.  Bare programs follow `kmode-tool-path`'s
`exec-path` rule, while an explicitly configured path follows its normal
absolute/source-root-relative executable checks.

The profile additions and their consumers are:

| Property | Validation and use |
| --- | --- |
| `:vng-arch` | Must be one of `amd64`, `arm64`, `armhf`, `ppc64el`, `s390x`, or `riscv64` and agree with `:arch` plus any recognizable `:cross-compile` architecture |
| `:vng-root` | Expanded from the source root when relative; used only at runtime, where a non-native architecture requires an existing readable/searchable directory; omitted from builds |
| `:vng-append` | Nonempty/control-free strings emitted as repeated `--append VALUE` pairs |
| `:vng-arguments` | Validated common vng arguments for run, exec, preview, and debug |
| `:vng-debug-arguments` | Validated vng arguments appended only to debug runs |
| `:vng-build-arguments` | Validated vng-level build arguments before `--` |
| `:vng-make-arguments` | Make assignments only, appended after managed `-- O=<output>` and optional `LLVM=1` |

Architecture inference is deliberately conservative.  `x86`, `arm`,
`powerpc`, and `riscv` are ambiguous unless they exactly describe the native
host without a cross compiler.  Unambiguous kernel names map directly; known
cross-compiler prefixes can infer a vng architecture; and `:vng-arch` resolves
the remaining cases.  kmode-emacs rejects contradictions among the kernel,
cross-compiler, and explicit vng values.  A pure cross build needs no guest
root and does not pass `--root`; run/debug/preview/exec require an existing
root whenever the resolved architecture is non-native.  A chained build/boot
preflights that runtime requirement before compiling.

The pure `kmode-vng-command-arguments` builder supports `build`, `run`,
`debug`, `preview`, and `exec`.  Builds execute from the source root as:

```text
vng --build [architecture/cross/jobs] [build arguments] -- \
  O=<absolute-output> [LLVM=1] [make assignments]
```

The other operations start with `vng --run <absolute-output>`, then add the
validated architecture/root, common arguments, repeated kernel arguments, and
one managed operation switch (`--debug`, `--dry-run`, or `--exec COMMAND`) as
needed.  An exec command must be one nonempty line.  It is one host process
argument and is intentionally interpreted by vng's guest shell.  The active
Kbuild environment is sanitized for all managed vng processes, and build/run
chains retain a copied context even if the worktree selection changes while
the build is running.

Direct Emacs argv removes an extra kmode-emacs-owned host shell from interactive
launches, but current vng itself reconstructs parts of its runtime through a
shell.  kmode-emacs therefore restricts runtime output/root paths and common/debug
argument tokens to a conservative shell-atom alphabet.  This is an upstream
compatibility guard, not a claim that arbitrary profile values are safe.

Profile pass-through is a canonical long-option allowlist, not arbitrary vng
argv.  Short flags and clusters, argparse abbreviations, positional arguments,
unknown future options, wrong scopes, missing/extra values, and invalid port
ranges fail closed.  Build scope allows only `--skip-modules`, `--config`,
`--configitem`, `--verbose`, and `--quiet`.  Runtime scope allows only:

```text
--no-virtme-ng-init  --empty-passwords  --pin  --snaps  --skip-modules
--busybox  --qemu  --name  --user  --shell  --rw  --no-root-posix-acl
--force-9p  --disable-microvm  --disable-kvm  --disable-monitor  --cwd
--rodir  --rwdir  --overlay-rwdir  --cpus  --memory  --numa
--numa-distance  --balloon  --network  --no-dhcp  --net-mac-address
--disk  --force-initramfs  --sound  --graphics  --fb  --verbose  --quiet
--qemu-opts  --nvgpu  --vfio-pci  --console  --console-client  --ssh
--ssh-client  --ssh-tcp  --remote-cmd  --systemd
```

kmode-emacs retains ownership of operation, output, architecture, root, cross
compiler, jobs, guest command, append values, dry-run/debug, help/version,
destructive Git/remote-build actions, and the `--` boundary.  Make-side
`O=`/`KBUILD_OUTPUT=`/`ARCH=`/`CROSS_COMPILE=`/`LLVM=` overrides are likewise
rejected.  `--debug` exists only as a typed configuration default because the
interactive debug operation owns the explicit selector.  These checks protect
context ownership; they do not make allowed trusted options harmless.

`kmode-vng-home-directory` selects one existing stable home directory
(default: the user's home).  kmode-emacs pins managed vng `HOME` to it and inspects
the same upstream precedence used by the child: first
`<home>/.config/virtme-ng/virtme-ng.conf`, then
`<home>/.virtme-ng.conf`, then `/etc/virtme-ng.conf`.  This applies to version
probing, build, preview, runtime, and dump operations and prevents ambient HOME
changes from selecting a different config after inspection.

Invalid or unreadable JSON fails closed.  A nonempty `default_opts` object is
also rejected until `kmode-vng-trust-default-options` is non-nil, because
upstream applies it after explicit arguments.  Trust does not disable
validation: each argparse destination must be unique, present in the option
schema (plus the default-only `debug` destination), and not one of kmode-emacs's
managed destinations.  Values must match their boolean flag, nonnegative
count, string/optional/list, or 1--65535 port type; runtime strings also obey
the upstream-shell atom restriction.  Unknown destinations, managed
overrides, bad shapes/ranges, and unsafe values therefore remain hard errors.
kmode-emacs computes effective dangerous/global/debug behavior from the validated
defaults, including a configured `debug: false`, instead of treating every
trusted configuration as globally locking.

At runtime kmode-emacs rejects a configured root that does not already exist with
read/search access, and rejects a non-native vng architecture without such a
root.  This prevents an ordinary managed boot from entering upstream's
missing-root download/extraction path, which can use the network and `sudo`.
The build operation intentionally omits and does not validate the root, so a
cross build remains available without provisioning a guest.  A separate
confirmed provisioning command is not implemented.

With `kmode-vng-confirm-host-access` enabled (the default), explicit profile
or enabled validated-default selections for writable host access, a custom
QEMU/extra QEMU options, disk/device passthrough, networking, empty passwords,
SSH/console services or clients, or systemd receive a `yes-or-no-p`
confirmation.  This is an attention gate, not isolation; trusted arguments
and defaults run with the user's authority.

`kmode-vng-build`, `kmode-vng-preview`, and every live vng guest own the
canonical profile output.  This serializes them with kmode-emacs builds, custom
QEMU, and aliases/profiles resolving to the same directory.  Only one vng
guest may run for a root/profile.  Debug, pin, SSH, and console arguments use
an additional process-global vng lock when enabled explicitly or by a
validated trusted default.  Effective debug mode also owns named
`tcp-port:1234` and `tcp-port:3636` resources.  Effective `--console` and
`--ssh` server settings own their selected TCP port, defaulting to 2222 when
the option has no value.  Raw QEMU `-s`, `-gdb`, and `-qmp` TCP endpoints use
the same port names, so collision checks cross runtime kind, profile, and
worktree; QEMU Unix endpoints use a canonical `unix-socket:` name, resolving a
relative socket from the source root.  These locks coordinate only managed
processes in the current Emacs instance.

Interactive run/exec/debug commands use a profile-named Comint buffer and
direct process argv.  Build/preview/dump use the common asynchronous
Compilation path, where each already-separated item is shell-quoted once.
All managed vng children receive the sanitized Kbuild environment, a
checkout-isolated child `PATH`, and the pinned vng `HOME`; trusted absolute
checkout `PATH` directories require the explicit
`kmode-build-trusted-path-directories` escape hatch.
`kmode-vng-stop` selects a live vng guest across the current worktree's
profiles and sends an interrupt.  Dashboard status uses the same process
metadata, and the generic `kmode-cancel-job` also sees these jobs.
Stop, attach, and dashboard discovery never adopt a guest from another kernel
root; the process-global facility lock deliberately spans roots because its
host ports/services are actually shared.

The build-and-run/debug path performs synchronous runtime preflight before it
starts a potentially long build, allowing only the future output directory to
be absent.  It resolves and freezes the operation, copied context, program,
argv, environment, effective typed defaults/debug state, HOME, config
path/content digest, trust flag, and named/global resources after any
host-access confirmation.  It rechecks external trust input after the prompt,
installs the completion hook before Compilation starts, and associates success
with the captured process rather than a reusable buffer.  On successful build,
the launch revalidates config/HOME/trust, output existence, and resource
availability before direct spawn.  Changed state aborts instead of adapting
the frozen plan.  The automatic launch does not select or pop to its buffer;
it reports the buffer name in a message, so completion cannot steal focus.

Debug attachment does not launch upstream's terminal-oriented `vng --gdb`.
`kmode-vng-gdb-attach` finds the worktree's managed debug guest, retrieves its
pinned context, requires its readable `vmlinux`, and calls the built-in Emacs
GDB/MI adapter with `kmode-vng-gdb-target` (default
`localhost:1234`).  `kmode-vng-dump` similarly requires a managed debug
guest, checks the destination directory, confirms replacement, and launches
`vng --dump FILE`.  Neither command waits for endpoint readiness or verifies
the running kernel's build identity.

`kmode-vng-preview` asks upstream `--dry-run` to resolve/show the VM command
without launching QEMU.  It still takes the output resource because upstream
initialization can prepare `.virtme_mods`; it is deliberately not described as
filesystem-side-effect-free.  `kmode-vng-show-commands` displays shell-quoted
build/run/preview/debug forms without executing them.  The forms show
kmode-emacs-generated argv; validated trusted defaults remain in the selected
fixed-HOME config and are applied by upstream, so displayed argv alone is not
an effective-option dump.

No `vng` or `virtme-ng` executable was installed in the development
environment used to implement this layer, and no real kernel build, VM boot,
GDB attachment, or memory dump was performed here.  Those remain opt-in
integration smoke tests rather than claims made by the hermetic suite.

## Public extension surface present today

### Refine a context

Functions in `kmode-context-functions` receive a resolved context.  They may
mutate and return it, return a replacement, or return nil to keep the object
passed to them.

```elisp
(defun my-kmode-ci-output (context)
  (when (string= (kmode-context-profile context) "ci")
    (setf (kmode-context-jobs context) 4))
  context)

(add-hook 'kmode-context-functions #'my-kmode-ci-output)
```

Hooks run last, after buffer and profile resolution.  Hook code must not start
processes or prompt: context resolution is used by action availability checks
and dashboard refreshes.  Code that needs to react after an interactive
worktree profile selection should use `kmode-profile-changed-hook` instead;
the hook receives no arguments and runs with the selecting buffer current.

### Register an action

```elisp
(defun my-kmode-smoke-test ()
  (interactive)
  (let ((context (kmode-resolve-context)))
    (kmode-start-command
     "smoke"
     "make"
     (append (list "-C" (kmode-context-root context))
             (when-let ((output (kmode-context-output context)))
               (list (concat "O=" output)))
             '("kselftest"))
     (kmode-context-root context))))

(kmode-register-action
 'my-smoke "Run smoke test" "Test" #'my-kmode-smoke-test
 :predicate (lambda () (kmode-tool-path "make"))
 :description "Run my project-specific smoke target")
```

An extension should use a globally unique symbol for its action ID and should
make the command validate context again.  A predicate is a presentation hint,
not an authorization or safety boundary.

### Reuse the Kbuild argv constructor

Extensions that invoke the top-level kernel Makefile should prefer
`kmode-build-make-arguments` to reconstructing profile options:

```elisp
(let* ((context (kmode-resolve-context))
       (make (kmode-require-tool kmode-build-make-program context))
       (argv (kmode-build-make-arguments
              context '("drivers/base/") '("W=1"))))
  (kmode-start-command "my-check" make argv
                        (kmode-context-root context)))
```

The target list passes the strict target validator.  The extra-argument list
is trusted configuration and may contain Make options or variable assignments;
do not populate it directly from untrusted minibuffer or file text.

### Core utility functions

The following functions are intended for cooperating modules in the current
tree:

| Function | Contract summary |
| --- | --- |
| `kmode-kernel-root-p` | Test all configured root markers |
| `kmode-locate-root` | Locate/cached lookup; nil outside a tree |
| `kmode-root` | Return the root or signal `user-error`; optional no-error form |
| `kmode-current-profile-name` | Resolve buffer/session/default profile name |
| `kmode-profile-property` | Read a property from a selected profile |
| `kmode-resolve-context` | Produce a context and run refinement hooks |
| `kmode-profile-changed-hook` | Notify consumers after worktree profile selection |
| `kmode-profile-description` | Produce compact profile text for a UI |
| `kmode-native-arch` / `kmode-srcarch` | Infer host ARCH and map it to the kernel source-directory spelling |
| `kmode-root-id` | Produce a collision-resistant root display/process identifier |
| `kmode-running-processes` | Return live processes for the active profile or, optionally, every profile in the worktree |
| `kmode-cancel-job` | Interrupt a validated live kmode-emacs process in the current worktree |
| `kmode-process-resource-key` / `kmode-resource-process` | Canonicalize and inspect writable-resource ownership |
| `kmode-assert-resource-available` / `kmode-mark-process-resource` | Reject or record overlapping resource use |
| `kmode-register-action` | Add or replace an action |
| `kmode-action-available-p` | Safely evaluate an action predicate |
| `kmode-actions` | Return sorted available/all actions |
| `kmode-tool-path` | Resolve a bare `exec-path` command or an explicit absolute/tree-relative executable |
| `kmode-require-tool` | Resolve or signal an actionable error |
| `kmode-shell-command` | Shell-quote a program and argument list |
| `kmode-start-shell-command` | Start a visible shell command with optional resource ownership |
| `kmode-start-command` | Start an asynchronous Compilation-mode process |
| `kmode-recompile` | Restart a kmode-emacs Compilation job after revalidating its resource |
| `kmode-file-in-root` | Return a source-root-relative file or reject it |
| `kmode-build-process-environment` | Copy the environment without ambient Kbuild selectors |
| `kmode-build-make-arguments` | Construct and validate a complete profile-aware Make argv |
| `kmode-compile` | Run an edited command as a serialized, profile-owned job |
| `kmode-vng-command-arguments` | Construct validated vng argv for a supported operation |
| `kmode-vng-command` | Render that argv as shell-quoted display/copy text |
| `kmode-vng-profile-problem` / `kmode-vng-available-p` | Explain or test current vng capability without starting it |
| `kmode-vng-config-file` / `kmode-vng-default-options` | Inspect the selected upstream config and its overriding defaults |
| `kmode-vng-processes` | Return managed vng guests for the active profile or whole worktree |

Consumers should prefer accessors such as `kmode-context-output` over relying
on the printed representation of the struct.

## Upstream facts that constrain the design

This section states facts supported by upstream documentation.  The following
roadmap section states kmode-emacs recommendations.

### Kbuild and compile databases

- `O=<directory>` selects a separate kernel output tree and must be supplied to
  every Make invocation for that build.  `O=` takes precedence over
  `KBUILD_OUTPUT`.  See the [kernel build-directory
  guide](https://docs.kernel.org/6.14/admin-guide/README.html) and [Kbuild
  variables](https://docs.kernel.org/kbuild/kbuild.html).
- Current mainline has a `compile_commands.json` Make target.  It invokes the
  kernel's generator and depends on the configured vmlinux objects/libraries
  and, when enabled, module order, so requesting it can cause substantial
  build work.  See the [mainline
  Makefile](https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/heads/master/Makefile).
- The in-tree generator derives commands from Kbuild `.cmd` files and does not
  support `tools/`; it also excludes `include/` and Documentation while walking
  the tree.  See
  [`gen_compile_commands.py`](https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux.git/+/refs/heads/master/scripts/clang-tools/gen_compile_commands.py).
- clangd needs the include, language, macro, target, driver, and working
  directory information in a compile command.  Missing/wrong flags create
  spurious diagnostics.  Headers generally have no direct database entry, so
  clangd infers a command from a source file.  See clangd's [compile-command
  design](https://clangd.llvm.org/design/compile-commands) and
  [FAQ](https://clangd.llvm.org/faq).
- clangd can query a cross compiler for implicit paths/target information only
  when it matches an explicit `--query-driver` allowlist.  This is opt-in
  because it executes the driver named by compile data.  See the [system-header
  guide](https://clangd.llvm.org/guides/system-headers).

### Static analysis

- Kbuild uses `W=` for additional warning groups and `C=1`/`C=2` to check
  rebuilt/all needed sources.  Sparse documents those two checking levels in
  [the kernel Sparse guide](https://docs.kernel.org/dev-tools/sparse.html).
- The kernel `coccicheck` target supports report, context, org, and patch-style
  modes, along with `M=` and `COCCI=` scoping.  Full-tree work can be expensive
  and findings can be false positives.  See the [kernel Coccinelle
  guide](https://docs.kernel.org/dev-tools/coccinelle.html).
- Current mainline makes `clang-analyzer` depend on the generated compilation
  database and rejects it when the kernel configuration is not Clang-based;
  `checkstack` disassembles built `vmlinux` and modules.  See the [mainline
  Makefile](https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/heads/master/Makefile).
- The kernel submission checklist recommends both Sparse and `make
  checkstack`, while warning that checkstack output requires interpretation.
  See the [submission
  checklist](https://www.kernel.org/doc/html/latest/process/submit-checklist.html).

### Emacs foundations

- Emacs Project provides project file search, shells, VC, and asynchronous
  compilation at the project root.  See [Project file
  commands](https://www.gnu.org/software/emacs/manual/html_node/emacs/Project-File-Commands.html).
- Xref is a common interface backed by Eglot, tags, or a major-mode-specific
  provider.  See [Xref](https://www.gnu.org/software/emacs/manual/html_node/emacs/Xref.html).
- Eglot normally shares a language server among buffers of the same language
  and project.  Its server association can be a function, and clangd can be
  given a separate compile-database directory.  See [setting up Eglot
  servers](https://www.gnu.org/software/emacs/manual/html_node/eglot/Setting-Up-LSP-Servers.html)
  and [the compilation-database
  example](https://www.gnu.org/software/emacs/manual/html_node/eglot/User_002dspecific-configuration.html).
- Flymake supports multiple buffer-local backends through
  `flymake-diagnostic-functions`; backends should return quickly, report
  through their callback, and cancel obsolete asynchronous work.  Eglot uses
  Flymake as an additional backend.  See [Flymake backend
  functions](https://www.gnu.org/software/emacs/manual/html_node/flymake/Backend-functions.html)
  and [using Flymake](https://www.gnu.org/software/emacs/manual/html_node/flymake/Using-Flymake.html).
- CC Mode includes a `linux` style.  The kernel coding-style documentation also
  contains its own directory-local Emacs setup and specifies tabs/indentation
  of eight for C.  See [CC Mode built-in
  styles](https://www.gnu.org/software/emacs/manual/html_node/ccmode/Built_002din-Styles.html)
  and [kernel coding style](https://docs.kernel.org/process/coding-style.html).

### Patches and review

- b4 retrieves whole patch threads, checks attestation, collects review
  trailers, prepares mailboxes, and can apply with `shazam`.  See [b4 am and
  shazam](https://b4.docs.kernel.org/en/latest/maintainer/am-shazam.html).
- `b4 diff` compares revisions using `git range-diff`, but both revisions must
  apply to the current tree.  See [b4
  diff](https://b4.docs.kernel.org/en/latest/maintainer/diff.html).
- b4's review workflow tracks lifecycle and revisions in a SQLite database and
  review branches.  It ships an Emacs helper for `*.b4-review.eml`, but the
  whole review interface is explicitly an alpha technology preview.  See [b4
  review](https://b4.docs.kernel.org/en/latest/maintainer/review.html).
- `b4 send` supports dry-run, output-directory inspection, reflection to the
  sender, and preview recipients.  Sending also records and rerolls a series.
  See [b4 send](https://b4.docs.kernel.org/en/latest/contributor/send.html).
- b4 warns that patch-ID trailer matching can occasionally find an unexpected
  trailer and provides interactive review.  See [b4
  trailers](https://b4.docs.kernel.org/en/latest/contributor/trailers.html).

### Test, logs, QEMU, and debugging

- KUnit's wrapper configures, builds, runs under UML or supported QEMU
  architectures, parses KTAP, filters suites, and can emit JSON or JUnit.  See
  [running KUnit](https://docs.kernel.org/dev-tools/kunit/run_wrapper.html).
- kselftest can select `TARGETS`, use `O=`, and requires TAP output for tests.
  Some tests require root.  See
  [kselftest](https://docs.kernel.org/dev-tools/kselftest.html).
- The kernel recommends `scripts/decode_stacktrace.sh` with matching debug
  information for useful source locations.  See [bug
  hunting](https://docs.kernel.org/admin-guide/bug-hunting.html).
- Dynamic debug exposes callsites and permits selectors for file, function,
  line, module, format, and class through a control file.  Writes generally
  require privilege.  See [dynamic
  debug](https://docs.kernel.org/admin-guide/dynamic-debug-howto.html).
- QEMU's gdbstub supports `-s -S` and Unix sockets.  `-nographic` multiplexes
  the console and monitor on stdio.  See [QEMU GDB
  usage](https://www.qemu.org/docs/master/system/gdb.html) and [QEMU
  invocation](https://www.qemu.org/docs/master/system/invocation.html).
- The virtme-ng project exposes `vng` as its public frontend and also installs
  `virtme-ng` as an alias; the maintainer recommends the public frontend over
  the deprecated underlying `virtme-*` commands.  There is no upstream
  `vng-ng` frontend.  See the [packaged entry
  points](https://github.com/arighi/virtme-ng/blob/main/setup.py) and the
  [maintainer guidance](https://github.com/arighi/virtme-ng/discussions/126).
- Public vng builds from the current kernel source directory, accepts an
  out-of-tree output after `--` as `O=...`, and boots an existing output with
  `--run DIRECTORY`; bare `-r` instead selects the running host kernel.  Its
  public architecture choices are `amd64`, `arm64`, `armhf`, `ppc64el`,
  `s390x`, and `riscv64`.  `--root` supplies a guest root, and repeated
  `--append` values extend the kernel command line.  See the [virtme-ng
  examples](https://github.com/arighi/virtme-ng/blob/main/README.md#examples)
  and [public argument
  parser](https://github.com/arighi/virtme-ng/blob/main/virtme_ng/run.py).
- vng's `--debug` prepares its supported GDB/QMP debugging configuration;
  the current public frontend uses `localhost:1234` for GDB and
  `localhost:3636` for QMP.  `--dry-run` prevents the final QEMU launch, but
  frontend setup may still create or prepare state.  Upstream applies JSON
  `default_opts` after ordinary CLI parsing, so they can override command-line
  choices.  These are version-sensitive frontend details, not generic QEMU
  guarantees; see the [current vng
  implementation](https://github.com/arighi/virtme-ng/blob/main/virtme_ng/run.py).
- Emacs's built-in `M-x gdb` has source, locals/registers, stack,
  breakpoints/threads, and I/O views.  See the [GDB graphical
  interface](https://www.gnu.org/software/emacs/manual/html_node/emacs/GDB-Graphical-Interface.html).

## Recommended target architecture

Each subsection first identifies the implemented baseline, then labels the
remaining recommendation.  No roadmap paragraph should be read as current
behavior.

### 1. Project minor mode and command surface (P0)

**Implemented baseline:** project/globalized modes, buffer-local C style and
compile command, a `C-c k` prefix/menu, Emacs Project recognition, completion
dispatcher, action-registry dashboard, initial doctor, and dedicated
`C-c k n` navigation and `C-c k v` virtme-ng submaps.

**Planned:** make each unavailable action link to its exact failed predicate;
include resolved executable versions/paths and richer configuration probes in
doctor; add durable latest-result history to the flight deck; and add an
optional Transient presentation without replacing the dependency-free
dispatcher.  A doctor must remain read-only and never download or install
anything.

Acceptance criteria:

- automatic enabling has no buffer-local effect outside recognized kernel trees;
- the active root/profile is visible and switchable;
- unavailable actions explain their own missing capability, not only a generic doctor hint;
- users can inspect every generated command.

### 2. Profile-aware Kbuild loop (P0)

**Implemented baseline:** one constructor supplies `O=`, `ARCH`,
`CROSS_COMPILE`, compiler choice, `-j`, and extra arguments to default,
prompted-target, current-object, current-directory, configuration,
compile-database, Sparse, and clean commands.  Compilation buffers support
resource-aware `recompile`; enabling the minor mode sets `compile-command` and
remaps standard compilation to the sanitized, profile-owned `kmode-compile`.
Managed jobs targeting the same canonical output directory cannot overlap.

**Planned:** add explicit module/image/full-kernel choices, durable job
identity/history/results, and artifact status beyond readability.

The implemented source-to-object mapping (`foo.c`/`foo.S`/Rust to `foo.o`) is
heuristic.  Headers, included C files, generated sources, composite objects,
and some Rust layouts do not have a standalone target.  The planned UI should
label an inferred target and provide directory/full-build fallback.

**Planned:** extend current active-profile/worktree live-process discovery into
a job registry keyed by root, profile, and operation.  Root/profile-specific
buffers already prevent an arm64 job from replacing x86 diagnostics; durable
records should add the
exact command, start/end time, exit status, error count, and relevant artifact
paths, plus stale-process cleanup.

Also add parsers for common Kbuild, modpost, Sparse, Coccinelle, Clang, GCC, and Rust
diagnostics without replacing Compilation mode's standard matchers.

### 3. Compilation database and semantic lifecycle (P0)

**Implemented baseline:** `kmode-build-compile-commands` explicitly invokes
the current Kbuild `compile_commands.json` target with the complete active
profile, and `kmode-eglot-ensure` points clangd at the resulting output
directory after checking that the file is readable.

**Planned:** feature-detect a compatible in-tree generator for older kernels,
warn before a request that can trigger a large build, and validate the result.

Record a fingerprint covering at least source root/revision, output tree,
`.config`, architecture, compiler/toolchain, and Make arguments.  Report
missing, partial, stale, and current states separately.  Update generated files
atomically where kmode-emacs owns them.

The implemented Eglot contact is buffer-local, and profile selection shuts
down discovered servers for the worktree by default without automatically
restarting them.  **Planned:** track the profile/server association explicitly,
resolve the contact dynamically, and offer a deliberate reconnect action; two
incompatible configurations must never silently share an index.  Expose a
diagnostic command that shows the compile command used for the current file
and can run `clangd --check`.

Never broaden `--query-driver` automatically.  Let the user choose exact
trusted compiler paths and show that the option permits execution.

Rust support should use the kernel's `rust-analyzer` Make target and keep its
generated `rust-project.json` profile-specific.

### 4. Kernel semantic navigation (P0/P1)

**Implemented baseline:** include/Kconfig definition/Kconfig user/Kbuild
owner/source-header/Documentation navigation, Xref fallback, profile-aware
clangd startup, and a dedicated Kconfig editing/source-following mode.

**Planned:** extend this navigation with:

- Kconfig symbol help, dependencies, reverse selections, and the active
  profile's `y`/`m`/`n` state;
- source-to-Kbuild membership and configured/built-in/module state;
- `EXPORT_SYMBOL*`, syscall declarations, trace events, module parameters, and
  device-table definitions;
- `scripts/get_maintainer.pl` for a file, region, staged diff, or commit;
- deterministic `git grep` fallback for macro-heavy code; and
- generated-output-to-source path remapping for diagnostics and Xref.

A context view at point should combine effective compile command, inferred
translation unit for a header, active `CONFIG_` values, owning Kbuild entry,
and maintainer subsystem.  Each field needs provenance and an uncertainty label
when it is heuristic.

Do not crawl the entire tree synchronously during buffer activation.  Prefer
`git ls-files`, ripgrep, clangd/Xref, and kernel scripts in asynchronous
processes; cache by source revision and profile fingerprint.

### 5. Checks and tests (P1)

**Implemented baseline:** strict checkpatch for a file, staged patch, selected
patch text, or Git range; an advisory whitespace/checkpatch flight check;
profile-aware Sparse `C=1`/`C=2`; raw-output KUnit run/config/build with filter
or configuration selection; raw-output Kselftest collection selection; and
raw-output Kbuild warning, Smatch, report-only Coccinelle, Clang analyzer, and
checkstack commands; plus an opt-in asynchronous live-checkpatch Flymake
backend that coexists with Eglot.

**Planned:** add change-local result comparison and full checks for a
subsystem or profile.  Further adapters should cover:

- structured/baselined output for the implemented warning/analyzer commands;
- the kernel clang-tidy target where supported;
- Smatch/Coccinelle scoping inferred from an impact plan; and
- explicit documentation and binding check commands/results.

Checkpatch results are style/review advice, not a correctness verdict.
Coccinelle and broad static analysis can be slow and noisy; neither should run
on save by default.

Current KUnit commands let the user edit a filter/config, and current
Kselftest commands select one or more `TARGETS`.  **Planned:** infer a nearby
KUnit suite/test, consume JSON/JUnit when supported, link failures to source,
and parse Kselftest TAP.  A test
dashboard should preserve command, profile, pass/fail/skip/timeout, duration,
and raw output, with rerun-failed support.  Tests that need root, special
hardware, or destructive setup require visible warnings and bounded timeouts.

### 6. Patch flight deck (P1)

**Implemented baseline:** file/staged/range/region checkpatch, file-based
maintainer discovery/copying, Git range-diff, local format-patch export, the
local submission guide, and the advisory flight check.  These operations do
not fetch/apply a series or send mail.

**Planned:** use b4 as the authority for message retrieval, attestation, series/version
tracking, trailers, and mail generation.  Do not parse RFC mail or access b4's
SQLite schema directly.

Maintainer/reviewer flow:

1. accept a Message-ID, lore URL, or Message-ID extracted from an optional
   Notmuch/Gnus buffer;
2. fetch and display series metadata, base, attestation, revisions, and status;
3. prepare/apply into an isolated worktree or `FETCH_HEAD`, leaving the user's
   current branch untouched by default;
4. compare revisions through b4/git range-diff;
5. run selected profile checks/tests and preserve a validation manifest; and
6. compose comments/trailers through b4's supported interface.

Load the b4-shipped Emacs review helper when compatible.  Keep it behind a
small adapter and version check because upstream calls the feature alpha.

Contributor flow:

1. prepare/edit the series and cover letter;
2. compute and display recipients via b4/get_maintainer;
3. run selected checks;
4. render messages to an output directory for exact review;
5. optionally reflect/preview; and
6. send only after a separate explicit confirmation.

kmode-emacs must never invent or automatically add `Reviewed-by`, `Acked-by`, or
`Tested-by`.  Incoming trailers should use b4's interactive review when there
is ambiguity.

Optional Magit integration may expose series worktrees and diff hunks; optional
Notmuch/Gnus integration may supply Message-IDs.  Neither should be a hard
dependency.  Notmuch's own documentation warns that its Emacs frontend and CLI
versions must agree, so kmode-emacs should use public frontend functions and report
version failures rather than vendoring the client.

### 7. Kernel log and crash-to-source loop (P1)

**Implemented baseline:** a Compilation-derived log mode can follow a
configurable local command, open a saved file, highlight/navigate common
incident markers, and pipe a region/buffer through the tree's stacktrace
decoder with the selected profile `vmlinux`.

**Planned:** evolve this into a read-only incremental log mode fed by local `dmesg`/journal, QEMU
serial, a file, or a later SSH transport.  Preserve raw text while adding
properties for:

- boot/run boundaries and timestamps;
- printk severity, CPU, PID/command, and subsystem prefix;
- taint state;
- Oops, panic, warning, hung-task, lockdep, KASAN, KCSAN, and UBSAN incidents;
- call-trace frames and modules; and
- KTAP/TAP records.

Users should be able to jump among incidents, fold boilerplate, filter without
deleting raw data, and export a reviewed incident bundle.

Decoding already uses `scripts/decode_stacktrace.sh` and artifacts resolved
from the selected profile.  **Planned:** compare kernel release/build identity where possible and
refuse or prominently mark uncertain output.  Module relocation and KASLR mean
that raw `addr2line` is not a universal substitute.

Dynamic-debug support should read the callsite catalog into a table and build
selectors for the file/function/module/callsite at point.  Enabling or disabling
callsites writes a privileged runtime interface and always requires exact
preview and confirmation.

### 8. QEMU, virtme-ng, and GDB cockpit (P1)

**Implemented baseline:** for custom QEMU, a user supplies a profile QEMU argv,
image, `vmlinux`, and GDB target.  kmode-emacs expands five profile placeholders,
starts one QEMU Comint process per root/profile, can interrupt it, and launches
built-in Emacs GDB with `target remote`.  First-class virtme-ng support also
builds into or boots the active output, runs guest commands, previews the
resolved upstream command, starts and stops run/debug guests, attaches GDB to
a managed debug guest, and requests a memory dump.  Both runtime paths pin the
resolved context, use direct runtime argv with a checkout-isolated child
environment, own the canonical output while live, and reserve recognized named
endpoints.  vng also enforces per-profile guest and shared-host-facility locks;
its build-and-boot path preflights and freezes the runtime plan before building,
revalidates it on success, and launches without changing the selected window.

**Planned:** replace the opaque custom-QEMU recipe with validated runtime
settings for QEMU binary/architecture, machine/CPU/memory, kernel image,
rootfs/initrd, kernel arguments, serial endpoint, QMP endpoint, gdbstub
endpoint, and optional networking.  Unify custom-QEMU and virtme-ng run
identity without obscuring which upstream frontend owns an option.

Create a short, private runtime directory per session/profile and give serial,
QMP, and gdbstub separate Unix sockets.  This avoids TCP port collisions and
avoids mixing monitor control with kernel logs.  Track PID/process sentinels,
socket ownership, run generation, command, artifact fingerprint, and exit
reason.  Base disk images should be read-only with a disposable overlay or
QEMU snapshot mode by default.

The vng workflow already provides profile/config-frozen build -> boot on
success without a fast-finish hook race.  **Planned:** extend it with a
readiness rule -> attach/execute-test sequence, apply equivalent frozen-plan
semantics to future custom-QEMU chains, and record durable run identity.

The first two steps of the debugger integration already use built-in `M-x gdb`
on the profile's `vmlinux` and connect to the configured target; the vng path
uses the context pinned to its managed debug guest and the frontend's current
fixed GDB endpoint.  **Planned:** add explicit endpoint-readiness checks and
make kernel GDB helper scripts available without editing `~/.gdbinit`.
Doctor should report the relevant kernel debug configuration, debug info,
frame pointers, KASLR choice, GDB Python support, and source path mapping.
Optional Dape support can follow only after remote-kernel and kernel Python
helper behavior is covered by tests.

QMP pause/resume/reset/powerdown/quit actions change guest state and must target
the named live run.  Graceful powerdown should precede force quit.

### 9. High-leverage workflows (P2)

#### Change-impact planner

**Implemented baseline:** a staged/range, path-classification report provides
clickable heuristic build/configuration/Sparse/test/checkpatch suggestions and
does not execute them while planning.

**Planned:** evolve it into a provenance-aware editable plan containing:

- touched subsystems and maintainers;
- likely object/directory/module build targets;
- source translation units affected by changed headers;
- Kconfig symbols that gate touched objects;
- relevant KUnit/kselftest targets and repository-local test hints; and
- selected architecture/compiler profiles.

The Kbuild and header graph is conditional and sometimes generated.  The
current report labels every recommendation heuristic.  A richer plan must
distinguish exact edges from inferred ones individually and allow edits before
running a multi-profile matrix.

#### Review-to-validation

Create a disposable review worktree for a b4 series, clone only profile
settings (not stale artifacts), run the edited impact plan, and retain a
manifest suitable for a human-written review reply.  A passing manifest may
suggest a `Tested-by` draft but cannot add or send it.

#### Bisect cockpit

Persist the good/bad endpoints, build profile, boot recipe, test command,
current commit, classification history, and raw logs.  Distinguish a bad test
from an unbuildable commit and offer `git bisect skip`.  Never reset unrelated
working-tree changes; prefer a dedicated worktree.

#### Runtime tracing

Add ftrace presets and function-at-point filters after log streaming and
privileged-action confirmation are mature.  Capture the exact tracefs state
changed by kmode-emacs and offer a scoped restore operation.

## Capability degradation

Every bundled Lisp module depends only on Emacs libraries.  The top-level mode
loads all bundled modules; external executables remain capability-specific.
Action predicates are checked for presentation and again before dispatch.

| Missing component | Current or planned degraded behavior | Status |
| --- | --- | --- |
| `rg` | Use Emacs Kconfig scan/file enumeration where implemented | Implemented |
| Eglot or `clangd` | Keep Xref/grep/include/Kconfig/Kbuild navigation | Implemented |
| compilation database | Keep textual navigation and reject Eglot startup with remediation | Implemented |
| `make` | Keep editing, textual navigation, saved logs, and applicable Git review commands | Implemented through action predicates/command validation |
| checkpatch/get_maintainer | Disable only the associated review actions | Implemented |
| Python/KUnit script | Disable KUnit actions; leave Kselftest/build independent | Implemented |
| QEMU | Preserve builds, checks/tests, saved/local logs, and non-QEMU GDB targets | Implemented |
| `vng`/`virtme-ng` | Disable only virtme-ng build/run/debug actions; preserve custom QEMU, builds, logs, and navigation | Implemented |
| usable virtme-ng guest root for a cross runtime | Refuse run/debug/preview/exec before upstream can auto-provision; preserve cross-build, native, and custom-QEMU workflows | Implemented |
| trust for nonempty vng `default_opts` | Refuse vng operations and explain the explicit trust customization; trusted but unknown/managed/ill-typed values still fail closed | Implemented |
| GDB | Preserve QEMU and log/decoder operations | Implemented |
| Magit | Use Git subprocesses or omit enhanced status/diff views | Planned adapters only |
| Notmuch/Gnus | Accept Message-ID/URL manually | Planned patch-series layer |
| b4 | Keep current checkpatch/Git/format-patch operations, omit network/apply/send | Planned patch-series layer |
| root access | Keep read-only inspection and guard privileged runtime writes/tests | Planned explicit privilege model |
| Sparse | Preserve ordinary builds; explicit Sparse invocation reports the missing tool | Implemented |
| Smatch or Coccinelle | Disable only its registered analyzer action | Implemented |
| Clang analyzer prerequisites | Disable only the analyzer action; other Clang builds/Eglot remain independent | Implemented |
| checkstack prerequisites/artifact | Disable only checkstack and retain other checks | Implemented |

## Safety invariants

**Implemented guards:** commands require a recognized tree; external
Compilation commands shell-quote each argv item; Make goals, Kselftest
collection names, and Git revisions/ranges read from the minibuffer are
restricted; managed build/test/QEMU/vng environments remove ambient Kbuild
selectors and untrusted checkout-contained child `PATH` entries;
canonical output ownership rejects overlapping writable jobs; the clean
command shows and confirms the resolved output; patch export asks before
writing outside the tree; and review code has no sender.  QEMU receives a
configured argv directly rather than a shell fragment and verifies readable
image/`vmlinux` artifacts referenced through `%i`/`%v`; GDB and decoding also
require a readable `vmlinux`.  Virtme-ng operations construct validated argv,
pin their context, reject managed/reserved selector overrides, require an
existing readable/searchable root for cross-architecture runtime, and refuse
upstream `default_opts` until explicitly trusted.  Trusted defaults remain
subject to the known destination/type/range/shell-safety schema.  Explicit or
enabled-default host-sensitive vng options prompt.  vng build/preview/live
guests own their canonical output; enabled debug/pin/SSH/console facilities
take a process-global lock, and effective debug/console/SSH ports take named
TCP resources that also collide with recognized raw-QEMU endpoints.  Chained
build/boot freezes a preflighted context/config/HOME/environment/argv/resource
plan and revalidates it before a no-focus-steal launch.  kmode-emacs itself never
invokes `sudo` or installs a tool; a trusted external recipe or validated
trusted upstream default can still do so.  These guards do not make trusted profile arguments, an edited
`kmode-compile` shell command, tree-local scripts, kernel tests, or a custom
QEMU/vng recipe harmless.  A vng preview means no final QEMU launch, not a
filesystem-side-effect-free operation.  The one guest-command string is passed
as one host argv element but is intentionally interpreted by the guest shell.
Live checkpatch is opt-in, cancels stale work, and cleans its source snapshots,
but after activation normal Flymake triggers run the trusted tree-local script.

The following are requirements for the remaining roadmap, not claims about
features that do not exist yet:

1. **No hidden send.** Mail is rendered and recipients are shown before any
   network send.  Sending requires a dedicated final action.
2. **No hidden history mutation.** Applying a series, rebasing trailers,
   bisecting, or creating/removing worktrees shows repository and branch state.
3. **No guessed destructive target.** Clean, module unload/reload, VM force
   quit, debugfs/tracefs writes, and file replacement resolve exact targets and
   require confirmation proportional to risk.
4. **No wrong-symbol confidence.** Crash decoding/debug sessions expose the
   source revision and artifact identity; mismatches are errors or prominent
   warnings.
5. **No writable base image by default.** QEMU tests use snapshots/overlays
   unless the user explicitly selects persistent disk writes.
6. **No broad compiler execution allowlist.** `--query-driver` entries are
   narrow, user-approved paths.
7. **No unquoted profile interpolation.** Arguments are represented as lists
   and validated.  Runtime Comint processes receive direct argv; commands
   using Emacs's Compilation interface shell-quote each item at that boundary.
8. **No global editor takeover.** Style, Eglot configuration, compilation
   variables, and navigation backends are buffer/project local.
9. **No unbounded background surprise.** Full-tree indexing, compile-database
   builds, analysis, and tests are explicit, cancellable jobs.
10. **No automatic credential management.** kmode-emacs delegates Git, SMTP/b4,
    SSH, and privilege authentication to their normal tools.

## Performance and compatibility hazards

- The kernel is too large for synchronous recursive Lisp scans during mode
  activation.  The current Kconfig and source/header fallbacks are acceptable
  explicit commands but should become asynchronous/bounded where possible.
- A build output and clangd index are meaningful only for one configuration.
  Reusing them across profile switches creates plausible but wrong results.
- Generated headers and diagnostic paths live under `O=` and need explicit
  mapping back to source buffers.
- `tools/` has its own build behavior and is absent from the kernel-generated
  compilation database; it needs a separate project/database strategy.
- Kernel versions differ in Make targets, script locations, and output formats.
  Feature detection is more reliable than a version-number table.
- b4 review keys, files, CLI output, and database are alpha.  Depend only on
  documented commands and isolate parsing by detected b4 version.
- QEMU Unix socket paths have host length limits; runtime paths must be short.
- Current public vng debug/QMP endpoints are fixed host ports.  kmode-emacs
  serializes global vng facilities and gives effective debug/console/SSH ports
  names shared with managed raw-QEMU endpoint locks, but an unmanaged process
  or another Emacs instance can still collide with them.
- Trusted vng `default_opts` are typed and allowlisted by kmode-emacs but remain
  upstream configuration applied after CLI parsing.  A config change therefore
  invalidates a frozen launch plan, and an unsupported future destination
  fails closed until classified.  vng preview may also prepare output-tree
  state.
- Process filters receive partial chunks.  Log, TAP, QMP, and diagnostic
  parsers must retain incomplete records across calls.
- Remote/TRAMP file names, cross-built debug paths, module relocation, and
  KASLR complicate source mapping.  Local QEMU is the first supported target.
- Checkpatch and static tools can report existing or intentional issues.
  Dashboards must distinguish new/change-local findings from the full stream
  without suppressing evidence.

## Testing strategy

**Implemented:** `make check` first byte-compiles every package/test file with
warnings as errors, then runs ERT in `emacs -Q`, then runs Checkdoc.  The
fixture-based ERT suite covers module loading, root/cache/profile/context
rules, shell quoting, output isolation/serialization, worktree cancellation,
ambient Kbuild and checkout-`PATH` sanitization, Kbuild argv validation, KUnit
directory isolation, containment and checkout-safe tool discovery, action behavior, diagnostic
matching, navigation and its definition/callers/back bindings, Kconfig source
resolution, QEMU argv expansion and endpoint ownership, virtme-ng
profile/config/HOME/root/architecture validation and exact
build/run/debug/preview/exec argv, dispatcher/dashboard/action/keymap
behavior, mode teardown, Project integration, and
live-checkpatch parsing, direct process argv, supersession/cleanup, failure
reporting, and backend coexistence.  vng tests also cover its canonical
long-option parser, typed trusted defaults, direct Comint spawn, pinned process
context/environment, frozen build-to-boot preflight, canonical-output/global
and named TCP locking, orphan/stop handling, and unsafe-option/default-option
guards.  CI runs the same target on Emacs
28.1, 29.4, and 30.2.

The suite does not currently cover the analysis/impact planners in depth,
perform real kernel or vng builds/tests, boot QEMU or a vng guest, attach GDB,
request a real vng dump, or exercise Git/review and decoder subprocesses end
to end.  Neither `vng` nor `virtme-ng` was installed for the implementation
run, so all current vng coverage is hermetic.
**Planned** layers include:

- fake subprocesses with split output chunks, nonzero exits, cancellation, and
  paths containing spaces/metacharacters;
- golden Compilation/log/KTAP/TAP/checkpatch samples with upstream-version
  labels;
- isolated temporary Git repositories/worktrees for review adapters and
  safety guards, with network calls mocked by default;
- QEMU command and QMP state-machine tests without requiring virtualization;
- opt-in vng build/boot/debug/dump smoke tests where virtualization and a
  suitable guest root are available; and
- opt-in integration tests against an actual kernel checkout and installed
  toolchain.

Every regression for a destructive or external action should assert both the
positive operation and the guard that prevents the wrong target.

## Milestones

### M0: truthful foundation — implemented

- [x] strict kernel-root discovery and cache
- [x] profile/context resolution and refinement hook
- [x] action registry and capability predicates
- [x] Compilation-mode process plumbing
- [x] first kernel-aware navigation commands
- [x] dedicated navigation prefix map
- [x] profile-output-aware Eglot startup
- [x] automated ERT/byte-compile/Checkdoc coverage and CI
- [x] top-level loader, project/globalized minor modes, prefix/menu, and dispatcher
- [x] initial dashboard and doctor/capability view
- [x] Kconfig major mode

### M1: edit-build-navigate — partly implemented

- [x] context-consistent Kbuild argv and root/profile-specific buffers
- [x] config targets and inferred object/directory builds
- [x] explicit compilation-database generation command
- [x] kernel C style scoped to recognized-tree buffers
- [x] maintainer lookup plus Kconfig/Kbuild navigation
- [x] active-profile/worktree live-process discovery, interruption, and
      canonical-output serialization
- [x] sanitized, profile-owned remap for edited compilation commands
- [x] default stale-Eglot shutdown on profile selection
- [ ] durable job history/results, module inference, and richer diagnostics
- [ ] compilation-database fingerprint/staleness and tracked Eglot reconnect
- [ ] combined provenance-aware context-at-point view

### M2: validate-review — partly implemented

- [x] checkpatch scopes/live Flymake, whitespace flight check, Sparse,
      warnings, Smatch, Coccinelle report, Clang analyzer, checkstack, and
      range-diff
- [x] raw-output KUnit and selected Kselftest runners
- [x] local format-patch export without sending
- [ ] structured static-analysis/KTAP/TAP views and rerun-failed
- [ ] b4 review/contributor adapters with isolated worktrees
- [ ] series validation manifests and guarded preview/send

### M3: run-debug — partly implemented

- [x] configured QEMU Comint process and interrupt
- [x] first-class virtme-ng build/run/guest-command/preview/debug/attach/dump/stop
      workflow and prefix map with output and shared-runtime locks
- [x] local/file log incident highlighting and stacktrace decoding
- [x] built-in GDB launch against profile `vmlinux`/remote target
- [ ] serial/QMP/gdbstub lifecycle with protected disks and run identity
- [ ] verified stack decoding and kernel GDB helpers
- [ ] dynamic-debug controls

### M4: workflow intelligence — partly implemented

- [x] read-only staged/range heuristic impact plan with opt-in action buttons
- [ ] dependency/provenance-rich impact plan and cross-profile matrix
- review-to-validation automation with human trailer approval
- reproducible bisect cockpit
- ftrace and advanced remote/runtime adapters

## Open design questions

- Should shareable profiles live only in Emacs configuration, or in a
  non-executable, versioned project file with separate per-user secrets/paths?
- What stable identity should distinguish two active profiles of the same
  source root to Eglot and Project without confusing ordinary project commands?
- How should header-to-translation-unit choices be persisted without editing a
  generated database?
- Which b4 output has a documented machine-readable form sufficient for a
  native dashboard, and which flows should simply launch upstream's TUI/helper?
- What artifact identity is reliable across compressed kernels, modules,
  remote machines, and distro builds when a build ID is unavailable?
- Which privileged transport (local helper, TRAMP/SSH, or user-supplied command)
  provides the clearest audit and confirmation boundary?

Until these questions are settled, extensions should avoid persisting private
state formats outside the documented context and action APIs.
