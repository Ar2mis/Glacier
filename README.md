# Glacier 🧊

**Live English–Chinese lecture captions and bilingual study notes for macOS.**

Glacier is an Apple Silicon desktop prototype for students who follow spoken
English more easily with captions. A transparent, always-on-top overlay keeps
English and Chinese visible while you read slides or use another application.
It is a native Swift app, not a browser extension or a Node.js service.

## What works in the implementation

- **Live captions:** observe an existing Wispr Flow Notetaker transcript through
  macOS Accessibility; segment and coalesce revisions before translation.
- **Translation:** OpenAI Responses API, Gemini's OpenAI-compatible endpoint, or
  DeepSeek. OpenAI/DeepSeek use streamed text; Gemini uses complete responses.
  Installed Apple English–Chinese translation can serve as an explicit option or
  a fallback after cloud credential/quota failures or repeated transient errors.
- **Desktop UI:** a draggable ice-cube launcher, confirmed start/stop indicators,
  a transparent click-through caption overlay, independent font/color/size/bold
  controls, adjustable shadows, and a draggable snapshot of the last 30 seconds.
  Defaults include Times New Roman and Songti SC.
- **Study notes:** after a Wispr recording stops, optional automatic archiving
  obtains its full transcript, translates numbered chunks, and exports a Word
  document with Chinese summary, a rendered mind map, an English outline, then
  the complete English transcript followed by the complete Chinese translation.
  Course/topic folders are created on the Desktop; interrupted archive jobs can
  be resumed.
- **Alternative input:** Apple's on-device Speech pipeline can capture microphone
  audio directly. This is separate from Wispr mode; automatic full-note capture
  currently depends on Wispr.

**Status:** prototype, not a notarized production release. Wispr must be installed
and signed in separately; Glacier does not embed or redistribute Wispr. There is
no iOS target, App Store release, built-in speaker diarization, PDF export, or
Markdown study-note export yet. Speaker labels, when available, originate in
Wispr. Simulations and offline tests do not establish live lecture accuracy.

## Requirements and local setup

- Apple Silicon Mac running macOS 26 or later.
- Xcode 26+ or compatible Command Line Tools with the macOS 26 SDK and Swift
  compiler. The scripts compile in Swift 5 language mode for arm64/macOS 26.
- Python 3.9+ for repository automation/tests (CI uses Python 3.12).
- Wispr Flow for the primary input mode, and a provider API key for cloud
  translation/AI note generation. Apple translation needs installed language assets.
- No third-party Swift packages or Python packages to install. No `npm install`.

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

In Glacier's settings, select the input and translation provider, save the API
key in the app's password field, and use **Test AI Translation**. If macOS denies
access to an existing key, use **Unlock saved key** and complete the OS prompt
personally. This desktop key is separate from the GitHub Actions secret.

Keep one Wispr Meeting Recorder window open on **Transcript**, scrolled to the
bottom and not minimized. Click the ice cube to start/stop, or operate Wispr
itself. Glacier observes recording state rather than assuming a click succeeded.
Right-click the cube to open the 30-second history. The subtitle overlay passes
mouse clicks through to apps underneath it. Settings are available from the menu
bar or app icon. Enter an optional course title/glossary and enable automatic
archiving if desired.

## Architecture

```text
Wispr audio/transcription → Accessibility snapshots (~350 ms)
                         → sentence/revision buffer → translation queue
Apple microphone → AudioBridge → SpeechAnalyzer ────┘
                         → selected cloud service / installed Apple Translation
                         → CaptionModel → SwiftUI/AppKit overlay + recent history

Stopped Wispr recording → full transcript copy → resumable archive job
                         → chunk translation + AI digest → OOXML Word document
```

| Component | Responsibility |
| --- | --- |
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
files are generated as OOXML and zipped with the system `zip` tool.

## Privacy and limitations

- Runtime API keys are stored in macOS Keychain. Never commit keys, `.env` files,
  personal recordings, transcripts, exports or debug logs. `.gitignore` excludes
  these common locations and formats; it is not a substitute for reviewing diffs.
- Live translation sends the current sentence, up to four recent bilingual context
  pairs and glossary text to the selected provider. Archive generation sends the
  full transcript in chunks. Glacier does not send audio to the translation API;
  Wispr handles its own recording and data processing.
- OpenAI requests use `store: false`; this is not a claim of zero provider retention.
  There is no automatic switch to a different cloud provider.
- Archive progress is stored locally under
  `~/Library/Application Support/听课字幕/待归档` with restricted file permissions,
  not application-level encryption. Exports contain lecture content.
- Wispr UI automation depends on its window structure and permissions. Interface
  changes, transcript virtualization and observer failures can interrupt captions.
  Locked screens/system-protected windows are not supported overlay surfaces.
- Tests cannot verify Accessibility authorization, Keychain prompts, real microphone
  accuracy, provider account/model availability, translation quality or live latency.

## Build and verification

```sh
bash scripts/ci.sh                 # complete build + syntax + offline test gate
bash scripts/verify-all.sh         # all seven Swift verification suites
python3 -m unittest discover -s Tests -p 'test_*.py' -v
```

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

The backlog is in [ROADMAP.md](ROADMAP.md), with 15 ordered tasks, explicit file
scopes and acceptance criteria. The workflow in
[`.github/workflows/daily-improve.yml`](.github/workflows/daily-improve.yml) runs at
**10:17 UTC daily** (05:17 EST / 06:17 EDT) and supports **Run workflow**. GitHub
schedules can be delayed. Only the default branch may run the secret-bearing job.

1. **Propose on Linux:** read the first unchecked task and tracked Swift source;
   send bounded source context to OpenAI's Responses API using structured JSON
   output. One request per run, a 12,000-output-token cap, and no automatic API
   retry loop. The model defaults to `gpt-4.1`; change `OPENAI_MODEL` as needed for
   your API account. Generated source is not executed in this job.
2. **Portable verification on a fresh `ubuntu-latest` runner:** no OpenAI secret,
   no persisted checkout credentials, and read-only repository access. Validate
   exact replacements and run shell/Python syntax checks and automation unit tests
   before and after applying the proposal. The bot may edit only the task's
   declared Swift files and must extend tests without removing existing assertion
   lines. Changes are limited to 400 added/deleted lines. Failures restore tracked
   content and produce no candidate patch. **Swift is not compiled or tested on
   Ubuntu; AppKit, Speech and Translation require macOS.**
3. **Publish on a fresh Ubuntu runner:** confirm the base has not moved and open
   a **draft PR explicitly labeled “native build NOT verified”** on a unique
   `codex/daily-improve-*` branch. Generated code never runs with write access.
   ROADMAP.md and CHANGELOG.md remain unchanged. Nothing auto-merges or
   force-pushes to `main`.
4. **Native verification before merge:** check out the draft PR on a disposable
   macOS 26+ Apple Silicon checkout and run `bash scripts/ci.sh`. After all checks
   pass and the implementation is reviewed, mark the roadmap task complete and
   append the changelog entry in that PR. The separate Build and verify workflow
   also retains its macOS runner and supports manual dispatch on the PR branch.

An existing open daily-improvement PR pauses further proposals until reviewed.
An empty backlog exits without calling the API. A declined/failed proposal is
retried on the next scheduled run; revise or reorder the task if it repeatedly
fails. Passing tests do not prove semantic correctness or code safety: inspect
both implementation and tests before merging. The file/assertion gates are
conservative checks, not a general-purpose sandbox.

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
5. Review and merge draft PRs yourself. GitHub normally does not trigger another
   `pull_request` workflow for PRs created with `GITHUB_TOKEN`; the daily workflow
   only runs portable checks. Run the native suite on the actual PR head before
   merging, and repeat it if the base or PR changes afterward.

Local inspection (clean, committed checkout required):

```sh
python3 scripts/daily_improve.py --inspect
# With OPENAI_API_KEY already provided through your shell's secret management:
python3 scripts/daily_improve.py --propose
# Ubuntu-compatible mode used by the daily workflow (completion stays pending):
python3 scripts/daily_improve.py --apply-proposal .daily-improve/proposal.json --portable
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
