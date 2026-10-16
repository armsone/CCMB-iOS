import SwiftUI
import UIKit

@main
struct CCMBApp: App {
    @StateObject private var store = SnapshotStore()
    @StateObject private var weatherStore = WeatherStore()
    @StateObject private var appearanceStore = AppearanceStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(weatherStore)
                .environmentObject(appearanceStore)
                .preferredColorScheme(appearanceStore.selection.preferredColorScheme)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    store.loadOnLaunch()
                    weatherStore.refresh()
                }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
                .onChange(of: scenePhase) { _, phase in
                    // Returning to the foreground re-reads the private
                    // database so the numbers match what the Mac uploaded
                    // while the app was in the background.
                    UIApplication.shared.isIdleTimerDisabled = phase == .active
                    if phase == .active {
                        store.resumeAutomaticRefresh()
                        store.refresh(isAutomatic: true)
                        weatherStore.refresh()
                    } else {
                        // The automatic refresh timer only ever runs in the
                        // foreground; background/inactive stops it instead
                        // of letting it keep firing network requests.
                        store.pauseAutomaticRefresh()
                    }
                }
        }
    }
}
