# Knowledge Base

> Concrete lessons from past bugs and mistakes. Only updated when explicitly instructed.
> Referenced by CLAUDE.md when working on related code areas.

## Project layout

### Opened panel width
Controlled by `panelWidth` in `ClaudeIsland/Core/NotchViewModel.swift`:
- Current: `min(screenRect.width * 0.53, 680)`

### Closed notch width (non-activated state)
When user says "减小没激活状态下的宽度", this is what to change.
Controlled by `sideWidth` in `ClaudeIsland/UI/Views/NotchView.swift`:
- Current: `max(0, closedNotchSize.height - 12) + 2`
- Change the trailing constant (`+ 2`) to make sides wider/narrower
- `expansionWidth` / `baseWidth` control hit-testing area, NOT visual width — don't touch those for visual sizing

## Workflow

### Always rebuild + restart after code changes
After modifying any code, always: build → kill running app → install to /Applications → relaunch. Don't just build and leave the old binary running. Command: `pkill -9 -f "Claude Island"; sleep 1; MARKETING_VERSION=1.4 CURRENT_PROJECT_VERSION=73 ./scripts/build.sh && open "/Applications/Claude Island.app"`

## Per-session vs global state

### Notification suppression must be per-session
**Bug:** `notificationSuppressedUntil` was a single global timestamp. Every session entering `processing` refreshed it. In multi-session scenarios, session B's ongoing processing kept pushing the suppression window forward, swallowing session A's completion notification (no sound, no checkmark).

**Fix:** `notificationSuppressedUntil` changed from `Date` to `[String: Date]` keyed by `session.stableId`. Each session's suppression window is independent.

**Rule:** Any state that gates per-session behavior (sounds, indicators, timers) must be keyed by session ID, not stored as a single global value.

## JSONL parsing

### Don't use naive string matching on JSONL lines
**Bug:** `/clear` detection used `line.contains("<command-name>/clear</command-name>")`. When Claude's Edit tool modified `ConversationParser.swift` itself, the tool_result in the JSONL contained that exact string as *data* (it was quoting the source code being edited). The parser treated every such tool_result line as a `/clear` command → wiped all chat history.

**Fix:** Parse the JSON, verify `type == "user"` and `message.content` is a String (not array) starting with the marker.

**Rule:** Always parse JSON structure and check `type`, `role`, etc. before acting on content patterns. A JSONL line can contain any string as data payload — including your own source code.

## Coordinate systems

### Multi-monitor: window coordinates != screen coordinates
**Bug:** `updatePanelFrame` used `geo.frame(in: .global)` directly as screen coordinates. `.global` gives window-relative coordinates. On multi-monitor, the built-in screen's origin can be e.g. `(-1470, -157)`, not `(0, 0)`. The panel frame was off by the entire screen offset → hover detection instantly closed the panel because `NSEvent.mouseLocation` (correct global coords) didn't match `panelScreenFrame` (wrong coords).

**Fix:** Reconstruct global position using `viewModel.screenRect.origin` (the actual screen's frame including offset).

**Rule:** Never assume screen origin is `(0, 0)`. Always use `screen.frame.origin` when converting between coordinate systems. Test with external displays.

## Window event handling

### `ignoresMouseEvents` can get stuck
**Bug:** `NotchPanel.sendEvent` set `ignoresMouseEvents = true` for pass-through clicks, but never restored it. The status sink only fires on status *changes* — if status stayed `.opened`, the sink wouldn't re-trigger. Result: the 750px window silently ate all mouse events in the upper screen area (beach ball / freeze appearance).

**Fix:** After reposting the event, restore `ignoresMouseEvents = false` on the next runloop tick if the panel is still opened.

**Rule:** Any temporary state change in `sendEvent` must be explicitly restored. Don't rely on external observers to clean up.

### Non-hover-opened panels must also auto-close
**Bug:** Auto-close on mouse leave was gated on `openReason == .hover`. Panels opened via `.click` or `.notification` would never auto-close when mouse left. Combined with the `ignoresMouseEvents` bug, this created permanently stuck panels.

**Fix:** All open reasons trigger auto-close. Hover uses 0.18s delay; click uses 0.6s.

**Rule:** Every opened state must have a path to close. Never leave a panel open with no way out.

## Code signing & Sparkle updates

### Bundle must be properly adhoc-signed for Sparkle
**Bug:** `xcodebuild` with `CODE_SIGNING_ALLOWED=NO` only left linker-level adhoc signature on the Mach-O — no `_CodeSignature/` directory. Sparkle downloaded the update, verified EdDSA (OK), but Apple code signing check failed (`errSecCSSignatureInvalid`). Update silently failed at 100%.

**Fix:** `build.sh` runs `codesign --force --deep --sign -` after xcodebuild.

**Rule:** Always run `codesign --verify --deep --strict` on the built app before packaging for distribution.

### CFBundleVersion must be monotonically increasing integer
**Bug:** `CFBundleVersion` was always `1` while `sparkle:version` in appcast used the marketing version (`1.4`). After installing 1.4, Sparkle compared `1.4 > 1` → always showed "update available" in a loop.

**Fix:** `release.sh` uses `git rev-list --count HEAD` as build number, writes it to both `CURRENT_PROJECT_VERSION` (xcodebuild) and `sparkle:version` (appcast). `sparkle:shortVersionString` carries the marketing version.

**Rule:** `sparkle:version` = build number (integer), `sparkle:shortVersionString` = marketing version (user-facing). Never use the same value for both.
