import Foundation
import SpeechFoundation

struct CorrectionCorpus {
    struct Clip: Decodable, Sendable {
        let audio: String
        let reference: String
        let vocabulary: String?
        let language: String?

        func decodeAudio(_ data: Data) throws -> AudioClip {
            let audio = try WAVCodec.decode(data)
            guard !audio.samples.isEmpty, audio.samples.count <= 45 * AudioClip.sampleRate else {
                throw Invalid.audioLength
            }
            return audio
        }
    }

    struct Score: Equatable {
        let referenceCharacters: Int
        let edits: Int
    }

    static func score(_ text: String, reference: String) -> Score {
        let expected = characters(in: reference)
        let actual = characters(in: text)
        var row = Array(0...expected.count)
        for (offset, character) in actual.enumerated() {
            var diagonal = row[0]
            row[0] = offset + 1
            for (index, target) in expected.enumerated() {
                let column = index + 1
                let above = row[column]
                row[column] = min(above + 1, row[index] + 1, diagonal + (character == target ? 0 : 1))
                diagonal = above
            }
        }
        return Score(referenceCharacters: expected.count, edits: row[expected.count])
    }

    private static func characters(in text: String) -> [Character] {
        text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
            .map { $0 }
    }

    enum Invalid: Error, Equatable {
        case manifest
        case audioLength
    }

    let clips: [Clip]

    init(data: Data) throws {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              !manifest.clips.isEmpty,
              Set(manifest.clips.map(\.audio)).count == manifest.clips.count,
              manifest.clips.allSatisfy({ clip in
                  clip.audio.hasSuffix(".wav") && !clip.audio.contains("/") && !clip.audio.contains("\\")
                      && clip.audio.count > 4
                      && clip.reference.contains { $0.isLetter || $0.isNumber }
                      && RecognitionLanguage(rawValue: clip.language ?? "auto") != nil
              })
        else { throw Invalid.manifest }
        clips = manifest.clips
    }

    private struct Manifest: Decodable {
        let clips: [Clip]
    }
}
