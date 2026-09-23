# 05: Browse paginated v2 sessions and transcripts

**What to build:** Session lists, activity views, search, and long transcripts load complete paginated results rather than silently truncating after one page.

**Blocked by:** 03: Browse v2 workspaces and source changes.

**Status:** ready-for-agent

- [ ] Browsing a v2 workspace retrieves every needed session and transcript page, including datasets larger than one server page.
- [ ] Empty pages, repeated cursors, and malformed pagination stop safely and surface a recoverable failure rather than looping or showing incomplete data as final.
