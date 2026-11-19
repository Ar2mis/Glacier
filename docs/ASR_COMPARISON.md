# Paced ASR comparison — November 18, 2026

Glacier 0.7.1 adds FluidAudio 0.18.3 / Parakeet Realtime EOU 120M alongside
WhisperKit 1.1.1. Fresh installs select Parakeet **320ms** and GPT translation;
existing saved choices remain intact. 160ms is also selectable. WhisperKit Turbo
remains the accuracy-oriented alternative; these small tests do not establish a
universal winner.

## Method

- Machine: Apple M5, macOS 27.2.1; Release build. No microphone was used.
- Each engine received the **same normalized 16 kHz mono samples**, in 100ms
  frames paced against a monotonic clock at real time. Models were prepared before
  the replay clock started. CPU-intensive builds did not run during comparisons.
- Used the actual `ParakeetEngine` / `ParakeetStreamProcessor` and
  `WhisperDecoder` / `WhisperStreamProcessor` used by live capture, including Stop.
- First text means the first nonempty provisional event from audio time zero.
  It may be a word/subword, not a completed sentence; hypotheses differ in length.
  It excludes model download/preparation and microphone/driver latency.
- Stop drain is completion time minus input duration. Final transcripts are joined
  from finalized utterances; provisional revisions are not double-counted.
- WER is word-level Levenshtein edits divided by reference words, ignoring case and
  punctuation. No course glossary or GPT correction was used for the ASR scores.
  WhisperKit retained its production previous-utterance conditioning.
- One final measurement per configuration/fixture: **not** confidence intervals,
  classroom benchmarks, iPhone memory/thermal results or latency guarantees.

Model weights are pinned to FluidInference Hugging Face revision
`40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355`; the SDK is pinned to release 0.18.3.

## Results for the final adapter

| Fixture | Engine | First text | Stop drain | Word errors |
|---|---|---:|---:|---:|
| Public human speech, 11.000s | Parakeet EOU 320ms | 1.233s | 0.076s | 0/22 (0.0%) |
| Same audio | WhisperKit Base | 1.715s | 0.215s | 0/22 (0.0%) |
| Same audio | WhisperKit Turbo | 2.187s | 0.932s | 0/22 (0.0%) |
| Synthetic biology, 22.416s | Parakeet EOU 320ms | 0.834s | 0.044s | 4/53 (7.5%) |
| Same audio | Parakeet EOU 160ms | 0.457s | 0.125s | 5/53 (9.4%) |
| Same audio | WhisperKit Base | 1.708s | 0.383s | 20/53 (37.7%) |
| Same audio | WhisperKit Turbo | 2.200s | 1.427s | 0/53 (0.0%) |

The human fixture is the [whisper.cpp JFK sample](https://github.com/ggml-org/whisper.cpp/blob/master/samples/jfk.wav).
SHA-256: `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`.

The biology fixture was synthesized using macOS `say -v Samantha -r 165`:

> The cell membrane is selectively permeable. Water moves across the membrane by osmosis. Aquaporins are proteins that form water channels. At equilibrium, water molecules still move in both directions, but there is no net movement. A higher solute concentration does not mean that individual molecules stop moving. Mitochondria produce ATP through cellular respiration.

SHA-256: `20aa3d8b7db97139001a776911f89e8a1a19f00fa9d1b8d7354f4672ba56ab6e`.
Different OS voice assets may synthesize different bytes; compare engines against
one generated file, not independently regenerated recordings.

Parakeet 320ms still wrote “a cooperants” for “aquaporins” and “might achondria”
for “mitochondria.” Turbo preserved all reference words in this particular clip.
Base omitted part of the continuous lecture. An exploratory Base run without
previous-utterance context still had 18/53 edits (34.0%), so its production behavior
was not changed on the strength of this one fixture.

## Fixes discovered while testing

1. **Deferred Core ML compilation:** the initial EOU implementation first emitted
   text at 3.773s on the human fixture, despite already loading the model. Preparation
   now performs silent inference and resets state before the microphone opens.
2. **Delayed EOU:** a model endpoint can arrive after the next word has started.
   Resetting immediately clipped words such as the beginning of “mitochondria.”
   Endpoints now also require 240ms of recent low-energy input. A short silent left
   context is primed after resets; no speech is removed from the input queue.
3. **Tradeoff in model context:** the initial 160ms adapter scored 12/53 edits
   (22.6%) on biology. Boundary fixes reduced this to 5/53; the 320ms model scored
   4/53 and became the selected default mode. These are combined integration/model
   improvements, not proof that every lecture gains the same amount.
4. **Bounded long sessions:** the SDK retains transcript tokens and latches EOU.
   Glacier drains/resets at valid endpoints and at a 60-second safety ceiling,
   rather than repeatedly decoding a growing lecture. A forced ceiling can split
   speech; uninterrupted classroom speech around that boundary needs further tests.
5. **Stop:** process the queued frames, add model lookahead, drain the final partial
   chunk, emit one final revision, then finish the existing full-text journal/export.
6. **Standalone test builds:** direct `swiftc` executables now receive FluidAudio's
   transitive Clang module paths; normal SwiftPM/Xcode builds supply these themselves.

## Real GPT integration probe

The same synthetic biology audio was replayed through the **actual Mac
CaptionModel**, Parakeet 320ms, stable-prefix scheduling, `TranscriptRefiner` and
OpenAI `gpt-4o-mini`, using a saved local key and the course glossary. Only the
synthetic recognized text was sent to OpenAI; audio stayed local.

- First Chinese appeared at **4.570s from audio playback start**. This is the first
  caption, not the mean delay behind every word or the API's isolated response time.
- Streaming Chinese contained 水通道蛋白, 渗透作用, 平衡 and the negation about
  molecules continuing to move. This is a smoke check, not an independent semantic
  evaluation of every partial translation.
- No Apple fallback occurred. The full raw English journal was saved with no
  finalization warning, and Stop hid the caption overlay state.
- The former 2.5-second switch is removed. A deterministic regression also holds
  the first GPT token for 3.3 seconds and verifies GPT completes without switching.
  Missing credentials/consent and actual request failures retain visible fallback.

## Sandbox verification

A separate ad-hoc signed verification bundle used Glacier's actual Mac Sandbox
entitlements. Parakeet downloaded/prepared its model inside that bundle's container
and replayed the biology fixture successfully with the same 4/53 word edits. This
checks native model inference and container storage, not App Store approval or
microphone permission. No private key or lecture was copied into the bundle.

## Reproduce locally

Swift 6.2+ and the macOS toolchain are required. Model downloads happen on first
use. These optional probes are separate from offline CI tests.

```bash
swift build -c release
BIN="$(swift build -c release --show-bin-path)/GlacierCoreVerify"
"$BIN" --compare-asr /absolute/path/clip.wav \
  --reference /absolute/path/reference.txt --report /absolute/path/report.json
# Optional: --only parakeet|base|turbo, --parakeet-mode 160ms|320ms,
# --glossary terms.txt, --no-previous-context (Whisper experimental ablation).

# Explicit live API probe: synthetic/non-private fixture only, up to 60 seconds.
# Uses the saved OpenAI key and incurs normal API usage; never reads the microphone.
bash scripts/probe_live_asr.sh /absolute/path/synthetic-fixture.wav
```

JSON reports include reference/hypothesis text, every provisional/final event,
audio hash, preparation time and timing metrics. Keep personal-lecture reports in
ignored local folders such as `.build/`; no personal recordings or credentials
are included in this repository.

Remaining release checks include actual classroom noise/distance, multiple
speakers/accents, sustained microphone sessions, forced 60-second boundaries, and
physical iPhone memory/thermal testing. Model-free regressions cover split-frame
EOU handling, late endpoints during speech, bounded continuous input, silence,
Stop tails, cancellation and capture errors. The audio replay is not a substitute
for microphone or UI permission testing.
