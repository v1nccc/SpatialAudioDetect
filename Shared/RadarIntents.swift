import AppIntents

/// Pause / Resume from the expanded Dynamic Island and the Lock Screen. As a LiveActivityIntent, iOS runs it
/// inside the app (waking it if needed), never in the widget, so it can reach the microphone.
struct SetListeningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or resume Sound Radar"

    @Parameter(title: "Listen")
    var listen: Bool

    init() {}
    init(listen: Bool) { self.listen = listen }

    func perform() async throws -> some IntentResult {
        await RadarControl.handler?(listen ? .resume : .pause)
        return .result()
    }
}

/// Stop from the expanded Dynamic Island / Lock Screen: mic off and the Live Activity removed.
struct StopListeningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Sound Radar"

    func perform() async throws -> some IntentResult {
        await RadarControl.handler?(.stop)
        return .result()
    }
}

nonisolated enum RadarCommand: Sendable { case resume, pause, stop }

/// The app plugs itself in here at launch; in the widget process nothing is plugged in and nothing runs.
@MainActor enum RadarControl {
    static var handler: ((RadarCommand) async -> Void)?
}
