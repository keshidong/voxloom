import SpeechFoundation
import Testing

struct CLIInvocationTests {
    @Test func parsesAnExplicitLocalModelWithSafeDefaults() throws {
        let command = try #require(try CLIInvocation.parse(["transcribe", "voice.wav", "--model", "local model.bin"]))
        #expect(command.audioPath == "voice.wav")
        #expect(command.modelPath == "local model.bin")
        #expect(command.executablePath == ".runtime/whisper-build/bin/whisper-cli")
        #expect(command.language == .automatic)
        #expect(command.context.isEmpty)
        #expect(command.threads == 4)
        #expect(command.timeoutSeconds == 120)
        #expect(command.useGPU)
        #expect(!command.json)
    }

    @Test func parsesAllOptionsWithoutInterpretingTheirContents() throws {
        let command = try #require(try CLIInvocation.parse(["transcribe", "a path.wav", "--model", "m.bin",
            "--engine", "engine path", "--language", "zh", "--context", "RxSwift $(literal)",
            "--threads", "2", "--timeout", "30", "--cpu", "--json"]))
        #expect(command.executablePath == "engine path")
        #expect(command.context == "RxSwift $(literal)")
        #expect(command.language == .chinese)
        #expect(command.threads == 2)
        #expect(command.timeoutSeconds == 30)
        #expect(!command.useGPU)
        #expect(command.json)
    }

    @Test(arguments: [[], ["--help"], ["transcribe", "--help"]])
    func helpDoesNotRequireModels(arguments: [String]) throws {
        #expect(try CLIInvocation.parse(arguments) == nil)
    }

    @Test(arguments: [["other"], ["transcribe"], ["transcribe", "--model"], ["transcribe", "a.wav"],
        ["transcribe", "a.wav", "--unknown"], ["transcribe", "a.wav", "--model"],
        ["transcribe", "a.wav", "--model", "m", "--model", "m"],
        ["transcribe", "a.wav", "--model", "m", "--json", "--json"],
        ["transcribe", "a.wav", "--model", ""], ["transcribe", "a.wav", "--model", "m", "--language", "bad"],
        ["transcribe", "a.wav", "--model", "m", "--threads", "0"],
        ["transcribe", "a.wav", "--model", "m", "--threads", "65"],
        ["transcribe", "a.wav", "--model", "m", "--threads", "abc"],
        ["transcribe", "a.wav", "--model", "m", "--timeout", "0"],
        ["transcribe", "a.wav", "--model", "m", "--timeout", "601"]])
    func rejectsInvalidOrAmbiguousArguments(arguments: [String]) {
        #expect(throws: CLIError.invalidArguments) { try CLIInvocation.parse(arguments) }
    }
}
