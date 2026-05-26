# Handoff migration table

When resolving a handoff, use this table to route each piece of
information to its permanent home:

| Content type | Destination |
|---|---|
| "We chose X over Y because Z" | `docs/adr/NNNN-*.md` |
| Step-by-step work items | `docs/plans/<topic>.md` |
| Spike results | `docs/spikes/<topic>.md` |
| How subsystem X works | `docs/<topic>.md` |
| Shipped changes | `CHANGELOG.md` |
| Code-level gotchas | Code comment near the relevant line |
| Build/test commands | `CLAUDE.md` or `Makefile` |

After migrating, `git rm docs/handoffs/<file>.md` in the same commit.
