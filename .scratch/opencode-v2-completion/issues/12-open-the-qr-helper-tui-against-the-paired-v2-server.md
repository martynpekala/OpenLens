# 12: Open the QR helper TUI against the paired V2 server

**What to build:** Launch the supported TUI for the detected CLI generation against the server used by the QR pairing flow.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Priority:** P1

- [ ] The V2 path uses the supported root CLI with an explicit server URL and environment-based password rather than legacy attach/password flags.
- [ ] The V1 startup path remains supported and standalone serve is not incorrectly treated as obsolete.
- [ ] The opened TUI and paired phone use the intended server identity and authentication.
- [ ] Helper shutdown stops only a process owned by the helper, including when a shared V2 service already exists.
- [ ] Package build and actual startup checks cover representative V1/V2 installations without logging secrets.
- [ ] Work from OpenLens V2 baseline 1dfb5aa or a descendant retaining its dual-protocol services and Remote isolation.
- [ ] Extend the existing services, environment injection, and view-local state; preserve V1 and chat navigation behavior without adding a ViewModel/Presenter layer.
- [ ] Verify externally visible behavior with Swift Testing at the existing service/transport boundary and gateway coverage where applicable; run the repository-required checks and include screenshots for visible changes.
