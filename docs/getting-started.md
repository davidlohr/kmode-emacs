# Getting started with kmode-emacs

This guide takes a fresh checkout from loading kmode-emacs to the short kernel
development loop it is designed for:

```text
edit -> build/check -> navigate -> boot/test -> inspect/debug
          ^                                      |
          +---------- one build profile ---------+
```

kmode-emacs is pre-1.0.  It makes kernel tooling faster to reach, but it does not
hide what is being run: build, test, review, QEMU, and virtme-ng actions show
their command lines in dedicated buffers or previews.

## Prerequisites

kmode-emacs itself requires GNU Emacs 28.1 or newer and only Emacs Lisp libraries
shipped with Emacs.  Individual workflows need their usual host tools:

- `make` and a configured Linux source tree for Kbuild;
- `rg` for the fastest source/Kconfig searches;
- Etags for the kernel `TAGS` target and indexed Xref fallback;
- `clangd` plus Eglot for semantic definitions and callers;
- `cscope` for the kernel-generated cscope database;
- optional `xcscope.el` for Kmode's profile-aware cscope query adapter;
- `vng` (virtme-ng) for the integrated virtual-kernel workflow; and
- the kernel-tree scripts or tools named by a check, test, or review action.

`consult-cscope` is a separate, user-owned front end; Kmode does not configure
or invoke it.  TAGS/cscope action availability checks resolve `make` and the
corresponding index executable; they do not probe whether this kernel Makefile
actually defines the target.  An unsupported `TAGS` or `cscope` target fails
visibly in the Compilation buffer.

A directory is recognized as a Linux source root only when it contains
`Makefile`, `Kconfig`, `MAINTAINERS`, and `scripts/checkpatch.pl`.  This strict
check prevents a similarly named non-kernel project from inheriting commands
that can compile or execute code.

On Emacs 29 and newer Eglot is included with Emacs.  On Emacs 28, install the
Eglot package separately if you want clangd-backed navigation.  All heuristic
include, Kconfig, Kbuild, source/header, and Documentation navigation remains
available without Eglot.

## Load kmode-emacs

Clone the public repository into a stable directory:

```sh
git clone https://github.com/davidlohr/kmode-emacs.git
```

Then add the checkout to Emacs's `load-path`:

```elisp
(add-to-list 'load-path "/absolute/path/to/kmode-emacs")
(require 'kmode-emacs)
(kmode-global-mode 1)
```

`kmode-global-mode` makes `C-c k` available throughout Emacs and automatically
enables the project minor mode in recognized kernel-tree file buffers.  The
global key is a launcher; the `K[profile]` lighter, editing policy, and compile
state remain local to kernel buffers.  To opt in one buffer without the
global launcher, omit the final line and run `M-x kmode-mode` from a kernel
checkout.  Optionally set `kmode-default-root` to a kernel root or a directory
below one for the launcher to try before prompting.  `C-c k k` and
`C-c k R` are the only prefix commands that establish context outside a kernel
tree.  With the global mode enabled, use every other command from a kernel
buffer or the pinned dashboard.  With only local mode, use the prefix in kernel
buffers and the dashboard's buttons plus `g`, `p`, and `d`.

In CC Mode buffers, the default style layers the complete CC Mode offset
table published in the kernel documentation—including tab-only argument-list
continuation and closing—on Emacs's built-in `linux` style.  It uses
8-column tabs and an 80-column fill target, shows trailing whitespace, and
requires a final newline by default.  `kmode-apply-kernel-c-style` is the master
switch for this C-buffer policy; customize its individual values with
`kmode-apply-kernel-c-style`, `kmode-kernel-fill-column`,
`kmode-show-trailing-whitespace`, and `kmode-require-final-newline`.  `c-ts-mode` receives the available
8-column indentation setting, but Kmode does not claim CC Mode offset parity
there.

After updating the checkout, restart Emacs.  Re-evaluating
`(require 'kmode-emacs)` does not reload an already provided feature or rebuild its keymaps.

## Define a first build profile

The built-in `default` profile is a native, in-tree build.  That is convenient
for an already configured checkout, but an out-of-tree output keeps generated
files out of the source tree and is the safer first setup:

```elisp
(with-eval-after-load 'kmode-core
  (add-to-list
   'kmode-profiles
   '("x86-clang"
     :description "Native x86-64 kernel with Clang"
     :arch "x86_64"
     :compiler clang
     :output "../build/linux-x86-clang"
     :jobs auto
     :make-arguments ("W=1")
     :image "arch/x86/boot/bzImage"
     :vmlinux "vmlinux")))
```

Change the architecture, compiler, output path, and artifact names to match
your kernel.  kmode-emacs resolves relative output paths from the source root and
uses the same resulting context for builds, clangd, tests, logs, QEMU, and
virtme-ng.  Do not mix artifacts from different configurations in one profile.

## Your first session

1. Press `C-c k k` from any ordinary buffer.  Kmode uses the current kernel
   root when there is one; otherwise it reuses the last valid session root, tries
   a valid `kmode-default-root`, or asks for a checkout.  Use `C-u C-c k k` to
   force the root prompt, or `C-c k R` to select and remember a root without
   opening the dashboard.
2. In the dashboard, press `p` and select the profile you defined, then press
   `d` for the capability doctor.  Missing optional tools disable only their
   workflows.
3. Confirm the source/output directories and six active-profile paths:
   `.config`, `compile_commands.json`, the `.cache/clangd/index/` directory,
   `TAGS`, `cscope.out`, and `vmlinux`.  The dashboard shows a readable path as
   `ready · YYYY-MM-DD HH:MM` and another as `missing`; Doctor uses `[OK]` or
   `[--]` with the path.  Neither view validates contents or freshness.
4. Open any source file inside that checkout.  This enables the local
   `K[profile]` editing cockpit and file-relative actions; no particular file
   is required.
5. Use `C-c k o` to compile only the current source file's object.  Use
   `C-c k b` only when you intend to run the profile's full/default build.
6. From the kernel file or dashboard, use `C-c k SPC` to select an action by
   name.  A prefix argument (`C-u C-c k SPC`) also lists unavailable actions
   and why they are disabled.

Compilation output uses Emacs Compilation mode, so `next-error` and
`previous-error` visit diagnostics normally.  kmode-emacs serializes jobs that
write the same output directory and `C-c k x` can interrupt a managed job.

In the dashboard, `g` refreshes state, `p` selects a profile, and `d` runs the
doctor.

## Definitions, callers, and kernel-aware jumps

The short answer is:

| Task | Standard key | kmode-emacs key |
| --- | --- | --- |
| Definition at point | `M-.` | `C-c k n d` |
| References/callers | `M-?` | `C-c k n r` |
| Return to previous location | `M-,` | `C-c k n b` |
| Context-sensitive kernel jump | — | `C-c k n .` |

When Eglot manages the buffer, definitions and references come from clangd's
semantic index.  Set it up for the active profile once its kernel output is
configured:

1. Install `clangd` and, on Emacs 28, Eglot.
2. Select the correct kmode-emacs profile with `C-c k p`.
3. Run `M-x kmode-build-compile-commands` (or choose “Compile database” from
   `C-c k SPC`).  This can cause real Kbuild work.
4. Run `C-c k n e` to start clangd against
   `<profile-output>/compile_commands.json`.
5. Put point on a function and use `C-c k n d` for its implementation,
   `C-c k n r` for references/call sites, and `C-c k n b` to return.

By default, `kmode-clangd-arguments` adds `--background-index`,
`--completion-style=detailed`, and `--header-insertion=never`.  Add
`--clang-tidy` yourself if you want clangd to run those checks; it is not an
implicit Kmode policy.  Unlike Kmode's explicit, cancellable TAGS/cscope
Compilation jobs, background indexing is owned by Eglot/clangd after the
explicit `C-c k n e` start.

Changing profile stops affected kernel Eglot servers by default, because an
index for one architecture/configuration is not trustworthy for another.
Regenerate the database if needed and explicitly restart with `C-c k n e`.

For an indexed non-LSP fallback, press `C-c k n t` to run the kernel's `TAGS`
target for the selected profile.  The output is visible in Compilation mode.
With `kmode-auto-activate-tags` at its default non-nil value, Kmode makes a
readable `<profile-output>/TAGS` buffer-local through `tags-file-name` when a
kernel buffer activates.  Set the option to nil if you prefer to manage Emacs
tag tables yourself.  `M-x kmode-refresh-tags-table` reapplies this policy in
the current buffer after a table is created or removed externally; selecting a
profile refreshes both compile-command and TAGS bindings in enabled buffers in
the worktree.  Etags can back the same standard Xref commands, but its textual
references are not the same as clangd's semantic caller information.

For an optional cscope call graph, install `cscope` and `xcscope.el`, then use
this profile-aware submap:

| Key | Task |
| --- | --- |
| `C-c k n C b` | Build the selected profile's database with kernel `make cscope` |
| `C-c k n C d` | Find a definition |
| `C-c k n C r` | Find callers |
| `C-c k n C c` | Find callees |
| `C-c k n C s` | Find a symbol |
| `C-c k n C t` | Find text |
| `C-c k n C i` | Find files including the header at point |

`C-c k n C b` always builds for the selected profile output; Dashboard and
Doctor report only `<profile-output>/cscope.out`, and queries require that same
readable database.  `cscope.files` alone is an input list, not a queryable
database.  During each query Kmode pins xcscope to the selected output,
standard database names, query-only mode, the resolved program, and kernel
mode, then restores the user's settings.  Loading Kmode never requires
`xcscope.el`, and `consult-cscope` remains independently configured.

The selected profile keeps its project-side indexes together:
`<profile-output>/TAGS`, `<profile-output>/cscope.files` plus `cscope.out` and
its auxiliary files, `<profile-output>/compile_commands.json`, and clangd's
`<profile-output>/.cache/clangd/index/` shards.  For the built-in in-tree
`default` profile, `<profile-output>` is the kernel root.

Kmode rejects `O=` and `KBUILD_OUTPUT=` in profile and per-call Make arguments;
set the profile's `:output` property instead so every index path and resource
lock stays coherent.

clangd stores shards for external headers without a compilation database in
the operating system's user cache; its
[index design](https://clangd.llvm.org/design/indexing.html) describes that
split.

The rest of the navigation map does not require clangd:

| Key | Task |
| --- | --- |
| `C-c k n .` | Follow an include or `CONFIG_` symbol, otherwise use Xref |
| `C-c k n i` | Follow the include on this line, including generated/profile headers |
| `C-c k n c` | Find a Kconfig declaration |
| `C-c k n u` | Find source/data users of a `CONFIG_` symbol |
| `C-c k n k` | Open the nearest owning `Kbuild` or `Makefile` |
| `C-c k n h` | Switch between same-basename source and header candidates |
| `C-c k n D` | Search the checkout's `Documentation/` tree |
| `C-c k n t` | Build and optionally activate the selected profile's `TAGS` table |
| `C-c k n C` | Open the optional profile-aware xcscope map |

These are deliberately useful on a partially configured tree.  Include and
source/header resolution are heuristics rather than a replacement for the C
preprocessor or Kbuild dependency analysis.

## First virtme-ng workflow

kmode-emacs integrates with the upstream **virtme-ng** project through its public
`vng` frontend.  There is no upstream `vng-ng` command.  If `vng` is absent,
kmode-emacs also recognizes the official `virtme-ng` executable alias.

Start with a native profile whose output is separate from the source tree:

```elisp
(with-eval-after-load 'kmode-core
  (add-to-list
   'kmode-profiles
   '("x86-vng"
     :description "Native LLVM kernel under virtme-ng"
     :arch "x86"
     :compiler clang
     :output "../build/linux-x86-vng"
     :jobs auto
     :vmlinux "vmlinux"
     :vng-append ("console=ttyS0" "panic=-1")
     :vng-arguments ("--cpus" "4" "--memory" "2G"))))
```

Then:

1. From a kernel buffer, select `x86-vng` with `C-c k p` and inspect vng
   readiness with `C-c k ?`.
2. Run `C-c k v b` for the first vng build.  This creates/configures the
   out-of-tree output; a brand-new output cannot yet supply runnable command
   previews.
3. Run `C-c k v s` to inspect the shell-quoted build, run, preview, and debug
   command vectors once that output exists.
4. Run `C-c k v r` to boot the existing output.  For later edit/build/boot
   cycles, `C-c k v a` builds and boots only after a successful build.
5. Use `C-c k v e` for a one-shot guest command and `C-c k v x` to stop a
   managed guest.
6. Use `C-c k v A` for build-then-debug and `C-c k v g` to attach Emacs GDB
   to the managed debug guest.  A matching readable `vmlinux` is required.

For a non-native guest, configure a supported public `:vng-arch` and an
existing `:vng-root`.  kmode-emacs refuses to let a cross-architecture runtime
silently auto-provision a root through network or privileged operations.  See
the full profile schema and trust model in the main README before adding
disks, host directories, networking, SSH, devices, a custom QEMU, writable
mounts, or upstream `default_opts`.

The adapter has hermetic argv, profile, safety, locking, and process tests; that
suite deliberately does not boot a VM.  Treat the first real boot on each
installed virtme-ng/kernel combination as an integration smoke test and inspect
`C-c k v s` before launching it.

## Three productive loops

### Edit and build

1. `C-c k o` — build the current object.
2. `M-g n` / `M-g p` — move through compiler diagnostics.
3. `C-c k r` — run strict checkpatch on the current file.
4. `C-c k i` — inspect the change-impact plan for staged work.

### Understand unfamiliar code

1. `C-c k n .` — do the right thing for the token or include at point.
2. `C-c k n d` / `r` — move between a symbol and references/call sites;
   results are semantic with Eglot/clangd and backend-dependent otherwise.
3. `C-c k n k` — inspect how the current directory is built.
4. `C-c k n c` / `u` — move between Kconfig declaration and consumers.

### Boot and debug

1. `C-c k v a` — build then boot with the frozen selected profile.
2. Reproduce the failure in the guest and save the console output.
3. `C-c k l` — decode stack text in the current buffer with the profile's `vmlinux`.
4. `C-c k v A`, then `C-c k v g` — boot a debug guest and attach GDB.

## Safety and troubleshooting

- If `C-c k` is undefined, confirm that `kmode-global-mode` is enabled.
  After updating Kmode, restart Emacs; evaluating `(require 'kmode-emacs)`
  again does not reload it or rebuild its keymaps.  It is normal not to see the
  `K[profile]` lighter outside a recognized tree: the key is global, but the
  editing cockpit is local.
- Outside a kernel tree, use `C-c k k` to open a dashboard or `C-c k R` to
  select a root; they are the only outside-tree entry points.  In the dashboard
  press `d` for Doctor.  `C-c k ?` works directly only from a kernel buffer or
  dashboard and reports executable, artifact, architecture, guest-root, and
  vng configuration status.
- Run `C-c k v s` before vng actions and inspect Compilation buffers for the
  exact Kbuild/test command.  kmode-emacs never sends patch mail.
- Do not put untrusted command fragments in profiles.  Tree-local scripts,
  Kbuild inputs, QEMU vectors, and guest commands can execute code.
- Host-sensitive vng options require confirmation by default.  Nonempty
  upstream `default_opts` fail closed until explicitly trusted and still must
  pass typed validation.
- If definition/caller lookup has no backend, confirm Eglot is installed,
  `clangd` is on Emacs's `exec-path`, the active output contains a readable
  `compile_commands.json`, and `C-c k n e` succeeded; alternatively build a
  `TAGS` table with `C-c k n t` for indexed, non-semantic lookup.
- For cscope queries, confirm Doctor finds `cscope` and `xcscope.el`, then
  build a database with `C-c k n C b`.  Dashboard and Doctor check only the
  selected profile's output `cscope.out`, and queries use that same database.
  Kmode pins xcscope settings only for each call and does not configure
  `consult-cscope`.
- If local `kmode-mode` does not activate, run it manually and verify all four
  root markers listed under Prerequisites exist at an ancestor of the current file.

For every command and customization, continue with the
[main README](../README.md).  For architecture, invariants, extension points,
and planned work, see [design.md](design.md).
