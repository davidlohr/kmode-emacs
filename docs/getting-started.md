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
- `clangd` plus Eglot for semantic definitions and callers;
- `vng` (virtme-ng) for the integrated virtual-kernel workflow; and
- the kernel-tree scripts or tools named by a check, test, or review action.

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

`kmode-global-mode` automatically enables the project minor mode only in
recognized kernel-tree buffers.  To opt in one buffer instead, omit the final
line and run `M-x kmode-mode` from a kernel checkout.

After updating the checkout, restart Emacs or evaluate the changed modules;
kmode-emacs does not replace loaded definitions behind your back.

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

1. Open a source file inside the Linux checkout.
2. Press `C-c k p` and select the profile you defined.
3. Press `C-c k ?` to run the capability doctor.  Missing optional tools
   disable only their workflows.
4. Press `C-c k k` for the dashboard.  It shows the resolved source/output
   directories, profile artifacts, live jobs, and available actions.
5. Use `C-c k o` to compile only the current source file's object.  Use
   `C-c k b` only when you intend to run the profile's full/default build.
6. Use `C-c k SPC` at any time to select an action by name.  A prefix argument
   (`C-u C-c k SPC`) also lists unavailable actions and why they are disabled.

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

Changing profile stops affected kernel Eglot servers by default, because an
index for one architecture/configuration is not trustworthy for another.
Regenerate the database if needed and explicitly restart with `C-c k n e`.

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

1. Select `x86-vng` with `C-c k p` and inspect vng readiness with `C-c k ?`.
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

The current adapter has extensive hermetic argv, profile, safety, locking, and
process tests, but its initial development environment did not have vng
installed.  Treat the first real boot on your installed virtme-ng release as
an integration smoke test and inspect `C-c k v s` before launching it.

## Three productive loops

### Edit and build

1. `C-c k o` — build the current object.
2. `M-g n` / `M-g p` — move through compiler diagnostics.
3. `C-c k r` — run strict checkpatch on the current file.
4. `C-c k i` — inspect the change-impact plan for staged work.

### Understand unfamiliar code

1. `C-c k n .` — do the right thing for the token or include at point.
2. `C-c k n d` / `r` — move between a symbol and its semantic callers.
3. `C-c k n k` — inspect how the current directory is built.
4. `C-c k n c` / `u` — move between Kconfig declaration and consumers.

### Boot and debug

1. `C-c k v a` — build then boot with the frozen selected profile.
2. Reproduce the failure in the guest and save the console output.
3. `C-c k l` — decode selected stack text with the profile's `vmlinux`.
4. `C-c k v A`, then `C-c k v g` — boot a debug guest and attach GDB.

## Safety and troubleshooting

- Run `C-c k ?` first when an action is unavailable.  It reports executable,
  artifact, architecture, guest-root, and vng configuration status.
- Run `C-c k v s` before vng actions and inspect Compilation buffers for the
  exact Kbuild/test command.  kmode-emacs never sends patch mail.
- Do not put untrusted command fragments in profiles.  Tree-local scripts,
  Kbuild inputs, QEMU vectors, and guest commands can execute code.
- Host-sensitive vng options require confirmation by default.  Nonempty
  upstream `default_opts` fail closed until explicitly trusted and still must
  pass typed validation.
- If definition/caller lookup has no backend, confirm Eglot is installed,
  `clangd` is on Emacs's `exec-path`, the active output contains a readable
  `compile_commands.json`, and `C-c k n e` succeeded.
- If kmode-emacs does not activate, run `M-x kmode-mode` and verify all four root
  markers listed under Prerequisites exist at an ancestor of the current file.

For every command and customization, continue with the
[main README](../README.md).  For architecture, invariants, extension points,
and planned work, see [design.md](design.md).
