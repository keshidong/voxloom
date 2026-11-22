import Foundation
import SpeechFoundation
import Testing

struct CorrectionCorpusTests {
    @Test func bundledFLEURSHasPairedMandarinAudioForEveryReference() throws {
        let manifest = try #require(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "FLEURS"))
        let corpus = try CorrectionCorpus(data: Data(contentsOf: manifest))
        #expect(corpus.clips.count == 36)
        for clip in corpus.clips {
            #expect(clip.language == "zh")
            let wav = manifest.deletingLastPathComponent().appendingPathComponent(clip.audio)
            let audio = try clip.decodeAudio(Data(contentsOf: wav))
            #expect(audio.samples.contains { $0 != 0 })
        }
    }

    @Test func corpusRequiresAReferenceForEveryUniqueLocalWAV() throws {
        let valid = Data(#"{"clips":[{"audio":"one.wav","reference":"请检查第7项。"}]}"#.utf8)
        let corpus = try CorrectionCorpus(data: valid)
        #expect(corpus.clips.map(\.reference) == ["请检查第7项。"])

        for invalid in [
            #"{"clips":[]}"#,
            #"{"clips":[{"audio":"one.wav","reference":" "}]}"#,
            #"{"clips":[{"audio":"../one.wav","reference":"内容"}]}"#,
            #"{"clips":[{"audio":"one.wav","reference":"一"},{"audio":"one.wav","reference":"二"}]}"#
        ] {
            #expect(throws: CorrectionCorpus.Invalid.manifest) {
                try CorrectionCorpus(data: Data(invalid.utf8))
            }
        }
    }

    @Test func corpusAcceptsShortAndFullWindowsAndRejectsLongerOnes() throws {
        let data = Data(#"{"clips":[{"audio":"one.wav","reference":"第7项"}]}"#.utf8)
        let clip = try #require(CorrectionCorpus(data: data).clips.first)
        let limit = 45 * AudioClip.sampleRate
        for frames in [1, limit] {
            let audio = try AudioClip(samples: Array(repeating: 1, count: frames))
            #expect(try clip.decodeAudio(WAVCodec.encode(audio)).samples.count == frames)
        }
        for frames in [0, limit + 1] {
            let audio = try AudioClip(samples: Array(repeating: 1, count: frames))
            #expect(throws: CorrectionCorpus.Invalid.audioLength) {
                _ = try clip.decodeAudio(WAVCodec.encode(audio))
            }
        }
    }

    @Test func characterScoreCountsEditsIgnoringPunctuationWidthAndCase() {
        let reference = "打印3份，导出 PDF。"
        #expect(CorrectionCorpus.score("打硬３份导出pdf", reference: reference) == .init(referenceCharacters: 9, edits: 1))
        #expect(CorrectionCorpus.score("打印３份 导出 pdf！", reference: reference) == .init(referenceCharacters: 9, edits: 0))
        #expect(CorrectionCorpus.score("", reference: reference) == .init(referenceCharacters: 9, edits: 9))
        #expect(CorrectionCorpus.score("好你们呀", reference: "你们") == .init(referenceCharacters: 2, edits: 2))
    }
}
