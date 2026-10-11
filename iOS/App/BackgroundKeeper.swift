// BackgroundKeeper.swift
//
// Keeps the app running while it's in the background by playing silence,
// so the connection to the Mac stays up on the home screen or in another
// app and the picture is back the moment you return. Needs the `audio`
// background mode (Info.plist). The silence mixes with other audio, so
// music keeps playing.

import AVFoundation

final class BackgroundKeeper {

    private var player: AVAudioPlayer?
    /// Should be playing: an interruption (a call, another app taking the
    /// audio session) ends playback, and it restarts when that's over.
    private var wanted = false

    var isPlaying: Bool { player?.isPlaying == true }

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mediaServicesReset),
                                               name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    func start() {
        wanted = true
        play()
    }

    func stop() {
        wanted = false
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func play() {
        guard wanted, !isPlaying else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silence)
            player.numberOfLoops = -1
            player.play()
            self.player = player
        } catch {
            player = nil
        }
    }

    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
        DispatchQueue.main.async { [weak self] in
            self?.player = nil
            self?.play()
        }
    }

    @objc private func mediaServicesReset() {
        DispatchQueue.main.async { [weak self] in
            self?.player = nil
            self?.play()
        }
    }

    /// One second of 8 kHz mono 16-bit silence as a WAV file.
    private static let silence: Data = {
        let sampleRate: UInt32 = 8000
        let dataSize = sampleRate * 2
        var wav = Data()
        func append(_ string: String) { wav.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + dataSize); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        append("data"); append32(dataSize)
        wav.append(Data(count: Int(dataSize)))
        return wav
    }()
}
