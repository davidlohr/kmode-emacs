## Summary

Describe the kernel-development workflow this changes and why.

## Validation

- [ ] `make check` passes.
- [ ] New behavior has focused ERT coverage.
- [ ] User-visible behavior and key bindings are documented in `README.md`.
- [ ] `CHANGELOG.md` is updated when the change is user-visible.
- [ ] Generated `.elc` files are not included.

## Safety review

- [ ] The exact external command, context, output, and target remain visible.
- [ ] User-controlled values cross process boundaries as distinct arguments.
- [ ] Profile/worktree state and writable resources cannot be confused.
- [ ] Irreversible, privileged, network, host-access, or external effects are
      previewed and separately confirmed, or this change has none.
- [ ] Failure preserves unrelated editor, Git, build, and guest state.

If a box does not apply, explain why.  Never add review/test identity trailers
for another person.
