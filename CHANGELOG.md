# Changelog

## 1.5.0 — 2026-04-09

### Features

- Add "+" button in notch header to create new tmux sessions running Claude Code.
- Tmux sessions use `claude-N` naming with smallest available number.
- Add trash button to kill individual tmux panes without affecting other sessions.
- Show tmux session name badge (`tmux: claude-1`) in chat header.
- Markdown links are now clickable — URLs open in browser, file paths open in Finder.
- Working directory in chat header is clickable — opens folder in Finder and closes panel.
- Bottom scroll fade gradient on instances list hints at more content below.

### Fixes

- ThinkingView now shows full text with auto-wrap instead of truncated ellipsis.
- Fix list item text wrapping in MarkdownRenderer cutting off long lines.

---

## 1.4.1 — 2026-04-08

### Fixes

- External display now uses built-in screen's notch size instead of hardcoded
  fallback, ensuring consistent sizing across all displays.
- Fine-tune internal display idle notch height (+0.5 offset).
- StatusLine wrapper auto-detects app deletion and restores original statusLine
  config, removing all wrapper artifacts on next invocation.

### Build

- `build.sh` now auto-derives `CURRENT_PROJECT_VERSION` from `git rev-list --count HEAD`,
  preventing false Sparkle update prompts during development.
- Adopt Semantic Versioning (`MAJOR.MINOR.PATCH`) for all releases.

---

## 1.4 — 2026-04-06

### Chat view

- New unified tool-call display: `● ToolName(arg)` header with collapsed-by-default
  result; click the chevron to expand full output.
- Markdown tables now render with borders, headers and cell separators.
- Paste placeholder: long/multi-line pastes show `[Pasted text #N +X lines]` in
  the input; original text is sent via tmux bracketed-paste so Claude CLI shows
  the same placeholder in its own input.
- Draft persistence: typed text is remembered per session across panel closes.
- Text selection enabled on assistant messages.
- Input UX: focus glow, proper I-beam/link cursors, click-anywhere to focus,
  send button hover + press animation, click empty area to defocus.
- "Pending" user-message bubble appears immediately on send (before JSONL sync).
- Swipe-back navigation: two-finger right-swipe returns from chat/menu to main.
- Tool calls show hand cursor + lighter rounded hover background.
- Bash, Read, Edit, Grep, Glob, WebSearch, WebFetch all share the same header
  format and receive expand/collapse on completion.
- Edit tool now collapses by default (diff only shown on expand).
- ESC while processing marks the session as user-interrupted (red ✗ indicator).

### Companion pet

- Context-aware effect badges next to the pet:
  - `...` while the user is typing (rotates through 1/2/3 dots)
  - `?` while Claude is thinking
  - `zZ` when idle for 30s+
- Effects use the pet's rarity color and sit to the left of the sprite.
- Pet gently paces left↔right when the panel is idle (no activity, closed).

### Notch / UI

- Page indicator dots at the bottom of the opened panel switch between
  the sessions list and settings menu.
- Menu page: wrapped in ScrollView so content grows safely; hover now lights up
  the whole row (including the space after labels) in every settings picker.
- Hooks off→on now re-scans active sessions and re-reads JSONL so recent
  messages / tool calls appear immediately.
- 5h/7d usage badge now refreshes from the most recently updated session cache
  file, so it reflects the active conversation instead of an idle one.
- Main-page row click opens chat (dedicated chat button removed).
- Sessions with a pending permission float to the top of the list.
- Status indicators (spinner / ✓ / ✗ / ?) centered in the notch right slot.

### Hooks / statusLine

- statusLine wrapper is self-healing: if another tool (e.g. claude-hud) replaces
  our config, Claude Island re-wraps it on next launch and persists the user's
  original command in a backup file.
- Complex statusLine commands (nested quotes, awk pipelines) are executed via a
  sidecar script — no more eval-based escaping corruption.
- Cache file now includes model id, token breakdown (input/output/cache),
  cost, api duration, lines added/removed, plus 5h/7d reset timestamps.

### Fixes

- Fix panel disappearing when returning to the main list via two-finger
  swipe-back (from chat or menu): the hover-bounds grace is now applied
  on every transition into the instances page, matching the page-dot
  click behaviour.
- Fix chat view showing stale history while the main page already shows
  a newer message: entering chat now always re-syncs from JSONL instead
  of trusting the in-memory cache.
- Fix git branch in the chat header not updating when you `git checkout`
  another branch while the chat stays open.
- Fix tool results staying empty after PostToolUse: JSONL sync now fills
  `result` / `structuredResult` on tools already marked `.success`.
- Fix 5h/7d badge not clearing after uninstalling hooks.
- Fix duplicate Stop hook reference left behind when toggling hooks off/on.
- Fix `statusLine.type` missing in settings.json causing `/doctor` error.
- Fix Bash commands > 1 line occasionally not being submitted (bracketed-paste
  gets a 300ms settle before Enter).
- Fix assistant messages containing only whitespace showing a stray gray dot.
- Fix cross-session message flicker caused by `pendingUserMessage` transitions.

### Removed

- CPU-based interrupt detection (10s idle threshold) removed.
- Boot animation (notch briefly expanded on launch) removed.
- Hooks on/off toggle remains but no longer clears old in-memory state
  aggressively; external tool interop is smoother.
