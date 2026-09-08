---
name: source-command-commit
description: Create one Git commit when the user asks to commit their current work.
---

Create one commit for the work the user selected. First run `git status --short`,
`git diff`, `git diff --cached`, `git branch --show-current`, and
`git log --oneline -10` to inspect the live state and message conventions.

Stage only the intended files or hunks. Preserve unrelated staged and unstaged
work. If existing staged changes make the requested commit ambiguous, clarify
the scope before committing. Check the staged diff and required validation,
then create the commit with a concise message explaining the change.
Do not amend, push, or open a PR unless the user requested those actions.
Report the commit hash and any remaining changes briefly.

Adapted from Anthropic commit-commands (Apache-2.0). The Codex version replaces
Claude command expansion and tool-only response constraints with explicit steps.
Branch cleanup preserves uncommitted or unmerged work by default.
