@preconcurrency import ApplicationServices
import AppKit
import SpeechInput

@MainActor struct DictationPermissions {
    var isTrusted: () -> Bool = { AXIsProcessTrusted() }
    var canPostEvents: () -> Bool = { CGPreflightPostEventAccess() }
    var requestAccessibility: () -> Void = {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    var requestPostEvents: () -> Void = { _ = CGRequestPostEventAccess() }
    var microphoneAuthorization: () -> MicrophoneCapture.Authorization = { MicrophoneCapture.authorization }
    var requestMicrophone: @MainActor () async -> Bool = { await MicrophoneCapture.requestAuthorization() }
    var openMicrophoneSettings: () -> Void = {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    var canInsert: Bool { isTrusted() && canPostEvents() }

    func requestAccess() {
        guard isTrusted() else { requestAccessibility(); return }
        // macOS exposes event posting in the same Accessibility settings as AX trust.
        if !canPostEvents() { requestPostEvents() }
    }
}

struct DictationAvailability {
    var globalShortcut = false
    var canInsert = false
}
