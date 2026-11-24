import AVFoundation
import SpeechFoundation

@MainActor protocol VoiceSamplePlaying {
    func play(_ clip: AudioClip, completion: @escaping @MainActor (Bool) -> Void) throws
    func stop()
}

@MainActor final class VoiceSamplePlayback: NSObject, VoiceSamplePlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var completion: (@MainActor (Bool) -> Void)?

    func play(_ clip: AudioClip, completion: @escaping @MainActor (Bool) -> Void) throws {
        stop()
        let player = try AVAudioPlayer(data: WAVCodec.encode(clip))
        self.player = player
        self.completion = completion
        player.delegate = self
        guard player.play() else {
            stop()
            throw PlaybackError.couldNotStart
        }
    }

    func stop() {
        player?.delegate = nil
        player?.stop()
        player = nil
        completion = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(ObjectIdentifier(player), successfully: flag)
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        finish(ObjectIdentifier(player), successfully: false)
    }

    private nonisolated func finish(_ id: ObjectIdentifier, successfully: Bool) {
        Task { @MainActor [weak self] in
            guard let self, let player, ObjectIdentifier(player) == id else { return }
            let callback = completion
            stop()
            callback?(successfully)
        }
    }

    private enum PlaybackError: Error { case couldNotStart }
}
