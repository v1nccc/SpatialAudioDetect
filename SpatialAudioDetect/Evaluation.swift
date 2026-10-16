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
    nonisolated enum Review: String, Codable, CaseIterable, Sendable { case real = "Real", falseAlarm = "False alarm", unsure = "Not sure" }
    var id = UUID()
    var at: Date
    var what: String
    var critical: Bool
    var azimuth: Double?          // when it started
    var settledAzimuth: Double?   // ~1 s later (the alert follows its sound)
    var appState: String
    var haptic: String?           // what iOS answered for its first vibration
    var hapticOK: Bool?
    var review: Review?           // real runs: was it a real danger?
    var direction: Double? { settledAzimuth ?? azimuth }
}

/// A real-run event someone noticed (siren, horn…), to check the app caught it.
nonisolated struct EvalMark: Codable, Identifiable, Sendable {
    var id = UUID()
    var at: Date
    var sound: String
    var note = ""
}

nonisolated struct EvalReliability: Codable, Sendable {
    var listening = 0.0, recognitionDown = 0.0, micTrouble = 0.0  // seconds
    var restarts = 0
    var batteryStart: Double?, batteryEnd: Double?                // 0…1
    var hottest = "normal"
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
    var played: [EvalTrial] { trials.filter { $0.at != nil } }
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

/// A real-run mark counts as caught if an alert came within 8 s either side of it.
nonisolated func caught(_ m: EvalMark, alerts: [EvalAlert]) -> Bool {
    alerts.contains { abs($0.at.timeIntervalSince(m.at)) <= 8 }
}

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
    share(g4, "Alerts that were real", reviewed.filter { $0 == .real }.count, reviewed.count, atLeast: 0.8,
          "Of the alerts you reviewed after the run, how many were a real danger (precision).")
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
        guard let a = s.reliability.batteryStart, let b = s.reliability.batteryEnd, s.reliability.listening > 300 else { return nil }
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
}
