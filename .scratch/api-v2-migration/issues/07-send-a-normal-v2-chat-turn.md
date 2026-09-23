# 07: Send a normal v2 chat turn

**What to build:** Users can create, rename, or remove a session and send a normal prompt with their selected agent/model, receiving a reconciled transcript.

**Blocked by:** 04: Choose v2 agents and models; 06: Synchronize v2 live chat after stream gaps.

**Status:** ready-for-agent

- [ ] Creating, renaming, and deleting a v2 session updates the UI correctly when the server uses no-content mutation responses.
- [ ] A normal prompt applies any changed model or agent before admission, preserves the local user message, and reconciles it with the resulting v2 transcript.
