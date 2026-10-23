import Foundation
import FirebaseFirestore

/// A food item inside a fridge.
/// Stored at `users/{uid}/fridges/{fridgeID}/items/{itemID}`.
struct FoodItem: Identifiable, Codable, Hashable {
    @DocumentID var id: String?
    var name: String
    /// Start of the day the item expires on.
    var expirationDate: Date
    var addedAt: Date = .now

    enum Freshness {
        case expired, expiringSoon, fresh
    }

    /// Number of calendar days until expiration. Negative once expired, 0 on the day itself.
    func daysUntilExpiration(from now: Date = .now) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let expiry = calendar.startOfDay(for: expirationDate)
        return calendar.dateComponents([.day], from: today, to: expiry).day ?? 0
    }

    func freshness(from now: Date = .now) -> Freshness {
        let days = daysUntilExpiration(from: now)
        if days < 0 { return .expired }
        if days <= 3 { return .expiringSoon }
        return .fresh
    }
}
