# Voxloom

[简体中文](README.md) · English

Voxloom is a macOS dictation app that runs on-device for Chinese and English. It appears as 小声哔哔 when macOS uses Chinese and as Voxloom in other languages.

## Use Voxloom

After preparing the runtimes, run `python3 scripts/package-app.py --external-models` to build `Voxloom.app`. The menu bar waveform has a transparent background and uses the system foreground color, appearing white on a dark menu bar. [App icon source](src/business/VoxloomDesktop/App/Resources/AppIcon.svg)

Pass `--configuration` (`-c`) with `debug` or `release` when packaging. Release is the default. The debug build has its own app name and bundle ID. Its menu bar includes an ASR context log with the latest dictation's draft excerpt, recent message excerpts, exact recognition prompt, and UTF-8 byte count. The message status shows where reading stopped. The app keeps this log in memory and clears it when you quit or choose Clear.

Builds with the optional voice isolation model include the experimental “Keep only my voice” setting, which is off by default. Record at least one 3–8 second clip. You can read the same Chinese-English sentence shown in settings for each speaking volume. Quiet, normal, and loud samples can be recorded, played back, replaced, or deleted separately. With isolation enabled, Voxloom filters new audio locally and updates the transcript preview while you hold Fn. Releasing Fn runs full-recording isolation and transcription for the final text.

- Place the cursor in the target field and hold Fn (Globe) on its own for about 0.18 seconds to start recording. On release, Voxloom transcribes the remaining audio. If correction is enabled, Voxloom waits up to three more seconds and uses the available draft at the deadline. It requests a paste when the original target field is still focused. The draft is kept if focus changes, recording is interrupted, or permissions are missing. A recording can last up to 60 seconds.
- During recording, press E while holding Fn to open the draft editor on release. Once transcription finishes, press Enter to insert into the original input field or Shift+Enter to add a new line. If Voxloom cannot verify the original field, it keeps the text in the draft. Press Esc while holding Fn to discard the current recording and restore the previous draft. Release Fn to record again.
- Voxloom submits the first preview as soon as it has about a second of audio and detects voice activity. At launch, Voxloom loads the selected Qwen3-ASR model and the enabled voice isolation model in the background. Preparation uses no microphone audio. Dictation reuses the resident workers. Voxloom releases the Qwen process when the next recording uses a different engine or when the app quits.
- The floating bar shows recording duration, audio level, progress, and the latest line of transcription. Open the draft to see the full text. The gear opens settings and the app icon in the menu bar brings back the floating bar. Holding Fn with an uninserted draft adds a new line, so both recordings can be inserted together. Canceling a continuation restores the earlier draft. A recording after an insertion request starts with an empty draft.
- Choose Expand to edit, copy, or clear the draft above the floating bar. In the draft editor, Enter inserts the text and Shift+Enter starts a new line. While the target app is focused, double-tapping Fn also inserts the draft. Voxloom uses the target app's normal paste behavior to replace selected text. If the frontmost app changes before insertion, the draft remains available to insert or copy.
- Dictation defaults to Chinese. Settings also offer automatic language detection and English, Qwen3-ASR or Whisper, and vocabulary hints. Qwen correction is off by default and can be enabled in Settings. Existing saved choices still apply. [Full accuracy evaluation](docs/reports/transcription-evaluation-2026-11-23.md)
- By default, holding Fn reads up to 240 UTF-16 code units near the cursor in the active editable field. Recognition uses words from the excerpt as hints. When enabled, correction also receives the excerpt. Voxloom processes the context locally and keeps it out of history and settings. Password fields, read-only fields, and fields it cannot read use ordinary dictation. Context can be turned off in settings. Changes apply to the next recording.
- In macOS Terminal, Voxloom scans up to 4,096 UTF-16 code units in the focused terminal text area using read-only Accessibility queries. The scan stays within the visible range when available. With a known caret, it takes up to three lines with text on each side of the input line. Otherwise it takes up to six from the end. The context retains up to 240 UTF-16 code units after trimming padding.
- Enable the separate conversation setting to use recent messages during dictation. When you hold Fn, Voxloom reads up to six recent text excerpts from a conversation log exposed to macOS Accessibility near the active input field. It extracts and deduplicates terms locally and prioritizes manual vocabulary and recent technical terms. The whole ASR prompt is capped at 512 UTF-8 bytes for Qwen and 192 for Whisper. Voxloom uses the remaining hints if the conversation changes, is unavailable, or takes too long to read. The conversation setting is off by default.
- With correction enabled, an 800 ms pause in transcription or typing triggers correction. With continuous input, Voxloom submits the latest draft after three seconds. While the engine is busy, only the newest waiting draft is kept. Corrections are merged by character position while preserving text the user retyped and positions overwritten by new transcription. The desktop app uses one pass of local edits. The shared `QwenTextCorrector` includes review by default and accepts `.interactive` as a `QwenConfiguration.mode`.
- When the app launches without Accessibility access, the floating bar asks for it first to enable the global shortcut and automatic insertion. Grant access or choose Later to continue to microphone setup. Choosing Later applies to the current launch. The ASR model downloads in the background from launch. The bar shows download progress once microphone access is granted. Dictation is available when the model is ready.
- Hold Fn to speak by default. If an external keyboard's Fn key is unavailable, go to **Settings → Push-to-talk key → Change** and press a single key of your choice, such as right Option. A selected regular key is reserved for dictation when pressed on its own.
- Use the Accessibility button in the floating bar or settings and enable Voxloom in macOS System Settings under Privacy & Security → Accessibility for the global shortcut and automatic insertion. This permission applies across target apps.

Local checks cover expanding and collapsing the draft, recording and transcription feedback, Fn press and release, updating Accessibility permission status, and cursor insertion, selection replacement, and clipboard restoration in native controls. Real global shortcuts and cross-app insertion require verification on a Mac with permission enabled.

Local builds use ad-hoc signing. If the floating bar asks for Accessibility access after a rebuild, re-add the current `Voxloom.app` in System Settings. If macOS asks you to reopen the app, follow that prompt.

## Runtime resource usage

Measurements were taken on 2026-11-23 at roughly 0.29-second intervals on an Apple M2 Pro with 32 GiB of unified memory and macOS 26.5.1. The desktop app was sampled while idle with Qwen ASR already loaded. Inference used the bundled Qwen3-ASR-1.7B 4-bit and Qwen3-4B-Instruct-2507 Q4_K_M models and a 4.2-second Mandarin clip. The two cases ran with and without input context. [Dual-model test](src/business/QwenASR/Tests/QwenASRE2ETests.swift)

| Scenario | Memory (median / peak) | CPU (median / peak) | System GPU (median / peak) |
|---|---:|---:|---:|
| Idle app process | 35.6 / 35.6 MiB | 0.0% / 0.1% | — |
| Idle app with resident ASR workers | 1.92 / 1.92 GiB | 0.0% / 0.1% | 0% / 97% |
| Short-clip inference with the ASR and correction workers | 1.72 / 2.32 GiB | 93.0% / 185.8% | 80% / 99% |

Memory is macOS `ri_phys_footprint`. Adding footprints across processes can count shared pages twice. Including the test process, the inference tree peaked at about 2.35 GiB. A CPU reading of 100% corresponds to one logical core. The GPU column shows the driver’s system-wide `Device Utilization %`, which includes activity from concurrent apps. This sample gives no per-app GPU percentage.

These figures cover a short fixture. Long dictation and performance on 16 GiB devices are pending measurement. The local report is at `.build/reports/desktop-resources.json`.

## Replaceable interfaces

The foundation layer provides PCM and WAV handling, recognition value types, and pure functions for correction prompts and results. The business layer handles devices, models, and processes. Individual inference requests use Swift async/await. RxSwift coordinates overlapping recording, clicks, timers, and responses. Tests live in `Tests/` directories alongside their modules.

```swift
let recognizer: any SpeechRecognizer = QwenASRRecognizer(configuration: .init(
    executable: asrRuntime.appendingPathComponent("qwen-asr"),
    model: asrModelDirectory
))
let corrector: any TextCorrecting = QwenTextCorrector(configuration: .init(
    executable: llamaCompletionURL,
    model: correctionModelURL
))
let original = try await recognizer.transcribe(audio, options: .init(
    language: .chinese, context: "图书卡 充值额度 预付费 USD"
))
let candidate = try await corrector.correct(.init(text: original.text, vocabulary: "充值额度 USD"))
// Keep original.text and candidate.text separately. candidate.numbersChanged flags numeric edits.
await recognizer.shutdown()
```

`AudioClip` contains up to 60 seconds of 16 kHz mono Int16 PCM. A recognizer instance runs one request at a time and returns a busy error for overlapping requests. Canceling the task stops its inference and cleans up temporary files. Qwen ASR keeps one model process for the session and `shutdown()` waits for it to exit. Whisper's default shutdown is a no-op. The audio and text interfaces support swapping implementations, and compatible weights are selected through configuration. The default timeouts are 45 seconds for correction and 90 seconds for Qwen ASR.

Vocabulary hints provide terminology. Review the correction against the audio, especially for inferred quantities such as percentages. Numeric change detection currently recognizes Arabic numerals, decimal points, and percent signs.

## Development and reproduction

Building from source requires Apple Silicon, macOS 14 or later, Swift 6, and Python 3. The build was verified on an M5 Pro with 48 GiB, macOS 26.6.2, and Swift 6.3.2. Intel and 16 GB machines are pending acceptance. The app bundles Python 3.12.16, MLX Audio 0.6.7, and their dependencies.

```bash
bash scripts/prepare-app.sh --prepare-only   # Download resources for local development and evaluation.
python3 scripts/prepare-voice-isolation.py --runtime-only
python3 scripts/package-app.py --external-models --voice-isolation
python3 scripts/package-app.py -c debug --external-models --voice-isolation
python3 scripts/check.py                     # Swift unit, module, and UI checks with coverage gates.
python3 scripts/check-python.py              # Python worker protocol tests and coverage.
python3 scripts/smoke-qwen.py                 # Run both real models and sample short-clip resource usage.
python3 scripts/smoke-whisper.py              # Run the Whisper API and CLI end-to-end checks.
```

`scripts/prepare-qwen.py` installs the pinned Qwen revisions and dependencies and checks SHA-256 hashes. Development resources go in `.runtime/` and `models/`. Once models are installed, recognition, correction, and voice isolation run locally. Audio and text stay on the device. The `voice-input` CLI also supports Whisper file transcription.

The [0.3.2 verification summary](docs/reports/0.3.2/README.md) and the [first Whisper acceptance report](docs/acceptance-01.md) document the test results. Complete local logs go in `.build/reports/`. Real-model end-to-end tests are outside the unit and module coverage figures. See the [third-party resources](docs/third-party.md) for model and dependency sources.

[Testing and measured coverage](docs/testing.md) · [Development guidelines](AGENTS.md)

### Package a macOS DMG

When a pull request merges into `main`, GitHub Actions increments the patch version, tags the merged commit, and publishes the Apple Silicon Release DMG under **Releases → Assets**. For example, the release after `v0.1.0` is `v0.1.1`. Rerunning the workflow for the same commit reuses its tag.

Use **Actions → Package Voxloom DMG → Run workflow** to select a Release or Debug build manually. Manual builds are available under **Artifacts** for up to 90 days.

The DMG includes the app, inference runtimes, and an `Applications` shortcut. Dictation is available once the selected ASR model passes SHA-256 verification. The correction and voice isolation models download when enabled. Check download status and retry failed downloads in Settings. Models in `~/Library/Application Support/dev.voxloom.app/Models` are reused across upgrades that require the same model versions.

The Release bundle ID is `dev.voxloom.app` and the Debug bundle ID is `dev.voxloom.app.debug`. The app is signed ad hoc and has no Apple notarization.

To build the Release DMG locally, run the following commands.

```bash
bash scripts/prepare-app.sh --runtime-only
python3 scripts/prepare-voice-isolation.py --runtime-only
python3 scripts/make-dmg.py --voice-isolation --output .build/distribution/Voxloom-release-arm64.dmg
```
