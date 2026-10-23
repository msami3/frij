import Foundation
import FirebaseAILogic

/// Gemini's text-to-speech through Firebase AI Logic: a far more natural voice than
/// the ones built into iOS. Used only for cloud (Gemini) conversations, so on-device
/// conversations stay on the device.
///
/// The model is a Public Preview: it can change, and Google notes it occasionally
/// fails, so `Speaker` falls back to the iPhone's own voice on any error.
@MainActor
final class CloudVoice {
    /// Off for now: on the free tier this preview model allows only 3 requests per
    /// minute (a conversation needs more), and each reply took 2–3.5 s to generate.
    /// Turn on once billing is enabled or the model's limits loosen, ideally with
    /// streaming playback to cut the delay.
    static let isEnabled = false

    static let modelName = "gemini-3.1-flash-tts-preview"
    /// Google describes Achird as "friendly". Other options are listed at
    /// https://firebase.google.com/docs/ai-logic/generate-speech
    static let voiceName = "Achird"

    private let model: GenerativeModel

    init() {
        model = FirebaseAI.firebaseAI(backend: .googleAI()).generativeModel(
            modelName: Self.modelName,
            generationConfig: GenerationConfig(
                responseModalities: [.audio],
                speechConfig: SpeechConfig(voiceName: Self.voiceName)
            ),
            // Someone is waiting to hear this; after a few seconds the iPhone voice is better than silence.
            requestOptions: RequestOptions(timeout: 6)
        )
    }

    /// Returns `text` spoken aloud, as WAV data ready for `AVAudioPlayer`.
    func audio(for text: String) async throws -> Data {
        let response = try await model.generateContent(Self.prompt(for: text))
        guard let part = response.inlineDataParts.first, !part.data.isEmpty else {
            throw CloudVoiceError.noAudio
        }
        return Self.wav(fromPCM: part.data, sampleRate: Self.sampleRate(from: part.mimeType))
    }

    enum CloudVoiceError: Error {
        case noAudio
    }

    #if DEBUG
    /// Launch with `-FrijTestCloudVoice YES` to log how long generation takes and how
    /// long the audio is. A clip far longer than its text means the style notes were read aloud.
    static func runSelfTestIfRequested() {
        guard UserDefaults.standard.bool(forKey: "FrijTestCloudVoice") else { return }
        Task { @MainActor in
            let voice = CloudVoice()
            for text in ["Mm-hmm.", "Got it, milk till Friday. Anything else?"] {
                let start = Date.now
                do {
                    let wav = try await voice.audio(for: text)
                    let seconds = Double(wav.count - 44) / 48_000 // 24 kHz × 2 bytes, minus the WAV header
                    NSLog("%@", "[CloudVoice] \"\(text)\": generated in \(String(format: "%.2f", Date.now.timeIntervalSince(start)))s, audio \(String(format: "%.1f", seconds))s")
                } catch {
                    NSLog("%@", "[CloudVoice] \"\(text)\" failed: \(error)")
                }
            }
            // Streaming: how soon does the first audio arrive?
            let text = "Got it, milk till Friday. Anything else?"
            let start = Date.now
            var first: TimeInterval?
            var chunks = 0
            do {
                for try await response in try voice.model.generateContentStream(prompt(for: text)) {
                    if !response.inlineDataParts.isEmpty {
                        chunks += 1
                        if first == nil { first = Date.now.timeIntervalSince(start) }
                    }
                }
                NSLog("%@", "[CloudVoice] streaming: first audio after \(String(format: "%.2f", first ?? -1))s, \(chunks) chunks, done in \(String(format: "%.2f", Date.now.timeIntervalSince(start)))s")
            } catch {
                NSLog("%@", "[CloudVoice] streaming failed: \(error)")
            }
        }
    }
    #endif

    /// Style direction in the structure Google recommends, so the notes steer the
    /// delivery instead of being read out.
    private static func prompt(for text: String) -> String {
        """
        # AUDIO PROFILE: A friendly, easygoing roommate
        ## THE SCENE: Helping put groceries away in the kitchen.
        ### DIRECTOR'S NOTES
        Style: warm, relaxed and upbeat. Pace: natural and conversational.
        #### TRANSCRIPT
        \(text)
        """
    }

    /// Gemini returns raw 16-bit mono PCM, usually at 24 kHz ("audio/L16;codec=pcm;rate=24000").
    private static func sampleRate(from mimeType: String) -> Int {
        guard let match = mimeType.firstMatch(of: #/rate=(\d+)/#), let rate = Int(match.1) else { return 24_000 }
        return rate
    }

    /// Wraps raw PCM in a WAV header so `AVAudioPlayer` can play it.
    private static func wav(fromPCM pcm: Data, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        let bytesPerFrame = channels * bitsPerSample / 8
        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                       // fmt chunk size
        append(UInt16(1))                        // PCM
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * bytesPerFrame)) // byte rate
        append(UInt16(bytesPerFrame))            // block align
        append(UInt16(bitsPerSample))
        wav.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}
