import SwiftUI
import FirebaseCore
import FirebaseAppCheck

@main
struct FrijApp: App {
    private let isFirebaseConfigured: Bool

    init() {
        // FirebaseApp.configure() crashes without GoogleService-Info.plist,
        // so check for it and show setup instructions instead.
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            #if DEBUG
            // App Check is enforced for Gemini (Firebase AI Logic). Debug builds,
            // including the simulator, use a debug token: it's printed in the console
            // on first launch and must be registered under App Check → Manage debug tokens.
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
            #endif
            FirebaseApp.configure()
            #if DEBUG
            CloudVoice.runSelfTestIfRequested()
            #endif
            isFirebaseConfigured = true
        } else {
            isFirebaseConfigured = false
        }
    }

    var body: some Scene {
        WindowGroup {
            if isFirebaseConfigured {
                RootView()
            } else {
                ContentUnavailableView(
                    "Firebase isn't set up",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Add GoogleService-Info.plist to the Frij folder and regenerate the project. See the README for steps.")
                )
            }
        }
    }
}
