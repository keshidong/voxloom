import SpeechFoundation
import Testing

struct AudioClipTests {
    @Test func rejectsMoreThanOneMinuteOfAudio() {
        #expect(throws: AudioError.tooLong) {
            _ = try AudioClip(samples: [Int16](repeating: 0, count: 16_000 * 60 + 1))
        }
    }

    @Test func acceptsEmptyAndExactLimitAndReportsDuration() throws {
        #expect(try AudioClip(samples: []).duration == 0)
        let samples = [Int16](repeating: 1, count: AudioClip.maximumSamples)
        let clip = try AudioClip(samples: samples)
        #expect(clip.duration == 60)
        #expect(clip.samples == samples)
    }
}
