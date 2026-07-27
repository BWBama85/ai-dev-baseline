# Shell discipline

The interactive shell is commonly **zsh** (macOS default) and **bash** on Linux
CI. Write commands that work in both, and default to POSIX `sh` semantics unless
you are running a script with an explicit `#!/usr/bin/env bash` shebang.

## Rules

- **One command, one purpose.** Prefer several simple calls over a long
  `A && B && C && D` chain. Compound chains are harder to permission-approve,
  harder to attribute when one link fails, and more likely to be denied outright
  by command-safety gating. Run steps separately unless they are genuinely one
  atomic operation.
- **No bashisms in `sh`/inline contexts.** Bash arrays, `[[ … ]]` where `[ … ]`
  works, `<(…)` process substitution, `${var^^}` case tricks, and `source`-ing
  interactive rc idioms all break or behave differently under zsh/sh. If you need
  bash features, put them in a real `bash` script, not a one-liner.
- **Quote every expansion.** `"$file"`, `"${arr[@]}"`. An unquoted variable
  containing a space or a glob char (`* ? [`) will word-split or glob-expand and
  silently do the wrong thing.
- **Never assign to a zsh-special name.** `path`, `fpath`, `cdpath`, `manpath`,
  `module_path` and `argv` are **bound to shell state** in zsh — `path` *is*
  `$PATH`. A loop like `read -r kind path key` therefore empties the search path
  on its first iteration, and every external command after it fails with
  "command not found". Under bash the same line is harmless, so this survives
  review and every bash-based test, then breaks on the default macOS shell. Pick
  a neutral name (`file`, `sfile`, `entry`) — and remember the rule applies to
  any snippet an agent executes, not just to `.sh` files.
- **Don't assume PATH.** Non-interactive shells may not have your rc's PATH. If a
  brew/user-installed tool might be missing, export the prefix explicitly once
  (e.g. `export PATH="/opt/homebrew/bin:$PATH"`) rather than relying on login
  shell setup.
- **Globs and `find`:** when a glob may match nothing, guard it (`shopt -s
  nullglob` in bash, or iterate `find … -print0 | while IFS= read -r -d ''`).
  Don't let an unmatched glob leak through as a literal argument.

## Why

Shell-environment friction — bash array expansions and globs failing under zsh,
exit-127 sourcing errors, and blocked compound commands — is a recurring source
of wasted retries. Defaulting to portable, single-purpose commands eliminates it
before it starts.
