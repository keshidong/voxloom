import Foundation
import SpeechFoundation
import SpeechInput

@main
enum TranscriptionEvaluation {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 5, ["asr", "correction", "correction-dataset"].contains(arguments[1]) else {
            FileHandle.standardError.write(Data("Usage: transcription-eval asr|correction|correction-dataset INPUT RESOURCES OUTPUT.json\n".utf8))
            exit(2)
        }
        let input = URL(fileURLWithPath: arguments[2])
        let resources = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let output = URL(fileURLWithPath: arguments[4])
        do {
            guard input.resolvingSymlinksInPath() != output.resolvingSymlinksInPath() else {
                throw EvaluationError.sameInputAndOutput
            }
            let failures: Int
            switch arguments[1] {
            case "asr":
                failures = try await ASRRun(resources: resources).evaluate(manifestAt: input, output: output)
            case "correction-dataset":
                failures = try await CorrectionRun(resources: resources).evaluate(datasetAt: input, output: output)
            default:
                failures = try await CorrectionRun(resources: resources).evaluate(asrReportAt: input, output: output)
            }
            if failures > 0 { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("Evaluation failed: \(failureName(error))\n".utf8))
            exit(1)
        }
    }
}

enum EvaluationError: Error {
    case invalidManifest
    case incompleteASRInput
    case sameInputAndOutput
}

func failureName(_ error: any Error) -> String {
    switch error {
    case let error as RecognitionError: String(describing: error)
    case let error as CorrectionError: String(describing: error)
    case let error as EvaluationError: String(describing: error)
    default: String(describing: type(of: error))
    }
}

func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
    let parts = start.duration(to: .now).components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

func saveReport(_ report: some Encodable, at output: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let directory = output.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try (encoder.encode(report) + Data([10])).write(to: output, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
}
