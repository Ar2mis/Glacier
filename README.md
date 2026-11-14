# Glacier 🧊

**On-device lecture transcription and English–Chinese captions for macOS and iOS.**

Glacier is an Apple Silicon desktop prototype for students who follow spoken
English more easily with captions. A transparent, always-on-top overlay keeps
English and Chinese visible while you read slides or use another application.
The iOS preview displays captions inside the app. Both use the shared Swift
package `GlacierCore`; the system-wide overlay and Wispr integration remain Mac features.

## What works in the implementation

- **Independent speech input:** WhisperKit 1.1.1 is the default for fresh installs.
  Choose multilingual Base or Large v3 Turbo. Models download/cache on first use;
  microphone audio is then decoded on device, without Wispr. Existing Mac input
  preferences are preserved. Bounded 16 kHz audio windows publish partial English
  after about 1.5 seconds of new audio and finalize on silence or a six-second
  boundary. These are scheduling thresholds, not measured latency guarantees.
- **Selectable alternatives:** on-device Apple `SFSpeechRecognizer`, OpenAI audio
  uploads in up-to-three-second chunks, or Deepgram WebSocket streaming. The Mac
  also retains Apple `SpeechAnalyzer` and Wispr input. Cloud speech is an explicit
  selection and sends audio to that provider; Deepgram uses its own API key.
- **One-pass bilingual cleanup:** `TranscriptRefiner` uses `gpt-4o-mini` (default)
  or `gpt-5-mini` with a strict JSON schema, returning cleaned English and Chinese
  in one request. Course Vocabulary / Glossary supplies names and academic terms.
  It preserves meaning and raw source, limits context to four pairs and glossary
  to 4,000 characters, and avoids blindly deleting meaningful words like “like.”
  Raw partial text appears before cleanup completes. New speech providers refine
  finalized utterances; the existing Wispr buffer still coalesces revisions.
- **Wispr live captions:** observe an existing Wispr Flow Notetaker transcript through
  macOS Accessibility; segment and coalesce revisions before translation.
- **Translation:** OpenAI Responses API, Gemini's OpenAI-compatible endpoint, or
  DeepSeek. OpenAI/DeepSeek use streamed text; Gemini uses complete responses.
  Installed Apple English–Chinese translation can serve as an explicit option or
  a fallback after cloud credential/quota failures or repeated transient errors.
- **Desktop UI:** a draggable ice-cube launcher, confirmed start/stop indicators,
  a transparent click-through caption overlay, independent font/color/size/bold
  controls, adjustable shadows, and a draggable snapshot of the last 30 seconds.
  Defaults include Times New Roman and Songti SC.
- **Complete lecture storage:** GlacierCore speech sessions persist every utterance
  outside the short live-caption history. Partial revisions replace the same
  utterance; finalized text is preserved. WhisperKit Stop closes microphone input,
  drains queued PCM and resampler output, decodes residual speech, and waits for the
  transcript writer before starting the archive. The overlay hides immediately;
  a new recording waits until finalization completes.
- **Study notes without Wispr:** after Stop, optional automatic archiving translates
  the complete saved English in numbered chunks, generates a Chinese summary,
  rendered mind map and English outline, and exports Word with the full English
  followed by the full Chinese. Mac exports go to course/topic folders on the
  Desktop; iOS exports go to Documents/Glacier with a Share button. Wispr's existing
  full-transcript capture remains available on Mac.
- **Recovery:** raw utterances and English.txt remain on device after export.
  Archive checkpoints retain successful translations after API/network failures.
  Reopening Glacier resumes unfinished automatic exports; the archive controls can
  also retry or export sessions recorded with automatic export disabled. Stable
  session IDs prevent duplicate exports. Interrupted/provisional captures are
  explicitly labelled, never silently called complete.

**Status:** prototype, not a notarized production or App Store release. Wispr is
only required for Wispr mode and must be installed/signed in separately. Glacier
does not embed Wispr or copy VoiceInk's implementation. The iOS target is a
foreground captioning preview: no system-wide overlay. Keep Glacier open while
Word export finishes; iOS may suspend background work. WhisperKit guarantees the
implemented graceful Stop path; Apple/OpenAI/Deepgram adapters currently retain
available text with a finalization warning rather than guaranteeing final audio
flushing. Crashes/power loss cannot recover audio that had not yet been recognized.
The durable storage contains transcripts, not reusable audio recordings.
No built-in speaker diarization, PDF or Markdown export is shipped. Accuracy,
mobile thermals, real lecture latency and provider availability need live testing.

## Requirements and local setup

- Apple Silicon Mac running macOS 26 or later.
- Xcode 26+ or compatible Command Line Tools with the macOS 26 SDK and Swift
  compiler. The scripts compile in Swift 5 language mode for arm64/macOS 26.
- Python 3.9+ for repository automation/tests (CI uses Python 3.12).
- Wispr Flow only for Wispr input mode, and a provider API key for cloud
  translation/AI note generation. Apple translation needs installed language assets.
- SwiftPM resolves pinned WhisperKit (Argmax) and its package graph on first build.
  `Package.resolved` is committed; model weights are downloaded at runtime, never
  committed. No Python packages or `npm install` are required.

```sh
git clone https://github.com/Ar2mis/Glacier.git
cd Glacier
bash scripts/build.sh
open dist/Glacier.app
```

The build creates an **ad-hoc signed** app; it does not replace your installed
copy. For Wispr mode, grant **Glacier** Accessibility access in System Settings →
Privacy & Security → Accessibility. Rebuilding can change the ad-hoc signature,
so macOS may require reauthorizing the new build even when the old toggle is on.
Stable signing/notarization is still future work. Apple's microphone input mode
requires microphone permission and speech assets.

For a fresh local speech session, select **WhisperKit → Base**, save your OpenAI
key, and enable **一次请求完成英文整理 + 中文翻译**. The model preparation message
appears before microphone capture starts. Turbo uses Argmax's actual model name
`openai_whisper-large-v3-v20240930_turbo`; `openai_whisper-large-v3-turbo` is not the
Core ML repository identifier. First model loading can take much longer than
subsequent starts. On iOS, disable cleanup for local English-only use without a key.

In Glacier's settings, select the input and translation provider, save the API
key in the app's password field, and use **Test AI Translation**. If macOS denies
access to an existing key, use **Unlock saved key** and complete the OS prompt
personally. This desktop key is separate from the GitHub Actions secret.

For **Wispr mode only**, keep one Wispr Meeting Recorder window open on **Transcript**, scrolled to the
bottom and not minimized. Click the ice cube to start/stop, or operate Wispr
itself. Glacier observes recording state rather than assuming a click succeeded.
Right-click the cube to open the 30-second history. The subtitle overlay passes
mouse clicks through to apps underneath it. Settings are available from the menu
bar or app icon. Enter an optional course title/glossary and enable automatic
archiving if desired.

## iOS preview

Install full Xcode (Command Line Tools alone do not include the iOS SDK), open
`Glacier.xcodeproj`, select **GlacierIOS**, choose an iPhone simulator, and Run.
For a physical device, select your signing team and a unique bundle identifier.
The target supports iOS 17+, uses Base by default, and requests microphone/speech
permissions on use. It stops capture on backgrounding and requests limited time to
finish the audio tail; saved text survives suspension. Return to the foreground to
finish/retry Word exports. Files are accessible under Glacier in Files and through
Share Word document. It cannot place captions over other apps. User keys are saved
in that device's Keychain.

```sh
bash scripts/verify-ios.sh   # unsigned generic iOS Simulator build, full Xcode required
```

## Architecture

```text
GlacierCore: microphone → bounded PCM → WhisperKit / Apple Speech / cloud ASR
                                    → partial English + finalized utterances
                                    → TranscriptRefiner → cleaned English + Chinese
                                    → Mac overlay / iOS caption view

Legacy Mac paths retained:
Wispr audio/transcription → Accessibility snapshots (~350 ms)
                         → sentence/revision buffer → translation queue
Apple microphone → AudioBridge → SpeechAnalyzer ────┘
                         → selected cloud service / installed Apple Translation
                         → CaptionModel → SwiftUI/AppKit overlay + recent history

WhisperKit Stop → drain audio → finalize utterance → durable full transcript ─┐
Stopped Wispr recording → full transcript copy ──────────────────────────────┘
                         → resumable archive job
                         → chunk translation + AI digest → OOXML Word document
```

| Component | Responsibility |
| --- | --- |
| `Package.swift`, `Core/` | Shared speech provider contract, bounded microphone capture, WhisperKit, Apple/cloud adapters, one-pass refiner and Keychain utilities |
| `iOS/GlacierMobileApp.swift`, `Glacier.xcodeproj` | Foreground iOS captions, vocabulary/provider settings, cancellation and bounded cleanup queue |
| `Sources/App.swift` | Main-actor observable state, session lifecycle, translation tasks and AppKit panels |
| `Sources/WisprCapture.swift` | Accessibility reader actor, recording controls and transcript polling |
| `Sources/SpeechCapture.swift` | AVAudioEngine capture, PCM conversion and Apple SpeechAnalyzer input |
| `Sources/SentenceFeed.swift`, `Sources/CaptionHistory.swift` | Sentence boundaries, revision coalescing, debounce, translation jobs and recent history |
| `Sources/GPTTranslator.swift` | Provider requests, SSE decoding, typed failures and per-provider Keychain storage |
| `Sources/IceLauncher.swift`, `Sources/GlacierTheme.swift` | Floating launcher and light-blue UI styling |
| `Sources/LectureArchive.swift`, `Sources/WordExporter.swift` | Durable archive jobs, coverage validation, AI digest and DOCX generation |
| `Sources/Simulation.swift`, `Tests/` | Synthetic app scenarios and standalone executable verification suites |

Translation jobs become eligible after 350 ms without revisions, or after about
1.2 seconds of continuous revision. Jobs older than eight seconds are skipped to
avoid a growing live backlog; this can leave gaps in live Chinese captions. Full
archive translation is a separate pipeline. Late callbacks are guarded by session
identifiers so old results cannot reopen stopped captions. Transient failures
back off; credential/quota failures do not retry indefinitely. A live cloud request
has a ten-second total deadline. These are implementation limits, not measured
end-to-end latency guarantees.

There is no hosted Glacier backend. The macOS process talks directly to the
selected provider. Swift concurrency, `URLSession`, Foundation/NaturalLanguage,
AppKit, SwiftUI, AVFoundation, Speech, Translation and Security are used. Word
files are generated as OOXML using a shared ZIP STORE writer; no shell process is
needed on iOS.

## Privacy and limitations

- Runtime API keys are stored in macOS Keychain. Never commit keys, `.env` files,
  personal recordings, transcripts, exports or debug logs. `.gitignore` excludes
  these common locations and formats; it is not a substitute for reviewing diffs.
- Live translation sends the current sentence, up to four recent bilingual context
  pairs and glossary text to the selected provider. Archive generation sends the
  full transcript in chunks. WhisperKit/Apple recognition is local; explicitly
  selected OpenAI/Deepgram ASR sends microphone audio. Bilingual cleanup sends
  text to OpenAI even when recognition is local. Wispr handles its own data flow.
- OpenAI requests use `store: false`; this is not a claim of zero provider retention.
  There is no automatic switch to a different cloud provider.
- Archive progress is stored locally under
  `~/Library/Application Support/听课字幕/待归档` with restricted file permissions,
  not application-level encryption. Independent utterance journals and English.txt
  are stored under `~/Library/Application Support/Glacier/Lectures/<session UUID>`
  on Mac (the app sandbox's Application Support directory on iOS), with private
  directory/file permissions. They remain after export so a failed export or a
  pruned live history does not lose the original. Exports contain lecture content.
- Wispr UI automation depends on its window structure and permissions. Interface
  changes, transcript virtualization and observer failures can interrupt captions.
  Locked screens/system-protected windows are not supported overlay surfaces.
- Tests cannot verify Accessibility authorization, Keychain prompts, real microphone
  accuracy, provider account/model availability, translation quality or live latency.

## Build and verification

```sh
bash scripts/ci.sh                 # complete build + syntax + offline test gate
bash scripts/verify-all.sh         # seven legacy Mac verification suites
swift run -c release GlacierCoreVerify # shared pipeline's deterministic offline tests
# Optional real model smoke test: downloads/caches Base; use a synthetic/consented file.
swift run -c release GlacierCoreVerify --whisper-audio /absolute/path/to/audio.wav
bash scripts/verify-ios.sh         # iOS app + shared core compilation (full Xcode)
python3 -m unittest discover -s Tests -p 'test_*.py' -v
```

The native CI workflow builds macOS and iOS in separate jobs on `macos-26`.
The daily automation still uses Ubuntu portable checks only. The bot can edit
the declared legacy `Sources/` and `Tests/` scope; `Core/`, iOS and package/build
configuration are outside its autonomous editing allowlist.

## Sharing a development build

Build the app, then package only the app bundle:

```sh
ditto -c -k --sequesterRsrc --keepParent dist/Glacier.app dist/Glacier-macOS.zip
```

Recipients need an Apple Silicon Mac with macOS 26+, their own API keys, initial
model-download connectivity and permission grants. Wispr is optional. The ZIP is
an ad-hoc signed development build, not a notarized release. Public distribution
still needs Developer ID signing, hardened-runtime configuration, notarization
and device testing. iOS distribution needs signing/TestFlight or an App Store
release process; a macOS ZIP cannot install on iPhone.

`ci.sh` checks shell/Python syntax, runs automation unit tests, builds the app,
and executes audio conversion, caption queue, provider pipeline, SSE stream,
caption session, accelerated-soak and archive tests. Swift tests use
`precondition` and standalone executables, not XCTest. Mocked provider calls do
not consume API credits. `CI=true` skips optional local speech-asset inspection.
Generated files remain under `.build/` and `dist/`.

For a visual simulation, close other Glacier instances first:

```sh
dist/Glacier.app/Contents/MacOS/LectureCaptions --simulate
# Uses real installed Apple Translation, with simulated input/cloud failure:
dist/Glacier.app/Contents/MacOS/LectureCaptions --simulate-local
```

Neither simulation starts Wispr, records audio, reads API keys, or archives a
lecture. They stop after approximately 50 seconds; add `--simulate-exit` to quit.
Do not treat an accelerated two-hour synthetic soak as a two-hour real recording.

## Daily improvement pipeline

The backlog is in [ROADMAP.md](ROADMAP.md), with 15 ordered tasks, explicit scopes
and acceptance criteria. [The workflow](.github/workflows/daily-improve.yml)
starts daily at **01:30 UTC** (`30 1 * * *`), then waits a uniformly random
**0–14,399 seconds** before proposing a change. This is **8:30 PM EST** on the
previous calendar day, with an intended start window of **8:30 PM–12:30 AM EST**.
The fixed UTC cron does not adjust for daylight saving time: during EDT the
window is **9:30 PM–1:30 AM**. GitHub scheduling/queue delays and generation
can move the actual commit later. `workflow_dispatch` skips jitter. Sleeping
consumes up to four hours of Ubuntu runner time; the propose job timeout is 260
minutes. Checkout resolves the current default branch after the delay.

All daily jobs use `ubuntu-latest`. Only the default branch can access the API
secret. Jobs separate API access, draft publication, portable verification and
merge permissions:

1. **Propose:** select the first unchecked task and send bounded tracked source
   context to OpenAI's Responses API. One call, up to 12,000 output tokens, no
   retry loop. `OPENAI_MODEL` defaults to `gpt-4.1`. No generated code executes.
2. **Open a draft:** validate exact replacements, declared file scopes, assertion
   preservation and the 400-line budget; publish the candidate before running
   checks. No roadmap completion is recorded yet. Invalid/refused proposals stop
   before a PR exists. A valid proposal that fails checks remains an open draft.
3. **Verify without secrets/write credentials:** run `scripts/ci-portable.sh` on
   both baseline and candidate, and reject unexpected repository changes. Only
   after success, mark the selected task `[x]` and append a changelog entry that
   explicitly records **portable checks only; native Swift build/tests not run**.
4. **Publish and merge:** update the same draft with checked completion metadata,
   ensure main and the draft have not changed, mark ready, and use
   `gh pr merge --squash --match-head-commit` for a direct conditional squash
   merge. There is no direct push/force-push to main by the daily bot and no
   `--admin` bypass. If publishing/merging fails, restore the open PR to draft.

**Automatic merging is gated by portable checks, not native application tests.**
These checks cover shell/Python syntax, automation unit tests, scoped edits and
patch consistency; they cannot establish Swift compilation, runtime correctness,
translation quality or live Wispr behavior. Generated Swift tests are added but
not executed on Ubuntu. This is the owner's explicitly selected unattended policy,
not a guarantee of a working native build. Native checks remain available through
`bash scripts/ci.sh` on an Apple Silicon Mac or the separate macOS CI workflow.

An open daily-improvement PR pauses new proposals, preventing duplicates after a
failure or blocked merge. Resolve/close that draft to resume. An empty backlog
exits without an API call. The job never automatically weakens repository branch
rules: a rule that requires additional checks/reviews can prevent merging and
will leave the PR for attention. Changes to the base/head during a run also stop
merging. A fresh run must verify against the new base.

### One-time GitHub setup

1. Merge/push this setup onto the repository's default branch.
2. In **Settings → Secrets and variables → Actions**, create repository secret
   **`OPENAI_API_KEY`**. Do not paste it into source, issues or chat. Optionally
   create repository variable **`OPENAI_MODEL`** for another structured-output
   capable Responses model available to your account.
3. In **Settings → Actions → General → Workflow permissions**, enable
   **Allow GitHub Actions to create and approve pull requests**. The workflow
   requests only the permissions each job needs; it never approves its own PR.
4. Open **Actions → Daily improvement → Run workflow** on `main` and review the
   first result. Account/org policy may restrict runners, Actions minutes or PR
   creation. Runners and API calls can incur charges; configure account
   budgets before unattended use.
5. Ensure squash merging is enabled. The workflow uses a direct squash merge
   after its own successful checks, so the repository's optional **Allow auto-merge**
   setting is not required. Job-level `contents: write` and `pull-requests: write`
   permit publication and merging; verification has read-only access. Rulesets
   and organization restrictions still apply. Bot-token merges normally do not
   trigger another push/PR workflow; do not assume macOS CI runs after each merge.

Local inspection (clean, committed checkout required):

```sh
python3 scripts/daily_improve.py --inspect
# With OPENAI_API_KEY already provided through your shell's secret management:
python3 scripts/daily_improve.py --propose
# Optional local portable review mode (completion stays pending):
python3 scripts/daily_improve.py --apply-proposal .daily-improve/proposal.json --portable
# The daily workflow adds --complete-portable to permit automatic completion.
# On a disposable Mac checkout, omit --portable to require the full native suite:
# python3 scripts/daily_improve.py --apply-proposal .daily-improve/proposal.json
# With no mode flag the script proposes, applies and verifies in one invocation.
```

The script never commits/pushes by itself. Local test processes receive a reduced
environment, but local execution does **not** isolate your filesystem or user
account; use the fresh CI runner for untrusted generated code. Proposal context
contains repository code, not local lectures or Keychain content. The API key used
by GitHub is separate from the keys saved in the desktop application.

Implementation references: [OpenAI structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs),
[GitHub macOS 26 runner labels](https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/),
and [create-pull-request behavior](https://github.com/peter-evans/create-pull-request/blob/main/docs/concepts-guidelines.md).

## Unattended local Mac updates

`AGENTS.md` records the owner's standing instruction: finish authorized local
feature work, run relevant checks, then commit and push to main without another
reminder. `scripts/check_daily_workflow.py` protects the fixed daily cron, jitter,
portable verification gate and conditional squash merge. It runs in portable CI
and the daily verify job. An intentional policy change must update the guard too.

Keep the checkout in `~/Developer/Glacier` (outside macOS-protected Documents and
Desktop folders) so the background job does not need Full Disk Access. If moving
an existing checkout, preserve all files and optionally leave a symbolic link at
its former location. Install the per-user launch agent once from the new location:

```sh
python3 scripts/install_local_updater.py
```

It checks at 1 PM on the Mac's calendar and hourly after 1 PM America/New_York
until that day's update succeeds. The hourly Eastern-time gate handles DST,
sleep/wake and travel. It uses `git pull --rebase origin main` only on a clean main
checkout with no local-only commits. It never stashes, discards, force-pushes or
publishes arbitrary local edits. A dirty checkout, active Glacier process or lost
network defers the update; it retries on later scheduled invocations.

Each new revision is built and fully verified in a detached worktree. Only a
successful, signed build is atomically installed at `/Applications/Glacier.app`;
the previous app is retained as a rollback copy. No lecture is terminated. The
installed app takes effect at its next launch. Existing ad-hoc signing limitations
still apply: macOS may ask to renew permissions/key access after an update.

```sh
bash scripts/sync_and_build_local.sh --check-only # read-only eligibility check
bash scripts/sync_and_build_local.sh              # sync, verify, install now
launchctl print gui/$(id -u)/com.ar2mis.glacier.local-updater
```

Logs, the installed commit ID, and rollback app are in
`~/Library/Application Support/Glacier/Updater`. The LaunchAgent is
`~/Library/LaunchAgents/com.ar2mis.glacier.local-updater.plist`. It runs while the
user is logged in; a powered-off Mac, OS privacy denial, provider outage, or failing
native build cannot be guaranteed away. Such failures preserve the installed app
and are recorded in the logs. The helper bootstrap is outside Documents so even
an OS denial of repository access can be logged.
