# Security policy

kmode-emacs is pre-1.0 and currently supports only the latest code on the default
branch.  There are no maintained release branches yet.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/davidlohr/kmode-emacs/security/advisories/new)
to start a private security advisory.  Please do not put exploit details,
credentials, private paths, or vulnerable guest/host information in a public
issue.  If that private form is unavailable, open a minimal public issue
asking the maintainers to establish a private channel, without including the
sensitive details.

Include, when safe to do so:

- the affected commit and Emacs version;
- the command or workflow involved;
- a minimal profile with secrets, private paths, and endpoints removed;
- the expected and observed trust boundary; and
- a reproducer that does not target systems or data you do not own.

Reports about shell/argument injection, path or symlink escapes, unsafe
project-local executable resolution, profile/context confusion, unconfirmed
host access, stale build/debug artifacts, or cross-project process/resource
ownership are especially useful.  Maintainers will acknowledge and triage
reports on a best-effort basis while the project is pre-release.

## Operational scope

kmode-emacs launches developer-selected kernel tools.  A trusted Linux checkout,
build configuration, compiler database, QEMU vector, virtme-ng profile, guest
command, or tree-local script can execute code and may expose host resources.
That expected capability is not itself a vulnerability.  A bypass of the
documented previews, validation, containment, profile isolation, resource
locking, or confirmation boundaries may be one.

## Lore network and cache boundary

Lore lookup is an explicit, read-only HTTPS action.  Kmode sends the selected
public-inbox query, which may contain an identifier and a kernel-relative path;
it does not upload source buffers.  Moving point never starts a request.  Git
blame provenance follows only trusted `https://lore.kernel.org/` links and
normalizes the exact legacy `https://lkml.kernel.org/r/` form; other hosts
and plain HTTP are rejected.  The integration does not fetch a patch series
into the worktree, apply patches, or send mail.

Parsed result metadata is cached below
`~/.emacs.d/kmode-emacs/lore/` by default, independently of TAGS, cscope,
and clangd indexes.  Kmode creates the directory with mode 0700 and cache
files with mode 0600, bounds the entry count, avoids following symlinks when
clearing, and labels fallback data `STALE`.  Treat subjects, authors, URLs, and
other public archive content as untrusted display data.

Never include authentication tokens, real passwords, private VM images, or
unredacted proprietary source in a report.
