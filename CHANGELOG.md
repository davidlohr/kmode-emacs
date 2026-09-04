# Changelog

All notable user-visible changes to Kemacs will be documented here.  The
project is pre-release; interfaces may change before 1.0.

## [Unreleased]

### Added

- A task-oriented getting-started guide covering safe out-of-tree profiles,
  the first build, dashboard operation, semantic definition/caller setup, the
  complete navigation map, initial virtme-ng workflows, and troubleshooting;
  the README now leads with the same critical first-session path.
- Public-repository hygiene for generated Emacs artifacts and local agent
  workspace state, plus bug-report and pull-request templates and a security
  reporting policy.
- Initial `kemacs-mode` 0.1.0 development implementation for Emacs 28.1 and
  newer, including a globalized auto-enable mode, kernel-local `C-c k` command
  map/menu, mode-line profile, Emacs Project integration, scoped Linux C style,
  profile-derived `compile-command`, and a profile-owned remap for edited
  compilation commands.
- Kernel-root discovery, per-worktree session profiles, buffer overrides,
  context refinement/change hooks, root/profile-namespaced process buffers,
  active-profile/worktree process discovery and worktree-wide interruption,
  canonical build-directory serialization, capability predicates, and shared
  Compilation-mode process plumbing.
- Completion dispatcher, read-only flight-deck dashboard, capability doctor,
  distinct active-profile/worktree live-job counts, and extension-facing
  action registry.
- Profile-aware Kbuild commands for default/explicit targets, the current
  object/directory, configuration targets, `compile_commands.json`, Sparse,
  and confirmed cleanup, with ambient Kbuild-selector sanitization;
  checkout-contained child `PATH` entries are removed unless explicitly listed
  in `kemacs-build-trusted-path-directories`; `menuconfig` uses an interactive
  Term buffer.
- Optional profile-aware extra-warning, Smatch, report-only Coccinelle, Clang
  analyzer, and checkstack commands with tool/target/artifact checks.
- Kernel-aware Kconfig/include/Kbuild/source-header/Documentation navigation,
  definition/caller/back commands, profile-aware Eglot/clangd startup, and a
  dedicated `C-c k n` navigation map.  The Kconfig mode provides indentation,
  font lock, Imenu, and contained root-relative/relative source following with
  distinct ARCH/SRCARCH expansion.  Profile switches stop stale worktree Eglot
  servers by default and leave restart explicit.  Standard Xref `M-.`, `M-?`,
  and `M-,` navigation remains available alongside the prefix aliases.
- File/range/staged/region checkpatch, file maintainer discovery, range-diff,
  local patch-series export, submission-guide access, and a non-sending
  pre-submission flight check, with revision/range validation and failure-safe
  temporary-patch cleanup.
- Disabled-by-default asynchronous checkpatch Flymake mode for unsaved C,
  assembly, and Rust text, with additive backend registration, stale-process
  cancellation, diagnostic mapping, and temporary-resource cleanup.
- Read-only staged/range change-impact reports with heuristic, opt-in build,
  configuration, check, test, and review action buttons.
- KUnit run/configure/build/filter commands using isolated per-profile build
  directories and Kselftest collection/current-collection commands derived
  from the active build profile.
- Configured QEMU launch/interrupt, built-in Emacs GDB attachment, local/saved
  kernel-log views, incident navigation, referenced image/`vmlinux` checks, and
  profile-based stacktrace decoding.  Managed QEMU uses a sanitized
  checkout-isolated environment and reserves recognized `-s`/`-gdb`/`-qmp`
  TCP-port or source-root-relative Unix-socket resources.
- First-class virtme-ng integration under `C-c k v`: profile-aware vng builds,
  existing-output run/guest-command/preview/debug flows, build-then-run/debug,
  GDB attachment, memory dumps, exact command display, and worktree-wide guest
  stopping.  It uses the public `vng` frontend (with the official `virtme-ng`
  executable alias), direct runtime argv, pinned contexts, canonical-output and
  shared-host-facility locks, plus named debug/console/SSH TCP locks shared with
  raw QEMU.  Hardened profile handling includes an exact canonical long-option
  allowlist, coherent ambiguous/cross-architecture resolution, build-only root
  omission, cross-runtime root enforcement, fixed
  `kemacs-vng-home-directory` config discovery, typed fail-closed trusted
  `default_opts`, dangerous-option confirmation, and checkout-safe child
  `PATH`.  Build-then-run/debug preflights and freezes the runtime plan before
  Compilation starts, revalidates it on success, and launches without stealing
  focus.
- Hermetic ERT fixtures, warning-fatal byte compilation, Checkdoc, Make
  targets, and CI coverage for Emacs 28.1, 29.4, and 30.2, including vng argv,
  canonical-option/default/config/HOME/architecture/PATH safety, frozen-chain,
  endpoint-locking, process/action/keymap tests, and navigation shortcut
  coverage.  No real vng build, guest boot, GDB attach, or dump was exercised
  in the implementation environment because neither vng executable was
  installed.
- README, design/roadmap, contribution, safety, capability-degradation, and
  extension documentation grounded in upstream Linux, Emacs, clangd, b4,
  KUnit/Kselftest, QEMU, and virtme-ng interfaces.
