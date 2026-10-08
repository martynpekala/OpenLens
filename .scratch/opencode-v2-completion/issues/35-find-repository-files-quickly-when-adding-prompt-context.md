# 35: Find repository files quickly when adding prompt context

**What to build:** Choose a repository attachment quickly through the supported server file-search operation.

**Blocked by:** 14: Attach text files and repository line references.

**Status:** ready-for-agent

**Priority:** P3

- [ ] The repository attachment picker offers supported file search and returns usable references in the selected workspace.
- [ ] Search results can be selected, previewed, and used with the existing line-range attachment flow.
- [ ] Cancelled/obsolete queries cannot overwrite newer results or another workspace.
- [ ] Unsupported search falls back to the existing repository picker without fetching arbitrary unapproved paths.
- [ ] Remote permits the exact supported operation for approved canonical locations and search/result errors remain visible.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
