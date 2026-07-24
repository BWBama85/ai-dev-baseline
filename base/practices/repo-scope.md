# Verify repo scope before starting

Before implementing an issue, fixing a bug from a ticket, or acting on any
reference, **confirm it belongs to _this_ repository.**

## Check

- `gh issue view <n>` in the current repo. If it 404s, or the body clearly
  describes a different codebase (wrong file paths, wrong stack, wrong product),
  it probably lives in another repo.
- When given several issue numbers, verify each — a batch can span repos.

## If there's a mismatch

**Stop and say which repo the work maps to.** Do not guess, and do not start
implementing against the wrong codebase. One misrouted issue can waste an entire
session of exploration before the mismatch surfaces.

## The project may be larger or smaller than the git root

Do not assume the working directory **is** the git root, or that there is exactly
**one** root doc. Real repos break both, and tooling that assumes a tidy single-root
state either fails or silently operates on the wrong root. Watch for:

- **Working dir ≠ git root.** You may be several directories below the top level.
  Resolve the git root explicitly before acting on repo-wide state.
- **Nested repos.** A repo can be checked out *inside* another repo (a plugin under
  a site, a vendored checkout). Git operations from inside the inner repo act on the
  **inner** one — confirm that's the one you mean.
- **Untracked parent trees.** The git root can sit deep inside a larger project that
  is **entirely untracked** (e.g. a plugin at `.../wp-content/plugins/<repo>` inside
  a WordPress install). Git-aware tools see only the inner repo; the surrounding
  project is invisible to them.
- **Out-of-repo root docs.** A `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` referenced by
  relative path may live **above** the git root, outside any repo — real context that
  no git-aware command will surface. Layered/monorepo layouts also carry **multiple**
  in-tree root docs (one per package).

**When the shape is non-tidy, surface it — don't hard-fail and don't operate on the
wrong root.** State what you resolved, note what's outside your reach (the untracked
parent, the out-of-repo doc), and confirm the intended boundary before proceeding.
The shared `adb_repo_shape` primitive (`scripts/lib/common.sh`) reports these facts
(git-root vs working dir, nested-in, out-of-repo `foreign_doc`s, in-tree `extra_doc`s)
so tooling can tolerate the shape from one home rather than each re-deriving it;
`bin/agent-init` consumes it.

## Why

A whole session was once lost because the requested issues lived in a different
repository than the one that was checked out. A three-second `gh issue view`
up front fails fast instead. The same class of mistake — assuming a tidy single-root
layout — surfaced in a 4-project sweep (a plugin nested in an untracked WordPress
install with a second root doc outside the repo; a pnpm monorepo whose "project" is
several packages), which is why repo-shape awareness is part of scoping.
