# Consume native v2 events and filter locations

**Status:** implemented — automated verification passed

**What to build:** Map the native {type,data,location} event envelope and session.text/reasoning/step/tool events into the chat pipeline. Preserve unknown-event tolerance without silently dropping supported events.

- [x] Contract-shaped frames exercise the decoder through visible chat text, tool steps, completion, and pending interactions.
- [x] Cross-location native events cannot mutate the selected workspace.
- [x] Reconnect and gap generation checks require fresh recovery; existing disconnect/overflow and v1 stream coverage passes.
- [ ] Live v2 direct/remote smoke testing (no live v2 server available).

Evidence and limits: [audit](../AUDIT.md).
