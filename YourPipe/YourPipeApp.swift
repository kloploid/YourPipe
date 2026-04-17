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
        // CRITICAL ORDER for the lock-screen Now Playing widget on iOS 18+:
        // `beginReceivingRemoteControlEvents()` must be called BEFORE we
        // register MPRemoteCommandCenter targets. Otherwise iOS caches an
        // empty command set at registration time and the widget renders with
        // missing transport icons even though our handlers are attached.
        UIApplication.shared.beginReceivingRemoteControlEvents()

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
