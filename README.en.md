# Voxloom

[简体中文](README.md) · English

Voxloom is a macOS dictation app that runs on-device for Chinese and English. It appears as 小声哔哔 when macOS uses Chinese and as Voxloom in other languages.

## Use Voxloom

After preparing the runtimes, run `python3 scripts/package-app.py --external-models` to build `Voxloom.app`. The menu bar waveform has a transparent background and uses the system foreground color, appearing white on a dark menu bar. [App icon source](src/business/VoxloomDesktop/App/Resources/AppIcon.svg)

Pass `--configuration` (`-c`) with `debug` or `release` when packaging. Release is the default. The debug build has its own app name and bundle ID.

Model downloads start at Hugging Face. If a connection resets, a server fails, or a file fails verification, Voxloom tries the configured ModelScope and HF-Mirror alternatives. During that installation, it prioritizes the source that most recently delivered a verified file. Every newly downloaded file must match the catalog's SHA-256 before installation. [Model download catalog](scripts/model-downloads.json)

Builds with the optional voice isolation model include the experimental “Keep only my voice” setting, which is off by default. Record at least one 3–8 second clip. You can read the same Chinese-English sentence shown in settings for each speaking volume. Quiet, normal, and loud samples can be recorded, played back, replaced, or deleted separately. With isolation enabled, Voxloom filters new audio locally and updates the transcript preview while you hold Fn. Releasing Fn runs full-recording isolation and transcription for the final text.

- Place the cursor in the target field and hold Fn (Globe) on its own for about 0.18 seconds to start recording. On release, Voxloom transcribes the remaining audio. With Omni enabled, it waits up to 45 seconds for audio review and uses the available draft at the deadline. It requests a paste when it verifies that the original field is still focused. It keeps the draft if the target cannot be verified, focus changes, recording is interrupted, or permissions are missing. A recording can last up to 60 seconds.
- You can also hold the waveform button on the left of the floating bar with the mouse for about 0.18 seconds. Release to finish, even after dragging the pointer off the button. During setup, choose Later at the Accessibility prompt if needed. You can record once microphone access is granted and the recognition model is ready. With Accessibility off, open the draft to copy the transcript.
- During recording, press E while holding Fn to open the draft editor on release. Once transcription finishes, press Enter to insert into the original input field or Shift+Enter to add a new line. If Voxloom cannot verify the original field, it keeps the text in the draft. Press Esc while holding Fn to discard the current recording and restore the previous draft. Release Fn to record again.
- Voxloom submits the first preview as soon as it has about a second of audio and detects voice activity. At launch, Voxloom loads the selected Qwen3-ASR model and the enabled voice isolation model in the background. Preparation uses no microphone audio. Dictation reuses the resident workers. Voxloom releases the Qwen process when the next recording uses a different engine or when the app quits.
- While the recording has no text yet, Voxloom tries a preview as soon as about 0.5 seconds of additional audio arrives. A failed voice isolation preview gets one retry with newer audio. Releasing still processes the final recording.
- The floating bar shows recording duration, audio level, progress, and the latest line of transcription. Open the draft to see the full text. The gear opens settings and the app icon in the menu bar brings back the floating bar. Holding Fn with an uninserted draft adds a new line, so both recordings can be inserted together. Canceling a continuation restores the earlier draft. A recording after an insertion request starts with an empty draft.
- Choose Expand to edit, copy, or clear the draft above the floating bar. In the draft editor, Enter inserts the text, Shift+Enter starts a new line, and Esc clears the draft. While the target app is focused, double-tapping Fn also inserts the draft. Voxloom uses the target app's normal paste behavior to replace selected text. If the frontmost app changes before insertion, the draft remains available to insert or copy.
- In the expanded draft editor, `⌘C` copies the selection and `⌘V` pastes text at the caret or replaces the selection.
- Dictation defaults to Chinese. Settings also offer automatic language detection and English, Qwen3-ASR or Whisper, and vocabulary hints. Correction is off by default. Saved Qwen3-4B correction selections switch to Off after upgrading. [Full accuracy evaluation](docs/reports/transcription-evaluation-2026-11-23.md)
- Enter terminology, names, and product names in Vocabulary Hints in Settings. The recognition prompt is capped at 512 UTF-8 bytes for Qwen3-ASR and 192 for Whisper.
- Qwen3-ASR formats clear dictated identifiers and decimal numbers. Identifiers use contiguous lowercase ASCII letters and digits, preserving leading zeros and every digit. Decimal numbers use Arabic numerals, retaining each digit and the spoken unit. Clock expressions and common idioms retain their original wording.
- When you select Omni, Voxloom downloads the review model after the ASR model is ready. Settings shows progress, verification, errors, and retry. Dictation is available during the download.
- Builds packaged with `--external-models` offer **Qwen3-Omni audio review** under Settings → Correction Model. The weights and audio projector total about 19.9 GB. After release, Omni uses the recording and any retained Voxloom draft to review the ASR draft. Awkward phrasing can flag transcription errors. Omni makes minimal edits supported by the recording. At the start of recording, Voxloom captures the target app’s active window through macOS Accessibility and passes the cleaned window words, app name, and bundle ID to local Omni for terminology. Voxloom preserves overlapping keyboard edits and falls back to the ASR draft if review fails or is canceled. [Offline evaluation](docs/reports/qwen3-omni-correction-2026-11-27.md)
- In Debug builds, open **查看 Omni 上下文** in Settings to view the most recent window words sent to Omni. The preview is held in memory. The log at `~/Library/Logs/dev.voxloom.app.debug/omni-app-context.json` records the app name, bundle ID, submission time, context size, elapsed time, and outcome of the latest review.
- Window context reads accessible titles, descriptions, and text values in their original order, skipping hidden controls and system-marked secure inputs. Voxloom strips common formatting, code blocks, variables, and paths, then passes up to the last 300 words. Both Chinese and English count toward this limit.
- Omni review uses pinyin to find similar-sounding Chinese terms in the window and mark them as alternatives at the matching position in the draft. The model chooses using the recording and the surrounding sentence.
- With GPU acceleration enabled, holding Fn starts local Omni and prepares the earlier window words during recording. Nearby dictations reuse the loaded model. It is released after 30 seconds of inactivity and warms up again on the next dictation.
- When the app launches without Accessibility access, the floating bar asks for it first to enable the global shortcut and automatic insertion. After granting access or choosing Later, click Allow Microphone or hold the dictation key to request microphone access for the first time. Choosing Later applies to the current launch. The ASR model downloads in the background from launch. The bar shows download progress once microphone access is granted. Hold the dictation key again when the model is ready.
- Hold Fn to speak by default. Go to **Settings → Push-to-talk key → Change** to choose a single key or a combination using Control, Option, Command, and Shift, such as Control + Option or Command + Shift + Space. Hold the chosen shortcut to dictate and release any of its keys to finish.
- Use the Accessibility button in the floating bar or settings and enable Voxloom in macOS System Settings under Privacy & Security → Accessibility for the global shortcut and automatic insertion. This permission applies across target apps.

Local checks cover expanding and collapsing the draft, recording and transcription feedback, Fn press and release, updating Accessibility permission status, and cursor insertion, selection replacement, and clipboard restoration in native controls. Real global shortcuts and cross-app insertion require verification on a Mac with permission enabled.

Local builds use ad-hoc signing. If the floating bar asks for Accessibility access after a rebuild, re-add the current `Voxloom.app` in System Settings. If macOS asks you to reopen the app, follow that prompt.

If Voxloom 0.1.4 shows `engineUnavailable` on macOS earlier than 26.2, select Whisper Turbo in the transcription model settings and wait for its download to finish. New builds select the Qwen MLX runtime for macOS 14 and verify its minimum system version when packaging.

## Runtime resource usage

These historical measurements were taken on 2026-11-23 at roughly 0.29-second intervals on an Apple M2 Pro with 32 GiB of unified memory and macOS 26.5.1. The idle desktop app had Qwen ASR loaded. The inference measurement used the Qwen3-ASR-1.7B 4-bit and Qwen3-4B-Instruct-2507 Q4_K_M dual-model test with a 4.2-second Mandarin clip. Omni resource usage still needs a separate measurement. [Dual-model test](src/business/QwenASR/Tests/QwenASRE2ETests.swift)

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

Open the DMG and follow the arrow in the Voxloom Installer window to drag Voxloom into Applications. Dictation is available once the selected ASR model passes SHA-256 verification. The correction and voice isolation models download when enabled. Check download status and retry failed downloads in Settings. Models in `~/Library/Application Support/dev.voxloom.app/Models` are reused across upgrades that require the same model versions.

The Release bundle ID is `dev.voxloom.app` and the Debug bundle ID is `dev.voxloom.app.debug`. The app is signed ad hoc and has no Apple notarization.

To build the Release DMG locally, run the following commands.

```bash
bash scripts/prepare-app.sh --runtime-only
python3 scripts/prepare-voice-isolation.py --runtime-only
.runtime/qwen-asr-runtime/asr-python/bin/python3.12 -m venv .build/dmg-tools
.build/dmg-tools/bin/python -m pip install -r scripts/dmg/requirements.txt
.build/dmg-tools/bin/python scripts/make-dmg.py --voice-isolation --output .build/distribution/Voxloom-release-arm64.dmg
```
