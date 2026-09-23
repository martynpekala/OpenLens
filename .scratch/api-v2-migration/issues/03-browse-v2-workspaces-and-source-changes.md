# 03: Browse v2 workspaces and source changes

**What to build:** Users can select a v2 location and browse its projects, files, file content, repository state, and diffs directly or remotely.

**Blocked by:** 02: Secure v2 remote discovery and workspace isolation.

**Status:** ready-for-agent

- [ ] Workspace browsing uses the canonical v2 location and presents project, filesystem, binary-file fallback, and VCS information correctly.
- [ ] The same user-visible workspace behavior works through both direct and paired remote connections without crossing the approved workspace boundary.
