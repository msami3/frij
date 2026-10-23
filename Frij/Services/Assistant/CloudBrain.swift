import Foundation
import FirebaseAILogic

/// Gemini through Firebase AI Logic, for devices without Apple Intelligence.
/// No API key lives in the app: requests go through the Firebase project.
@MainActor
final class CloudBrain: AssistantBrain {
    /// Stable, fast Gemini model on the free tier: replies in under a second.
    /// `gemini-3.8-flash` took ~19 s per reply, too slow for voice. See
    /// https://firebase.google.com/docs/ai-logic/models before changing it.
    static let modelName = "gemini-3.5-flash-lite"

    /// Upper bound on tool-call round trips per user message, so a confused
    /// model can't loop forever.
    private static let maxToolRounds = 5

    private let tools: AssistantTools
    private let chat: Chat

    init(instructions: String, tools: AssistantTools) {
        self.tools = tools
        let addFoodItem = FunctionDeclaration(
            name: FoodItemAdder.toolName,
            description: FoodItemAdder.toolDescription,
            parameters: [
                "name": .string(description: FoodItemAdder.nameDescription),
                "expirationDate": .string(description: FoodItemAdder.dateDescription),
            ]
        )
        let updateFoodItem = FunctionDeclaration(
            name: AssistantTools.updateToolName,
            description: AssistantTools.updateToolDescription,
            parameters: [
                "currentName": .string(description: AssistantTools.currentNameDescription),
                "newName": .string(description: AssistantTools.newNameDescription),
                "newExpirationDate": .string(description: AssistantTools.newDateDescription),
            ],
            optionalParameters: ["newName", "newExpirationDate"]
        )
        // Gemini rejects function declarations with no properties, so `reason` is an optional placeholder.
        let endConversation = FunctionDeclaration(
            name: AssistantTools.endConversationName,
            description: AssistantTools.endConversationDescription,
            parameters: ["reason": .string(description: AssistantTools.endReasonDescription)],
            optionalParameters: ["reason"]
        )
        let model = FirebaseAI.firebaseAI(backend: .googleAI()).generativeModel(
            modelName: Self.modelName,
            tools: [.functionDeclarations([addFoodItem, updateFoodItem, endConversation])],
            systemInstruction: ModelContent(role: "system", parts: instructions),
            // Fail fast instead of the SDK's 180-second default: someone is waiting to hear a reply.
            requestOptions: RequestOptions(timeout: 30)
        )
        chat = model.startChat()
    }

    func prewarm() {}

    func respond(to text: String) async throws -> String {
        var response = try await chat.sendMessage(text)

        for _ in 0..<Self.maxToolRounds {
            let calls = response.functionCalls
            guard !calls.isEmpty else { break }

            var results: [FunctionResponsePart] = []
            var ended = false
            for call in calls {
                let result: String
                if call.name == FoodItemAdder.toolName,
                   case let .string(name)? = call.args["name"],
                   case let .string(date)? = call.args["expirationDate"] {
                    result = await tools.adder.add(name: name, expirationDate: date)
                } else if call.name == AssistantTools.updateToolName,
                          case let .string(currentName)? = call.args["currentName"] {
                    var newName: String?
                    if case let .string(value)? = call.args["newName"] { newName = value }
                    var newDate: String?
                    if case let .string(value)? = call.args["newExpirationDate"] { newDate = value }
                    result = await tools.update(currentName, newName, newDate)
                } else if call.name == AssistantTools.endConversationName {
                    result = await tools.endConversation()
                    ended = true
                } else {
                    result = "Unknown tool or missing arguments."
                }
                results.append(FunctionResponsePart(name: call.name, response: ["result": .string(result)]))
            }
            // The screen is closing, so don't wait for a reply nobody will hear.
            if ended { return "" }
            response = try await chat.sendMessage([ModelContent(role: "user", parts: results)])
        }

        let reply = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reply.isEmpty ? "Sorry, could you say that again?" : reply
    }
}
