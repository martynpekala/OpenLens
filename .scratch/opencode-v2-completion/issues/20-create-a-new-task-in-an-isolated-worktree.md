# 20: Create a new task in an isolated worktree

**What to build:** Start work in a real Git worktree using its canonical returned location and the existing workspace-selection flow.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P2

- [ ] The supported worktree inventory distinguishes real worktrees from projects and remembered directories.
- [ ] A create flow returns a canonical location and creates/opens the new task's session there.
- [ ] Creation and session admission failures are distinguishable and do not create duplicate worktrees through blind retries.
- [ ] Remote requires the existing explicit Mac approval before access to a new location and explains the required approval.
- [ ] An unapproved new directory is never automatically authorized merely because its parent project is approved.
- [ ] A live direct/Remote demo confirms that the new task uses the separate working directory; destructive removal is outside this slice.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
