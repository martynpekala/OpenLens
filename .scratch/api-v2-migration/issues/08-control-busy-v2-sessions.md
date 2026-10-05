# 08: Control busy v2 sessions

**What to build:** Users can explicitly queue or steer prompts and interrupt active work, with correct handling for late updates and idle states.

**Blocked by:** 07: Send a normal v2 chat turn.

**Status:** ready-for-agent

- [ ] The chat offers deliberate queue and steer behavior when a session is busy, and shows the admitted work in the correct order.
- [ ] Interrupting an active or idle session produces the documented v2 behavior and does not let late stream events corrupt the final chat state.
