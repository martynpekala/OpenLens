# 06: Synchronize v2 live chat after stream gaps

**What to build:** Chat safely handles v2 SSE framing, unknown events, disconnects, overflow, and foregrounding by reconciling authoritative session and transcript state.

**Blocked by:** 05: Browse paginated v2 sessions and transcripts.

**Status:** ready-for-agent

- [ ] Live v2 chat processes standard SSE framing, split and multi-line data, heartbeats, and known events while safely ignoring unknown future events.
- [ ] A disconnect, overflow, decode failure, workspace transition, or foreground return refreshes authoritative state before the chat is considered synchronized.
