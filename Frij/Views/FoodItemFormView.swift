import SwiftUI

/// Adds a new food item, or edits an existing one when `item` is non-nil.
struct FoodItemFormView: View {
    let itemsStore: FridgeItemsStore
    let item: FoodItem?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var expirationDate: Date
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    init(itemsStore: FridgeItemsStore, item: FoodItem?) {
        self.itemsStore = itemsStore
        self.item = item
        _name = State(initialValue: item?.name ?? "")
        _expirationDate = State(initialValue: item?.expirationDate ?? Self.date(addingDays: 7))
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Food name, e.g. Milk", text: $name)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                }

                Section {
                    DatePicker("Expires", selection: $expirationDate, displayedComponents: .date)
                    HStack {
                        quickPick("3 days", days: 3)
                        quickPick("1 week", days: 7)
                        quickPick("2 weeks", days: 14)
                        quickPick("1 month", days: 30)
                    }
                } header: {
                    Text("Expiration date")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(item == nil ? "Add Food" : "Edit Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear {
                if item == nil { isNameFocused = true }
            }
        }
    }

    private func quickPick(_ title: String, days: Int) -> some View {
        Button(title) {
            expirationDate = Self.date(addingDays: days)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    private func save() {
        do {
            if var item {
                item.name = trimmedName
                item.expirationDate = expirationDate
                try itemsStore.update(item)
            } else {
                try itemsStore.add(name: trimmedName, expirationDate: expirationDate)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func date(addingDays days: Int) -> Date {
        let today = Calendar.current.startOfDay(for: .now)
        return Calendar.current.date(byAdding: .day, value: days, to: today) ?? today
    }
}
