# 02: Secure v2 remote discovery and workspace isolation

**What to build:** A paired device can establish v2 compatibility through the encrypted relay, while strict route and canonical-location controls reject scope escapes.

**Blocked by:** 01: Establish v2 contract fixtures and runtime protocol selection.

**Status:** done

- [x] A paired client can probe and select v2 through the encrypted remote transport without weakening v1 compatibility.
- [x] The relay permits only explicitly supported v2 routes and rejects encoded, duplicate, conflicting, or unregistered workspace locations.
