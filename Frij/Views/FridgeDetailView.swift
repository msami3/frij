import SwiftUI
import FirebaseFirestore

/// The food in one fridge, grouped by how close it is to expiring.
struct FridgeDetailView: View {
    let fridge: Fridge

    @Environment(FridgeStore.self) private var store
    @State private var itemsStore: FridgeItemsStore
    @State private var isAddingItem = false
    @State private var isTalking = false
    @State private var itemToEdit: FoodItem?

    init(fridge: Fridge, itemsRef: CollectionReference) {
        self.fridge = fridge
        _itemsStore = State(initialValue: FridgeItemsStore(itemsRef: itemsRef))
    }

    /// Picks up renames made while this screen is open.
    private var title: String {
        store.fridges.first(where: { $0.id == fridge.id })?.name ?? fridge.name
    }

    var body: some View {
        content
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Food", systemImage: "plus") { isAddingItem = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add by Voice", systemImage: "mic") { isTalking = true }
                }
            }
            .sheet(isPresented: $isAddingItem) {
                FoodItemFormView(itemsStore: itemsStore, item: nil)
            }
            .sheet(isPresented: $isTalking) {
                FoodAssistantView(fridgeName: title, itemsStore: itemsStore)
            }
            .sheet(item: $itemToEdit) { item in
                FoodItemFormView(itemsStore: itemsStore, item: item)
            }
            .saveErrorAlert($itemsStore.writeError)
            .task { itemsStore.startListening() }
            .onDisappear { itemsStore.stopListening() }
    }

    @ViewBuilder
    private var content: some View {
        if !itemsStore.hasLoaded {
            ProgressView()
        } else if itemsStore.items.isEmpty {
            ContentUnavailableView {
                Label("Nothing in here yet", systemImage: "carrot")
            } description: {
                Text("Add food and its expiration date to keep track of what to eat first.")
            } actions: {
                Button("Add Food") { isAddingItem = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                section("Expired", freshness: .expired)
                section("Expiring Soon", freshness: .expiringSoon)
                section("Fresh", freshness: .fresh)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, freshness: FoodItem.Freshness) -> some View {
        let items = itemsStore.items.filter { $0.freshness() == freshness }
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    Button {
                        itemToEdit = item
                    } label: {
                        FoodItemRow(item: item)
                    }
                    .tint(.primary)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            itemsStore.delete(item)
                        }
                    }
                }
            }
        }
    }
}

private struct FoodItemRow: View {
    let item: FoodItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                Text("Expires \(item.expirationDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(relativeLabel)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(badgeColor.opacity(0.15), in: Capsule())
                .foregroundStyle(badgeColor)
        }
    }

    private var relativeLabel: String {
        let days = item.daysUntilExpiration()
        switch days {
        case ..<(-1): return "\(-days) days ago"
        case -1: return "Yesterday"
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return "\(days) days"
        }
    }

    private var badgeColor: Color {
        switch item.freshness() {
        case .expired: .red
        case .expiringSoon: .orange
        case .fresh: .green
        }
    }
}
