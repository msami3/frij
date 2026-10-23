import SwiftUI

struct FridgeListView: View {
    @Environment(FridgeStore.self) private var store
    @Environment(AuthService.self) private var auth

    @State private var path: [Fridge] = []
    @State private var isAddingFridge = false
    @State private var fridgeToRename: Fridge?
    @State private var renameText = ""
    @State private var fridgeToDelete: Fridge?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.fridges) { fridge in
                    NavigationLink(value: fridge) {
                        Label(fridge.name, systemImage: "refrigerator")
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { startRename(fridge) }
                        Button("Delete", systemImage: "trash", role: .destructive) { fridgeToDelete = fridge }
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { fridgeToDelete = fridge }
                        Button("Rename", systemImage: "pencil") { startRename(fridge) }
                    }
                }
            }
            .navigationTitle("My Fridges")
            .navigationDestination(for: Fridge.self) { fridge in
                if let itemsRef = store.itemsRef(for: fridge) {
                    FridgeDetailView(fridge: fridge, itemsRef: itemsRef)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if let email = auth.user?.email {
                            Text(email)
                        }
                        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                            try? auth.signOut()
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Fridge", systemImage: "plus") { isAddingFridge = true }
                }
            }
            .sheet(isPresented: $isAddingFridge) {
                NavigationStack {
                    CreateFridgeView(isOnboarding: false)
                }
                .presentationDetents([.medium])
            }
            .alert("Rename Fridge", isPresented: isRenaming) {
                TextField("Fridge name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if let fridgeToRename { store.rename(fridgeToRename, to: renameText) }
                }
            }
            .confirmationDialog(
                "Delete \(fridgeToDelete?.name ?? "fridge")?",
                isPresented: isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Fridge and Its Food", role: .destructive) {
                    if let fridgeToDelete { delete(fridgeToDelete) }
                }
            } message: {
                Text("All food items in this fridge will be deleted too.")
            }
            .alert("Something went wrong", isPresented: isShowingError) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onAppear {
            // Most people have one fridge, so skip straight into it.
            if path.isEmpty, store.fridges.count == 1 {
                path = [store.fridges[0]]
            }
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { fridgeToRename != nil }, set: { if !$0 { fridgeToRename = nil } })
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { fridgeToDelete != nil }, set: { if !$0 { fridgeToDelete = nil } })
    }

    private var isShowingError: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func startRename(_ fridge: Fridge) {
        renameText = fridge.name
        fridgeToRename = fridge
    }

    private func delete(_ fridge: Fridge) {
        Task {
            do {
                try await store.delete(fridge)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
