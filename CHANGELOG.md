# Changelog

## 2026-02-28 (4687307)

### Added
- Usage history log written to `~/Library/Application Support/TokenEater/usage-log.ndjson` — one JSON line per successful API fetch with full response data and fetch timestamp
- "Usage Log" section in Connection settings showing the log file path and a "Reveal in Finder" button

### Removed
- File-based offline cache (`claude-usage-cache.json`) — stale data on startup is not useful; widget and menu bar now show an error on network failure instead

### Refactoring
- Auth method label in UI corrected to "Claude Code (auto)" across connection and settings views
- Pacing display mode added: dot + time offset (shows minutes ahead/behind ideal pace)
- Version injected at build time rather than hardcoded

---

## 2026-02-28 (b941ee2)

### Added
- Launch at Login toggle in Display settings (via `SMAppService`)

### Fixed
- Keychain password prompt triggering on every usage refresh — token is now cached in a separate keychain item; Claude Code's keychain is only read on first access or after token expiry (401/403) `f3c3345` `26c1a0b`
- Settings window no longer opens automatically on launch `7be65f9`

### Settings
- App logo and version moved to a dedicated About tab
- Pacing display mode section disabled when Pacing metric is not pinned
- At least one pinned metric is always enforced
- Removed "Show in menu bar" toggle — menu bar icon is always present

### Refactoring
- `KeychainOAuthReader` public API narrowed to `cachedToken()` and `invalidateCache()`
- Raw Security framework calls extracted into a reusable `KeychainItem` wrapper

---

## 2026-02-27 (febc24d)

### Added
- Extra usage row with monthly credit limit pacing
- Notifications at 95% and 100% usage
- Proper usage coloring thresholds
- Hide Sonnet limit when null in API response
