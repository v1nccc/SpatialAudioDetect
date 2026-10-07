import AudioToolbox
import AVFAudio
import CoreHaptics
import Observation
import UIKit
import UserNotifications

/// A vibration rhythm the user edits: "." short tap, "-" long buzz, " " pause.
struct HapticPattern: Codable, Equatable {
    var rhythm: String
    var intensity = 1.0  // 0…1
    var sharpness = 0.5  // 0 = soft rumble, 1 = crisp

    static let presets: [(name: String, rhythm: String)] = [
        ("Three taps, three times", "... ... ..."), ("Three long", "- - -"), ("SOS", "...---..."),
        ("Heartbeat", ".. .. .."), ("One long", "---"), ("Escalating", ". .. ..."),
    ]
}

/// When each pulse of a rhythm starts and how long it lasts, in seconds.
nonisolated func pulses(_ rhythm: String) -> [(start: Double, duration: Double)] {
    var t = 0.0, afterPulse = false, out: [(start: Double, duration: Double)] = []
    for ch in rhythm {
        switch ch {
        case ".", "-":
            if afterPulse { t += 0.1 }
            let d = ch == "." ? 0.08 : 0.3
            out.append((t, d))
            t += d
            afterPulse = true
        case " ":
            t += 0.2
            afterPulse = false
        default:
            continue
        }
    }
    return out
}

/// The ways an iPhone app can make the phone vibrate. Which of them still work with the screen locked
/// is exactly what the haptics test finds out.
enum HapticMethod: String, Codable, CaseIterable, Identifiable {
    case coreHaptics, coreHapticsMicSession, systemBuzz, notification
    var id: Self { self }
    var name: String {
        switch self {
        case .coreHaptics: "Custom pattern"
        case .coreHapticsMicSession: "Custom pattern (mic's audio session)"
        case .systemBuzz: "System buzz (rhythm only)"
        case .notification: "Notification"
        }
    }
}

struct HapticSettings: Codable, Equatable {
    var horn = HapticPattern(rhythm: "... ... ...", intensity: 1, sharpness: 0.9)
    var approach = HapticPattern(rhythm: "- - -", intensity: 1, sharpness: 0.3)
    var method = HapticMethod.coreHaptics
    var notifyWhenAway = true  // also post a notification for a warning while the app isn't on screen

    static func load() -> HapticSettings {
        UserDefaults.standard.data(forKey: "haptics").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? HapticSettings()
    }

    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "haptics") }
}

/// "foreground" / "background", plus ", locked" once the locked phone's data protection kicks in.
func appState() -> String {
    let app = UIApplication.shared
    let state = switch app.applicationState {
    case .active: "foreground"
    case .inactive: "inactive"
    case .background: "background"
    @unknown default: "unknown"
    }
    return app.isProtectedDataAvailable ? state : state + ", locked"
}

/// Plays a pattern by one of the methods and reports what iOS answered (not whether it was felt).
@Observable final class Haptics {
    private(set) var engineStatus = "not started"
    @ObservationIgnored var onLog: ((String) -> Void)?
    @ObservationIgnored private var engines: [Bool: CHHapticEngine] = [:]  // keyed by "on the mic's audio session"

    init() {
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    /// Ask now, while someone is looking: from a locked phone the permission prompt can't be answered.
    func askForNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// iOS mutes haptics and system sounds while an app records, unless the app opts in. The capture session can
    /// reconfigure the audio session at any time, so this is repeated before every vibration.
    @discardableResult
    func allowWhileRecording() -> String? {
        do {
            try AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The audio facts that decide whether a vibration can be felt right now.
    var audioFacts: String {
        let s = AVAudioSession.sharedInstance()
        guard s.category == .playAndRecord || s.category == .record else { return "mic not recording" }
        return s.allowHapticsAndSystemSoundsDuringRecording ? "mic recording, haptics allowed" : "mic recording, haptics MUTED by iOS"
    }

    /// Plays and reports what iOS answered plus the audio state at that moment.
    func play(_ p: HapticPattern, title: String, body: String, via method: HapticMethod) async -> (ok: Bool, detail: String) {
        let optIn = allowWhileRecording()
        let r = switch method {
        case .coreHaptics: coreHaptics(p, micSession: false)
        case .coreHapticsMicSession: coreHaptics(p, micSession: true)
        case .systemBuzz: systemBuzz(p)
        case .notification: await notify(title: title, body: body)
        }
        return (r.ok, r.detail + " · " + audioFacts + (optIn.map { " (opt-in failed: \($0))" } ?? ""))
    }

    private func coreHaptics(_ p: HapticPattern, micSession: Bool) -> (ok: Bool, detail: String) {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return (false, "not supported on this device") }
        do {
            let engine = try engine(micSession: micSession)
            try engine.start()  // restarts it if iOS stopped it
            let params = [CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(p.intensity)),
                          CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(p.sharpness))]
            let events = pulses(p.rhythm).flatMap { pulse in
                [CHHapticEvent(eventType: .hapticTransient, parameters: params, relativeTime: pulse.start),
                 CHHapticEvent(eventType: .hapticContinuous, parameters: params, relativeTime: pulse.start, duration: pulse.duration)]
            }
            try engine.makePlayer(with: CHHapticPattern(events: events, parameters: [])).start(atTime: CHHapticTimeImmediate)
            return (true, "played")
        } catch {
            return (false, "failed: " + describe(error))
        }
    }

    private func engine(micSession: Bool) throws -> CHHapticEngine {
        if let e = engines[micSession] { return e }
        let e = micSession ? try CHHapticEngine(audioSession: .sharedInstance()) : try CHHapticEngine()
        e.playsHapticsOnly = true
        e.isAutoShutdownEnabled = false
        e.stoppedHandler = { @Sendable [weak self] reason in
            guard let self else { return }
            Task { @MainActor in self.note("haptic engine\(micSession ? " (mic session)" : "") stopped: \(Self.why(reason))") }
        }
        e.resetHandler = { @Sendable [weak self] in
            guard let self else { return }
            Task { @MainActor in self.note("haptic engine reset by iOS") }
        }
        engines[micSession] = e
        return e
    }

    /// The system's own fixed ~0.4 s vibration, once per pulse; it can't be shorter, so pulses are spaced ≥ 0.5 s.
    private func systemBuzz(_ p: HapticPattern) -> (ok: Bool, detail: String) {
        var at = -1.0
        let times = pulses(p.rhythm).map { pulse in
            at = max(pulse.start, at + 0.5)
            return at
        }
        for t in times {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
        }
        return (!times.isEmpty, "requested \(times.count) buzz\(times.count == 1 ? "" : "es")")
    }

    /// Vibrates with the phone's own notification vibration, not the rhythm.
    private func notify(title: String, body: String) async -> (ok: Bool, detail: String) {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return (false, "notifications not allowed") }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return (true, "posted")
        } catch {
            return (false, "failed: \(error.localizedDescription)")
        }
    }

    private func note(_ message: String) {
        engineStatus = message
        onLog?(message)
    }

    private nonisolated static func why(_ reason: CHHapticEngine.StoppedReason) -> String {
        switch reason {
        case .applicationSuspended: "app suspended"
        case .audioSessionInterrupt: "audio session interrupted"
        case .idleTimeout: "idle timeout"
        case .systemError: "system error"
        case .notifyWhenFinished: "finished"
        case .engineDestroyed: "engine destroyed"
        case .gameControllerDisconnect: "controller disconnected"
        @unknown default: "reason \(reason.rawValue)"
        }
    }

    private func describe(_ error: Error) -> String {
        let code = (error as NSError).code
        let names = [-4805: "engine not running", -4806: "operation not permitted", -4808: "engine start timed out",
                     -4809: "not supported", -4810: "server init failed", -4811: "server interrupted", -4897: "insufficient power"]
        return "\(names[code] ?? (error as NSError).localizedDescription) (\(code))"
    }
}

/// Shows notifications even while the app is on screen, so the test treats every round the same.
nonisolated final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// "Why can't I feel it?": plays one thing at a time, with the mic on and then paused, asks after each,
/// and names the cause that fits the answers.
@Observable final class HapticCheck {
    struct Step: Identifiable {
        let id: Int
        let name: String
        let method: HapticMethod
        let pattern: HapticPattern?  // nil = the user's horn pattern
        let micOn: Bool
        var result = ""
        var felt: Bool?
    }

    static let strongBuzz = HapticPattern(rhythm: "---", intensity: 1, sharpness: 0.5)
    private(set) var steps: [Step] = []
    private(set) var current: Int?  // the step waiting for "felt it?"
    private var wasPaused: Bool?     // your pause state before the check, put back afterwards

    func begin(_ radar: SoundRadar, settings: HapticSettings) {
        wasPaused = radar.paused
        steps = [
            Step(id: 1, name: "Strong buzz · custom pattern · mic on", method: .coreHaptics, pattern: Self.strongBuzz, micOn: true),
            Step(id: 2, name: "Your horn pattern · custom pattern · mic on", method: .coreHaptics, pattern: nil, micOn: true),
            Step(id: 3, name: "System vibration · mic on", method: .systemBuzz, pattern: HapticPattern(rhythm: "-"), micOn: true),
            Step(id: 4, name: "Strong buzz · custom pattern · mic paused", method: .coreHaptics, pattern: Self.strongBuzz, micOn: false),
            Step(id: 5, name: "System vibration · mic paused", method: .systemBuzz, pattern: HapticPattern(rhythm: "-"), micOn: false),
        ]
        Task { await play(0, radar, settings) }
    }

    func play(_ i: Int, _ radar: SoundRadar, _ settings: HapticSettings) async {
        current = nil
        let step = steps[i]
        if radar.paused == step.micOn {
            radar.setPaused(!step.micOn)
            try? await Task.sleep(for: .seconds(1.5))  // let the mic actually stop / start
        }
        let r = await radar.haptics.play(step.pattern ?? settings.horn, title: "Haptics check", body: step.name, via: step.method)
        steps[i].result = r.detail
        current = i
    }

    func answer(_ felt: Bool, _ radar: SoundRadar, _ settings: HapticSettings) {
        guard let i = current else { return }
        steps[i].felt = felt
        if i + 1 < steps.count {
            Task { await play(i + 1, radar, settings) }
        } else {
            current = nil
            abandon(radar)
        }
    }

    /// Done or walked away from: put the mic back the way it was.
    func abandon(_ radar: SoundRadar) {
        guard let wasPaused else { return }
        radar.setPaused(wasPaused)
        self.wasPaused = nil
    }

    var conclusion: String? {
        guard !steps.isEmpty, steps.allSatisfy({ $0.felt != nil }) else { return nil }
        return diagnose(felt: steps.map { $0.felt == true }, results: steps.map(\.result))
    }

    var report: String {
        (["Haptics check · \(Date.now.formatted(date: .abbreviated, time: .shortened))"]
            + steps.map { "\($0.id). \($0.name) → \($0.result) → felt: \($0.felt.map { $0 ? "yes" : "no" } ?? "?")" }
            + [conclusion ?? ""]).joined(separator: "\n")
    }
}

/// A timed field test: every few seconds try the next method, log what iOS said, whether the phone was locked
/// and whether the mic was still running; the tester marks or counts what they actually felt.
@Observable final class HapticTest {
    static let placements = ["Hand", "Pocket", "Armband", "Shoulder strap"]
    static let activities = ["Still", "Walking", "Running", "Cycling"]

    struct Attempt: Identifiable {
        let id = UUID()
        var round: Int
        var time: Date
        var method: HapticMethod
        var category: String
        var appState: String
        var mic: String
        var ok: Bool
        var result: String
        var feltTaps = 0
    }

    var placement = "Pocket"
    var activity = "Running"
    var methods = Set(HapticMethod.allCases)
    var interval = 15.0
    var rounds = 12
    var felt: [HapticMethod: Int] = [:]  // counted by the tester afterwards (e.g. it was locked in a pocket)
    private(set) var attempts: [Attempt] = []
    private(set) var running = false
    private(set) var nextAt: Date?
    private(set) var startedAt: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Each round uses the next method; horn and getting-closer patterns alternate per full cycle of methods.
    func start(_ haptics: Haptics, settings: HapticSettings, mic: @escaping () -> String) {
        let order = HapticMethod.allCases.filter(methods.contains)
        guard !order.isEmpty else { return }
        attempts = []
        felt = [:]
        startedAt = .now
        running = true
        let (rounds, interval) = (rounds, interval)
        task = Task { [weak self] in
            if order.contains(.notification) { await haptics.askForNotifications() }
            for round in 0..<rounds {
                self?.nextAt = .now + interval
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { break }
                let method = order[round % order.count], horn = (round / order.count) % 2 == 0
                let state = appState(), micState = mic()
                let result = await haptics.play(horn ? settings.horn : settings.approach, title: "Haptic test, round \(round + 1)",
                                                body: "\(method.name) · \(horn ? "horn" : "getting closer")", via: method)
                attempts.append(Attempt(round: round + 1, time: .now, method: method, category: horn ? "horn/siren" : "getting closer",
                                        appState: state, mic: micState, ok: result.ok, result: result.detail))
            }
            self?.finish()
        }
    }

    func stop() {
        task?.cancel()
        finish()
    }

    /// Tapped right after feeling one (phone in hand): credits the round that just played.
    func feltIt() {
        guard let i = attempts.indices.last, Date.now.timeIntervalSince(attempts[i].time) < 8 else { return }
        attempts[i].feltTaps += 1
    }

    var report: String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        let used = HapticMethod.allCases.filter(methods.contains)
        var lines = ["Haptics test · \(startedAt?.formatted(date: .abbreviated, time: .shortened) ?? "") · \(activity) · \(placement) · every \(Int(interval)) s"]
        lines += attempts.map {
            "#\($0.round) \(time.string(from: $0.time)) \($0.method.name) · \($0.category) · \($0.appState) · mic \($0.mic) → \($0.result)"
                + ($0.feltTaps > 0 ? " · felt" : "")
        }
        lines.append("Felt, counted afterwards: " + used.map { m in
            "\(m.name) \(felt[m] ?? 0)/\(attempts.filter { $0.method == m }.count)"
        }.joined(separator: " · "))
        return lines.joined(separator: "\n")
    }

    private func finish() {
        task = nil
        running = false
        nextAt = nil
    }
}

/// Which cause fits the answers to the five check steps (strong buzz, your pattern, system buzz with the mic on;
/// strong buzz, system buzz with the mic paused).
nonisolated func diagnose(felt: [Bool], results: [String]) -> String {
    if !felt.contains(true) {
        if results.contains(where: { $0.contains("not supported") }) { return "This device has no vibration hardware." }
        return "Nothing at all, even with the mic paused and iOS saying it played: the iPhone's vibration is probably switched off. Check Settings › Accessibility › Touch › Vibration and Settings › Sounds & Haptics › System Haptics."
    }
    if !felt[0] && !felt[2] && (felt[3] || felt[4]) {
        return "It only vibrates with the mic paused: iOS mutes vibration while the app records. During the mic-on steps: \(results[0])."
    }
    if !felt[0] && felt[2] { return "The system vibration works but Core Haptics doesn't: \(results[0])." }
    if felt[0] && !felt[1] { return "The strong buzz works but your horn pattern is too faint: raise Strength or use long buzzes (-)." }
    if felt[0] && felt[1] && felt[2] { return "Vibration works with the mic on. Next: the locked / background test below." }
    return "Mixed result: compare the steps above."
}

nonisolated func hapticsSelfCheck() {
    let ok = Array(repeating: "played", count: 5)
    precondition(diagnose(felt: [false, false, false, false, false], results: ok).contains("switched off"), "nothing felt -> settings")
    precondition(diagnose(felt: [false, false, false, true, true], results: ok).contains("mic paused"), "only with mic paused -> recording mutes")
    precondition(diagnose(felt: [false, false, true, false, true], results: ok).contains("Core Haptics doesn't"), "only system buzz -> Core Haptics")
    precondition(diagnose(felt: [true, false, true, true, true], results: ok).contains("too faint"), "strong yes, pattern no -> pattern")
    precondition(diagnose(felt: [true, true, true, true, true], results: ok).contains("works with the mic on"), "all felt -> fine")

    let p = pulses("-. .")
    precondition(p.count == 3, "three pulses -> \(p)")
    precondition(p[0].start == 0 && p[0].duration == 0.3, "long buzz first -> \(p[0])")
    precondition(abs(p[1].start - 0.4) < 1e-9 && p[1].duration == 0.08, "short tap after a 0.1 s gap -> \(p[1])")
    precondition(abs(p[2].start - 0.68) < 1e-9, "a space adds a 0.2 s pause -> \(p[2])")
    precondition(pulses("ab?").isEmpty, "other characters are ignored")
}
