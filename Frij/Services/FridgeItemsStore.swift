import Foundation
import FirebaseFirestore

/// Live list of the food items in one fridge, soonest expiration first.
@MainActor
@Observable
final class FridgeItemsStore {
    private(set) var items: [FoodItem] = []
    private(set) var hasLoaded = false
    private(set) var lastError: Error?
    /// Set when the server rejects a write (Firestore then undoes it locally). Clear it to dismiss.
    var writeError: String?

    private let itemsRef: CollectionReference
    private var listener: ListenerRegistration?

    init(itemsRef: CollectionReference) {
        self.itemsRef = itemsRef
    }

    func startListening() {
        guard listener == nil else { return }
        listener = itemsRef
            .order(by: "expirationDate")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.lastError = error
                        return
                    }
                    self.items = snapshot?.documents.compactMap { try? $0.data(as: FoodItem.self) } ?? []
                    self.hasLoaded = true
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
    }

    /// Returns the new item's document ID, or nil if the name was blank.
    @discardableResult
    func add(name: String, expirationDate: Date) throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = FoodItem(
            name: trimmed,
            expirationDate: Calendar.current.startOfDay(for: expirationDate)
        )
        return try itemsRef.addDocument(from: item, completion: reportWriteResult).documentID
    }

    func update(_ item: FoodItem) throws {
        guard let id = item.id else { return }
        var updated = item
        updated.expirationDate = Calendar.current.startOfDay(for: item.expirationDate)
        try itemsRef.document(id).setData(from: updated, completion: reportWriteResult)
    }

    func delete(_ item: FoodItem) {
        guard let id = item.id else { return }
        deleteItem(withID: id)
    }

    func deleteItem(withID id: String) {
        itemsRef.document(id).delete(completion: reportWriteResult)
    }

    /// Completion handler for writes. Only called once the server responds,
    /// so offline writes aren't reported as failures.
    private var reportWriteResult: @Sendable (Error?) -> Void {
        { [weak self] error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in
                self?.writeError = message
            }
        }
    }
}
