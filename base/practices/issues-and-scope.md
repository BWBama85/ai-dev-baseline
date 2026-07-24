# Out-of-scope work always becomes a tracked issue

The moment **anything** is deferred, declared out of scope, or punted "for later"
during a task, it is owed a tracked issue in the same run — filed **before** you
call the work done.

This includes, without exception:

- Slices you cut because the work was too large for one PR.
- A parent issue's own **"Out of scope" / "Future" / "Deferred"** list. That list
  evaporates into a *closed* issue when the PR merges, so it must be re-homed into
  open issues. The parent listing its non-goals is **not** tracking.
- Anything a reviewer (human or bot) or a gap-analysis pass flagged and you
  resolved by **deferring** rather than fixing.
- Test/infra gaps you knowingly left.

## Rules

- **A PR-body note is not tracking.** It falls out of view the moment the issue
  closes on merge. Only an open issue tracks deferred work.
- **File by default; do not ask.** Filing is the default action, then inform the
  owner what you filed. (If the owner explicitly says "don't file X," honor that.)
- **Link both ways.** Comment the new issue on the parent (the link survives after
  the parent closes) and reference it from the PR.
- **Place it correctly.** If the project has a release-goal / milestone
  convention, follow it: newly *discovered* work defaults to the **backlog** — never
  the active release milestone; only a deliberate current-release requirement enters
  it. Freezing the release set that way is what keeps "done" reachable: an
  ever-growing set never converges. Detect the convention live rather than assuming
  it. Otherwise default to the project's backlog. Never leave a new issue
  milestone-less if the project uses milestones.

## Why

Deferred work that lives only in prose is deferred work that gets lost. Filing it
as a tracked issue — automatically, every time — is the single most-missed
discipline and the one that most reliably prevents silent scope loss.
