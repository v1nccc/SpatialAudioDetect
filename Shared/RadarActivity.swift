import ActivityKit
import Foundation

/// What the Dynamic Island and Lock Screen show while Sound Radar runs (shared by the app and the widget).
nonisolated struct RadarActivity: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        nonisolated enum Status: String, Codable, Hashable { case listening, warning, interrupted, paused }
        var status: Status
        var title: String           // "Listening", "Car horn", "Mic interrupted", "Paused"
        var detail: String          // "behind you", "a call, Siri or another app has the mic"
        var azimuth: Double? = nil  // a warning's direction: 0 = ahead, +90 = left

        /// Most important first: a pause you chose, then a mic that isn't delivering audio, then a warning.
        static func make(paused: Bool, micTrouble: String?, warning: (what: String, azimuth: Double?, whereText: String)?) -> Self {
            if paused { return Self(status: .paused, title: "Paused", detail: "Mic off. Resume here or in the app.") }
            if let micTrouble { return Self(status: .interrupted, title: "Not hearing anything", detail: micTrouble) }
            if let w = warning { return Self(status: .warning, title: w.what, detail: w.whereText, azimuth: w.azimuth) }
            return Self(status: .listening, title: "Listening", detail: "Watching for horns, sirens and vehicles")
        }
    }

    var startedAt: Date
}

nonisolated func radarActivitySelfCheck() {
    typealias S = RadarActivity.ContentState
    let horn = (what: "Car horn", azimuth: Optional(180.0), whereText: "behind you")
    precondition(S.make(paused: true, micTrouble: "call", warning: horn).status == .paused, "your pause wins over everything")
    precondition(S.make(paused: false, micTrouble: "call", warning: horn).status == .interrupted, "no audio beats an old warning")
    precondition(S.make(paused: false, micTrouble: nil, warning: horn) == S(status: .warning, title: "Car horn", detail: "behind you", azimuth: 180))
    precondition(S.make(paused: false, micTrouble: nil, warning: nil).status == .listening)
}
