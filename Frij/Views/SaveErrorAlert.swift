import SwiftUI

extension View {
    /// Shows an alert when the server rejects a save. Firestore undoes the change
    /// locally, so this explains why it disappeared.
    func saveErrorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Couldn't save",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(message.wrappedValue ?? "") Your change was undone.")
        }
    }
}
