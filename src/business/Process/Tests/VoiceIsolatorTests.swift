import Foundation
import SpeechFoundation
import SpeechInput
import Testing

struct VoiceIsolatorTests {
    @Test func workerReceivesEveryReferenceAndOnlyItsOutputIsReturned() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = directory.appendingPathComponent("worker")
        let script = """
        #!/bin/sh
        /usr/bin/touch "$(dirname "$0")/started"
        printf '%s\\n' '{"ready":true}'
        while IFS= read -r request; do
            destination=$(printf '%s' "$request" | /usr/bin/plutil -extract output raw -o - -- -) || exit 2
            if session=$(printf '%s' "$request" | /usr/bin/plutil -extract previewSession raw -o - -- - 2>/dev/null); then
                test "$session" = '00000000-0000-0000-0000-000000000001' || exit 5
                reference=$(printf '%s' "$request" | /usr/bin/plutil -extract references.0 raw -o - -- -) || exit 3
            else
                reference=$(printf '%s' "$request" | /usr/bin/plutil -extract references.2 raw -o - -- -) || exit 3
            fi
            /bin/cp "$reference" "$destination" || exit 4
            printf '%s\\n' '{"ok":true}'
        done
        """
        try script.write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let isolator = VoiceIsolator(executable: worker)
        await isolator.prepare()
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("started").path))
        let microphone = try AudioClip(samples: [1, 2])
        let references = try [AudioClip(samples: [100]), AudioClip(samples: [200, -200]),
                              AudioClip(samples: [300, -300])]
        let session = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let preview = try await isolator.preview(microphone, references: references, session: session)
        #expect(preview == references[0])
        let output = try await isolator.isolate(microphone, references: references)
        #expect(output == references[2])
        await isolator.shutdown()
    }
}
