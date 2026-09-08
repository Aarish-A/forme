---
name: source-command-commit-push-pr
description: Commit selected changes, push the branch, and open a pull request when the user requests that workflow.
---

Inspect `git status --short`, `git diff`, `git diff --cached`, the current
branch, configured remotes, and recent commits. Confirm the work is in the
repository and remote intended by the user.

If on the default branch (including main or master), create a descriptive
`codex/` branch unless the user specified a different name. Stage only the
requested work, preserving unrelated changes. Run the required checks, inspect
the staged diff, and create one focused commit. Do not amend or force-push.

Push the selected branch with its upstream to the intended remote. Reuse an
existing PR for the branch if one exists; otherwise create a PR with `gh pr
create`. Put the problem, resulting behavior, and relevant validation in its
description. Write multiline text to a temporary file and use `--body-file`.
Verify the resulting PR and report its link. A request for a commit alone does
not authorize pushing or opening a PR. If publication fails, report the state
already achieved and the specific remaining action.

Adapted from Anthropic commit-commands (Apache-2.0). The Codex version replaces
Claude command expansion and tool-only response constraints with explicit steps.
Branch cleanup preserves uncommitted or unmerged work by default.
