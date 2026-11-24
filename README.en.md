# voxloom

[简体中文](README.md) · English

Voxloom is a local speech input project for Chinese and English. It connects speech recognition, contextual correction, and device interaction through separate interfaces.

## Voxloom desktop app

Run `python3 scripts/make-demo.py --product voxloom` to build `Voxloom.app`. The app has its own entry point and settings and uses the project's recording, recognition, and draft modules directly. The editable dark green waveform is included in the source. [App icon source](src/business/VoxloomDesktop/App/Resources/AppIcon.svg)

Pass `--configuration` (`-c`) with `debug` or `release` when packaging. Release is the default. The debug build has its own app name and bundle ID. Its menu bar includes an ASR context log with the latest dictation's draft excerpt, recent message excerpts, exact recognition prompt, and UTF-8 byte count. The message status shows where reading stopped. The app keeps this log in memory and clears it when you quit or choose Clear.

Builds with the optional voice isolation model include the experimental “Keep only my voice” setting, which is off by default. Record at least one 3–8 second clip. You can read the same Chinese-English sentence shown in settings for each speaking volume. Quiet, normal, and loud samples can be recorded, played back, replaced, or deleted separately. With isolation enabled, Voxloom filters new audio locally and updates the transcript preview while you hold Fn. Releasing Fn runs full-recording isolation and transcription for the final text.

- Place the cursor in the target field and hold Fn (Globe) on its own for about 0.18 seconds to start recording. On release, Voxloom transcribes the remaining audio. If correction is enabled, Voxloom waits up to three more seconds and uses the available draft at the deadline. It requests a paste when the original target field is still focused. The draft is kept if focus changes, recording is interrupted, or permissions are missing. A recording can last up to 60 seconds.
- During recording, press E while holding Fn to open the draft editor on release. Once transcription finishes, press Enter to insert into the original input field or Shift+Enter to add a new line. If Voxloom cannot verify the original field, it keeps the text in the draft. Press Esc while holding Fn to discard the current recording and restore the previous draft. Release Fn to record again.
- Voxloom submits the first preview as soon as it has about a second of audio and detects voice activity. At launch, Voxloom loads the selected Qwen3-ASR model and the enabled voice isolation model in the background. Preparation uses no microphone audio. Dictation reuses the resident workers. Voxloom releases the Qwen process when the next recording uses a different engine or when the app quits.
- The floating bar shows recording duration, audio level, progress, and the latest line of transcription. Open the draft to see the full text. The gear opens settings and the menu bar waveform brings back the floating bar. Holding Fn with an uninserted draft adds a new line, so both recordings can be inserted together. Canceling a continuation restores the earlier draft. A recording after an insertion request starts with an empty draft.
- Select the draft button to edit, copy, clear, or try the bundled example. In the draft editor, Enter inserts the text and Shift+Enter starts a new line. While the target app is focused, double-tapping Fn also inserts the draft. Voxloom uses the target app's normal paste behavior to replace selected text. If the frontmost app changes before insertion, the draft remains available to insert or copy.
- Settings offer Qwen3-ASR or Whisper, language selection, and vocabulary hints. Qwen correction is off by default and can be enabled in Settings. Existing saved choices still apply. [Full accuracy evaluation](docs/reports/transcription-evaluation-2026-11-23.md)
- By default, holding Fn reads up to 240 UTF-16 code units near the cursor in the active editable field. Recognition uses words from the excerpt as hints. When enabled, correction also receives the excerpt. Voxloom processes the context locally and keeps it out of history and settings. Password fields, read-only fields, and fields it cannot read use ordinary dictation. Context can be turned off in settings. Changes apply to the next recording.
- In macOS Terminal, Voxloom scans up to 4,096 UTF-16 code units in the focused terminal text area using read-only Accessibility queries. The scan stays within the visible range when available. With a known caret, it takes up to three lines with text on each side of the input line. Otherwise it takes up to six from the end. The context retains up to 240 UTF-16 code units after trimming padding.
- Enable the separate conversation setting to use recent messages during dictation. When you hold Fn, Voxloom reads up to six recent text excerpts from a conversation log exposed to macOS Accessibility near the active input field. It extracts and deduplicates terms locally and prioritizes manual vocabulary and recent technical terms. The whole ASR prompt is capped at 512 UTF-8 bytes for Qwen and 192 for Whisper. Voxloom uses the remaining hints if the conversation changes, is unavailable, or takes too long to read. The conversation setting is off by default.
- With correction enabled, an 800 ms pause in transcription or typing triggers correction. With continuous input, Voxloom submits the latest draft after three seconds. While the engine is busy, only the newest waiting draft is kept. Corrections are merged by character position while preserving text the user retyped and positions overwritten by new transcription. The desktop app uses one pass of local edits. The shared `QwenTextCorrector` includes review by default and accepts `.interactive` as a `QwenConfiguration.mode`.
- Use the Accessibility button in the floating bar or settings and enable Voxloom in macOS System Settings under Privacy & Security → Accessibility for global Fn and automatic insertion. This permission applies across target apps. macOS requests microphone access on the first recording. The example uses the bundled audio.

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

## macOS demo

The retained demo is `voxloom 0.3.2.app`. GitHub contains the source, tests, documentation, and build scripts. Model weights, runtimes, and both app bundles are prepared locally.

The default pipeline is **Qwen3-ASR-1.7B 4-bit → Qwen3-4B-Instruct-2507 Q4_K_M correction**. Chinese and English are processed locally. The raw transcript and editable correction are displayed separately and can each be copied. While the demo is focused, press Fn once to start recording, or double-tap it to stop and confirm a pending draft. Typing can continue during transcription and correction.

Correction runs after an 800 ms pause or three seconds of continuous changes. It flags changes to numbers for review. Confirming transcribes the remaining audio and freezes the draft. Correction can be disabled and recognition can switch to Whisper base, tiny, or Turbo. See the [demo draft guide](docs/demo.md#当前源码的草稿输入) for details and shortcuts.

Local correction uses both the transcript and Mandarin pinyin with tone marks. The prompt covers common sound confusions such as r/l, t/d, retroflex and non-retroflex sounds, and front and back nasals. It uses sentence meaning and vocabulary to decide whether to make a change. The pinyin comes from the transcript and vocabulary hints. Evaluating the actual pronunciation requires audio.

Version 0.3.2 addressed `invalidResult` when the correction engine stopped prematurely. It checks local edits against the original text and can run one review pass after edits to catch repeated reference errors within the same segment. See the [correction fix notes](docs/correction-0.3.2.md).

The demo periodically recognizes the audio collected in a recording of up to 60 seconds. Qwen native streaming, Watch input, and system input method insertion are pending. Initial model loading takes time. Accuracy, quiet speech on AirPods, and mixed Chinese and English still require corpus evaluation. Both local models have run on the development machine. Acceptance on a 16 GB device with a process tree peak of at most 8 GB is pending.

[Demo usage and verification](docs/demo.md) · [Testing and measured coverage](docs/testing.md) · [Development guidelines](AGENTS.md)

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
bash scripts/prepare-demo.sh                  # Install pinned resources and build. Requires network access.
python3 scripts/make-demo.py                  # Rebuild the 0.3.2 demo from installed resources.
python3 scripts/make-demo.py --product voxloom # Build the standalone desktop app.
python3 scripts/prepare-voice-isolation.py   # Prepare the optional offline isolation model.
python3 scripts/make-demo.py --product voxloom -c debug --voice-isolation
python3 scripts/check.py                     # Swift unit, module, and UI checks with coverage gates.
python3 scripts/check-python.py              # Python worker protocol tests and coverage.
python3 scripts/smoke-qwen.py                 # Run both real models and sample short-clip resource usage.
python3 scripts/smoke-qwen.py --app 'voxloom 0.3.2.app' # Run the tests with bundled resources.
python3 scripts/smoke-whisper.py              # Run the Whisper API and CLI end-to-end checks.
```

`scripts/prepare-qwen.py` installs the pinned Qwen revisions and dependencies and checks SHA-256 hashes. Resources go in `.runtime/` and `models/` without sudo. In offline mode, audio and text stay on the device and recognition and correction use the installed resources. The app is signed ad hoc for local use. The `voice-input` CLI also supports Whisper file transcription.

The [0.3.2 verification summary](docs/reports/0.3.2/README.md) and the [first Whisper acceptance report](docs/acceptance-01.md) document the test results. Complete local logs go in `.build/reports/`. Real-model end-to-end tests are outside the unit and module coverage figures. See the [third-party resources](docs/third-party.md) for model and dependency sources.

### Package a macOS DMG

Pushing a `v*` version tag triggers a Release build for Apple Silicon. Use **Actions → Package Voxloom DMG → Run workflow** to select a Release or Debug build manually. Sign in to GitHub and download the DMG from the run's **Artifacts** section. The DMG is retained for up to 90 days and includes the offline models, voice isolation runtime, and an `Applications` shortcut. The app is signed ad hoc and has no Apple notarization.

To build the Release DMG locally, run the following commands.

```bash
bash scripts/prepare-demo.sh --prepare-only
python3 scripts/prepare-voice-isolation.py
python3 scripts/make-dmg.py --voice-isolation --output .build/distribution/Voxloom-release-arm64.dmg
```
