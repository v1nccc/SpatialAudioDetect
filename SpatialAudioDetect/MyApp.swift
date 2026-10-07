import SwiftUI

@main struct MyApp: App {
    init() {
        // The Dynamic Island / Lock Screen buttons run SetListeningIntent inside this app, even in the background.
        RadarControl.handler = { command in await SoundRadar.shared.handle(command) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
