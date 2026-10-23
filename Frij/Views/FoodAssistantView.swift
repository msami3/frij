import SwiftUI
import AVFoundation

/// Hands-free conversation for adding food: listen → model → speak → listen again.
struct FoodAssistantView: View {
    let fridgeName: String
    let itemsStore: FridgeItemsStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ConversationView(fridgeName: fridgeName, itemsStore: itemsStore)
            .navigationTitle("Add by Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ConversationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var assistant: FoodAssistant
    @State private var recognizer = SpeechRecognizer()
    @State private var speaker: Speaker
    @State private var isSpeaking = false
    @State private var isClosed = false
    @State private var hasMicAccess = true
    @State private var micError: String?
    @State private var typedText = ""

    init(fridgeName: String, itemsStore: FridgeItemsStore) {
        let assistant = FoodAssistant(fridgeName: fridgeName, itemsStore: itemsStore)
        _assistant = State(initialValue: assistant)
        // Gemini's voice only for Gemini conversations, so on-device ones stay on the device.
        _speaker = State(initialValue: Speaker(useCloudVoice: CloudVoice.isEnabled && !assistant.isOnDevice))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(assistant.messages) { message in
                            MessageRow(message: message) { assistant.undo(message) }
                                .id(message.id)
                        }
                        if assistant.isThinking {
                            HStack {
                                ProgressView()
                                Spacer()
                            }
                            .id("thinking")
                        }
                    }
                    .padding()
                }
                .onChange(of: assistant.messages.count) {
                    withAnimation { proxy.scrollTo(assistant.messages.last?.id, anchor: .bottom) }
                }
            }

            Divider()
            controls
                .padding()

            Label(
                assistant.isOnDevice ? "Processed on this iPhone" : "Processed by Google Gemini",
                systemImage: assistant.isOnDevice ? "lock.iphone" : "cloud"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.bottom, speaker.hasNaturalVoice ? 8 : 4)

            if !speaker.hasNaturalVoice {
                // Apps can't download voices themselves, so point the user to Settings.
                Text("For a more natural voice, download an Enhanced or Premium voice in Settings › Accessibility › Spoken Content › Voices.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .task { await begin() }
        .onDisappear(perform: close)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if let message = micError ?? recognizer.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if !hasMicAccess {
                Text("Allow microphone and speech recognition in Settings to talk, or type below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(recognizer.isListening ? .primary : .secondary)
                    .lineLimit(2)
                    .frame(minHeight: 44)
            }

            if hasMicAccess {
                Button(action: micTapped) {
                    Image(systemName: recognizer.isListening ? "stop.fill" : "mic.fill")
                        .font(.title)
                        .frame(width: 72, height: 72)
                        .foregroundStyle(.white)
                        .background(recognizer.isListening ? Color.red : Color.accentColor, in: Circle())
                        .symbolEffect(.pulse, isActive: recognizer.isListening)
                }
                .disabled(assistant.isThinking)
                .accessibilityLabel(recognizer.isListening ? "Stop listening" : "Talk")
            }

            HStack {
                TextField("Or type here", text: $typedText)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit(sendTyped)
                Button("Send", systemImage: "arrow.up.circle.fill", action: sendTyped)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(typedText.trimmingCharacters(in: .whitespaces).isEmpty || assistant.isThinking)
            }
        }
    }

    private var statusText: String {
        if recognizer.isListening {
            return recognizer.transcript.isEmpty ? "Listening…" : recognizer.transcript
        }
        if assistant.isThinking { return "Thinking…" }
        if isSpeaking { return "" }
        return "Tap the mic to talk"
    }

    // MARK: - Conversation loop

    private func begin() async {
        assistant.start()
        speaker.prepareAcknowledgements()
        recognizer.onUtterance = { text in
            Task { await handle(text) }
        }
        hasMicAccess = await SpeechRecognizer.requestPermissions()
        await say(assistant.greeting)
        listen()
    }

    private func handle(_ text: String) async {
        // A person says "mm-hmm" instead of going silent while they think. Only fill
        // the gap when the reply is slow: the model saving an item, or Gemini's
        // voice generating the audio.
        let acknowledgement = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, !isClosed else { return }
            isSpeaking = true
            await speaker.acknowledge()
            isSpeaking = false
        }

        guard let reply = await assistant.send(text) else {
            // The user said they're done: close and go back to the fridge.
            acknowledgement.cancel()
            close()
            dismiss()
            return
        }
        let speech = await speaker.prepare(reply)
        acknowledgement.cancel()
        // If it already started, let it finish rather than cutting it off mid-word.
        await acknowledgement.value

        await say(speech)
        // Keep the conversation going hands-free. The recognizer stops by itself
        // if the user doesn't say anything.
        listen()
    }

    private func say(_ text: String) async {
        await say(await speaker.prepare(text))
    }

    private func say(_ speech: Speaker.PreparedSpeech) async {
        guard !isClosed else { return }
        isSpeaking = true
        await speaker.play(speech)
        isSpeaking = false
    }

    private func listen() {
        guard !isClosed, hasMicAccess, !recognizer.isListening else { return }
        do {
            micError = nil
            try recognizer.start()
        } catch {
            micError = "Couldn't start the microphone: \(error.localizedDescription)"
        }
    }

    private func micTapped() {
        if recognizer.isListening {
            recognizer.finish()
        } else {
            speaker.stop()
            listen()
        }
    }

    private func sendTyped() {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !assistant.isThinking else { return }
        typedText = ""
        recognizer.cancel()
        speaker.stop()
        Task { await handle(text) }
    }

    private func close() {
        isClosed = true
        recognizer.cancel()
        speaker.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private struct MessageRow: View {
    let message: FoodAssistant.Message
    let undo: () -> Void

    var body: some View {
        switch message.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
            }
        case .assistant(let text):
            HStack {
                Text(text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Spacer(minLength: 48)
            }
        case let .added(name, date, itemID):
            HStack(spacing: 12) {
                Image(systemName: itemID == nil ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(itemID == nil ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                        .strikethrough(itemID == nil)
                    Text(itemID == nil ? "Removed" : "Expires \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if itemID != nil {
                    Button("Undo", action: undo)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        case let .edited(name, date):
            HStack(spacing: 12) {
                Image(systemName: "pencil.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                    Text("Updated · expires \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
