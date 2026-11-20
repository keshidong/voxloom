import Foundation
import SpeechFoundation
import Testing

struct WAVCodecTests {
    @Test func encodingProducesStandardPCMHeaderAndLittleEndianSamples() throws {
        let data = WAVCodec.encode(try AudioClip(samples: [0x1234, -1]))
        #expect(data.count == 48)
        #expect(Array(data.prefix(12)) == Array("RIFF".utf8) + [40, 0, 0, 0] + Array("WAVE".utf8))
        #expect(Array(data.suffix(4)) == [0x34, 0x12, 0xff, 0xff])
    }

    @Test func decodesSignedPCMAndRejectsTruncatedInput() throws {
        let clip = try AudioClip(samples: [.min, -1, 0, 1, .max])
        let wave = WAVCodec.encode(clip)
        #expect(try WAVCodec.decode(wave) == clip)
        #expect(throws: AudioError.malformedWAV) {
            try WAVCodec.decode(wave.dropLast())
        }
    }

    @Test func supportsEmptyAudioAndUnknownPaddedChunks() throws {
        let empty = try AudioClip(samples: [])
        #expect(try WAVCodec.decode(WAVCodec.encode(empty)) == empty)
        var wave = WAVCodec.encode(try AudioClip(samples: [123]))
        wave.insert(contentsOf: Array("JUNK".utf8) + [1, 0, 0, 0, 9, 0], at: 12)
        wave[4] += 10
        #expect(try WAVCodec.decode(wave).samples == [123])
    }

    @Test func rejectsMalformedChunksAndMissingRequiredChunks() throws {
        let wave = WAVCodec.encode(try AudioClip(samples: [1]))
        var badChunk = wave
        badChunk[16] = 255
        var noFormat = wave
        noFormat.replaceSubrange(12..<16, with: "JUNK".utf8)
        var noData = wave
        noData.replaceSubrange(36..<40, with: "JUNK".utf8)
        var oddData = wave
        oddData[40] = 1
        var missingPadding = wave
        missingPadding.replaceSubrange(36..<40, with: "JUNK".utf8)
        missingPadding[40] = 1
        missingPadding.removeLast()
        missingPadding[4] -= 1
        for input in [Data(), Data("RIFF".utf8), badChunk, noFormat, noData, oddData, missingPadding] {
            #expect(throws: AudioError.malformedWAV) { try WAVCodec.decode(input) }
        }
        #expect(throws: AudioError.tooLong) {
            try WAVCodec.decode(Data(repeating: 0, count: WAVCodec.maximumFileSize + 1))
        }
    }

    @Test(arguments: [20, 22, 24, 28, 32, 34])
    func rejectsUnsupportedAudioFormats(field: Int) throws {
        var wave = WAVCodec.encode(try AudioClip(samples: [1]))
        wave[field] ^= 1
        #expect(throws: AudioError.unsupportedFormat) { try WAVCodec.decode(wave) }
    }

    @Test func rejectsDuplicateShortOrTrailingChunksAndWrongContainerHeaders() throws {
        let valid = WAVCodec.encode(try AudioClip(samples: [1]))
        func withCorrectSize(_ bytes: Data) -> Data {
            var result = bytes
            let size = UInt32(bytes.count - 8)
            for offset in 0..<4 { result[4 + offset] = UInt8(truncatingIfNeeded: size >> (8 * offset)) }
            return result
        }
        var duplicateFormat = valid
        duplicateFormat.append(valid[12..<36])
        var duplicateData = valid
        duplicateData.append(valid[36...])
        var shortFormat = valid
        shortFormat[16] = 14
        shortFormat.removeSubrange(34..<36)
        var trailing = valid
        trailing.append(0)
        var wrongRIFF = valid
        wrongRIFF[0] = 0
        var wrongWAVE = valid
        wrongWAVE[8] = 0
        for input in [withCorrectSize(duplicateFormat), withCorrectSize(duplicateData),
                      withCorrectSize(shortFormat), withCorrectSize(trailing), wrongRIFF, wrongWAVE] {
            #expect(throws: AudioError.malformedWAV) { try WAVCodec.decode(input) }
        }
    }
}
