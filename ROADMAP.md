# Glacier roadmap

Ordered, small reviewable changes. The bot selects the first unchecked task only.
Each task declares the exact existing files it may edit; tests must be extended in
an existing executable test suite. The daily bot marks `[x]` after passing Ubuntu
portable checks under the owner's automatic merge policy. A checkmark does NOT
mean the native Swift build or Swift tests passed; consult CHANGELOG.md for the
actual verification level. The entry advances only when the PR merges.
If a task needs broader changes, revise its scope manually instead of bypassing it.

## Shared speech architecture (manual integration, outside the daily bot scope)

- [x] CORE-01: Add pinned WhisperKit 1.1.1 to the shared GlacierCore Swift package, with Base and Large v3 Turbo model selection.
- [x] CORE-02: Add bounded microphone capture and selectable WhisperKit, Apple SFSpeechRecognizer, OpenAI chunked ASR and Deepgram streaming adapters; retain Mac Wispr/SpeechAnalyzer paths.
- [x] CORE-03: Add TranscriptRefiner for one OpenAI request returning cleaned English and Chinese, with editable course vocabulary, bounded context and retained raw ASR.
- [x] CORE-04: Wire shared providers into the Mac settings and add an iOS foreground captioning target and simulator build check.
- [ ] CORE-05: Measure real microphone latency, academic word error rate, cleanup meaning preservation and iPhone memory/thermal behavior for Parakeet EOU versus WhisperKit Base/Turbo. Paced file replay is implemented; classroom and iPhone acceptance remain open.
- [x] CORE-06: Persist full independent-ASR lecture transcripts, drain WhisperKit audio on Stop, and export complete bilingual Word study notes without Wispr on Mac and iOS.
- [ ] CORE-07: Add model download progress/retry/offline management, interruption/route-change recovery and on-device UI tests.
- [ ] CORE-08: Add provider-specific graceful finalization for Apple/OpenAI/Deepgram; currently their saved transcripts explicitly warn about potentially unfinished audio.

- [x] CORE-09: Integrate pinned FluidAudio Parakeet EOU on Mac/iOS with bounded incremental decoding, graceful Stop, shared lecture journaling/export, and reproducible same-audio paced comparison against WhisperKit.
- [x] CORE-10: Default new translation settings to GPT and retain slow successful requests beyond 2.5 seconds; retain visible Apple fallback for actual failures and missing credentials, with regression coverage.

## Daily bounded improvements

- [x] DI-01: Prune obsolete caption debounce timestamps when sentences merge or history expires.
  - Files: Sources/CaptionHistory.swift, Tests/CaptionQueueTests.swift
  - Acceptance: Remove stale queuedAt entries during update; preserve debounce for pending revisions; add deterministic merge/expiry regression tests.
- [x] DI-02: Exclude unfinished translations from subsequent sentences' translation context.
  - Files: Sources/CaptionHistory.swift, Tests/CaptionQueueTests.swift
  - Acceptance: Context includes only exact completed source/translation pairs, at most four; test partial, revised and completed cases.
- [x] DI-03: Bound extremely long unpunctuated caption segments at whitespace without losing source characters.
  - Files: Sources/SentenceFeed.swift, Tests/PipelineVerify.swift
  - Acceptance: Add a bounded splitting helper used by sentences; cover Unicode, whitespace and long academic passages, preserving order.
- [x] DI-04: Improve sentence splitting around academic abbreviations and decimal numbers.
  - Files: Sources/SentenceFeed.swift, Tests/PipelineVerify.swift
  - Acceptance: Fixtures for e.g., i.e., Dr., decimal measurements and sentence-ending punctuation keep useful caption boundaries.
- [x] DI-05: Normalize duplicate and empty academic glossary lines before prompt construction.
  - Files: Sources/GPTTranslator.swift, Tests/PipelineVerify.swift
  - Acceptance: Keep the first occurrence and original term spelling; preserve the 4,000-character bound; test blank and bilingual glossary lines without changing credential handling.
- [x] DI-06: Parse HTTP-date Retry-After values as well as numeric seconds.
  - Files: Sources/GPTTranslator.swift, Tests/StreamVerify.swift
  - Acceptance: Shared deterministic parsing with injectable time handles future, past and invalid values; use it in both response paths.
- [x] DI-07: Limit accumulated SSE translation content independently of the per-line limit.
  - Files: Sources/GPTTranslator.swift, Tests/StreamVerify.swift
  - Acceptance: Many small deltas cannot grow text indefinitely; oversize streams fail with a sanitized typed error and regression coverage.
- [ ] DI-08: Recover the Wispr observer after a terminal transcript-gap failure.
  - Files: Sources/App.swift, Sources/WisprCapture.swift, Tests/SessionVerify.swift
  - Acceptance: Reset observer state after terminal failure and allow an explicit reconnect; ignore callbacks from the previous observer generation; do not start a new recording.
- [ ] DI-09: Preserve recording state when repeated unknown Wispr observations arrive.
  - Files: Sources/App.swift, Tests/SessionVerify.swift
  - Acceptance: Unknown state never falsely reports stopped or hides an active caption session; test active/unknown/stopped transitions and late callbacks.
- [ ] DI-10: Add keyboard shortcuts for opening settings and the 30-second history window.
  - Files: Sources/App.swift, Tests/SessionVerify.swift
  - Acceptance: Expose menu key equivalents and test action routing without starting recording; no new global input-monitoring permissions.
- [ ] DI-11: Clamp persisted caption sizing and offsets to valid screen-safe ranges.
  - Files: Sources/App.swift, Tests/SessionVerify.swift
  - Acceptance: Handle non-finite and out-of-range saved values in a pure helper with tests; preserve transparent, click-through captions.
- [ ] DI-12: Strengthen archive translation coverage validation against duplicate or unexpected IDs.
  - Files: Sources/LectureArchive.swift, Tests/ArchiveVerify.swift
  - Acceptance: Reject duplicate, missing, unexpected and whitespace-only translations with precise errors; retain exact English reconstruction.
- [ ] DI-13: Make export filenames robust to reserved names and very long Unicode course titles.
  - Files: Sources/LectureArchive.swift, Tests/ArchiveVerify.swift
  - Acceptance: Bound filename length without splitting graphemes; prevent empty or dot-only names; preserve Chinese titles and uniqueness suffixes.
- [ ] DI-14: Add a Markdown study-note companion to the Word export.
  - Files: Sources/WordExporter.swift, Tests/ArchiveVerify.swift
  - Acceptance: Save summary, English outline, full English then full Chinese alongside DOCX; escape Markdown structure and test content ordering.
- [ ] DI-15: Improve Word document pagination and accessibility of study notes.
  - Files: Sources/WordExporter.swift, Tests/ArchiveVerify.swift
  - Acceptance: Use semantic heading styles, keep headings with following paragraphs and label the mind-map image; inspect generated OOXML in tests.

## Larger work requiring a separate design

- Evaluate end-to-end microphone-to-caption latency and domain terminology accuracy with consented lecture samples.
- PDF export, editable course glossary presets, stable Developer ID signing/notarization.
- Broader iOS feature parity, signed distribution and real-device validation; no App Store release is shipped.

## Store distribution (manual work, excluded from daily bot)

- [x] STORE-01: Add native GlacierMac/GlacierMacDev targets, configurable signing/bundle IDs, sandbox entitlements and compile-time removal of Wispr automation.
- [x] STORE-02: Isolate nightly developer installs and app data from official Glacier; refuse official-app replacement.
- [x] STORE-03: Add original generated Mac/iOS icon assets, privacy manifest, bundled policy/support and static Pages source.
- [x] STORE-04: Add recipient/data-specific cloud consent, Apple-first captions, cancellable model preparation and scoped-folder persistence.
- [ ] STORE-05: Validate a distribution-signed Archive, privacy report, TestFlight first-install/whole-lecture tests and published support URLs after developer enrollment. Simulator/portable checks alone do not complete this item.
