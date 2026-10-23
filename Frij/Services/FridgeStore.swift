import Foundation
import FirebaseFirestore

/// Live list of the user's fridges, backed by Firestore.
///
/// Writes go through Firestore's local cache first, so they show up immediately
/// (and work offline) without waiting for the server to acknowledge them.
@MainActor
@Observable
final class FridgeStore {
    private(set) var fridges: [Fridge] = []
    /// False until the first snapshot arrives, so the UI can tell "loading" from "no fridges".
    private(set) var hasLoaded = false
    private(set) var lastError: Error?
    /// Set when the server rejects a write. Firestore undoes rejected writes locally,
    /// so the UI shows this to explain why a change disappeared. Clear it to dismiss.
    var writeError: String?

    let userID: String
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    init(userID: String) {
        self.userID = userID
    }

    private var fridgesRef: CollectionReference {
        db.collection("users").document(userID).collection("fridges")
    }

    func itemsRef(for fridge: Fridge) -> CollectionReference? {
        guard let id = fridge.id else { return nil }
        return fridgesRef.document(id).collection("items")
    }

    func startListening() {
        guard listener == nil else { return }
        listener = fridgesRef
            .order(by: "createdAt")
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.lastError = error
                        return
                    }
                    self.fridges = snapshot?.documents.compactMap { try? $0.data(as: Fridge.self) } ?? []
                    self.hasLoaded = true
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
    }

    func addFridge(named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try fridgesRef.addDocument(from: Fridge(name: trimmed), completion: reportWriteResult)
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

    func rename(_ fridge: Fridge, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = fridge.id, !trimmed.isEmpty else { return }
        fridgesRef.document(id).updateData(["name": trimmed], completion: reportWriteResult)
    }

    /// Deletes the fridge and every item in it. Firestore doesn't cascade deletes
    /// to subcollections, so the items are removed explicitly.
    func delete(_ fridge: Fridge) async throws {
        guard let id = fridge.id, let itemsRef = itemsRef(for: fridge) else { return }
        let items = try await itemsRef.getDocuments()
        let batch = db.batch()
        for doc in items.documents {
            batch.deleteDocument(doc.reference)
        }
        batch.deleteDocument(fridgesRef.document(id))
        try await batch.commit()
    }
}
