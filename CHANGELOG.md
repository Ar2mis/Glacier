# Changelog


## 2026-11-18 — Mac App Store preparation (0.7.0 / 12)

- Added native sandboxed GlacierMac and isolated GlacierMacDev targets, configurable
  bundle/team settings, shared icon/privacy resources and iOS 18 Translation readiness.
- Compiled Wispr accessibility control out of store builds; added per-provider
  audio/text consent checks before network requests. Apple local translation is the
  new-install default; cloud captions can fall back after a 2.5-second first-token wait.
- Moved model initialization off the decoder actor, made preparation waiters
  cancellable/bounded, serialized inference across restarts, and added explicit
  prepare-without-recording controls. Full text and Stop-tail handling remain tested.
- Added security-scoped export folders, an offline English Word export, original
  geometric ice-cube assets, privacy/support documents and generated static HTML.
- Local updater now installs only Glacier Dev.app with a .dev identity and separate
  data; official Glacier.app is protected by the atomic installer guard.
- Local verification passed: 36 Python checks, 36 SSE checks, 42 session
  simulations, Core/caption/soak checks and independent full/offline Word readers.
  APP_STORE compilation, signed-entitlement/AX-symbol inspection, real sandbox
  credential persistence and an actual Apple Translation UI smoke also passed.
  The current local toolchain is Command Line Tools; hosted Xcode target builds
  are separate from these checks. Distribution signing, App Store validation and real classroom/device acceptance
  remain release gates; no approval or measured end-to-end latency guarantee is claimed.

## Unreleased

### DI-06: Honor dated translation retry instructions (2026-11-17)
- Add a shared Retry-After parser for nonnegative seconds and the three HTTP date formats, with an injectable reference time and fixed POSIX locale/GMT handling.
- Clamp past dates to zero and fall back to the existing retry policy for missing, malformed, non-finite or out-of-range values. Keep provider error messages sanitized and preserve permanent quota/access error classification.
- Use the parser in both complete-response and SSE error paths. Add deterministic date/invalid-value cases and mocked HTTP-date rate-limit coverage across OpenAI, Gemini and DeepSeek; no real API requests or keys are used.
- Verification: full native `CI=true bash scripts/ci.sh`, including 34 portable tests, 33 stream checks, 41 session checks, shared Core, accelerated soak, Word export/recovery validation and the daily workflow guard.

### DI-05: Consistent course glossary prompts (2026-11-17)
- Reuse GlacierCore's course vocabulary normalization for OpenAI, Gemini and DeepSeek translation prompts: trim empty lines, remove case-insensitive duplicates and preserve the first term's spelling and bilingual mapping.
- Apply the 4,000-character limit after deduplication, including newline separators, without cutting a technical term in half.
- Add native pipeline regression coverage for repeated, blank, bilingual and over-limit glossaries, idempotence and all three provider request bodies. Verification: native pipeline suite, portable checks and daily workflow guard.

### Reduce Chinese translation head-of-line delay (2026-11-16)
- The owner confirmed that 0.6.4 made English noticeably faster, while Chinese still lagged. This follow-up targets translation scheduling without changing ASR models or discarding the full lecture transcript.
- Request Chinese before cleaned English using an explicit instruction, required-field order and deterministic JSON schema serialization. Retain strict completion validation and the existing conservative glossary/negation rules.
- Allow at most two live cloud requests, spaced by at least 800 ms. Coalesce pending work to the newest ready source; keep Apple translation and reading-priority mode serial.
- Keep out-of-order results in their exact-source history entries without rewinding displayed Chinese. Stop/restart cancels all active requests and rejects late callbacks. Network retry backoff and Apple fallback remain available.
- Verified the full native build and shared Core suite, 41 session assertions, 34 portable tests, accelerated two-hour soak, Word export/recovery checks and the daily workflow guard.
- Three synthetic GPT-4o mini smoke requests produced first Chinese in 2.51, 0.77 and 0.62 seconds, before cleanup completed. These are network-dependent translation-only samples, not end-to-end classroom latency measurements.

### Catch up during continuous speech (2026-11-16)
- Local voice testing confirmed the ice starts the microphone and stops/finalizes the recording, but the user still experienced caption latency.
- Decouple live English from GPT and stable-prefix translation scheduling: raw ASR drafts appear immediately, previous Chinese stays visible with a catching-up label, and older translation replies cannot rewind the English. Reading-priority mode still holds matched pairs.
- Stop treating capitalization/punctuation revisions as entirely unstable speech. Preserve real word-change and negation checks.
- In live-follow mode, translate the newest ready sentence after a busy request and discard superseded queued requests, preserving all source history and the separate full-lecture journal. Reading-priority mode retains ordered translation.
- Shorten live-only coalescing waits to 150 ms / 700 ms, with regression coverage for busy translation, retained unready work, complete source history and punctuation-only ASR changes.
- Verified the full native suite: build, shared Core, 35 session assertions, 34 portable tests, accelerated soak and Word archive validation. The user voice test and transcripts remain local and are not committed.

### Responsive ice startup and live streaming (2026-11-15)
- Reproduce the desktop startup stall in Core ML encoder specialization. Start microphone ingestion independently of model readiness, prewarm downloaded models on Mac launch without opening the microphone, use complete-cache lookup without remote enumeration, and retain the prepared Mac Whisper adapter. Hardware compute defaults and model choices are unchanged.
- Accept the first inactive-window ice click, ignore the second click of a double-click, show persistent preparation/cancel state, and report startup failures beside the ice. Announce recording only after microphone startup succeeds.
- Ingest audio while decoding and coalesce superseded partials at a 0.75-second audio cadence. Preserve ordered final windows and the Stop tail with a bounded, explicit overload failure.
- Stream validated bilingual fields from Responses SSE, while requiring a successful completion before treating translation as final. Handle split escaped/Unicode JSON, refusal, failed/incomplete streams and size bounds.
- Default Mac captions to live follow without the forced five-second presentation queue. Keep the previous bilingual pair until the next useful translation arrives; reading-priority dwell remains selectable.
- Verified native build, shared Core checks, all seven Swift suites (32 session assertions), 34 portable tests and schedule guard. A synthetic real GPT-4o mini request produced its first bilingual update in about 1.1 seconds and completed in about 2.2 seconds; this excludes ASR and is not a classroom latency guarantee.

### Readable live captions and transcription context (2026-11-14)
- Stop incoming Whisper partials and fast translations from replacing a just-completed bilingual pair. Add a five-second default reading interval (2–12 seconds), a bounded revision-coalescing presentation queue and immediate cancellation on Stop.
- Translate stable prefixes before the ASR final boundary, while preserving full raw hypotheses/finals in the lecture journal. Use cleaned English in subsequent translation context so corrected terminology does not revert to the recognition error.
- Default Mac to WhisperKit Large v3 Turbo, retain Base for mobile/low-memory use, and condition decoding on bounded course vocabulary and previous finalized text. Show the active translation engine explicitly.
- Synthetic Turbo speech testing found a remaining technical-word error; real GPT-4o mini cleanup corrected it and produced Chinese while preserving negation/net-movement meaning. This is not evidence of zero-error live classroom recognition.
- The prior API key was successfully migrated to private persistent storage; the actual desktop GPT-4o mini connection test passed. Native verification passed the Mac build, shared-core tests, all seven Swift suites, 25 session assertions and 34 portable tests.

### Reliable desktop credentials and automatic Apple fallback (2026-11-14)
- Unify Mac ASR, live translation and archive credential loading through GlacierCore. Persist user-saved or migrated keys outside the bundle in a private config file; preserve them when an ad-hoc rebuild loses Keychain access. iOS stays Keychain-only.
- Add one-click Test Connection using the selected live caption model, persistent save after a successful test, clear status, and one-time legacy Keychain migration. No credential values are logged.
- Seed missing OpenAI credentials from literal environment/shell/.env assignments during local updates, without executing shell files or replacing saved/deleted keys. Malformed config files remain intact.
- Initialize installed Apple English–Chinese translation automatically and retry the same caption locally on the first cloud failure. Missing language packs show actionable download instructions; English capture continues.
- Native verification found DI-04's invalid Swift regex literal. Replace the unsafe custom regex with bounded NaturalLanguage token merging; keep and pass every existing academic abbreviation/decimal regression.
- Verified native Mac build, shared-core checks, all seven Swift suites, 22 session assertions, 34 portable automation/migration tests, accelerated soak and Word export. A real Apple translation probe and caption fallback succeeded using installed language packs; live OpenAI verification still requires an accessible user credential.

### Complete WhisperKit lectures and unattended local updates (2026-11-13)
- CORE-06: persist every GlacierCore ASR utterance in a private on-device journal, replacing partial revisions without duplicating text and retaining raw English after export.
- WhisperKit Stop drains queued PCM and the resampler tail, decodes residual speech, waits for persistence, and queues the existing complete-transcript archive. Captions hide immediately; repeat Stop/restart cannot interrupt finalization.
- Mac and iOS now export Word without Wispr: Chinese summary, rendered mind map, English outline, full English then full Chinese. Mac writes course/topic folders on Desktop; iOS writes Documents/Glacier with sharing and foreground recovery.
- Preserve translation checkpoints across API/network failures and app relaunches. Stable session IDs make archive handoff idempotent. Interrupted captures and adapters without guaranteed final audio flushing are explicitly labelled.
- Reuse one OOXML/ZIP writer across Mac and iOS; retain the Mac Wispr archive and existing credentials/providers. Raw audio files are not retained; crashes cannot reconstruct audio that was never recognized.
- Add AGENTS.md standing instructions to verify, commit and push authorized changes to main, plus a CI guard for 01:30 UTC cron, scheduled-only four-hour jitter and conditional main squash merge.
- Add a 1 PM Eastern local updater with hourly retry eligibility, clean-checkout/local-commit guards, detached native verification, signature checks, atomic installation and rollback copy. Active Glacier sessions defer installation.
- Local verification: all native suites and shared-core checks pass, including 1,002 saved utterances, final-audio draining, 19 session assertions, network-loss archive recovery, accelerated soak and Word generation; 30 portable automation/updater tests pass. Independently validated DOCX ZIP/XML and visually checked all eight synthetic document pages. Native iOS compilation is checked by the hosted Simulator job.

### Shared WhisperKit transcription and bilingual refinement (2026-11-13)
- Added GlacierCore with pinned WhisperKit 1.1.1, Base/Turbo selection, bounded PCM capture, Apple SFSpeechRecognizer, OpenAI chunked audio transcription and Deepgram streaming options.
- Added one-pass English cleanup/Chinese translation with strict structured output, course vocabulary, preserved source text, bounded context and explicit cloud audio/text disclosure.
- Added a foreground iOS SwiftUI app and unsigned simulator build check; retained the macOS overlay, Wispr path and existing translation/archive providers.
- Fixed DI-02's generated native test: it mutated private setters, dequeued before debounce, and asserted an incorrect rolling-context boundary. Tests now exercise public buffer behavior and reject stale cleanup results.
- Updated the daily cron to 01:30 UTC (8:30 PM EST / 9:30 PM EDT) with its existing 0–4 hour scheduled jitter. The immediate run skipped jitter but rejected its DI-03 patch before publishing; no change was merged from that failed run.
- Verification: native macOS build, shared-core checks (including a mocked single-request bilingual response), all seven legacy Mac suites, 21 automation tests, and GitHub-hosted iOS Simulator compilation. A local WhisperKit Base smoke test correctly transcribed synthetic speech about a cell membrane and osmosis; it used no microphone or cloud ASR.
- Preserved recent bilingual-pair display during continuous ASR revisions while retaining exact-source guards for stored history; the session regression suite caught and verified this distinction.
- No claim of live lecture accuracy, iPhone performance, live provider access, or an App Store/notarized release. Full independent-ASR archiving and final-utterance flushing remain on the roadmap.

### Caption queue — DI-01 (2026-11-13)
- Prune obsolete debounce timestamps during sentence merges and history expiry, while preserving the initial timer for pending transcript revisions.
- Corrected the generated expiry fixture, which advanced only ten seconds, and added regressions for the five-minute boundary, empty observations, continuous revisions, and restored sentence suffixes. Private-state inspection now fails explicitly if unavailable.
- Verified on Apple Silicon macOS 27.2 with `CI=true bash scripts/ci.sh`: native app build, shell/Python syntax, 18 automation tests, and all seven Swift verification suites passed, including streaming/session faults, the accelerated two-hour soak, and Word export. Live microphone/Wispr/provider testing was not part of this verification.

### Repository and automation
- Hardened asynchronous session tests with bounded waits for completed state and unbuffered failure diagnostics after an intermittent hosted-runner assertion. All 15 session checks still pass, including an explicitly observed late callback after cancellation; application timing was not changed.
- Normalize duplicated blank lines at the end of generated Swift files before draft/verification, with a regression test. Two DI-03 attempts were correctly rejected by the whitespace gate; this formatting-only normalization preserves internal whitespace and all existing validation gates.
- Added scheduled 0–4 hour jitter and automatic squash merging after Ubuntu portable checks. Candidate PRs are opened as drafts before verification; failures retain a draft. Automated completion records the portable-only verification level, not native build success.
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

## 2026-11-13 — DI-02

- Exclude unfinished translations from subsequent sentences' translation context.
- Ubuntu portable checks passed; native Swift build/tests NOT run. Completed under the configured automatic portable-only policy.

## 2026-11-13 — DI-03

- Bound extremely long unpunctuated caption segments at whitespace without losing source characters.
- Ubuntu portable checks passed; native Swift build/tests NOT run. Completed under the configured automatic portable-only policy.
- Subsequent local verification of merged PR #4: `CI=true bash scripts/ci.sh` passed the native Mac build, shared-core checks, all seven Swift suites and 22 automation tests. Unicode/whitespace reconstruction, session behavior, accelerated two-hour soak and Word export passed. The shared iOS target also compiled successfully in GitHub-hosted Simulator CI; lecture/device accuracy remains unmeasured.

## 2026-11-14 — DI-04

- Improve sentence splitting around academic abbreviations and decimal numbers.
- Ubuntu portable checks passed; native Swift build/tests NOT run. Completed under the configured automatic portable-only policy.

## 2026-11-18 — DI-07

- Limit accumulated SSE translation content independently of the per-line limit.
- Ubuntu portable checks passed; native Swift build/tests NOT run. Completed under the configured automatic portable-only policy.
