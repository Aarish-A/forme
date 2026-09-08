---
name: source-command-clean-gone
description: Clean up local Git branches whose upstream was deleted, and their worktrees, when the user asks for stale branch cleanup.
---

Inspect `git branch -vv`, `git for-each-ref` with upstream tracking fields,
and `git worktree list --porcelain`. Verify the upstream's absence against the
intended remote (fetch/prune its tracking refs when authorized for this cleanup).
Match exact branch names and parse worktree paths without whitespace splitting.

Never select the current branch, the main worktree, or the default branch.
For each candidate, inspect its worktree for tracked and untracked changes and
check whether its commits are merged into the intended base. A deleted upstream
alone does not mean local work is disposable.

Remove only clean, unused worktrees with `git worktree remove` and merged
branches with `git branch -d`. If force would be required, preserve the work and
explain why it was skipped; obtain explicit authorization identifying the work
that would be lost before using any force option. Summarize exact branches and
worktrees removed or skipped; if none qualify, report no cleanup needed.

Adapted from Anthropic commit-commands (Apache-2.0). The Codex version replaces
Claude command expansion and tool-only response constraints with explicit steps.
Branch cleanup preserves uncommitted or unmerged work by default.
