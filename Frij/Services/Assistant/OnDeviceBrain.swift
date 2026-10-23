import Foundation
import FoundationModels

/// Apple's on-device model (Apple Intelligence). Free, private, and works offline,
/// but only on iPhone 15 Pro and newer with Apple Intelligence turned on.
@available(iOS 26.0, *)
@MainActor
final class OnDeviceBrain: AssistantBrain {
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    private let instructions: String
    private let tools: AssistantTools
    private var session: LanguageModelSession

    init(instructions: String, tools: AssistantTools) {
        self.instructions = instructions
        self.tools = tools
        session = Self.makeSession(instructions: instructions, tools: tools)
    }

    func prewarm() {
        session.prewarm()
    }

    func respond(to text: String) async throws -> String {
        do {
            return try await session.respond(to: text).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // The on-device model has a small context window. Long sessions start
            // fresh; items already added are saved, so nothing is lost.
            session = Self.makeSession(instructions: instructions, tools: tools)
            return try await session.respond(to: text).content
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            return "Sorry, I can only help add food. What are you adding?"
        }
    }

    private static func makeSession(instructions: String, tools: AssistantTools) -> LanguageModelSession {
        LanguageModelSession(
            tools: [
                AddFoodItemTool(adder: tools.adder),
                UpdateFoodItemTool(update: tools.update),
                EndConversationTool(end: tools.endConversation),
            ],
            instructions: instructions
        )
    }
}

@available(iOS 26.0, *)
private struct AddFoodItemTool: Tool {
    let name = FoodItemAdder.toolName
    let description = FoodItemAdder.toolDescription

    @Generable
    struct Arguments {
        @Guide(description: "Short name of the food, for example \"Orange juice\"")
        var name: String

        @Guide(description: "The expiration date in the user's own words, for example \"the 20th\", \"next Friday\", \"in a week\" or \"October 20\"")
        var expirationDate: String
    }

    let adder: FoodItemAdder

    func call(arguments: Arguments) async throws -> String {
        await adder.add(name: arguments.name, expirationDate: arguments.expirationDate)
    }
}

@available(iOS 26.0, *)
private struct UpdateFoodItemTool: Tool {
    let name = AssistantTools.updateToolName
    let description = AssistantTools.updateToolDescription

    @Generable
    struct Arguments {
        @Guide(description: "The item's current name, for example \"Yogurt\"")
        var currentName: String

        @Guide(description: "Optional: the new name, for example \"Desi yogurt\"")
        var newName: String?

        @Guide(description: "Optional: the new expiration date in the user's own words, for example \"Sunday\"")
        var newExpirationDate: String?
    }

    let update: @Sendable (String, String?, String?) async -> String

    func call(arguments: Arguments) async throws -> String {
        await update(arguments.currentName, arguments.newName, arguments.newExpirationDate)
    }
}

@available(iOS 26.0, *)
private struct EndConversationTool: Tool {
    let name = AssistantTools.endConversationName
    let description = AssistantTools.endConversationDescription

    @Generable
    struct Arguments {
        @Guide(description: "Optional: what the user said to finish, for example \"I'm good\"")
        var reason: String?
    }

    let end: @Sendable () async -> String

    func call(arguments: Arguments) async throws -> String {
        await end()
    }
}
