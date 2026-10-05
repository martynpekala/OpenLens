# Enforce remote session and event ownership

**Status:** implemented — automated verification passed

**What to build:** Resolve session ownership against registered workspaces before forwarding session-owned operations; filter global active snapshots and native event streams. Location query injection is not authorization for these endpoints.

- [x] A valid ID belonging to an unregistered workspace is denied before reads or mutations.
- [x] Registered sessions remain usable and ownership changes are revalidated.
- [x] Global active snapshots and event streams disclose only approved workspaces.
- [x] Integration tests use a contract-shaped server that ignores unsupported location queries.

Evidence and limits: [audit](../AUDIT.md).
