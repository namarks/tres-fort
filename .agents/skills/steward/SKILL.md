---
name: steward
description: "Tres Fort's pull request conventions for any agent opening, watching or fixing a PR. Points to the codex-gate skill."
---

# Pull request stewardship

When you open, watch or fix a Tres Fort pull request, follow
[`codex-gate`](../codex-gate/SKILL.md): Codex must review the exact head
commit, CI must be green on that commit, and the PR then waits for Nick to
merge. Some agents, such as Claude Code, read a skill named `steward`
automatically while driving a PR; this pointer exists for them.
