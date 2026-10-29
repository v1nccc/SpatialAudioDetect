import Foundation

// Evaluation data and scoring (Evaluate screen). Ground truth comes from the tester (what was played, when, from
// where; what they felt); what the app did is recorded automatically. Pure, so the Mac can self-check it.

nonisolated enum EvalKind: String, Codable, CaseIterable, Sendable {
    case controlled = "Controlled test", realRun = "Real run"
}

/// Where a test sound came from, relative to the runner.
nonisolated enum Side: String, Codable, CaseIterable, Sendable {
    case ahead = "Ahead", left = "Left", behind = "Behind", right = "Right"
    var azimuth: Double { [.ahead: 0, .left: 90, .behind: 180, .right: -90][self]! }
}

/// Sounds for a controlled test: should raise an alert, or shouldn't (to count false alarms).
nonisolated let evalAlertSounds = ["Siren", "Car horn", "Dog bark", "Shout", "Bike bell", "Reversing beeps", "Vehicle getting closer"]
nonisolated let evalQuietSounds = ["Talking", "Music", "Whistling", "Kettle / phone beeps", "Birds", "Ordinary traffic"]

/// Whether the app's alert names the sound that was played.
nonisolated func alertMatches(_ sound: String, _ what: String) -> Bool {
    switch sound {
    case "Siren": what == "Siren"
    case "Car horn": what == "Horn"
    case "Dog bark": what.hasPrefix("Dog")
    case "Shout": ["Shout", "Yell", "Screaming", "Children shouting"].contains(what)
    case "Bike bell": what == "Bicycle bell"
    case "Reversing beeps": what == "Reverse beeps"
    case "Vehicle getting closer": what.contains("getting closer")
    default: false
    }
}

nonisolated struct EvalConditions: Codable, Equatable, Sendable {
    var place = "Busy street", carry = "Hand", activity = "Standing"
    var tester = "", helper = "", notes = ""
    var model = "", fineTune = "", device = "", system = ""  // filled in automatically
    static let places = ["Quiet street", "Busy street", "Park / path", "Indoors"]
    static let carries = ["Hand", "Pocket", "Armband", "Chest / strap", "Bag"]
    static let activities = ["Standing", "Walking", "Running", "Cycling"]
    var summary: String { "\(place) · \(carry) · \(activity) · \(model)" }
}

/// One played (or planned) test sound. `at` = when the sound started; nil while it's only planned.
nonisolated struct EvalTrial: Codable, Identifiable, Sendable {
    var id = UUID()
    var sound: String
    var shouldAlert: Bool
    var side: Side
    var meters: Double
    var locked: Bool
    var at: Date?
    var felt: Bool?        // the tester felt the vibration
    var noticedAt: Date?   // the tester tapped "I noticed it"
    var note = ""
}

/// Every alert the app raised during a session, recorded automatically.
nonisolated struct EvalAlert: Codable, Identifiable, Sendable {
    /// The sound: right, a real sound under the wrong name (a siren called a horn), nothing worth an alert, or not sure.
    nonisolated enum Review: String, Codable, CaseIterable, Sendable {
        case real = "Real", wrongSound = "Wrong sound", falseAlarm = "False alarm", unsure = "Not sure"
    }
    /// The arrow: pointed at it, the right side but off, or a different side.
    nonisolated enum DirectionReview: String, Codable, CaseIterable, Sendable { case right = "Right", close = "Close", wrong = "Wrong" }
    /// While the sound was still on and early enough to react, or only after it mattered.
    nonisolated enum TimingReview: String, Codable, CaseIterable, Sendable { case onTime = "On time", late = "Late" }
    var id = UUID()
    var at: Date
    var what: String
    var critical: Bool
    var azimuth: Double?          // when it started
    var settledAzimuth: Double?   // ~1 s later (the alert follows its sound)
    var appState: String
    var haptic: String?           // what iOS answered for its first vibration
    var hapticOK: Bool?
    var review: Review?           // real runs: was it a real danger, and the right sound?
    var directionReview: DirectionReview?  // real runs: was the arrow right (not asked for false alarms)
    var timingReview: TimingReview?        // real runs: did it come in time
    var audioAt: Double?          // test sessions: seconds into the recording's audio (exact even after a pause)
    var directionOffBy: Double?   // where the sound really was: degrees clockwise from the arrow (− = counter-clockwise)
    var lateBy: Double?           // how late it came, seconds
    var direction: Double? { settledAzimuth ?? azimuth }
    /// Where the sound really was (clockwise = toward the right = smaller azimuth), once you've said how far off it was.
    var trueAzimuth: Double? { zip2(direction, directionOffBy).map { remainder($0 - $1, 360) } }
}

/// A real-run event someone noticed (siren, horn…), to check the app caught it.
nonisolated struct EvalMark: Codable, Identifiable, Sendable {
    var id = UUID()
    var at: Date
    var sound: String
    var note = ""
    var audioAt: Double?  // test sessions: seconds into the recording's audio
    var inReplay: Bool?   // flagged afterwards while replaying the test, not live
}

nonisolated struct EvalReliability: Codable, Sendable {
    var listening = 0.0, recognitionDown = 0.0, micTrouble = 0.0  // seconds
    var restarts = 0
    var batteryStart: Double?, batteryEnd: Double?                // 0…1
    var hottest = "normal"
    var charging: Bool?  // on the charger at the start or end: its battery use doesn't count
}

nonisolated struct EvalSession: Codable, Identifiable, Sendable {
    var id = UUID()
    var kind: EvalKind
    var started: Date
    var ended: Date?
    var conditions: EvalConditions
    var trials: [EvalTrial] = []
    var marks: [EvalMark] = []
    var alerts: [EvalAlert] = []
    var reliability = EvalReliability()
    var recording: String?  // test sessions (Testing tab): their audio and logs, Documents/Recordings/<this>
    var played: [EvalTrial] { trials.filter { $0.at != nil } }
    var recordingFolder: URL? { recording.map { URL.documentsDirectory.appending(path: "Recordings/\($0)") } }
}

/// Alerts from 1 s before a trial's mark (tapped a bit late) to 8 s after (the classifier needs ~1–2 s to confirm).
nonisolated let evalWindow = (before: 1.0, after: 8.0)

/// What the app did for one played trial.
nonisolated struct TrialResult: Sendable {
    var alert: EvalAlert?      // the alert credited to this sound (the right kind if there was one)
    var typeRight = false
    var latency: Double?
    var sideRight: Bool?
    var angleError: Double?
    var reaction: Double?
    var detected: Bool { alert != nil }
}

nonisolated func result(_ t: EvalTrial, alerts: [EvalAlert]) -> TrialResult? {
    guard let at = t.at else { return nil }
    let near = alerts.filter { let d = $0.at.timeIntervalSince(at); return d >= -evalWindow.before && d <= evalWindow.after }
        .sorted { $0.at < $1.at }
    let right = near.first { alertMatches(t.sound, $0.what) }
    guard let a = right ?? near.first else { return TrialResult(reaction: t.noticedAt.map { $0.timeIntervalSince(at) }) }
    let error = a.direction.map { angularDistance($0, t.side.azimuth) }
    return TrialResult(alert: a, typeRight: right != nil, latency: max(a.at.timeIntervalSince(at), 0),
                       sideRight: a.direction.map { slot($0, of: 4) == slot(t.side.azimuth, of: 4) }, angleError: error,
                       reaction: t.noticedAt.map { $0.timeIntervalSince(at) })
}

/// Within 8 s either side: by the recording's time when both have one (exact across pauses, and the only time a flag
/// made in a replay has), else by the clock.
nonisolated func near(_ a: EvalAlert, _ m: EvalMark) -> Bool {
    if let x = a.audioAt, let y = m.audioAt { return abs(x - y) <= 8 }
    return abs(a.at.timeIntervalSince(m.at)) <= 8
}

/// The warning that caught a danger someone flagged: near it and for that sound. "Other danger" takes any warning, and so
/// does a warning you marked the wrong sound (it noticed this danger under another name). A coincidental warning for a
/// different sound doesn't count: the runner wasn't warned about this one.
nonisolated func catcher(_ m: EvalMark, alerts: [EvalAlert]) -> EvalAlert? {
    alerts.first { near($0, m) && (m.sound == "Other danger" || alertMatches(m.sound, $0.what) || $0.review == .wrongSound) }
}

nonisolated func caught(_ m: EvalMark, alerts: [EvalAlert]) -> Bool { catcher(m, alerts: alerts) != nil }

// MARK: Metrics

nonisolated struct EvalMetric: Identifiable, Sendable {
    var id: String { group + name }
    var group: String
    var name: String
    var value: String      // "18/20 = 90%"
    var range = ""         // 95% confidence range for percentages
    var target: String
    var pass: Bool?        // nil = no data yet
    var explain: String
}

/// 95% range for k successes out of n (Wilson): with few trials, 9/10 really means "somewhere around 60–98%".
nonisolated func wilson(_ k: Int, _ n: Int) -> (low: Double, high: Double)? {
    guard n > 0 else { return nil }
    let p = Double(k) / Double(n), z = 1.96, nn = Double(n), d = 1 + z * z / nn
    let center = (p + z * z / (2 * nn)) / d, half = z * ((p * (1 - p) / nn + z * z / (4 * nn * nn)).squareRoot()) / d
    return (max(center - half, 0), min(center + half, 1))
}

nonisolated func percentile(_ xs: [Double], _ p: Double) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

nonisolated func evalMetrics(_ sessions: [EvalSession]) -> [EvalMetric] {
    var out: [EvalMetric] = []
    func share(_ group: String, _ name: String, _ k: Int, _ n: Int, atLeast target: Double? = nil, atMost cap: Double? = nil, _ explain: String) {
        let p = n > 0 ? Double(k) / Double(n) : 0
        let r = wilson(k, n).map { "\(Int(($0.low * 100).rounded()))–\(Int(($0.high * 100).rounded()))%" } ?? ""
        let goal = target.map { "≥ \(Int($0 * 100))%" } ?? cap.map { "≤ \(Int($0 * 100))%" } ?? ""
        let pass: Bool? = n == 0 ? nil : target.map { p >= $0 } ?? cap.map { p <= $0 }
        out.append(EvalMetric(group: group, name: name, value: n == 0 ? "no data" : "\(k)/\(n) = \(Int((p * 100).rounded()))%",
                              range: r, target: goal, pass: pass, explain: explain))
    }
    func number(_ group: String, _ name: String, _ x: Double?, unit: String, digits: Int = 1, atMost cap: Double, n: Int, _ explain: String) {
        out.append(EvalMetric(group: group, name: name, value: x.map { String(format: "%.\(digits)f %@", $0, unit) + " (n=\(n))" } ?? "no data",
                              target: "≤ " + String(format: "%.\(digits)f %@", cap, unit), pass: x.map { $0 <= cap }, explain: explain))
    }

    // Controlled tests
    let played = sessions.filter { $0.kind == .controlled }.flatMap { s in s.played.map { (t: $0, r: result($0, alerts: s.alerts)!, s: s) } }
    let positives = played.filter { $0.t.shouldAlert }, negatives = played.filter { !$0.t.shouldAlert }
    let found = positives.filter { $0.r.detected }
    let g1 = "Recognition (controlled tests)"
    share(g1, "Alert sounds caught", found.count, positives.count, atLeast: 0.9,
          "Played sounds that should alert (siren, horn…) that got any alert within 8 s.")
    share(g1, "Named correctly", found.filter { $0.r.typeRight }.count, found.count, atLeast: 0.9,
          "Of the caught ones: the alert said the right sound (\"Siren\" for a siren).")
    share(g1, "False alarms on harmless sounds", negatives.filter { $0.r.detected }.count, negatives.count, atMost: 0.1,
          "Talking, music, whistling… that wrongly raised an alert.")
    let lat = found.compactMap(\.r.latency)
    number(g1, "Time to alert (median)", percentile(lat, 0.5), unit: "s", atMost: 1.5, n: lat.count,
           "From the moment the sound started to the alert.")
    number(g1, "Time to alert (slowest 10%)", percentile(lat, 0.9), unit: "s", atMost: 3, n: lat.count,
           "9 in 10 alerts came at least this fast.")

    let aimed = found.filter { $0.r.sideRight != nil }
    let g2 = "Direction (controlled tests)"
    share(g2, "Correct side", aimed.filter { $0.r.sideRight == true }.count, aimed.count, atLeast: 0.85,
          "The alert pointed to the right quarter: ahead, left, behind or right.")
    let errors = aimed.compactMap(\.r.angleError)
    number(g2, "Angle off (median)", percentile(errors, 0.5), unit: "°", digits: 0, atMost: 30, n: errors.count,
           "Degrees between the alert's arrow and where the sound really was.")
    number(g2, "Angle off (worst 10%)", percentile(errors, 0.9), unit: "°", digits: 0, atMost: 60, n: errors.count,
           "9 in 10 arrows were at least this close.")
    share(g2, "Front/back mix-ups", errors.filter { $0 > 135 }.count, errors.count, atMost: 0.1,
          "Arrow pointing the opposite way (more than 135° off): the phone's known weak spot.")

    let g3 = "Feeling it"
    let buzzed = played.compactMap { $0.r.alert?.hapticOK }
    share(g3, "Vibration delivered", buzzed.filter { $0 }.count, buzzed.count, atLeast: 0.95,
          "iOS accepted the vibration for the alert (also with the phone locked).")
    let answered = positives.filter { $0.r.detected }.compactMap(\.t.felt)
    share(g3, "Vibration felt", answered.filter { $0 }.count, answered.count, atLeast: 0.9,
          "The tester said they felt it, where it was carried.")
    let lockedFelt = positives.filter { $0.t.locked && $0.r.detected }.compactMap(\.t.felt)
    share(g3, "Felt with the phone locked", lockedFelt.filter { $0 }.count, lockedFelt.count, atLeast: 0.9,
          "Same, only the trials with the phone locked.")
    let reactions = played.compactMap(\.r.reaction).filter { $0 >= 0 }
    number(g3, "Reaction time (median)", percentile(reactions, 0.5), unit: "s", atMost: 2.5, n: reactions.count,
           "From the sound starting to the tester tapping \"I noticed it\".")

    // Real runs
    let runs = sessions.filter { $0.kind == .realRun }
    let reviewed = runs.flatMap(\.alerts).compactMap(\.review).filter { $0 != .unsure }
    let g4 = "Real runs"
    let real = reviewed.filter { $0 != .falseAlarm }
    share(g4, "Alerts that were real", real.count, reviewed.count, atLeast: 0.8,
          "Of the alerts you reviewed after the run, how many were a real danger (precision).")
    share(g4, "Real alerts named right", real.filter { $0 == .real }.count, real.count, atLeast: 0.9,
          "Of the real ones: the alert said the right sound.")
    let realAlerts = runs.flatMap(\.alerts).filter { $0.review != .falseAlarm }
    let aimedReal = realAlerts.compactMap(\.directionReview)
    share(g4, "Real alerts pointing right", aimedReal.filter { $0 == .right }.count, aimedReal.count, atLeast: 0.85,
          "Of the real ones you judged: the arrow pointed at the sound (\"close\" doesn't count).")
    let timed = realAlerts.compactMap(\.timingReview)
    share(g4, "Real alerts on time", timed.filter { $0 == .onTime }.count, timed.count, atLeast: 0.9,
          "Of the real ones you judged: it came while the sound was on, early enough to react.")
    var judged = VerdictCount()
    runs.flatMap(\.alerts).forEach { judged.add($0) }
    number(g4, "Real alerts: angle off (median)", percentile(judged.angleErrors, 0.5), unit: "°", digits: 0, atMost: 30,
           n: judged.angleErrors.count, "0° when it pointed right, else how far off you set it.")
    number(g4, "Real alerts: late by (median)", percentile(judged.lateBys, 0.5).map { $0 * 1000 }, unit: "ms", digits: 0, atMost: 500,
           n: judged.lateBys.count, "0 when on time, else how late you set it.")
    let falseCount = reviewed.filter { $0 == .falseAlarm }.count, minutes = runs.map(\.reliability.listening).reduce(0, +) / 60
    out.append(EvalMetric(group: g4, name: "False alarms per 10 min",
                          value: minutes > 0 ? String(format: "%.1f (%d in %.0f min)", Double(falseCount) / minutes * 10, falseCount, minutes) : "no data",
                          target: "≤ 1.0", pass: minutes > 0 ? Double(falseCount) / minutes * 10 <= 1 : nil,
                          explain: "Reviewed false alarms per 10 minutes of listening."))
    let marks = runs.flatMap { s in s.marks.map { (m: $0, s: s) } }
    share(g4, "Noticed events caught", marks.filter { caught($0.m, alerts: $0.s.alerts) }.count, marks.count, atLeast: 0.9,
          "Real sirens, horns… someone marked during the run that the app also alerted for (±8 s).")

    // Everything
    let rel = sessions.map(\.reliability), listening = rel.map(\.listening).reduce(0, +)
    let g5 = "Reliability"
    let up = listening > 0 ? 1 - rel.map(\.recognitionDown).reduce(0, +) / listening : nil
    out.append(EvalMetric(group: g5, name: "Recognition working", value: up.map { String(format: "%.1f%% of %.0f min", $0 * 100, listening / 60) } ?? "no data",
                          target: "≥ 99%", pass: up.map { $0 >= 0.99 }, explain: "Time sounds could be recognized while listening (also locked)."))
    let mic = listening > 0 ? 1 - rel.map(\.micTrouble).reduce(0, +) / listening : nil
    out.append(EvalMetric(group: g5, name: "Mic working", value: mic.map { String(format: "%.1f%%", $0 * 100) } ?? "no data",
                          target: "≥ 99%", pass: mic.map { $0 >= 0.99 }, explain: "Time audio actually arrived while listening."))
    let hours = listening / 3600
    number(g5, "Classifier restarts per hour", hours > 0 ? Double(rel.map(\.restarts).reduce(0, +)) / hours : nil, unit: "/h",
           atMost: 2, n: rel.map(\.restarts).reduce(0, +), "Times recognition failed and restarted itself.")
    let drains = sessions.compactMap { s -> (Double, Double)? in
        guard let a = s.reliability.batteryStart, let b = s.reliability.batteryEnd, s.reliability.listening > 300,
              s.reliability.charging != true else { return nil }
        return (a - b, s.reliability.listening / 3600)
    }
    let drain = drains.isEmpty ? nil : drains.map(\.0).reduce(0, +) / drains.map(\.1).reduce(0, +) * 100
    number(g5, "Battery used per hour", drain, unit: "%/h", digits: 0, atMost: 15, n: drains.count,
           "From sessions over 5 min with the battery level known (not on the simulator).")
    return out
}

// MARK: Export

nonisolated func csv(_ rows: [[String]]) -> String {
    rows.map { $0.map { f in f.contains(where: { ",\"\n".contains($0) }) ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f }
        .joined(separator: ",") }.joined(separator: "\n") + "\n"
}

nonisolated func evalCSVs(_ sessions: [EvalSession]) -> [String: String] {
    let iso = ISO8601DateFormatter()
    iso.timeZone = .current  // local time with its offset, e.g. 2026-10-13T14:17:07+07:00
    func t(_ d: Date?) -> String { d.map(iso.string) ?? "" }
    func f(_ x: Double?, _ digits: Int = 2) -> String { x.map { String(format: "%.\(digits)f", $0) } ?? "" }
    func b(_ x: Bool?) -> String { x.map { $0 ? "yes" : "no" } ?? "" }
    let cond = ["place", "carry", "activity", "model", "fine_tune", "tester", "helper", "device", "ios"]
    func c(_ s: EvalSession) -> [String] {
        let k = s.conditions
        return [k.place, k.carry, k.activity, k.model, k.fineTune, k.tester, k.helper, k.device, k.system]
    }
    var trials = [["session", "kind"] + cond + ["trial", "sound", "should_alert", "true_side", "meters", "locked", "sound_start",
                                               "alerted", "alert", "critical", "right_sound", "latency_s", "azimuth", "right_side",
                                               "angle_error", "vibration", "vibration_ok", "felt", "reaction_s", "note"]]
    var alerts = [["session", "kind"] + cond + ["time", "alert", "critical", "azimuth_start", "azimuth_1s", "app_state", "vibration",
                                               "vibration_ok", "review"]]
    var marks = [["session"] + cond + ["time", "sound", "caught", "note"]]
    var sessionsRows = [["session", "kind", "started", "ended"] + cond + ["notes", "listening_s", "recognition_down_s", "mic_trouble_s",
                                                                         "restarts", "battery_start", "battery_end", "hottest"]]
    for s in sessions {
        let id = String(s.id.uuidString.prefix(8))
        for (i, tr) in s.played.enumerated() {
            let r = result(tr, alerts: s.alerts)!
            trials.append([id, s.kind.rawValue] + c(s) + ["\(i + 1)", tr.sound, b(tr.shouldAlert), tr.side.rawValue, f(tr.meters, 0), b(tr.locked),
                           t(tr.at), b(r.detected), r.alert?.what ?? "", b(r.alert?.critical), b(r.detected ? r.typeRight : nil),
                           f(r.latency), f(r.alert?.direction, 0), b(r.sideRight), f(r.angleError, 0), r.alert?.haptic ?? "",
                           b(r.alert?.hapticOK), b(tr.felt), f(r.reaction), tr.note])
        }
        for a in s.alerts {
            alerts.append([id, s.kind.rawValue] + c(s) + [t(a.at), a.what, b(a.critical), f(a.azimuth, 0), f(a.settledAzimuth, 0), a.appState,
                           a.haptic ?? "", b(a.hapticOK), a.review?.rawValue ?? ""])
        }
        for m in s.marks { marks.append([id] + c(s) + [t(m.at), m.sound, b(caught(m, alerts: s.alerts)), m.note]) }
        let r = s.reliability
        sessionsRows.append([id, s.kind.rawValue, t(s.started), t(s.ended)] + c(s) + [s.conditions.notes, f(r.listening, 0),
                            f(r.recognitionDown, 0), f(r.micTrouble, 0), "\(r.restarts)", f(r.batteryStart), f(r.batteryEnd), r.hottest])
    }
    let summary = [["group", "metric", "value", "95% range", "target", "pass", "meaning"]]
        + evalMetrics(sessions).map { [$0.group, $0.name, $0.value, $0.range, $0.target, b($0.pass), $0.explain] }
    return ["summary.csv": csv(summary), "trials.csv": csv(trials), "alerts.csv": csv(alerts), "marks.csv": csv(marks),
            "sessions.csv": csv(sessionsRows)]
}

// MARK: Test sessions (Testing tab)

/// Each alert's three verdicts counted: the sound (right / wrong name / false alarm), and for the real ones the
/// direction (right / close / wrong) and the timing (on time / late). Not-sure or not-yet-marked counts apart.
nonisolated struct VerdictCount: Sendable {
    var right = 0, wrongSound = 0, falseAlarms = 0, unsure = 0, unmarked = 0
    var pointedRight = 0, pointedClose = 0, pointedWrong = 0
    var onTime = 0, late = 0
    var angleErrors: [Double] = []  // degrees off: 0 when it pointed right, else what you set (unset ones left out)
    var lateBys: [Double] = []      // seconds late: 0 when on time, else what you set
    var real: Int { right + wrongSound }
    var aimed: Int { pointedRight + pointedClose + pointedWrong }
    var timed: Int { onTime + late }

    mutating func add(_ a: EvalAlert) {
        switch a.review {
        case .real?: right += 1
        case .wrongSound?: wrongSound += 1
        case .falseAlarm?: falseAlarms += 1
        case .unsure?: unsure += 1
        case nil: unmarked += 1
        }
        guard a.review != .falseAlarm else { return }  // nothing there: no direction or timing to judge
        switch a.directionReview {
        case .right?: pointedRight += 1; angleErrors.append(0)
        case .close?: pointedClose += 1; if let d = a.directionOffBy { angleErrors.append(abs(d)) }
        case .wrong?: pointedWrong += 1; if let d = a.directionOffBy { angleErrors.append(abs(d)) }
        case nil: break
        }
        switch a.timingReview {
        case .onTime?: onTime += 1; lateBys.append(0)
        case .late?: late += 1; if let l = a.lateBy { lateBys.append(l) }
        case nil: break
        }
    }

    /// What's wrong, in words: more than 20% of the judged ones failed on that point.
    var problems: [String] {
        func over(_ bad: Int, _ of: Int) -> Bool { of > 0 && Double(bad) > 0.2 * Double(of) }
        return [(over(falseAlarms, real + falseAlarms), "false alarms"), (over(wrongSound, real), "wrong sound"),
                (over(pointedWrong, aimed), "direction"), (over(late, timed), "late")].filter(\.0).map(\.1)
    }
}

/// One sound's results in a test: its alerts' verdicts, and the real events you flagged.
nonisolated struct SoundTally: Identifiable, Sendable {
    var id: String { sound }
    var sound: String
    var verdicts = VerdictCount()
    var caught = 0, missed = 0  // real events you flagged: the app alerted within 8 s or not
    var problems: [String] { verdicts.problems + (missed > 0 ? ["missed"] : []) }
    var needsWork: Bool { !problems.isEmpty }
}

/// Per sound, the ones that need work first. A flagged event counts under the alert name it should have produced.
nonisolated func soundTallies(_ s: EvalSession) -> [SoundTally] {
    var t: [String: SoundTally] = [:]
    for a in s.alerts {
        var x = t[a.what] ?? SoundTally(sound: a.what)
        x.verdicts.add(a)
        t[a.what] = x
    }
    for m in s.marks {
        let key = t.keys.first { alertMatches(m.sound, $0) } ?? m.sound
        var x = t[key] ?? SoundTally(sound: key)
        if caught(m, alerts: s.alerts) { x.caught += 1 } else { x.missed += 1 }
        t[key] = x
    }
    func order(_ x: SoundTally) -> (Int, Int, String) { (x.needsWork ? 0 : 1, -s.alerts.filter { $0.what == x.sound }.count, x.sound) }
    return t.values.sorted { order($0) < order($1) }
}

/// A test session's headline numbers.
nonisolated struct TestSummary: Sendable {
    var minutes = 0.0, verdicts = VerdictCount(), eventsCaught = 0, eventsMissed = 0
    var falsePer10Minutes: Double?
    var batteryUsed: Double?      // 0…1, nil on the charger or unknown (simulator)
    var batteryPerHour: Double?   // only from 5 min on: iOS reports the battery in 5% steps

    init(_ s: EvalSession, now: Date = .now) {
        minutes = (s.ended ?? now).timeIntervalSince(s.started) / 60
        s.alerts.forEach { verdicts.add($0) }
        eventsCaught = s.marks.filter { caught($0, alerts: s.alerts) }.count
        eventsMissed = s.marks.count - eventsCaught
        let listening = s.reliability.listening / 60
        falsePer10Minutes = listening > 0 ? Double(verdicts.falseAlarms) / listening * 10 : nil
        if let a = s.reliability.batteryStart, let b = s.reliability.batteryEnd, s.reliability.charging != true {
            batteryUsed = a - b
            batteryPerHour = minutes >= 5 ? (a - b) / (minutes / 60) : nil
        }
    }
}

/// k of n as a fraction, nil without any.
nonisolated func fraction(_ k: Int, _ n: Int) -> Double? { n > 0 ? Double(k) / Double(n) : nil }

/// A test session as spreadsheets: timeline.csv (every alert and flagged event by time into the test, with its
/// direction and your three verdicts), by_sound.csv and summary.csv.
nonisolated func testCSVs(_ s: EvalSession) -> [String: String] {
    let iso = ISO8601DateFormatter()
    iso.timeZone = .current
    func f(_ x: Double?, _ digits: Int = 0) -> String { x.map { String(format: "%.\(digits)f", $0) } ?? "" }
    func pct(_ x: Double?) -> String { x.map { "\(Int(($0 * 100).rounded()))%" } ?? "" }
    let sounds: [EvalAlert.Review: String] = [.real: "right", .wrongSound: "wrong sound", .falseAlarm: "false alarm", .unsure: "not sure"]
    func row(_ a: EvalAlert) -> [String] {
        let nothing = a.review == .falseAlarm, off = nothing || a.directionReview == .right, late = !nothing && a.timingReview == .late
        let vibration: String = a.hapticOK.map { $0 ? "ok" : "failed: \(a.haptic ?? "")" } ?? ""
        let soundVerdict: String = a.review.flatMap { sounds[$0] } ?? "not marked"
        let directionVerdict: String = nothing ? "" : a.directionReview?.rawValue.lowercased() ?? "not marked"
        let timingVerdict: String = nothing ? "" : a.timingReview?.rawValue.lowercased() ?? "not marked"
        let head: [String] = ["alert", a.what, a.critical ? "critical" : "warning", f(a.azimuth), f(a.settledAzimuth), directionWords(a.direction),
                              a.appState, vibration]
        let verdicts: [String] = [soundVerdict, directionVerdict, timingVerdict, off ? "" : f(a.directionOffBy), off ? "" : f(a.trueAzimuth),
                                  late ? f(a.lateBy.map { $0 * 1000 }) : ""]
        return head + verdicts
    }
    var items: [(at: Date, offset: Double, row: [String])] = s.alerts.map { ($0.at, $0.audioAt ?? $0.at.timeIntervalSince(s.started), row($0)) }
    for m in s.marks {
        let row: [String] = ["real event", m.sound, m.inReplay == true ? "flagged in replay" : "flagged live", "", "", "", "", "",
                             caught(m, alerts: s.alerts) ? "caught" : "missed", "", "", "", "", ""]
        items.append((m.at, m.audioAt ?? m.at.timeIntervalSince(s.started), row))
    }
    let timeline = [["offset_s", "time", "type", "what", "level", "azimuth", "azimuth_1s", "direction", "app_state", "vibration",
                     "sound_verdict", "direction_verdict", "timing_verdict", "direction_off_cw_deg", "true_azimuth", "late_ms"]]
        + items.sorted { $0.offset < $1.offset }.map { [f($0.offset, 1), iso.string(from: $0.at)] + $0.row }
    let bySound = [["sound", "right", "wrong_sound", "false_alarm", "not_sure", "not_marked", "direction_right", "direction_close",
                    "direction_wrong", "on_time", "late", "events_caught", "events_missed", "median_angle_off", "median_late_ms", "needs_work"]]
        + soundTallies(s).map { x in
            let v = x.verdicts
            return [x.sound] + [v.right, v.wrongSound, v.falseAlarms, v.unsure, v.unmarked, v.pointedRight, v.pointedClose, v.pointedWrong,
                                v.onTime, v.late, x.caught, x.missed].map(String.init)
                + [f(percentile(v.angleErrors, 0.5)), f(percentile(v.lateBys, 0.5).map { $0 * 1000 }), x.problems.joined(separator: "; ")]
        }
    let t = TestSummary(s), v = t.verdicts, r = s.reliability, c = s.conditions
    let summary: [[String]] = [["metric", "value"], ["started", iso.string(from: s.started)], ["minutes", f(t.minutes, 1)], ["method", c.model],
                   ["carried", c.carry], ["activity", c.activity], ["place", c.place], ["notes", c.notes], ["alerts", "\(s.alerts.count)"],
                   ["not_marked", "\(v.unmarked)"], ["not_sure", "\(v.unsure)"],
                   ["real_sound", "\(v.real) of \(v.real + v.falseAlarms)"], ["real_share", pct(fraction(v.real, v.real + v.falseAlarms))],
                   ["named_right", "\(v.right) of \(v.real)"], ["direction_right", "\(v.pointedRight) of \(v.aimed)"],
                   ["direction_right_or_close", pct(fraction(v.pointedRight + v.pointedClose, v.aimed))],
                   ["on_time", "\(v.onTime) of \(v.timed)"], ["false_alarms_per_10_min", f(t.falsePer10Minutes, 1)],
                   ["angle_off_median_deg", f(percentile(v.angleErrors, 0.5))], ["angle_off_worst_deg", f(v.angleErrors.max())],
                   ["late_median_ms", f(percentile(v.lateBys, 0.5).map { $0 * 1000 })], ["late_worst_ms", f(v.lateBys.max().map { $0 * 1000 })]]
    let rest: [[String]] = [
                   ["events_caught", "\(t.eventsCaught)"], ["events_missed", "\(t.eventsMissed)"],
                   ["battery_start", f(r.batteryStart.map { $0 * 100 })], ["battery_end", f(r.batteryEnd.map { $0 * 100 })],
                   ["battery_per_hour", f(t.batteryPerHour.map { $0 * 100 }, 1)], ["on_charger", r.charging == true ? "yes" : "no"],
                   ["hottest", r.hottest], ["recognition_down_s", f(r.recognitionDown)], ["mic_trouble_s", f(r.micTrouble)],
                   ["classifier_restarts", "\(r.restarts)"], ["device", "\(c.device) · \(c.system)"], ["fine_tune", c.fineTune]]
    return ["timeline.csv": csv(timeline), "by_sound.csv": csv(bySound), "summary.csv": csv(summary + rest)]
}

/// Plan for a controlled test: every chosen alert sound from every side `repeats` times, plus harmless sounds, shuffled.
/// `lockEvery`: 0 = never locked, 2 = every other trial, 1 = all.
nonisolated func evalPlan(sounds: [String], repeats: Int, quiet: [String], quietCount: Int, meters: Double, lockEvery: Int,
                          using rng: inout some RandomNumberGenerator) -> [EvalTrial] {
    var plan = sounds.flatMap { s in Side.allCases.flatMap { side in (0..<repeats).map { _ in
        EvalTrial(sound: s, shouldAlert: true, side: side, meters: meters, locked: false) } } }
    if !quiet.isEmpty {
        plan += (0..<quietCount).map { i in
            EvalTrial(sound: quiet[i % quiet.count], shouldAlert: false, side: Side.allCases.randomElement(using: &rng)!, meters: meters, locked: false)
        }
    }
    plan.shuffle(using: &rng)
    for i in plan.indices where lockEvery > 0 && i % lockEvery == lockEvery - 1 { plan[i].locked = true }
    return plan
}

nonisolated func evaluationSelfCheck() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    var s = EvalSession(kind: .controlled, started: t0, conditions: EvalConditions())
    // 10 sirens: 8 caught in time (one named "Horn"), 1 alert too late (12 s), 1 nothing.
    for i in 0..<10 {
        s.trials.append(EvalTrial(sound: "Siren", shouldAlert: true, side: i % 2 == 0 ? .left : .behind, meters: 10, locked: i == 0,
                                  at: at(Double(i) * 30), felt: i < 7 ? true : false))
    }
    for i in 0..<8 {
        let wrongSide = i == 7  // arrow 170° off for a siren from behind/left
        s.alerts.append(EvalAlert(at: at(Double(i) * 30 + 1.2), what: i == 3 ? "Horn" : "Siren", critical: true,
                                  azimuth: wrongSide ? (i % 2 == 0 ? -80 : 10) : (i % 2 == 0 ? 80 : 175), appState: "background",
                                  hapticOK: i != 5))
    }
    s.alerts.append(EvalAlert(at: at(8 * 30 + 12), what: "Siren", critical: true, azimuth: 90, appState: "foreground"))
    // 4 harmless sounds, one false alarm.
    for i in 0..<4 { s.trials.append(EvalTrial(sound: "Talking", shouldAlert: false, side: .right, meters: 5, locked: false, at: at(400 + Double(i) * 30))) }
    s.alerts.append(EvalAlert(at: at(400 + 2), what: "Shout", critical: false, azimuth: -90, appState: "foreground"))
    s.trials.append(EvalTrial(sound: "Siren", shouldAlert: true, side: .ahead, meters: 10, locked: false))  // planned, not played

    let m = Dictionary(evalMetrics([s]).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    precondition(m["Alert sounds caught"]!.value == "8/10 = 80%" && m["Alert sounds caught"]!.pass == false, "recall -> \(m["Alert sounds caught"]!.value)")
    precondition(m["Alert sounds caught"]!.range == "49–94%", "Wilson range for 8/10 -> \(m["Alert sounds caught"]!.range)")
    precondition(m["Named correctly"]!.value == "7/8 = 88%", "one 'Horn' for a siren")
    precondition(m["False alarms on harmless sounds"]!.value == "1/4 = 25%", "one shout during talking")
    precondition(m["Time to alert (median)"]!.value.hasPrefix("1.2 s"), "latency -> \(m["Time to alert (median)"]!.value)")
    precondition(m["Correct side"]!.value == "7/8 = 88%", "one arrow on the wrong side -> \(m["Correct side"]!.value)")
    precondition(m["Front/back mix-ups"]!.value == "1/8 = 13%", "the wrong one is a front/back mix-up")
    precondition(m["Vibration delivered"]!.value == "7/8 = 88%" && m["Vibration felt"]!.value == "7/8 = 88%", "vibrations")
    precondition(m["Felt with the phone locked"]!.value == "1/1 = 100%", "the locked trial")
    precondition(m["Alerts that were real"]!.value == "no data" && m["Alerts that were real"]!.pass == nil, "no real runs yet")
    let rows = evalCSVs([s])["trials.csv"]!.split(separator: "\n")
    precondition(rows.count == 15, "header + 14 played trials -> \(rows.count)")
    precondition(csv([["a,b", "say \"hi\""]]) == "\"a,b\",\"say \"\"hi\"\"\"\n", "CSV quoting")
    var rng = SystemRandomNumberGenerator()
    let plan = evalPlan(sounds: ["Siren", "Car horn"], repeats: 3, quiet: ["Talking"], quietCount: 4, meters: 10, lockEvery: 2, using: &rng)
    precondition(plan.count == 28 && plan.filter(\.shouldAlert).count == 24 && plan.filter(\.locked).count == 14, "plan")
    precondition(Side.allCases.allSatisfy { side in plan.filter { $0.sound == "Siren" && $0.side == side }.count == 3 }, "every side 3×")

    // A 30 min test. Horns: 3 right (one pointing wrong, one late) + 1 false alarm; sirens: a real siren named "Siren"
    // pointing right and on time, and one that was really a horn; a dog not marked yet. Flagged: a horn the app caught,
    // a siren it missed.
    func alert(_ s: Double, _ what: String, _ r: EvalAlert.Review?, _ d: EvalAlert.DirectionReview? = nil, _ tm: EvalAlert.TimingReview? = nil,
               off: Double? = nil, late: Double? = nil) -> EvalAlert {
        EvalAlert(at: at(s), what: what, critical: true, azimuth: 180, appState: "foreground", review: r, directionReview: d, timingReview: tm,
                  directionOffBy: off, lateBy: late)
    }
    var test = EvalSession(kind: .realRun, started: t0, ended: at(1800), conditions: EvalConditions())
    // Set by hand: the second horn was really 90° clockwise of the arrow, the fourth 1.2 s late, the misnamed siren 30° off
    // counter-clockwise; the false alarm's numbers don't count.
    test.alerts = [alert(0, "Horn", .real, .right, .onTime), alert(100, "Horn", .real, .wrong, .onTime, off: 90),
                   alert(200, "Horn", .falseAlarm, .wrong, .late, off: 45, late: 3), alert(300, "Horn", .real, .right, .late, late: 1.2),
                   alert(600, "Siren", .real, .right, .onTime), alert(660, "Siren", .wrongSound, .close, .onTime, off: -30), alert(900, "Dog barking", nil)]
    test.marks = [EvalMark(at: at(102), sound: "Car horn"), EvalMark(at: at(1500), sound: "Siren")]
    test.reliability = EvalReliability(listening: 1800, batteryStart: 0.80, batteryEnd: 0.75)
    let tallies = Dictionary(uniqueKeysWithValues: soundTallies(test).map { ($0.sound, $0) })
    let horn = tallies["Horn"]!, siren = tallies["Siren"]!
    precondition(horn.verdicts.right == 3 && horn.verdicts.falseAlarms == 1 && horn.caught == 1, "horns -> \(horn)")
    precondition(horn.verdicts.aimed == 3 && horn.verdicts.timed == 3, "a false alarm's direction and timing don't count")
    precondition(horn.problems == ["false alarms", "direction", "late"], "1 of 4 false, 1 of 3 wrong way, 1 of 3 late -> \(horn.problems)")
    precondition(siren.problems == ["wrong sound", "missed"], "1 of 2 named wrong, a flagged one missed -> \(siren.problems)")
    precondition(tallies["Dog barking"]!.verdicts.unmarked == 1 && !tallies["Dog barking"]!.needsWork, "dog not marked yet")
    precondition(soundTallies(test).last?.sound == "Dog barking", "the ones that need work come first")
    let sum = TestSummary(test), v = sum.verdicts
    precondition(v.real == 5 && v.falseAlarms == 1 && v.right == 4 && v.unmarked == 1 && v.pointedRight == 3 && v.aimed == 5
                 && v.onTime == 4 && v.timed == 5 && sum.eventsCaught == 1 && sum.eventsMissed == 1, "summary -> \(sum)")
    precondition(abs(sum.falsePer10Minutes! - 1.0 / 3) < 1e-9 && abs(sum.batteryPerHour! - 0.1) < 1e-9, "rates -> \(sum)")
    precondition(v.angleErrors.sorted() == [0, 0, 0, 30, 90] && v.lateBys.sorted() == [0, 0, 0, 0, 1.2], "angles and delays -> \(v)")
    precondition(test.alerts[1].trueAzimuth == 90 && test.alerts[5].trueAzimuth == -150, "clockwise = toward the right (smaller azimuth)")
    test.reliability.charging = true
    precondition(TestSummary(test).batteryUsed == nil, "on the charger: battery use doesn't count")
    let files = testCSVs(test), lines = files["timeline.csv"]!.split(separator: "\n")
    precondition(lines.count == 10 && files["by_sound.csv"]!.split(separator: "\n").count == 4,
                 "timeline: header + 7 alerts + 2 events; by sound: header + 3")
    precondition(lines[2].hasPrefix("100.0,") && lines[2].hasSuffix("right,wrong,on time,90,90,"), "sorted, verdicts, really 90° -> \(lines[2])")
    precondition(lines[4].hasSuffix("false alarm,,,,,"), "a false alarm has no direction or timing -> \(lines[4])")
    precondition(lines[5].hasSuffix(",late,,,1200"), "1.2 s late -> \(lines[5])")

    // A danger flagged while replaying, timed by the recording: caught by an alert at the same recording time even though
    // the test was paused before it (so the clock times are 100 s apart); missed when the recording times are far apart.
    var later = EvalAlert(at: at(500), what: "Horn", critical: true, appState: "foreground")
    later.audioAt = 400
    precondition(caught(EvalMark(at: at(400), sound: "Car horn", audioAt: 403, inReplay: true), alerts: [later]), "same recording time: caught")
    precondition(!caught(EvalMark(at: at(500), sound: "Car horn", audioAt: 300, inReplay: true), alerts: [later]), "100 s apart: missed")
    // A dog flagged 5 s after a horn warning wasn't warned about; it is once the horn is marked the wrong sound (it was the
    // dog), and an "other danger" takes any warning.
    let dog = EvalMark(at: at(505), sound: "Dog bark", audioAt: 405, inReplay: true)
    precondition(!caught(dog, alerts: [later]) && caught(EvalMark(at: at(505), sound: "Other danger", audioAt: 405), alerts: [later]), "another sound")
    later.review = .wrongSound
    precondition(caught(dog, alerts: [later]), "marked the wrong sound: it noticed the dog")
    test.marks.append(EvalMark(at: at(1700), sound: "Siren", audioAt: 950, inReplay: true))
    let replayLines = testCSVs(test)["timeline.csv"]!.split(separator: "\n")
    precondition(replayLines[9].hasPrefix("950.0,") && replayLines[9].contains("flagged in replay"), "sorted by recording time -> \(replayLines[9])")
}
