# Changelog

## Unreleased

### Caption queue — DI-01 (2026-11-13)
- Prune obsolete debounce timestamps during sentence merges and history expiry, while preserving the initial timer for pending transcript revisions.
- Corrected the generated expiry fixture, which advanced only ten seconds, and added regressions for the five-minute boundary, empty observations, continuous revisions, and restored sentence suffixes. Private-state inspection now fails explicitly if unavailable.
- Verified on Apple Silicon macOS 27.2 with `CI=true bash scripts/ci.sh`: native app build, shell/Python syntax, 18 automation tests, and all seven Swift verification suites passed, including streaming/session faults, the accelerated two-hour soak, and Word export. Live microphone/Wispr/provider testing was not part of this verification.

### Repository and automation
- Moved daily proposal verification to Ubuntu-only portable checks. Draft PRs explicitly require native Mac verification; roadmap completion and changelog updates remain manual until then.
- Documented the native macOS architecture, setup, privacy boundaries and known limitations.
- Added a scoped 15-task roadmap and a guarded OpenAI-powered daily improvement pipeline.
- Added CI and offline automation tests. Daily proposals require portable checks; completion requires native checks and human PR review.
- Updated the synthetic audio-conversion fixture to signed 16-bit PCM, verified the output format, and skipped optional speech-asset discovery in headless CI.

## 0.4.0 — existing local prototype

- Wispr UI integration, transparent bilingual overlay, draggable ice launcher and 30-second history.
- Provider-specific streaming translation, retry classification, stale-session guards and Apple translation fallback.
- Resumable full-transcript translation and Word study-note export.
- Synthetic stream, queue, session, accelerated-soak and archive verification programs.

This entry describes the imported prototype, not a published or notarized release.
