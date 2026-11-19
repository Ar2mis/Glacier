# Glacier Support

Glacier provides English–Chinese lecture captions and transcript exports.
Maintained by Ziruo Chen (GitHub: Ar2mis).

## Start a lecture on Mac

1. Open Glacier. Choose **Parakeet EOU → 320ms** (the new-install default) for streaming English, or **WhisperKit → Base**.
2. Connect to the internet for the initial speech-model download. Choose
   **Download / Prepare speech model** before class. Parakeet opens the microphone
   only after its model is ready.
3. Allow microphone access when prompted. Select your microphone in macOS Sound settings.
4. Choose a folder under **Lecture archive → Choose export folder**. Glacier uses
   this permission for future Word exports; no broad Desktop access is needed.
5. Click the floating ice cube or Start. The status distinguishes microphone
   capture from model preparation. Wait for “recognition ready” before an important
   lecture; a cold download may exceed the bounded audio queue.
6. Click Stop once. Capture ends immediately; allow pending audio to finish.
   Use **Export saved English Word (offline)** for a key-free document. Complete
   translated study notes require an optional cloud key and explicit text consent.

## Translation and cloud keys

GPT is the default translation option. Apple is the optional on-device alternative. Language packs need one initial
download and cannot be installed while offline. If they are missing, Glacier
shows a preparation message; it cannot promise offline translation before setup.
For OpenAI cleanup on Mac, choose GPT / AI translation, paste your own key,
Save, allow text sharing to OpenAI, then Test Connection. Never share your key with
the developer or paste it into GitHub. GitHub Actions secrets do not configure the
installed app. API usage is billed by your provider, separately from Glacier.

If cloud captions fail, Glacier uses installed Apple language packs when available.
A slow GPT response does not switch to Apple after 2.5 seconds. Only missing
credentials/consent or actual service failures can trigger the local fallback,
with status explaining why. Prepare Apple language packs in advance if desired.
Reading-priority mode deliberately holds captions longer; turn it off to follow
speech more closely. Base uses less memory than Turbo. Lecture text is saved
separately from the short on-screen history.

## Troubleshooting

- **No microphone:** macOS System Settings → Privacy & Security → Microphone;
  check the selected input under Sound. Glacier and Glacier Dev have separate grants.
- **First start is slow:** keep the app open while models download/compile. Stop is
  still available. A failed or incomplete download is retried on the next start.
  Choose Base and close memory-heavy applications. Do not begin an important
  session until model preparation has finished.
- **Translation unavailable:** prepare Apple language packs while online, or check
  the selected provider, consent, key, quota and network. Saved English remains available.
- **Export denied after restart:** choose the export folder again if it was moved,
  removed or its permission changed. Original text/checkpoints are retained.
- **Cloud summary/export unavailable:** local transcription does not require a key;
  generative summaries do. Use the offline English Word exporter in the meantime.
- **Stop takes time:** input has stopped but pending audio is decoding. Avoid
  quitting until completion. An interrupted app can recover saved text, but cannot
  restore audio that was still only in memory.
- **iPhone/iPad:** iOS 18 or later; keep Glacier in the foreground. iOS captions are
  inside the app, not an overlay above other apps. Backgrounding ends recording;
  keep the app open for long exports. Use the document Share button to save a copy.

## Development versus official builds

Glacier Dev is a separate local developer application. Nightly source builds update
`/Applications/Glacier Dev.app` only. `/Applications/Glacier.app` is reserved for
signed TestFlight/App Store builds. Store updates come through Apple's channels.
Do not copy keys into an application bundle or distribute your private config file.
Mac currently requires Apple silicon and macOS 26 or later.

## Contact and privacy

[Report a reproducible issue or request help](https://github.com/Ar2mis/Glacier/issues).
Include app version, macOS/iOS version, speech/translation provider, and steps to
reproduce. Use a short invented example rather than a private lecture. **Do not
include keys, private transcripts, recordings or sensitive screenshots.**

[Privacy policy](PRIVACY_POLICY.md) explains local storage, third-party requests,
retention and deletion. Glacier is a study aid; verify important terminology and
facts against course materials.
