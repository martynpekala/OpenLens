# Require successful recovery before declaring synchronization

**Status:** implemented — automated verification passed

**What to build:** Propagate success or failure of status and pending-interaction recovery so the chat does not report synchronization after incomplete REST recovery.

- [x] Status, permission, or form recovery failure leaves synchronization incomplete and recoverable.
- [x] A successful retry refreshes canonical session, transcript, status, and interactions before marking synchronized.
- [x] Switching sessions during recovery cannot apply stale results.

Evidence and limits: [audit](../AUDIT.md).
