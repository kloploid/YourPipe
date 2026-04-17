import SwiftUI
import UIKit

@main
@MainActor
struct YourPipeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settings: AppSettingsStore
    @StateObject private var playback: PlaybackController
    @StateObject private var subscriptions = SubscriptionStore()

    init() {
        let settings = AppSettingsStore.shared
        _settings = StateObject(wrappedValue: settings)
        _playback = StateObject(wrappedValue: PlaybackController(settings: settings))
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
                .environmentObject(settings)
        }
        .onChange(of: scenePhase) { newPhase in
            playback.handleScenePhase(newPhase)
        }
    }
}
