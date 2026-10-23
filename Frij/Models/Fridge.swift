import Foundation
import FirebaseFirestore

/// A named fridge belonging to the signed-in user.
/// Stored at `users/{uid}/fridges/{fridgeID}`.
struct Fridge: Identifiable, Codable, Hashable {
    @DocumentID var id: String?
    var name: String
    var createdAt: Date = .now
}
