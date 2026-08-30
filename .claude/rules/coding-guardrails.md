# Coding Guardrails

Always-on; the preventive half of the plan/diff gates.

- **Think before coding** — state assumptions and the simpler alternative before the first edit; ask only when readings differ materially.
- **Simplicity first** — the minimum code that solves the request; no speculative options, abstractions for one call site, or handling for cases that can't occur.
- **Surgical changes** — touch only what the request requires; no drive-by reformatting, refactors, or comment edits; clean up only orphans you created.
- **Goal-driven** — done means verified (the `## Verification` commands in CLAUDE.md), not written; report failures verbatim.
