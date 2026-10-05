# 06: Show accurate v2 model capabilities and prices

**What to build:** The v2 model picker presents the capabilities and price information actually reported by the runtime catalog, so users can compare models without missing badges or prices.

**Blocked by:** None (can start immediately).

**Status:** catalog contract verified

- [ ] Tool support and supported input media are derived from the v2 capability shape rather than legacy boolean fields.
- [ ] Available v2 price tiers are represented in the picker without inventing a price when none is reported.
- [ ] A realistic v2 catalog fixture covers a tool-capable, image-capable model with prices, and the v1 picker remains correct.

## Audit evidence — 2026-09-25

The tools/input capability mapping was correct. Tiered prices still broke decoding because tier was treated as an integer. Fixed the documented {type:context,size} shape and corrected the catalog fixtures; v1 cost decoding remains supported. See [audit](../AUDIT.md) for test results and remaining release blockers.
