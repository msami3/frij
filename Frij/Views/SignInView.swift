import SwiftUI
import GoogleSignIn

struct SignInView: View {
    @Environment(AuthService.self) private var auth
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "refrigerator.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Frij")
                    .font(.largeTitle.bold())
                Text("Know what's in your fridge and eat it before it expires.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await signIn() }
            } label: {
                HStack {
                    if isSigningIn {
                        ProgressView()
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                    }
                    Text("Continue with Google")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSigningIn)
        }
        .padding(24)
    }

    private func signIn() async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            try await auth.signInWithGoogle()
        } catch let error as GIDSignInError where error.code == .canceled {
            // User cancelled the Google sheet; nothing to report.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
