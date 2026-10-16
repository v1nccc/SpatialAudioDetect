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
        var short = ""              // one word for the compact island: "Horn", "Siren", "Vehicle"
        var endedAt: Date? = nil    // a warning still shown after it stopped: when it stopped
        var critical = false        // red and pops the island open; otherwise an orange heads-up

        /// Most important first: a pause you chose, then a mic that isn't delivering audio, then a warning.
        static func make(paused: Bool, micTrouble: String?,
                         warning: (what: String, azimuth: Double?, whereText: String, short: String, critical: Bool, endedAt: Date?)?) -> Self {
            if paused { return Self(status: .paused, title: "Paused", detail: "Mic off. Resume here or in the app.") }
            if let micTrouble { return Self(status: .interrupted, title: "Not hearing anything", detail: micTrouble) }
            if let w = warning {
                return Self(status: .warning, title: w.what, detail: w.whereText, azimuth: w.azimuth, short: w.short,
                            endedAt: w.endedAt, critical: w.critical)
            }
            return Self(status: .listening, title: "Listening", detail: "Watching for horns, sirens and vehicles")
        }
    }

    var startedAt: Date
}

/// Pop the island open when a critical alert starts. Not while the same one continues (a long siren pops once), but
/// again when it comes back after it had stopped, even while the island still shows the old one as "… ago".
/// Warnings never pop it.
nonisolated func islandAlertDue(_ state: RadarActivity.ContentState, previous: RadarActivity.ContentState?) -> Bool {
    guard state.status == .warning, state.critical, state.endedAt == nil else { return false }
    let continuing = previous?.status == .warning && previous?.critical == true && previous?.endedAt == nil
        && previous?.title == state.title
    return !continuing
}

nonisolated func radarActivitySelfCheck() {
    typealias S = RadarActivity.ContentState
    let horn = (what: "Car horn", azimuth: Optional(180.0), whereText: "behind you", short: "Horn", critical: true, endedAt: Date?.none)
    precondition(S.make(paused: true, micTrouble: "call", warning: horn).status == .paused, "your pause wins over everything")
    precondition(S.make(paused: false, micTrouble: "call", warning: horn).status == .interrupted, "no audio beats an old warning")
    precondition(S.make(paused: false, micTrouble: nil, warning: horn) == S(status: .warning, title: "Car horn", detail: "behind you", azimuth: 180, short: "Horn", critical: true))
    precondition(S.make(paused: false, micTrouble: nil, warning: nil).status == .listening)

    let listening = S.make(paused: false, micTrouble: nil, warning: nil), hornNow = S.make(paused: false, micTrouble: nil, warning: horn)
    let siren = S.make(paused: false, micTrouble: nil, warning: (what: "Police siren", azimuth: 90, whereText: "on your left", short: "Siren", critical: true, endedAt: nil))
    let t0 = Date(timeIntervalSince1970: 0)  // a past end time for the "… ago" states
    precondition(islandAlertDue(hornNow, previous: listening), "new horn pops the island")
    precondition(!islandAlertDue(hornNow, previous: hornNow), "same horn still going: no repeat")
    precondition(islandAlertDue(siren, previous: hornNow), "a different critical sound pops at once")
    precondition(!islandAlertDue(listening, previous: hornNow), "warning over: nothing to pop")
    let hornAfter = S.make(paused: false, micTrouble: nil, warning: (what: "Car horn", azimuth: 180, whereText: "behind you", short: "Horn", critical: true, endedAt: t0))
    precondition(!islandAlertDue(hornAfter, previous: hornNow), "horn just ended, still shown: no new pop")
    precondition(islandAlertDue(hornNow, previous: hornAfter), "the horn again while the old one still shows as '… ago': pop")
    let dog = S.make(paused: false, micTrouble: nil, warning: (what: "Dog bark", azimuth: 0, whereText: "ahead", short: "Bark", critical: false, endedAt: nil))
    precondition(!islandAlertDue(dog, previous: listening), "a warning-level alert doesn't pop the island")
    var dogNear = dog
    dogNear.critical = true
    precondition(islandAlertDue(dogNear, previous: dog), "the same sound turning critical (came near) pops")
}
