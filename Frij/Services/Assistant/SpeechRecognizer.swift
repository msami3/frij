import Foundation
import AVFoundation
import Speech

/// Listens to the microphone and transcribes speech on device.
/// Stops by itself after a short pause once the user has said something,
/// then hands the transcript to `onUtterance`.
@MainActor
@Observable
final class SpeechRecognizer {
    private(set) var transcript = ""
    private(set) var isListening = false
    /// Set when recognition fails with nothing heard.
    private(set) var errorMessage: String?

    /// Called with the final transcript when the user stops talking.
    var onUtterance: ((String) -> Void)?

    /// How long a pause ends the user's turn.
    private let endOfSpeechPause: Duration = .seconds(1.2)
    /// Give up if nothing is said for this long.
    private let noSpeechTimeout: Duration = .seconds(8)

    private let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timeoutTask: Task<Void, Never>?
    /// On-device recognition is preferred, but its model can be missing or broken
    /// (it often is in the simulator). After one failure, Apple's server recognizer is used.
    private var useOnDeviceRecognition = true
    private var isUsingOnDeviceRecognition = false

    var isAvailable: Bool {
        recognizer?.isAvailable ?? false
    }

    static func requestPermissions() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        guard !isListening, let recognizer else { return }
        transcript = ""
        errorMessage = nil

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        isUsingOnDeviceRecognition = useOnDeviceRecognition && recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = isUsingOnDeviceRecognition
        self.request = request

        Self.installTap(on: audioEngine.inputNode, feeding: request)
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let errorDescription = error?.localizedDescription
            Task { @MainActor in
                self?.handle(text: text, errorDescription: errorDescription)
            }
        }

        isListening = true
        scheduleTimeout(after: noSpeechTimeout)
    }

    /// Stops listening without delivering a transcript.
    func cancel() {
        guard isListening else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
    }

    /// Ends the user's turn now and delivers whatever was heard.
    func finish() {
        guard isListening else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cancel()
        if !text.isEmpty {
            onUtterance?(text)
        }
    }

    private func handle(text: String?, errorDescription: String?) {
        guard isListening else { return }
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            scheduleTimeout(after: endOfSpeechPause)
        } else if let errorDescription {
            if transcript.isEmpty, isUsingOnDeviceRecognition {
                cancel()
                useOnDeviceRecognition = false
                do {
                    try start()
                } catch {
                    errorMessage = error.localizedDescription
                }
            } else if transcript.isEmpty {
                cancel()
                errorMessage = "Speech recognition failed: \(errorDescription)"
            } else {
                finish()
            }
        }
    }

    private func scheduleTimeout(after delay: Duration) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    /// The tap runs on the audio thread, so it's built outside the main actor.
    private nonisolated static func installTap(on input: AVAudioInputNode, feeding request: SFSpeechAudioBufferRecognitionRequest) {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }
}
