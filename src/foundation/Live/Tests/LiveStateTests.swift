import Testing
import SpeechFoundation

struct LiveStateTests {
    @Test(arguments: [true, false])
    func filteredPreviewDoesNotReplaceFullFinalRecognition(previewCompletesBeforeRelease: Bool) {
        let audio = Array(repeating: Int16(1000), count: AudioClip.sampleRate)
        var state = LiveState()
        func send(_ event: LiveEvent) -> LiveTransition {
            let next = LiveReducer.reduce(state, event, requiresFinalRecognition: true)
            state = next.state
            return next
        }
        _ = send(.start)
        _ = send(.ready(1))
        #expect(send(.audio(1, audio)).effects == [.recognize(1, audio)])
        let preview = LiveEvent.result(1, audio.count, "预览")
        if previewCompletesBeforeRelease { _ = send(preview) }
        let release = send(.stop)
        let finalEffects = previewCompletesBeforeRelease ? release.effects : send(preview).effects
        #expect(finalEffects.contains(.recognize(1, audio)))
        #expect(state.phase == .finishing)
        #expect(send(.result(1, audio.count, "定稿")).effects.isEmpty)
        #expect(state.phase == .idle)
        #expect(state.text == "定稿")
    }

    @Test func finalOnlyRecognitionQueuesTheRecordingOnceOnRelease() {
        let started = LiveReducer.reduce(LiveState(), .start, recognizesWhileRecording: false).state
        let recording = LiveReducer.reduce(started, .ready(started.session), recognizesWhileRecording: false).state
        let audio = Array(repeating: Int16(1000), count: AudioClip.sampleRate)
        let held = LiveReducer.reduce(recording, .audio(started.session, audio), recognizesWhileRecording: false)
        #expect(held.effects.isEmpty)
        #expect(LiveReducer.reduce(held.state, .pulse, recognizesWhileRecording: false).effects.isEmpty)
        let released = LiveReducer.reduce(held.state, .stop, recognizesWhileRecording: false)
        let queuedExactlyOnce = released.effects == [.stopCapture, .recognize(started.session, audio)]
        #expect(queuedExactlyOnce)
    }

    @Test func releaseDuringAuthorizationStopsAndIgnoresLatePermission() {
        let awaiting = LiveReducer.reduce(LiveState(), .start).state
        let released = LiveReducer.reduce(awaiting, .stop)
        #expect(released.state.phase == .idle)
        #expect(released.effects == [.stopCapture, .cancelRecognition])
        let late = LiveReducer.reduce(released.state, .ready(awaiting.session))
        #expect(late.state.phase == .idle)
        #expect(late.effects.isEmpty)
    }

    @Test func firstPreviewSubmitsOnArrivalOfOneSecondOfAudioWithoutWaitingForATick() {
        let started = LiveReducer.reduce(LiveState(), .start).state
        let recording = LiveReducer.reduce(started, .ready(1)).state
        let sampleRate = AudioClip.sampleRate
        let almostOneSecond = [Int16](repeating: 1000, count: sampleRate - 1)
        let partial = LiveReducer.reduce(recording, .audio(1, almostOneSecond))
        #expect(partial.effects.isEmpty)
        let first = LiveReducer.reduce(partial.state, .audio(1, [1000]))
        let submittedFullSecond = first.effects == [.recognize(1, almostOneSecond + [1000])]
        #expect(submittedFullSecond)
        let more = LiveReducer.reduce(first.state, .audio(1, Array(repeating: 1000, count: sampleRate / 2)))
        #expect(more.effects.isEmpty)
        #expect(LiveReducer.reduce(more.state, .pulse).effects.isEmpty)
        let next = LiveReducer.reduce(more.state, .result(1, sampleRate, "预览"))
        #expect(next.effects.count == 1)
        #expect(next.state.submitted == sampleRate + sampleRate / 2)
    }

    @Test func anEmptyPreviewRetriesAsSoonAsEnoughNewAudioArrives() {
        let initial = [Int16](repeating: 1000, count: AudioClip.sampleRate)
        let more = [Int16](repeating: 1000, count: AudioClip.sampleRate / 2)
        var state = LiveState()
        for event in [LiveEvent.start, .ready(1), .audio(1, initial), .result(1, initial.count, "")] {
            state = LiveReducer.reduce(state, event).state
        }
        #expect(state.text.isEmpty)
        let partial = LiveReducer.reduce(state, .audio(1, Array(more.dropLast())))
        #expect(partial.effects.isEmpty)
        let next = LiveReducer.reduce(partial.state, .audio(1, [1000]))
        let recognizesImmediately = next.effects == [.recognize(1, initial + more)]
        #expect(recognizesImmediately)
    }

    @Test func visiblePreviewRefreshesAsSoonAsEnoughNewAudioArrives() {
        let initial = [Int16](repeating: 1000, count: AudioClip.sampleRate)
        let more = [Int16](repeating: 1000, count: AudioClip.sampleRate / 2)
        var state = LiveState()
        for event in [LiveEvent.start, .ready(1), .audio(1, initial), .result(1, initial.count, "实时中文")] {
            state = LiveReducer.reduce(state, event).state
        }
        let partial = LiveReducer.reduce(state, .audio(1, Array(more.dropLast())))
        #expect(partial.effects.isEmpty)
        let next = LiveReducer.reduce(partial.state, .audio(1, [1000]))
        let refreshesImmediately = next.effects == [.recognize(1, initial + more)]
        #expect(refreshesImmediately)
    }

    @Test func filteredPreviewStartsAt750MillisecondsAndRetriesAfter250MillisecondsUntilTextAppears() {
        let firstSize = AudioClip.sampleRate * 3 / 4
        let retrySize = AudioClip.sampleRate / 4
        let refreshSize = AudioClip.sampleRate / 2
        var state = LiveState()
        func send(_ event: LiveEvent) -> LiveTransition {
            let transition = LiveReducer.reduce(state, event, requiresFinalRecognition: true, usesShortPreviewCadence: true)
            state = transition.state
            return transition
        }

        _ = send(.start)
        _ = send(.ready(1))
        #expect(send(.audio(1, Array(repeating: 1000, count: firstSize - 1))).effects.isEmpty)
        let first = send(.audio(1, [1000]))
        let submittedFirst = first.effects == [.recognize(1, first.state.samples)]
        #expect(submittedFirst)
        _ = send(.result(1, firstSize, ""))
        #expect(send(.audio(1, Array(repeating: 1000, count: retrySize - 1))).effects.isEmpty)
        let retry = send(.audio(1, [1000]))
        let submittedRetry = retry.effects == [.recognize(1, retry.state.samples)]
        #expect(submittedRetry)
        _ = send(.result(1, firstSize + retrySize, "实时中文"))
        #expect(send(.audio(1, Array(repeating: 1000, count: refreshSize - 1))).effects.isEmpty)
        let refresh = send(.audio(1, [1000]))
        let submittedRefresh = refresh.effects == [.recognize(1, refresh.state.samples)]
        #expect(submittedRefresh)
    }

    @Test(arguments: [true, false])
    func onePreviewFailureCanRecoverBeforeRelease(retrySucceeds: Bool) {
        let first = [Int16](repeating: 1000, count: AudioClip.sampleRate)
        let extra = [Int16](repeating: 1000, count: AudioClip.sampleRate / 2)
        var state = LiveState()
        func send(_ event: LiveEvent) -> LiveTransition {
            let next = LiveReducer.reduce(state, event, requiresFinalRecognition: true)
            state = next.state
            return next
        }
        _ = send(.start)
        _ = send(.ready(1))
        _ = send(.audio(1, first))
        let retry: LiveTransition
        if retrySucceeds {
            #expect(send(.audio(1, extra)).effects.isEmpty)
            retry = send(.previewFailed(1, first.count))
        } else {
            #expect(send(.previewFailed(1, first.count)).effects.isEmpty)
            #expect(send(.pulse).effects.isEmpty)
            retry = send(.audio(1, extra))
        }
        let retriesWithNewAudio = retry.effects == [.recognize(1, first + extra)]
        #expect(retriesWithNewAudio)
        if retrySucceeds {
            _ = send(.result(1, first.count + extra.count, "预览"))
            #expect(state.text == "预览")
            #expect(state.phase == .recording)
        } else {
            _ = send(.previewFailed(1, first.count + extra.count))
            #expect(send(.audio(1, extra)).effects.isEmpty)
            #expect(send(.pulse).effects.isEmpty)
        }
        let recorded = state.samples
        let release = send(.stop)
        let recognizesFinal = release.effects == [.stopCapture, .recognize(1, recorded)]
        #expect(recognizesFinal)
    }

    @Test func startRequestsPermissionAndIgnoresRepeatedStart() {
        let first = LiveReducer.reduce(LiveState(), .start)
        #expect(first.state.phase == .authorizing)
        #expect(first.effects == [.authorize(1)])
        let repeated = LiveReducer.reduce(first.state, .start)
        #expect(repeated.state == first.state)
        #expect(repeated.effects.isEmpty)
    }

    @Test func recordingStartsOnlyAfterCurrentPermissionAndKeepsOnlyOneInference() {
        let starting = LiveReducer.reduce(LiveState(), .start).state
        #expect(LiveReducer.reduce(starting, .ready(99)).effects.isEmpty)
        let ready = LiveReducer.reduce(starting, .ready(1))
        #expect(ready.state.phase == .recording)
        #expect(ready.effects == [.capture(1)])
        let voiced = [Int16](repeating: 1000, count: 24_000)
        let first = LiveReducer.reduce(ready.state, .audio(1, voiced))
        #expect(first.state.seconds == 1.5)
        #expect(first.state.level > 0)
        let firstMatches = first.effects == [.recognize(1, voiced)]
        #expect(firstMatches)
        let more = LiveReducer.reduce(first.state, .audio(1, voiced)).state
        #expect(LiveReducer.reduce(more, .pulse).effects.isEmpty)
        let result = LiveReducer.reduce(more, .result(1, voiced.count, "中文"))
        #expect(result.state.text == "中文")
        let latestMatches = result.effects == [.recognize(1, voiced + voiced)]
        #expect(latestMatches)
    }

    @Test func stoppingFlushesLatestAudioAndCancellationRejectsLateResults() {
        var state = LiveState()
        for event in [LiveEvent.start, .ready(1), .audio(1, [1000, -1000]), .stop] {
            let change = LiveReducer.reduce(state, event); state = change.state
        }
        #expect(state.phase == .finishing)
        #expect(state.busy)
        let complete = LiveReducer.reduce(state, .result(1, 2, "最终结果"))
        #expect(complete.state.phase == .idle)
        #expect(complete.state.text == "最终结果")
        let cleared = LiveReducer.reduce(complete.state, .clear).state
        #expect(cleared.text.isEmpty)
        let restarted = LiveReducer.reduce(cleared, .start).state
        let cancelled = LiveReducer.reduce(restarted, .cancel)
        #expect(cancelled.state.phase == .idle)
        #expect(cancelled.effects == [.stopCapture, .cancelRecognition])
        #expect(LiveReducer.reduce(cancelled.state, .ready(restarted.session)).effects.isEmpty)
        #expect(LiveReducer.reduce(cancelled.state, .result(1, 2, "迟到结果")).state.text.isEmpty)
    }

    @Test func stopWaitsForBusyInferenceAndThenFlushesShortTail() {
        var state = LiveState()
        for event in [LiveEvent.start, .ready(1), .audio(1, Array(repeating: 1000, count: 24_000)),
                      .pulse, .audio(1, [1000]), .stop] { state = LiveReducer.reduce(state, event).state }
        #expect(state.phase == .finishing)
        let tail = LiveReducer.reduce(state, .result(1, 24_000, "部分"))
        #expect(tail.state.submitted == 24_001)
        #expect(tail.effects.count == 1)
        #expect(LiveReducer.reduce(tail.state, .result(1, 24_001, "全部")).state.phase == .idle)
    }

    @Test func stoppingReusesTheResultWhenAllAudioHasAlreadyBeenRecognized() {
        let text = String(repeating: "转写完成的一段内容。", count: 100)
        let samples = [Int16](repeating: 1000, count: AudioClip.sampleRate * 45)
        var state = LiveState()
        for event in [LiveEvent.start, .ready(1), .audio(1, samples), .pulse, .result(1, samples.count, text)] {
            state = LiveReducer.reduce(state, event).state
        }
        #expect(state.phase == .recording)
        #expect(state.text == text)

        let released = LiveReducer.reduce(state, .stop)
        let finalPhase = released.state.phase
        let reusedText = released.state.text == text
        let stillProcessing = released.state.busy
        let stoppedWithoutRecognition = released.effects == [.stopCapture]
        #expect(finalPhase == .idle)
        #expect(reusedText)
        #expect(!stillProcessing)
        #expect(stoppedWithoutRecognition)
    }

    @Test func silenceLimitAndFailureHaveBoundedRecovery() {
        var state = LiveReducer.reduce(LiveState(), .start).state
        #expect(LiveReducer.reduce(state, .failed(99, "旧错误")).state.error == nil)
        state = LiveReducer.reduce(state, .failed(1, "没有麦克风权限")).state
        #expect(state.error == "没有麦克风权限")
        #expect(state.phase == .idle)
        state = LiveReducer.reduce(state, .start).state
        state = LiveReducer.reduce(state, .ready(state.session)).state
        #expect(LiveReducer.reduce(state, .audio(99, [1])).state.samples.isEmpty)
        state = LiveReducer.reduce(state, .audio(state.session, [])).state
        state = LiveReducer.reduce(state, .audio(state.session, Array(repeating: 0, count: AudioClip.maximumSamples + 2))).state
        #expect(state.samples.count == AudioClip.maximumSamples)
        #expect(state.phase == .idle)
        #expect(!state.busy)
        #expect(state.text.isEmpty)
        #expect(LiveReducer.reduce(state, .stop).effects.isEmpty)
    }
}
