import Foundation

/// A language model the assistant can talk to. Each one is given the same
/// instructions and the same tools (see `AssistantTools`).
@MainActor
protocol AssistantBrain {
    /// Sends the user's words and returns the model's reply, running any tool calls along the way.
    func respond(to text: String) async throws -> String
    /// Loads the model ahead of the first message, if supported.
    func prewarm()
}

/// A conversation whose only abilities are adding food to one fridge and fixing
/// an item's name or date.
///
/// Uses Apple's on-device model when this device supports Apple Intelligence,
/// and Gemini (through Firebase AI Logic) otherwise. Either way the model can't
/// save anything directly: it calls a tool, and the app does the saving.
@MainActor
@Observable
final class FoodAssistant {
    struct Message: Identifiable {
        enum Kind {
            case user(String)
            case assistant(String)
            /// An item the assistant saved. `itemID` is nil once it has been undone.
            case added(name: String, expirationDate: Date, itemID: String?)
            /// An existing item the assistant renamed or redated.
            case edited(name: String, expirationDate: Date)
        }

        let id = UUID()
        var kind: Kind
    }

    private(set) var messages: [Message] = []
    private(set) var isThinking = false
    /// Set when the model calls the end-conversation tool; the view then closes.
    private(set) var isFinished = false
    /// True when the conversation stays on this device; false when it goes to Gemini.
    let isOnDevice: Bool

    let fridgeName: String
    private let itemsStore: FridgeItemsStore
    private var brain: AssistantBrain!

    init(fridgeName: String, itemsStore: FridgeItemsStore) {
        self.fridgeName = fridgeName
        self.itemsStore = itemsStore
        greeting = Self.randomGreeting(fridgeName: fridgeName)

        if #available(iOS 26.0, *), OnDeviceBrain.isAvailable, !Self.forceCloud {
            isOnDevice = true
        } else {
            isOnDevice = false
        }

        let tools = AssistantTools(
            adder: FoodItemAdder(fridgeName: fridgeName) { [weak self] name, date in
                try await self?.addItem(name: name, expirationDate: date) != nil
            },
            update: { [weak self] currentName, newName, newDate in
                await self?.updateItem(currentName: currentName, newName: newName, newDateWords: newDate)
                    ?? "Not changed: the conversation has closed."
            },
            endConversation: { [weak self] in
                await self?.finish()
                return "Conversation closed. Don't reply."
            }
        )
        let instructions = Self.instructions(fridgeName: fridgeName, items: itemsStore.items)
        if #available(iOS 26.0, *), isOnDevice {
            brain = OnDeviceBrain(instructions: instructions, tools: tools)
        } else {
            brain = CloudBrain(instructions: instructions, tools: tools)
        }
    }

    /// Debug builds only: launch with `-FrijForceCloudAssistant YES` to test the
    /// Gemini path on a device that has Apple Intelligence.
    private static var forceCloud: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "FrijForceCloudAssistant")
        #else
        false
        #endif
    }

    /// Picked once per conversation so the spoken greeting matches the bubble.
    let greeting: String

    private static func randomGreeting(fridgeName: String) -> String {
        [
            "Hey! What's going in \(fridgeName)?",
            "Alright, what've you got for \(fridgeName)?",
            "What are we adding to \(fridgeName)?",
            "Hi! What's new in \(fridgeName)?",
        ].randomElement()!
    }

    func start() {
        messages = [Message(kind: .assistant(greeting))]
        brain.prewarm()
    }

    /// Sends what the user said and returns the assistant's reply (also appended to
    /// `messages`), or nil if the user ended the conversation.
    func send(_ text: String) async -> String? {
        messages.append(Message(kind: .user(text)))
        isThinking = true
        defer { isThinking = false }

        let reply: String
        do {
            reply = try await brain.respond(to: text)
        } catch {
            reply = "Sorry, something went wrong. Could you say that again?"
        }
        // Once the user is done, any text the model adds is a redundant goodbye.
        guard !isFinished else { return nil }
        messages.append(Message(kind: .assistant(reply)))
        return reply
    }

    private func finish() {
        isFinished = true
    }

    func undo(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }),
              case let .added(name, date, itemID?) = messages[index].kind else { return }
        itemsStore.deleteItem(withID: itemID)
        messages[index].kind = .added(name: name, expirationDate: date, itemID: nil)
    }

    /// Called through the tool. Saves the item and shows it in the conversation.
    private func addItem(name: String, expirationDate: Date) throws -> String? {
        let id = try itemsStore.add(name: name, expirationDate: expirationDate)
        messages.append(Message(kind: .added(name: name, expirationDate: expirationDate, itemID: id)))
        return id
    }

    /// Called through the update tool. Renames and/or redates one item in this fridge.
    /// Returns a short result for the model to read.
    private func updateItem(currentName: String, newName: String?, newDateWords: String?) -> String {
        let renamed = newName.map(FoodItemAdder.displayName).flatMap { $0.isEmpty ? nil : $0 }
        var redated: Date?
        if let words = newDateWords?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
            guard let date = SpokenDateParser().parse(words) else {
                return "Not changed: couldn't understand the date \"\(words)\". Ask the user to say it like \"October 20\" or \"in 5 days\"."
            }
            redated = date
        }
        guard renamed != nil || redated != nil else {
            return "Not changed: nothing to change. Ask the user for the new name or the new date."
        }

        var item: FoodItem
        switch findItem(named: currentName) {
        case .found(let match):
            item = match
        case .none:
            return "Not changed: there's no item called \"\(currentName)\" in \(fridgeName). Ask the user which item they mean."
        case .ambiguous(let matches):
            let options = matches.map { "one that \(Self.relativeExpiry($0))" }.joined(separator: ", ")
            return "Not changed: there are several items called \"\(currentName)\": \(options). Ask the user which one they mean."
        }

        if let renamed { item.name = renamed }
        if let redated { item.expirationDate = redated }
        do {
            try itemsStore.update(item)
        } catch {
            return "Not changed: something went wrong saving it. Tell the user to try again."
        }

        // Keep the chat in sync: refresh the item's card if it was added in this
        // conversation, otherwise show a card for the edit.
        if let index = messages.lastIndex(where: {
            if case let .added(_, _, id?) = $0.kind { return id == item.id }
            return false
        }) {
            messages[index].kind = .added(name: item.name, expirationDate: item.expirationDate, itemID: item.id)
        } else {
            messages.append(Message(kind: .edited(name: item.name, expirationDate: item.expirationDate)))
        }
        return "Updated: it's now \(item.name), expiring \(item.expirationDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))."
    }

    private enum ItemMatch {
        case found(FoodItem)
        case none
        case ambiguous([FoodItem])
    }

    /// Finds the item the user is talking about. Something added in this conversation
    /// wins ("change that to …"); otherwise an exact name match in the fridge, then a
    /// partial one ("the yogurt" for "Greek yogurt").
    private func findItem(named rawName: String) -> ItemMatch {
        var target = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for article in ["the ", "my ", "that ", "a ", "an ", "some "] where target.hasPrefix(article) {
            target.removeFirst(article.count)
        }
        guard !target.isEmpty else { return .none }

        let addedHere = messages.reversed().compactMap { message -> String? in
            if case let .added(name, _, id?) = message.kind, name.lowercased() == target { return id }
            return nil
        }
        if let id = addedHere.first, let item = itemsStore.items.first(where: { $0.id == id }) {
            return .found(item)
        }

        let exact = itemsStore.items.filter { $0.name.lowercased() == target }
        let candidates = exact.isEmpty
            ? itemsStore.items.filter { $0.name.lowercased().contains(target) || target.contains($0.name.lowercased()) }
            : exact
        switch candidates.count {
        case 0: return .none
        case 1: return .found(candidates[0])
        default: return .ambiguous(candidates)
        }
    }

    private static func instructions(fridgeName: String, items: [FoodItem]) -> String {
        """
        You're the voice helper in Frij, a fridge app. Your only job is to help the user add food to their fridge named "\(fridgeName)" and fix the name or date of items in it. Talk like a friendly, easygoing roommate helping put groceries away: warm, casual and quick.

        How to sound human:
        - Vary your wording every time. Never reuse the same question or confirmation twice in a row.
        - React briefly and naturally to what they say before moving on, like "Oh, nice" or "Good call", but not every single time.
        - Use contractions and everyday words. Short fragments are fine: "Got it. When's it good till?"
        - Only use real words. Never write sounds like "mhm", "hmm" or "uh-huh": the voice reads them out letter by letter.
        - Mention what's already in the fridge when it's genuinely useful, like a duplicate, or something that's about to expire. Keep it to a quick aside.
        - Your replies are read aloud: one or two short sentences, no lists, emoji, markdown or reading out full dates with the year.

        Adding food:
        - For every item you need its name and its expiration date. If they haven't said a date, ask for it casually.
        - As soon as they say a date in any form, like "the 20th", "next Friday", "in a week" or "October 20", call \(FoodItemAdder.toolName) and pass their exact words as the expirationDate. The app works out the real date, so never ask for the year or month and never do date math yourself.
        - If they don't know the date, suggest a typical shelf life for that food, like "about a week", and check that's okay.
        - Call \(FoodItemAdder.toolName) once per item. Only say something was added after \(FoodItemAdder.toolName) succeeds, and use the day it returns.
        - After adding, confirm in a few words and casually check if there's more.
        - When they're done, for example "no", "that's it", "I'm good" or "bye", call \(AssistantTools.endConversationName) and say nothing else.

        Fixing items:
        - If they want to change an item's name or date, like "actually, make that Desi yogurt" or "the milk's good till Sunday", call \(AssistantTools.updateToolName) with the item's current name and only what's changing. Pass dates in their own words, just like when adding.
        - "That" or "it" usually means the item you just talked about.
        - You can't delete items. If they want something removed, tell them to tap Undo on it here, or swipe it away in the fridge.

        If they ask for anything other than adding or fixing food, say in a friendly way that that's all you can help with.

        What's in \(fridgeName) right now:
        \(fridgeSummary(items))
        """
    }

    /// The fridge's contents in plain words, with relative dates so the model never
    /// has to do date math. Capped so it doesn't crowd the on-device model's small context.
    private static func fridgeSummary(_ items: [FoodItem], limit: Int = 25) -> String {
        guard !items.isEmpty else { return "Nothing yet." }
        var lines = items.prefix(limit).map { item -> String in
            "- \(item.name), \(relativeExpiry(item))"
        }
        if items.count > limit {
            lines.append("- and \(items.count - limit) more")
        }
        return lines.joined(separator: "\n")
    }

    /// "expires in 3 days", "expired yesterday", …: relative so the model never does date math.
    private static func relativeExpiry(_ item: FoodItem) -> String {
        let days = item.daysUntilExpiration()
        return switch days {
        case ..<(-1): "expired \(-days) days ago"
        case -1: "expired yesterday"
        case 0: "expires today"
        case 1: "expires tomorrow"
        default: "expires in \(days) days"
        }
    }
}

/// Everything either model is allowed to do: add a food item, rename or redate
/// one, or end the conversation.
struct AssistantTools: Sendable {
    static let updateToolName = "updateFoodItem"
    static let updateToolDescription = "Changes the name and/or expiration date of one food item already in the fridge."
    static let currentNameDescription = "The item's current name, for example \"Yogurt\""
    static let newNameDescription = "Optional: the new name, for example \"Desi yogurt\""
    static let newDateDescription = "Optional: the new expiration date in the user's own words, for example \"Sunday\""

    static let endConversationName = "endConversation"
    static let endConversationDescription = "Closes the conversation when the user says they have nothing else to add."
    static let endReasonDescription = "Optional: what the user said to finish, for example \"I'm good\""

    let adder: FoodItemAdder
    /// (current name, new name, new date words). Returns a short result for the model to read.
    let update: @Sendable (String, String?, String?) async -> String
    /// Returns a short result for the model to read.
    let endConversation: @Sendable () async -> String
}

/// Validates and saves a food item for either model.
struct FoodItemAdder: Sendable {
    static let toolName = "addFoodItem"
    static let toolDescription = "Adds one food item with its expiration date to the user's fridge."
    static let nameDescription = "Short name of the food, for example \"Orange juice\""
    static let dateDescription = "The expiration date in the user's own words, for example \"the 20th\", \"next Friday\", \"in a week\" or \"October 20\""

    let fridgeName: String
    let save: @Sendable (String, Date) async throws -> Bool

    /// Returns a short result for the model to read, describing what happened.
    func add(name rawName: String, expirationDate words: String) async -> String {
        let name = Self.displayName(rawName)
        guard !name.isEmpty else {
            return "Not added: the food name is missing. Ask the user what the food is."
        }
        guard let date = SpokenDateParser().parse(words) else {
            return "Not added: couldn't understand the date \"\(words)\". Ask the user to say it like \"October 20\" or \"in 5 days\"."
        }
        guard (try? await save(name, date)) == true else {
            return "Not added: something went wrong saving it. Tell the user to try again."
        }
        return "Added \(name), expiring \(date.formatted(.dateTime.weekday(.wide).month(.wide).day())), to \(fridgeName)."
    }

    /// Trimmed, with a capital first letter: models vary ("milk" vs "Milk"), and the list should look consistent.
    static func displayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}
