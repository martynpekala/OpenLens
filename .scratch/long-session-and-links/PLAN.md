# Long-session scrolling and detected links

Two user reports, shipped as two PRs (links first).

## PR 1 — Detected links (tap to open, long-press to copy)

See **Detected link** in `CONTEXT.md`.

Today `[text](url)` markdown links are already tappable (SwiftUI `Text` honours `.link`), but bare URLs are not: `MarkdownContentView.makeAttributed` skips plain prose, and `AttributedString(markdown:)` never auto-links.

1. In `MarkdownContentView` parsing (prose, list and blockquote fragments only — not code blocks), run `NSDataDetector(.link)` over the text and add `.link` runs for `http(s)` and `www.` matches (`www.` → `https://`). Do it at parse time on `parserQueue`, like the existing `AttributedString` work. The plain-prose fast path must still trigger when text contains `http` or `www.`.
2. Apply to both user and assistant messages (same renderer).
3. Tap: default `openURL` → system browser. No localhost rewriting.
4. Copy: in `MessageCopyActions` (`MessageBubbleView.swift`), add a "Copy Link" item per detected link (show the host, or a shortened URL) under "Copy message"; if there are more than 5, show "Copy All Links" instead. Strings go in `AppText`.
5. Tests (Swift Testing): detection in prose/list/blockquote; none in code blocks; `www.` normalisation; existing `[text](url)` links unchanged; link list for the menu.
6. Screenshot of a tapped/long-pressed link for the PR.

## PR 2 — Long sessions: lag and blank bottom

Symptom: on every phone, long sessions scroll with lag, and the bottom of the chat is blank until you scroll up and back down.

Suspected cause (to confirm): `DeferredMarkdownTextView` first renders an ≤800-character plain preview at 16pt, then swaps to the parsed markdown at 17pt asynchronously. `onAppear` resets `prepared = nil` and re-prepares every time a lazy row is re-created, even when the parse is cached. So each long row appears too short and grows a frame later. `LazyVStack` height estimates are wrong, `scrollTo(bottom)` lands past the realised content (blank), and scrolling triggers repeated height corrections (lag).

1. **Reproduce** with a throwaway `DemoPlayer` long session (many turns, tall varied responses, "Load earlier" several times) on the iPhone 18 Pro simulator. Confirm the blank bottom and capture a SwiftUI Instruments trace. Do not commit the fixture.
2. **Fix inside the existing `ScrollView` + `LazyVStack`** (no UIKit; `List` only as a fallback, with the user's OK first):
   - Synchronous cache hit: initialise `prepared` from `MarkdownContentView`'s cache when the text is already parsed, and do not reset it on `onAppear`.
   - Parse finished messages before they render (when the timeline is rebuilt), so rows usually lay out at their final height on first appearance.
   - Make the fallback preview use the same typography as the final render.
3. Re-run the repro: no blank bottom after opening, after "Load earlier", or after streaming; no repeated layout corrections in Instruments.
4. If it still reproduces, profile further (`.textSelection` on every bubble, timeline rebuild frequency, the streaming auto-follow observer) before changing structure. After two failed fixes, stop and report.
5. `./scripts/test-ios.sh` full suite.
6. Real-device smoothness: send a TestFlight build to the reporter. Note in the PR that only simulator behaviour was checked until they confirm.
