import Foundation
import UIKit
import FirebaseAuth
import FirebaseCore
import GoogleSignIn

/// Owns the signed-in Firebase user and the Google sign-in flow.
@MainActor
@Observable
final class AuthService {
    private(set) var user: User?
    /// False until Firebase has reported the persisted session (if any) on launch.
    private(set) var hasResolvedSession = false

    private var listenerHandle: AuthStateDidChangeListenerHandle?

    init() {
        listenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
                self?.hasResolvedSession = true
            }
        }
    }

    func signInWithGoogle() async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw AuthError.missingClientID
        }
        guard let presenter = Self.topViewController() else {
            throw AuthError.noPresenter
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)

        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.missingIDToken
        }
        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
        try await Auth.auth().signIn(with: credential)
    }

    func signOut() throws {
        GIDSignIn.sharedInstance.signOut()
        try Auth.auth().signOut()
    }

    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    enum AuthError: LocalizedError {
        case missingClientID, noPresenter, missingIDToken

        var errorDescription: String? {
            switch self {
            case .missingClientID: "Firebase is missing a Google client ID. Check GoogleService-Info.plist."
            case .noPresenter: "Couldn't find a screen to show Google sign-in from."
            case .missingIDToken: "Google didn't return an ID token."
            }
        }
    }
}
