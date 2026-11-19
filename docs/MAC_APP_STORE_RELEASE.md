# Glacier Mac App Store release procedure

## What this repository prepares

- `GlacierMac`: native macOS 26+ Apple-silicon application, default bundle ID
  `com.ziruochen.glacier`, `APP_STORE` compilation, App Sandbox and hardened runtime.
- `GlacierMacDev`: native developer target with `.dev` identity; the shell builder
  also produces `dist/Glacier Dev.app`. Neither is a store distribution artifact.
- `GlacierIOS`: iOS/iPadOS 18+ application with the same shared GlacierCore, bundled
  icon/privacy documents, explicit cloud consent and Apple Translation integration.
  iOS 18 is required for the Translation framework; real-device testing is still required.
- `Config/GlacierMac.entitlements`: sandbox, microphone (sandbox and hardened-runtime
  keys), outgoing network, user-selected read/write and app-scoped bookmarks only.
  There are no Apple Events, Accessibility, broad home-folder or incoming-network grants.
- Wispr automation is compiled out of the store binary, checked using imported symbols.
  Developer builds retain the optional integration. Existing Wispr preferences cannot
  activate it in a store build.

Store keys/settings/models/transcripts live inside the application's sandbox.
No App Group is needed because there is no extension or shared-process storage.
Mac keys use a private 0600 config plus Keychain, outside the app binary. The
sandbox cannot silently read your old unsandboxed config: paste your own key in
store Settings if you choose cloud features. Glacier Dev has separate storage and
can seed an existing local OpenAI key with the private helper. No key is distributed.

## Verify before an Archive

```sh
python3 scripts/check_daily_workflow.py
CI=true bash scripts/ci.sh
bash scripts/verify-store.sh
bash scripts/verify-ios.sh
```

`ci.sh` runs portable checks, the native development build, Core checks and
caption/stream/session/soak/Word tests. `verify-store.sh` compiles the store branch,
checks actual signed entitlements and absence of AX automation imports, and runs
an isolated sandbox storage/consent smoke check. With full Xcode it builds the
GlacierMac Xcode target first; with Command Line Tools only it reports an explicit
fallback to direct Swift compilation. That fallback does **not** validate the
Xcode target, asset-catalog compiler, Archive, distribution signing or upload.
Hosted `Build and verify` checks build both native Xcode targets without your keys.
A portable daily-bot checkmark is not evidence of any of these native checks.

## Exact signing, Archive and upload steps after enrollment

1. Install the full current Xcode from Apple and open it once to install components
   and accept its license. In Xcode Settings → Locations, select its command-line tools.
   If needed: `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.
2. Xcode Settings → Accounts → add your Apple Account and select your approved team.
3. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig`.
   Replace `YOURTEAMID` with your 10-character Team ID. This local override is ignored
   by git. Keep the default bundle IDs, or choose available permanent IDs here
   **before** creating the App Store Connect records. Do not include passwords/keys.
4. Open `Glacier.xcodeproj`. Choose scheme **GlacierMac** (not GlacierMacDev), and
   destination **Any Mac (Apple Silicon)** or the equivalent generic Mac destination.
5. In target GlacierMac → Signing & Capabilities, confirm Automatically manage signing,
   the approved Team, bundle ID, App Sandbox, Audio Input, Outgoing Connections and
   User Selected File Read/Write. Confirm the Release configuration has `APP_STORE`.
   The development target is deliberately separate and must not be submitted.
6. Build and run the signed sandbox target. Test microphone permission, model/language
   downloads, a full lecture, Stop/final-tail handling, offline captions, consent
   rejection/revocation, credential persistence after quit/relaunch and replacement
   by a new signed build. Choose an export folder, relaunch, then export again.
7. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Config/Shared.xcconfig`
   for every new upload. Commit source changes normally. Never ship config.json,
   shell profiles, recordings, API keys or signing certificates in resources.
8. Product → **Archive**. In Organizer select the resulting Glacier archive. Review
   its signed entitlements, embedded resources and **Generate Privacy Report** output.
   Check required-reason API/SDK manifests against the actual shipping binary.
9. In App Store Connect create a new **macOS** app for the matching bundle ID, select
   a unique SKU (for example `glacier-mac`), and complete ownership/content rights,
   export-compliance questions, age rating, privacy answers and contact details.
   BYOK providers can associate requests with their API accounts: do not blindly
   declare “Data Not Collected.” The manifest conservatively declares optional
   cloud audio/other user content, linked, for app functionality, never tracking.
10. Organizer → **Distribute App → App Store Connect → Upload**. Resolve every
    validation warning/error. Automatic signing should manage the distribution
    certificate/profile for the team. Do not use Developer ID as a substitute for
    Mac App Store distribution signing. An ad-hoc smoke bundle is not uploadable.
11. When processing finishes, use **TestFlight** for an initial classroom pilot.
    Supply beta review notes for external testing when requested. Obtain real
    performance/reliability evidence before marketing latency or accuracy claims.
12. Complete screenshots, listing, privacy/support URLs and review notes. Select the
    tested build, submit for review and choose manual release until approved.

Optional command-line Archive (requires full Xcode and an approved signed-in team):

```sh
xcodebuild -project Glacier.xcodeproj -scheme GlacierMac -configuration Release \
  -destination 'generic/platform=macOS' -archivePath .build/Glacier.xcarchive \
  -allowProvisioningUpdates archive
```

## Public privacy/support URLs

`PRIVACY_POLICY.md` and `SUPPORT.md` are bundled for offline access. Their generated
static versions are `docs/privacy.html` and `docs/support.html`; no remote fonts,
analytics or JavaScript are used. Regenerate after editing Markdown:

```sh
python3 scripts/render_support_site.py
```

In GitHub Settings → Pages, publish from branch `main`, folder `/docs` if supported
by the repository plan/visibility. After publishing, verify that
`https://ar2mis.github.io/Glacier/privacy.html` and
`https://ar2mis.github.io/Glacier/support.html` load publicly before entering them in
App Store Connect. These are intended URLs, not a claim that Pages is enabled.
The GitHub issues support link must also be publicly usable; otherwise publish a
real public contact channel before submission. Never invent a support email.

## Review notes and remaining release gates

Describe the ice-cube Start/Stop control, menu-bar Settings, transparent click-through
caption window, model downloads, and user-selected export folder. Explain that
WhisperKit + Apple translation need no developer-provided key; optional cloud AI
uses the reviewer's own key/consent and incurs provider fees. Full generative study
notes require cloud access. The offline English Word export is available without it.
If Apple requires access to optional cloud features, arrange a limited review
credential through App Store Connect review information, never source code.

Do not assert App Store readiness/approval solely from a green build. The following
still require evidence before public release: approved account/signing, Archive
validation and privacy report, published support URLs, first-install/download tests,
real microphone/end-to-end Chinese latency, a complete classroom pilot, sandbox
folder reauthorization across reboot, iPhone thermal/memory/device tests, and review.
Additional provider-specific audio-tail guarantees remain on the roadmap.

The existing nightly GitHub schedule/jitter/portable auto-merge policy is unchanged.
Nightly local builds replace only `/Applications/Glacier Dev.app`. Official Glacier
updates use App Store/TestFlight distribution. This repository does not auto-upload
or auto-release store binaries.
