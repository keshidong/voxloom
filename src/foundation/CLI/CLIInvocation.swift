public enum CLIError: Error, Equatable { case invalidArguments }

/// Pure argument parsing; no filesystem, environment lookup, or process execution.
public struct CLIInvocation: Sendable, Equatable {
    public let audioPath: String
    public let executablePath: String
    public let modelPath: String
    public let language: RecognitionLanguage
    public let context: String
    public let threads: Int
    public let timeoutSeconds: Int
    public let useGPU: Bool
    public let json: Bool

    /// nil requests usage/help. All paths remain uninterpreted strings here.
    public static func parse(_ arguments: [String]) throws -> Self? {
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["transcribe", "--help"] { return nil }
        guard arguments.count >= 2, arguments[0] == "transcribe", !arguments[1].hasPrefix("--")
        else { throw CLIError.invalidArguments }
        let valueOptions: Set<String> = ["--engine", "--model", "--language", "--context", "--threads", "--timeout"]
        let flagOptions: Set<String> = ["--cpu", "--json"]
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var index = 2
        while index < arguments.count {
            let key = arguments[index]
            if flagOptions.contains(key) {
                guard flags.insert(key).inserted else { throw CLIError.invalidArguments }
                index += 1
            } else {
                guard valueOptions.contains(key), values[key] == nil, index + 1 < arguments.count
                else { throw CLIError.invalidArguments }
                values[key] = arguments[index + 1]
                index += 2
            }
        }
        guard let model = values["--model"], !model.isEmpty,
              let language = RecognitionLanguage(rawValue: values["--language"] ?? "auto"),
              let threads = Int(values["--threads"] ?? "4"), (1...64).contains(threads),
              let timeout = Int(values["--timeout"] ?? "120"), (1...600).contains(timeout)
        else { throw CLIError.invalidArguments }
        return Self(audioPath: arguments[1], executablePath: values["--engine"] ?? ".runtime/whisper-build/bin/whisper-cli",
                    modelPath: model, language: language, context: values["--context"] ?? "",
                    threads: threads, timeoutSeconds: timeout, useGPU: !flags.contains("--cpu"), json: flags.contains("--json"))
    }
}
