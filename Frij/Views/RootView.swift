import SwiftUI
import GoogleSignIn

/// Routes between signing in, creating a first fridge, and the main fridge list.
struct RootView: View {
    @State private var auth = AuthService()

    var body: some View {
        Group {
            if !auth.hasResolvedSession {
                ProgressView()
            } else if let user = auth.user {
                SignedInView(userID: user.uid)
                    .id(user.uid)
            } else {
                SignInView()
            }
        }
        .environment(auth)
        .onOpenURL { url in
            GIDSignIn.sharedInstance.handle(url)
        }
    }
}

private struct SignedInView: View {
    @State private var store: FridgeStore

    init(userID: String) {
        _store = State(initialValue: FridgeStore(userID: userID))
    }

    var body: some View {
        Group {
            if let error = store.lastError, !store.hasLoaded {
                ContentUnavailableView(
                    "Couldn't load your fridges",
                    systemImage: "wifi.exclamationmark",
                    description: Text(error.localizedDescription)
                )
            } else if !store.hasLoaded {
                ProgressView()
            } else if store.fridges.isEmpty {
                NavigationStack {
                    CreateFridgeView(isOnboarding: true)
                }
            } else {
                FridgeListView()
            }
        }
        .environment(store)
        .saveErrorAlert($store.writeError)
        .task { store.startListening() }
        .onDisappear { store.stopListening() }
    }
}
