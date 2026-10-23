import Foundation
import AVFoundation

/// Reads the assistant's replies aloud.
///
/// Cloud conversations use Gemini's voice (`CloudVoice`), falling back to the
/// iPhone's own voice if it fails. On-device conversations always use the iPhone voice.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let systemVoice: AVSpeechSynthesisVoice?
    private let cloudVoice: CloudVoice?
    private var player: AVAudioPlayer?

    private var continuation: CheckedContinuation<Void, Never>?
    private var currentUtterance: ObjectIdentifier?
    /// Bumped by `stop()`, i.e. when the user interrupts. Speech prepared before an
    /// interruption is stale and won't play.
    private var interruptions = 0

    /// Short fillers in the cloud voice, generated once so they play with no delay.
    private var cachedAcknowledgements: [Data] = []
    /// The cloud voice can say "mm-hmm" naturally; the iPhone voice spells such sounds out.
    private static let cloudAcknowledgements = ["Mm-hmm.", "Okay.", "Got it.", "Sure."]
    private static let systemAcknowledgements = ["Okay.", "Got it.", "Sure.", "Alright.", "One sec."]

    /// Text ready to be spoken: with Gemini audio when it was generated, otherwise
    /// it's read by the iPhone voice.
    struct PreparedSpeech {
        let text: String
        fileprivate let audio: Data?
        fileprivate let interruptions: Int
    }

    /// False when only the basic iPhone voice is available, so the UI can suggest
    /// downloading an Enhanced or Premium voice in Settings.
    var hasNaturalVoice: Bool {
        cloudVoice != nil || (systemVoice?.quality ?? .default) != .default
    }

    init(useCloudVoice: Bool) {
        systemVoice = Self.bestSystemVoice()
        cloudVoice = useCloudVoice ? CloudVoice() : nil
        super.init()
        synthesizer.delegate = self
    }

    /// Generates the filler clips in the background. Call when the conversation opens.
    func prepareAcknowledgements() {
        guard let cloudVoice else { return }
        Task {
            for text in Self.cloudAcknowledgements {
                if let audio = try? await cloudVoice.audio(for: text) {
                    cachedAcknowledgements.append(audio)
                }
            }
        }
    }

    /// Generates the audio for `text` without playing it, so callers can overlap
    /// the wait with something else (like a filler).
    func prepare(_ text: String) async -> PreparedSpeech {
        let interruptions = interruptions
        let audio = try? await cloudVoice?.audio(for: text)
        return PreparedSpeech(text: text, audio: audio, interruptions: interruptions)
    }

    /// Plays prepared speech and returns when it's finished (or was stopped).
    /// Does nothing if the user interrupted after it was prepared.
    func play(_ speech: PreparedSpeech) async {
        guard speech.interruptions == interruptions else { return }
        halt()
        if let audio = speech.audio, await play(audio) { return }
        await speakWithSystemVoice(speech.text)
    }

    /// Speaks `text` and returns when it's finished (or was stopped).
    func speak(_ text: String) async {
        await play(await prepare(text))
    }

    /// A quick "mm-hmm" while the reply is on its way, with no network delay.
    func acknowledge() async {
        halt()
        if let audio = cachedAcknowledgements.randomElement(), await play(audio) { return }
        await speakWithSystemVoice(Self.systemAcknowledgements.randomElement()!)
    }

    /// Stops speaking because the user interrupted. Anything still being prepared won't play.
    func stop() {
        interruptions += 1
        halt()
    }

    // MARK: - Playback

    /// Stops whatever is playing, without discarding speech that's being prepared.
    private func halt() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        player?.stop()
        player = nil
        finish()
    }

    /// Plays WAV data. Returns false if it couldn't be played, so the caller can fall back.
    private func play(_ audio: Data) async -> Bool {
        guard let player = try? AVAudioPlayer(data: audio) else { return false }
        Self.activateAudioSession()
        player.delegate = self
        self.player = player
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            if !player.play() { finish() }
        }
        return true
    }

    private func speakWithSystemVoice(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = systemVoice
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            currentUtterance = ObjectIdentifier(utterance)
            synthesizer.speak(utterance)
        }
    }

    /// Resumes the waiting `speak` call. Pass the utterance that ended, or nil to end whatever is current.
    private func finish(_ utterance: ObjectIdentifier? = nil) {
        guard utterance == nil || utterance == currentUtterance else { return }
        currentUtterance = nil
        continuation?.resume()
        continuation = nil
    }

    /// Plays through the speaker even when the ring/silent switch is on, matching the recognizer's setup.
    private static func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
        try? session.setActive(true)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            if let current = self.player, ObjectIdentifier(current) == id {
                self.player = nil
                self.finish()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finish(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finish(id) }
    }

    /// Picks a Premium or Enhanced voice for the user's language if one is downloaded,
    /// otherwise the system's standard voice.
    ///
    /// Only Apple's modern voices (`com.apple.voice.*`, like Ava, Susan or Nathan) are
    /// considered. Quality ratings alone aren't enough: old Mac voices such as Agnes
    /// and Alex are rated "enhanced" but sound robotic, as do the Eloquence voices
    /// (Shelley, Flo, …). Siri voices aren't available to apps at all.
    private static func bestSystemVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let natural = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == language
                && $0.identifier.hasPrefix("com.apple.voice.")
                && $0.quality != .default
        }
        return natural.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
    }
}
