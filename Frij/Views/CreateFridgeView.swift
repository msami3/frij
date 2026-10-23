import SwiftUI

/// Names a new fridge. Shown full-screen right after first sign-in (`isOnboarding`),
/// and as a sheet when adding another fridge later.
struct CreateFridgeView: View {
    let isOnboarding: Bool

    @Environment(FridgeStore.self) private var store
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 24) {
            if isOnboarding {
                Spacer()
                Image(systemName: "refrigerator")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                VStack(spacing: 8) {
                    Text("Add your fridge")
                        .font(.title.bold())
                    Text("Give it a name so you can tell it apart, like \"Kitchen\" or \"Garage freezer\".")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            TextField("Fridge name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .submitLabel(.done)
                .focused($isNameFocused)
                .onSubmit(create)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button(action: create) {
                Text("Create Fridge")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(trimmedName.isEmpty)

            Spacer()
        }
        .padding(24)
        .navigationTitle(isOnboarding ? "" : "New Fridge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isOnboarding {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign Out") { try? auth.signOut() }
                }
            } else {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { isNameFocused = true }
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        do {
            try store.addFridge(named: trimmedName)
            if !isOnboarding { dismiss() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
