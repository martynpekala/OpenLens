# 01: Establish v2 contract fixtures and runtime protocol selection

**What to build:** OpenLens reliably detects a reachable v2 server, retains v1 fallback, and uses reproducible direct-connection contract fixtures and capability evidence.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] A reachable v2 server is identified through capability-based probing, while a v1 server continues to select the supported v1 behavior.
- [ ] Sanitized representative v1 and v2 HTTP/SSE contracts make the selected behavior and compatibility failures reproducible in tests.
