# Glacier Privacy Policy

Effective date: November 18, 2026. Applies to Glacier 0.7 for macOS and iOS,
including the App Store/TestFlight edition. Developer: Ziruo Chen (Ar2mis).

## What Glacier does

Glacier uses microphone audio to display English captions and Chinese translation,
and saves lecture transcripts so you can export study documents. There is no
Glacier account, advertising SDK, tracking, or Glacier-operated cloud backend in
this version. We do not sell lecture data or use it to train our own models.

## Microphone and local processing

Recording starts only after you select Start and grant the operating system's
microphone permission. Stop ends capture; queued audio may continue to be decoded
so the last sentence is saved. Parakeet EOU (FluidAudio), WhisperKit and the Apple Speech option perform
recognition on your device. Glacier's own recorder buffers audio in memory and
**does not save a reusable audio recording file**. The transcript, including the
latest provisional text, is saved locally. Recognition and translation can be wrong.

Parakeet downloads Core ML models from Hugging Face/FluidInference; WhisperKit
downloads models/tokenizers from Hugging Face/Argmax model repositories
on first use. Those download services receive normal network information such as
your IP address and requested model, not your lecture audio. Apple Translation
processes English–Chinese text on device after language packs are installed. Apple
may receive translation API usage/performance metrics (such as app identifier and
languages), but not the original or translated content through that framework.
First-time downloads require an internet connection; offline operation depends on
having compatible models and language packs installed.

## Optional cloud AI: explicit choice

The App Store edition blocks cloud requests until you explicitly allow the
recipient and data type in Settings. Saving a key alone does not grant permission.
GPT translation is the default selection, but it cannot send data without the
required consent and key. You can use Parakeet/WhisperKit with Apple translation
without a cloud API key.

- **OpenAI audio transcription** sends microphone audio chunks to OpenAI.
- **Deepgram audio transcription** streams microphone audio to Deepgram.
- **OpenAI text cleanup/translation** sends the current transcript, recent context,
  and your course vocabulary. The Mac edition also offers DeepSeek and Gemini
  text translation through their APIs.
- **Cloud study-note export** sends the complete saved transcript in batches,
  vocabulary/course information and derived notes to your selected text provider
  to create Chinese translation, summary, mind map and English outline.
- **Test Connection** sends a short built-in sample caption to the selected service.
  It is a real API request and may use your provider quota.

Requests use HTTPS/WSS and your own provider key. Your provider can associate
requests with its API account. OpenAI Responses requests set `store: false`; this
is not a promise of zero retention by a third party. Retention, processing region,
training, deletion and billing depend on your provider's policies/account terms:
[OpenAI](https://openai.com/policies/privacy-policy/),
[Deepgram](https://deepgram.com/privacy),
[DeepSeek](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html),
[Google](https://policies.google.com/privacy), and
[Hugging Face](https://huggingface.co/privacy).
No personal API key is included in the distributed application.

## Storage, retention and deletion

Settings and cloud permissions stay in the application's preferences. Mac keys
are stored in a private app-owned `config.json` with owner-only filesystem
permissions (plaintext, not encryption), with Keychain as a supplementary source.
For the sandboxed Mac app, this file is inside its sandbox container under
Application Support/Glacier. iOS keys use the device Keychain. App updates preserve
this storage. The separately identified Glacier Dev application uses separate
preferences and Application Support/Glacier Dev storage.

Full transcripts and unfinished cloud-export checkpoints stay in the app's local
Application Support directory until you remove them. Only bounded recent caption
history is kept on screen. On Mac, you select the external Word export folder;
Glacier saves a security-scoped bookmark to retain your permission across launches.
iOS exports are placed in Glacier's Documents folder. Exported documents remain
where you saved/shared them, including any copies in your backups or cloud drive.

Use **Remove** in API-key settings to remove a saved key. Turn off cloud-sharing
switches while recording/export is idle to stop future requests. Already completed
provider requests are governed by that provider's retention policy. The Mac
**View local lecture data** button opens the local data directory: quit recording
and export, then delete the Lectures and PendingArchives folders to remove local
transcript/checkpoint data. On iOS, deleting the app removes its container data;
remove keys in the app first because Keychain items can survive uninstallation.
Delete exported Word files separately in Finder/Files. Backups may retain copies.
Deleting local data does not delete copies you sent to another person or provider.

## Permissions and other people

Glacier requests microphone and, for Apple Speech, speech-recognition permission.
It does not request screen recording, contacts or location. The App Store Mac
edition does not read/control Wispr or require Accessibility automation permission.
Record only when you have permission from the people involved and your institution.
Avoid sending sensitive classroom information to cloud providers without permission.

## Support and changes

Contact the developer through [Glacier Support](https://github.com/Ar2mis/Glacier/issues).
Public issues are public: never attach API keys, private lecture recordings,
transcripts or personal information. You may ask for a private follow-up channel
without posting the sensitive material. Any future material change to cloud data
sharing will be reflected in this policy and the application's controls.
