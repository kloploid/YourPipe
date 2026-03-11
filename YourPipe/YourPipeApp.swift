import SwiftUI
import UIKit

@main
struct YourPipeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playback = PlaybackController()
    @StateObject private var subscriptions = SubscriptionStore()

    init() {
#if DEBUG
        if let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") {
            print("[App] UIBackgroundModes=\(modes)")
        } else {
            print("[App] UIBackgroundModes not set")
        }
#endif
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(playback)
                .environmentObject(subscriptions)
        }
        .onChange(of: scenePhase) { newPhase in
            playback.handleScenePhase(newPhase)
        }
    }
}
