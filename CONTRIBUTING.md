# Contributing to kmode-emacs

kmode-emacs is an early Linux-kernel development environment for Emacs.  Small,
well-tested changes that preserve a transparent command line are preferable to
large integrations that duplicate Kbuild, b4, GDB, or another upstream tool.

Use [GitHub issues](https://github.com/davidlohr/kmode-emacs/issues) for
reproducible bugs and focused design proposals, and
[pull requests](https://github.com/davidlohr/kmode-emacs/pulls) for reviewed
changes.  Do not disclose vulnerabilities in a public issue; follow
[SECURITY.md](SECURITY.md) instead.  There is no published release process or
project mailing list yet.

## Development setup

The implemented modules require GNU Emacs 28.1 or newer and only core Lisp
libraries.  From a clone, start a clean development session with:

```sh
emacs -Q -L .
```

Then evaluate:

```elisp
(require 'kmode-emacs)
(kmode-global-mode 1)
```

Use a real or minimal fixture kernel tree for interactive commands.  A
recognized root currently needs `Makefile`, `Kconfig`, `MAINTAINERS`, and
`scripts/checkpatch.pl`.

Before submitting a change, run the complete local gate:

```sh
make check
```

This cleans and byte-compiles all `kmode*.el` and the test file with warnings
as errors, runs ERT under `emacs -Q`, and runs Checkdoc.  The individual
targets are `make compile`, `make test`, and `make checkdoc`; `make clean`
removes generated `.elc` files.  Do not include those files in a patch.  CI
runs `make check` on Emacs 28.1, 29.4, and 30.2.

Use a real kernel checkout only for opt-in integration smoke tests.  Default
tests must remain hermetic and must not build a kernel, use the network,
require privilege, boot QEMU or virtme-ng, attach GDB, request a VM dump, or
send mail.  Neither `vng` nor its official `virtme-ng` executable alias was
installed for the initial integration, so the current vng tests validate
kmode-emacs behavior without running the upstream frontend.

## Project boundaries

Keep the dependency direction simple:

1. `kmode-core.el` contains root discovery, profiles/contexts, capability
   primitives, action registration, and generic process plumbing.
2. Feature modules require the core and register their own actions.  Runtime
   policy and vng-specific validation belong in `kmode-debug.el` and
   `kmode-virtme.el`, not in the generic process layer.
3. `kmode-emacs.el` is the top-level loader/project-mode integration and may
   require feature modules; the core must never require it.
4. Optional integrations are loaded with `require`'s no-error form or after a
   capability check; they are not reasons for the package itself to fail to
   load.

kmode-emacs is an umbrella minor-mode environment, not a replacement C major mode.
The dedicated `kmode-kconfig-mode` is appropriate because Emacs has no
built-in Kconfig mode used here.

Do not globally change C indentation, `compile-command`, Xref backends, Eglot
server settings, display rules, or user key bindings.  Scope editor changes to
recognized kernel buffers/projects and restore them when appropriate.

## Profiles and contexts

Every external operation must begin with `kmode-resolve-context`; do not read
one profile variable and silently ignore the others.  Keep `O=`, `ARCH`,
`CROSS_COMPILE`, compiler family, jobs, extra Make arguments, image, and debug
artifacts coherent.  A virtme-ng consumer must also keep the mapped/overridden
vng architecture, guest root, append values, common/debug/build arguments, and
vng-specific Make assignments in that same immutable context.  Ordinary
`:make-arguments` are not vng build arguments; only `:vng-make-arguments`
crosses vng's `--` boundary.  Keep vng architecture inference conservative:
generic word-size/endianness-ambiguous kernel names need an exact native match,
a recognized cross compiler, or `:vng-arch`, and every supplied source must be
coherent.  A cross build omits the runtime root; cross run/debug/preview/exec
must validate an existing root before upstream can auto-provision.
Profile-managed builds, tests, and runtimes must use
`kmode-build-process-environment` so inherited Kbuild selectors cannot
silently replace that context.

Use the generated `kmode-context-*` accessors.  Do not depend on a struct's
printed representation or the storage layout of `kmode--selected-profiles`.
Paths received from a user must be expanded against the documented root,
checked for the operation's required containment, and passed as one argument.

`kmode-context-functions` is for quick, deterministic context refinement.
Callbacks must not prompt, start processes, perform network requests, or scan a
kernel tree.  Return the context or nil as documented.

When adding a context field:

- document its type, relative-path rules, and precedence;
- decide whether a corresponding file-local variable can actually be safe;
- add validation at the boundary that consumes it; and
- update README profile examples and `docs/design.md`.

Do not mark arbitrary command strings, executable paths, network endpoints, or
privileged settings as safe local variables.

## Actions and capabilities

Register user-facing operations with `kmode-register-action` so the current
dispatcher and dashboard can discover them.  Action IDs must be globally
unique symbols.  Choose stable, verb-first command names with the `kmode-`
prefix and provide docstrings suitable for `describe-function`.

An action predicate should be fast, noninteractive, and side-effect-free.  It
is only a presentation hint: the command itself must repeat tool, context,
state, and safety validation at invocation time.  Predicates can fail safely
and are treated as unavailable by the registry.

Missing optional software should remove or disable only its own feature.  Error
messages should name the missing executable/library, state what remains
available, and give a direct next step without attempting installation.

Pass bare host-tool names to `kmode-tool-path` only when resolution through
`exec-path` is intended.  Pass checked-out helpers with an explicit directory
component such as `scripts/checkpatch.pl`; relative explicit paths resolve
from the kernel root and, like absolute paths, must be executable.
Bare resolution must continue to exclude empty, relative, and checkout-contained
search directories.  Managed child environments must filter the same entries;
add an absolute directory to `kmode-build-trusted-path-directories` only as a
reviewed escape hatch for an intentional checkout tool shim.  That child-PATH
exception must not silently broaden bare `kmode-tool-path` resolution.

## External commands

Prefer argument lists throughout the implementation.  Quote only at the final
Compilation-mode boundary with `kmode-shell-command`, or use a direct process
API when shell behavior is unnecessary.  Never concatenate untrusted profile,
file, Message-ID, branch, or remote-target text into a shell fragment.
Interactive QEMU and virtme-ng guests must use direct process argv.  The vng
guest-command value is the documented exception: keep it as one host argv
element, validate it, and make clear that vng deliberately evaluates it in the
guest shell.  Direct spawn does not erase upstream shell reconstruction: keep
the conservative vng runtime-token/path validation unless upstream replaces
that boundary and tests establish the new contract.

External work should normally be asynchronous and cancellable.  Preserve:

- the exact command and working directory;
- resolved root/profile;
- start/end time and exit state;
- raw output; and
- artifact identity needed to reproduce or interpret the result.

Any command that writes a build directory must pass that directory as the
resource to the shared process launcher.  This serializes aliases and profiles
that resolve to the same canonical output.  KUnit must retain a separate build
directory rather than treating the profile's ordinary output itself as
scratch configuration state.  Edited compilation commands should go through
`kmode-compile`, the mode's managed `compile` remap.

Runtime processes that consume a profile output must retain its canonical
resource for their lifetime so a build cannot mutate the running kernel's
tree.  Keep one managed vng guest per root/profile.  vng operations exposing
shared host facilities such as fixed debug, pin, SSH, or console endpoints
also need the process-global resource when enabled by explicit arguments or
validated defaults.  Give effective debug ports 1234/3636 and console/SSH
server ports (default 2222 when omitted) canonical `tcp-port:` resources.
Raw QEMU `-s`/`-gdb`/`-qmp` parsing must use the same TCP identity and resolve
relative `unix:` paths from the source root.  Discovery, stop, attach, and
sentinels must use the context captured on the process, never the buffer's
newly selected profile.

For a chained build and runtime, finish all run-only validation and
host-access confirmation before compiling, then freeze the copied context,
program/argv, sanitized environment, HOME, config digest, validated defaults,
trust state, and resources.  Install the finish callback before Compilation
starts, associate success with that exact process, and revalidate external
trust input/output/resource availability before spawn.  Automatic completion
must not select the runtime buffer or steal focus.

Parsers must handle output split at arbitrary process-filter boundaries.  Keep
raw evidence even when adding structured properties or summaries.

Do not run a full build, clangd index, Coccinelle scan, test suite, network
fetch, or recursive Lisp scan merely because a file was opened.

## Safety review

Any change that can send mail, alter Git history/worktrees, write outside the
build/runtime area, install or unload modules, write debugfs/tracefs/sysfs,
change a live VM, use privilege, or execute a compiler from project data needs
an explicit safety section in its change description.

At minimum, verify that the implementation:

1. resolves and displays the exact target;
2. offers a dry run or rendered preview where the upstream tool supports it;
3. requires a separate affirmative user action for irreversible/external
   effects;
4. cannot reuse stale state from another profile or worktree;
5. preserves unrelated working-tree and editor state; and
6. reports partial failure and a recovery path.

Never add `Reviewed-by`, `Acked-by`, `Tested-by`, or another identity trailer on
the user's behalf.  Never send a patch as a side effect of formatting or
checking it.  Never silently pair a crash log with an unverified `vmlinux`.

QEMU tests should default to a read-only base disk plus snapshot/overlay.
For virtme-ng, reject missing guest roots rather than permitting upstream's
automatic network/`sudo` provisioning during runtime; reserve kmode-emacs-owned
action/output/architecture/debug switches; accept only explicitly classified
canonical long profile options (no short flags or argparse abbreviations); and
prompt for explicit or enabled-default host-sensitive disk, directory, custom
QEMU, device, network, SSH, console, password, or systemd options.  Pin child
`HOME` to `kmode-vng-home-directory` and inspect exactly its
`.config/virtme-ng/virtme-ng.conf`, then `.virtme-ng.conf`, then the system
`/etc/virtme-ng.conf`.  Fail closed on nonempty `default_opts` unless the user
explicitly enables the trust customization; even then reject unknown,
duplicate, managed, ill-typed, out-of-range, or shell-unsafe defaults.  A vng
`--dry-run` preview means “do not launch QEMU,” not “no filesystem writes.”
Compiler query-driver allowlists must be narrow and user-approved.  See the
safety invariants in [docs/design.md](docs/design.md).

## Emacs Lisp style

- Keep `lexical-binding: t` file headers and package metadata accurate.
- Use two-space indentation, complete docstrings, and the `kmode-` namespace.
- Use `cl-defstruct` accessors and public Emacs APIs instead of editing internal
  representations owned by another package.
- Prefer buffer-local variables and hooks.  Remove hooks, advice, timers,
  process sentinels, and temporary buffers when their owner stops.
- Use `user-error` for actionable invocation mistakes and ordinary errors for
  broken invariants/programming defects.
- Avoid broad advice around Project, Eglot, Compilation, Magit, or GDB.  Prefer
  documented extension points and small adapters.
- Keep synchronous filesystem work bounded.  A Linux tree is large and may be
  on a remote or slow filesystem.
- Add autoload cookies to interactive entry points intended to work before a
  feature module is loaded.

When adding a customization, put it in the `kmode` group, give it a precise
Custom type, and state whether changing it affects existing jobs/sessions.

## Tests expected with new features

Every behavior change should extend the ERT fixture suite in
`test/kmode-test.el`.  Keep tests independent of personal Emacs setup and
assert failure guards as well as successful construction.

| Area | Minimum coverage |
| --- | --- |
| Context | buffer/profile/default precedence, refresh hooks, relative paths, invalid jobs/compiler values |
| Root/project | positive tree, missing marker, cache/override, collision-resistant root ID, Project protocol |
| Mode/UI | activation guard, restoration, keymap, action origin/availability, dashboard isolation |
| Actions | replacement by ID, sorting, unavailable/erroring predicates, invocation recheck |
| Commands | argv/quoting, whitespace/metacharacters, bare/explicit executable resolution, unique buffers, nonzero exit, worktree cancellation |
| Build/test | full profile argv, ambient-variable sanitization, target injection guards, canonical-resource serialization, KUnit isolation, filters/collections |
| Analysis | target/tool gates, `W=`/`C=` levels, root-contained scopes, safe report-only defaults |
| Navigation/Kconfig | generated/arch includes, CONFIG normalization, Kbuild, source/rsource bases, variable expansion, symlink containment, indentation, and `C-c k n` bindings |
| Review/impact | safe revision/range syntax, failure-safe temporary files, NUL paths, classification/dedup/caps, no planning-time execution |
| Flymake | severity/location parsing, direct argv, unsaved snapshots, stale cancellation/cleanup, coexistence |
| Parsers | partial chunks, ANSI text, malformed lines, upstream-version samples, clickable locations |
| Runtime/QEMU | argv token expansion, sanitized environment/checkout PATH, process collision, canonical-output ownership, normalized TCP/source-root-relative Unix endpoint locks, stale sentinels, base-image protection |
| virtme-ng | exact build/run/debug/preview/exec argv; canonical long-option schema with no short/abbreviated forms; coherent ambiguous/cross architecture and build-vs-runtime root handling; pinned HOME/config candidates and typed trusted-default guards; direct runtime spawn vs quoted Compilation boundary; frozen race-free build/boot plan; output/global/debug/console/SSH endpoint locks; orphan/stop behavior; actions and `C-c k v` keys |
| Logs/debug | artifact mismatch, KASLR/module cases, decoder argv and source locations |

Network, privilege, mail, and virtualization tests must be opt-in.  The default
test suite must be hermetic and safe to run in an arbitrary checkout.

## Documentation and changelog

Documentation is part of the interface.

- Add every implemented interactive command to README's implemented table.
- Put planned behavior only in roadmap/design sections labeled **Planned**.
- Include a profile example when introducing a profile property.
- Document fallback behavior when an optional dependency is absent.
- Update `CHANGELOG.md` under `Unreleased` for user-visible changes.
- Link to authoritative upstream documentation for version-sensitive kernel,
  Emacs, b4, LLVM, QEMU, GDB, and virtme-ng behavior.  For vng, prefer the
  [project README](https://github.com/arighi/virtme-ng/blob/main/README.md),
  [public parser](https://github.com/arighi/virtme-ng/blob/main/virtme_ng/run.py),
  and [packaged entry points](https://github.com/arighi/virtme-ng/blob/main/setup.py).

Avoid claims such as “automatic,” “safe,” or “verified” unless the described
guard and test exist in the same checkout.

## Change checklist

- [ ] Loads under `emacs -Q` on the documented minimum version.
- [ ] `make check` passes on the supported Emacs versions affected by the change.
- [ ] Does not alter unrelated buffers or global user configuration.
- [ ] Uses a resolved context for all profile-sensitive behavior.
- [ ] Quotes/validates every external argument and records the exact command.
- [ ] Degrades when optional tools are missing.
- [ ] Adds focused ERT coverage, including the relevant failure/safety guard.
- [ ] Reviews destructive, privileged, Git, mail, and network effects.
- [ ] Updates README, design documentation, and changelog truthfully.
