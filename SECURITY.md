# Security policy

Kemacs is pre-1.0 and currently supports only the latest code on the default
branch.  There are no maintained release branches yet.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/davidlohr/kemacs-mode/security/advisories/new)
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

Kemacs launches developer-selected kernel tools.  A trusted Linux checkout,
build configuration, compiler database, QEMU vector, virtme-ng profile, guest
command, or tree-local script can execute code and may expose host resources.
That expected capability is not itself a vulnerability.  A bypass of the
documented previews, validation, containment, profile isolation, resource
locking, or confirmation boundaries may be one.

Never include authentication tokens, real passwords, private VM images, or
unredacted proprietary source in a report.
