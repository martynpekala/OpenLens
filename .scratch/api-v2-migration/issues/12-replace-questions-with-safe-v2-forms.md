# 12: Replace questions with safe v2 forms

**What to build:** Users can recover, render, submit, or cancel supported v2 forms; unknown future fields fail safely with a clear fallback.

**Blocked by:** 06: Synchronize v2 live chat after stream gaps; 07: Send a normal v2 chat turn.

**Status:** ready-for-agent

- [ ] Pending forms are restored after missed events and render supported string, numeric, boolean, multiselect, and external-link fields within existing safety limits.
- [ ] Submitting or cancelling a form reaches the v2 session-scoped operation, while unsupported new fields offer a safe, explicit fallback.
