# Changelog

All notable user-visible changes to kmode-emacs will be documented here.  The
project is pre-release; interfaces may change before 1.0.

## [Unreleased]

### Added

- An explicitly enabled global `C-c k` launcher.  `C-c k k` uses the current
  kernel root, otherwise reuses the last valid session root, tries
  `kmode-default-root`, or prompts; `kmode-select-root` / `C-c k R` selects a
  new remembered root and a dashboard prefix argument always prompts.  These
  are the only outside-tree entry points; other prefix commands require a
  kernel buffer or dashboard context.  Buffer-local editing behavior remains
  restricted to recognized kernel-tree files.
- Profile-aware kernel index generation: `kmode-build-tags` / `C-c k n t`
  runs `make TAGS`, and `kmode-build-cscope` / `C-c k n C b` runs
  `make cscope`.  `kmode-auto-activate-tags` optionally binds the selected
  profile's readable output table buffer-locally;
  `kmode-refresh-tags-table` reapplies that policy, and profile selection
  refreshes TAGS plus compile-command state across enabled worktree buffers.
  Xref remains the standard interface and Etags is documented as a non-semantic
  fallback.  TAGS/cscope availability checks do not pre-detect kernel Make
  targets, so unsupported targets fail visibly in Compilation.  Documentation
  identifies the active profile's exact TAGS, cscope, compilation-database, and
  clangd-shard paths and distinguishes clangd's external-header user cache.
- An optional, feature-detected xcscope adapter under `C-c k n C` for
  definitions, callers, callees, symbols, text, and includers.  Build and
  status paths are pinned to the selected profile output, and queries require
  that output's readable `cscope.out` rather than accepting `cscope.files` or
  another profile's source-tree database.  Each call dynamically binds the
  chosen database directory, standard names, query-only behavior, resolved
  cscope program, kernel mode, and source working directory; Kmode has no
  load-time xcscope dependency and does not configure `consult-cscope`.
- The complete CC Mode offset table from the kernel documentation,
  including its exact tab-only argument-list continuation/closing behavior,
  plus an 80-column fill target and buffer-local trailing-whitespace and
  final-newline values under a master C-style switch.
- Managed Kbuild output selectors cannot be replaced by free-form Make arguments; profiles must use `:output`, keeping locks and index locations coherent.
- A truthful editor-integration policy covering Eglot/clangd, TAGS,
  optional dynamically scoped xcscope, user-owned consult-cscope, TRAMP, and
  diff gutters, grounded in upstream kernel documentation and cited community
  prior art.  Kmode-owned TAGS/cscope jobs are explicit and cancellable;
  clangd background indexing begins after explicit Eglot startup and remains
  owned by Eglot/clangd.  `kmode-clangd-arguments` now defaults to background
  indexing, detailed completion, and no automatic header insertion; clang-tidy
  is opt-in.
- The project is published as `kmode-emacs`; files, features, commands,
  customization variables, process buffers, tests, and documentation use the
  `kmode-` namespace before the first stable release.
- A task-oriented getting-started guide covering safe out-of-tree profiles,
  the first build, dashboard operation, semantic definition/caller setup, the
  complete navigation map, initial virtme-ng workflows, and troubleshooting;
  the README now leads with the same critical first-session path.  Updates
  require an Emacs restart; re-running `require` does not reload an already
  provided feature or rebuild its keymaps.
- Public-repository hygiene for generated Emacs artifacts and local agent
  workspace state, plus bug-report and pull-request templates and a security
  reporting policy.
- Initial `kmode-emacs` 0.1.0 development implementation for Emacs 28.1 and
  newer, including a global launcher/auto-enable mode, `C-c k` command map/menu,
  mode-line profile, Emacs Project integration, scoped Linux C style,
  profile-derived `compile-command`, and a profile-owned remap for edited
  compilation commands.
- Kernel-root discovery, per-worktree session profiles, buffer overrides,
  context refinement/change hooks, root/profile-namespaced process buffers,
  active-profile/worktree process discovery and worktree-wide interruption,
  canonical build-directory serialization, capability predicates, and shared
  Compilation-mode process plumbing.
- Completion dispatcher, read-only flight-deck dashboard, capability doctor,
  status for six active-profile paths (`.config`, `compile_commands.json`,
  `.cache/clangd/index/`, `TAGS`, `cscope.out`, and `vmlinux`),
  Etags/cscope/xcscope checks, distinct active-profile/worktree live-job counts,
  and an extension-facing action registry.  Dashboard status is
  `ready · <mtime>`/`missing`; Doctor uses `[OK]`/`[--]` plus the path, and both
  are readability checks rather than freshness validation.
- Profile-aware Kbuild commands for default/explicit targets, the current
  object/directory, configuration targets, `compile_commands.json`, Sparse,
  and confirmed cleanup, with ambient Kbuild-selector sanitization;
  checkout-contained child `PATH` entries are removed unless explicitly listed
  in `kmode-build-trusted-path-directories`; `menuconfig` uses an interactive
  Term buffer.
- Optional profile-aware extra-warning, Smatch, report-only Coccinelle, Clang
  analyzer, and checkstack commands with tool/target/artifact checks.
- Kernel-aware Kconfig/include/Kbuild/source-header/Documentation navigation,
  definition/caller/back commands, profile-aware Eglot/clangd startup, explicit
  TAGS/cscope generation, and a dedicated `C-c k n` navigation map with an
  optional `C-c k n C` xcscope submap.  The Kconfig mode provides indentation,
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
  `kmode-vng-home-directory` config discovery, typed fail-closed trusted
  `default_opts`, dangerous-option confirmation, and checkout-safe child
  `PATH`.  Build-then-run/debug preflights and freezes the runtime plan before
  Compilation starts, revalidates it on success, and launches without stealing
  focus.
- Hermetic ERT fixtures, warning-fatal byte compilation, Checkdoc, Make
  targets, and CI coverage for Emacs 28.1, 29.4, and 30.2, including vng argv,
  canonical-option/default/config/HOME/architecture/PATH safety, frozen-chain,
  endpoint-locking, process/action/keymap tests, and navigation shortcut
  coverage.  Real vng builds, guest boots, GDB attaches, and dumps remain
  explicit integration smoke tests outside the hermetic suite.
- README, design/roadmap, contribution, safety, capability-degradation, and
  extension documentation grounded in upstream Linux, Emacs, clangd, b4,
  KUnit/Kselftest, QEMU, and virtme-ng interfaces.
