# 10: Preserve one-tap revert on v2

**What to build:** Users retain the existing revert experience while OpenLens safely performs v2's staged operation and handles busy-session conflicts.

**Blocked by:** 06: Synchronize v2 live chat after stream gaps; 07: Send a normal v2 chat turn.

**Status:** ready-for-agent

- [ ] A single user action completes the required v2 revert stages and refreshes the affected session, transcript, and diff state.
- [ ] A busy-session conflict or incomplete revert leaves the app in a recoverable, accurately refreshed state.
