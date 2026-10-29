import Foundation
import simd

/// One debug session in Documents/Recordings/<date time>/ (also visible in the Files app):
/// audio.caf    raw 4-channel ambisonics, exactly what the mics delivered (written by the capture tap; optional)
/// listen.m4a   the all-around channel as AAC, to listen back to (~0.5 MB per minute)
/// blocks.csv   every audio block (~47/s) and every number computed from it
/// verdicts.csv every classifier verdict (4/s) with Apple's raw top labels
/// events.txt   the decisions log, including "SHOWN" lines: each warning on screen as it starts, turns, ends
/// warnings.csv the same warnings as a spreadsheet: time into the recording, what, level, direction (degrees and words)
/// display.jsonl what the main screen showed, ~10 times a second, timed to the audio (to replay a test as it looked)
final class Recorder {
    static let blockColumns = ["t", "duration", "db", "directness", "raw_azimuth", "heading_correction", "azimuth",
                               "hum_db", "usual_db", "loudness", "strength", "W_db", "X_db", "Y_db", "Z_db"]
        + phoneSides.map { $0.name.lowercased().replacingOccurrences(of: " ", with: "_") + "_db" }
        + ["gx", "gy", "gz", "yaw_rate", "kind", "alert", "alert_azimuth", "audio_saved"]

    let folder: URL, audio: URL, listen: URL, startedAt: Double
    private let blocks: FileHandle, verdicts: FileHandle, events: FileHandle, display: FileHandle, warnings: FileHandle
    private var audioStart: Double?  // stream time of the recording's first audio sample
    private let encoder = JSONEncoder()

    init(startedAt: Double) throws {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let dir = URL.documentsDirectory.appending(path: "Recordings/\(stamp.string(from: .now))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func open(_ name: String, _ header: String) throws -> FileHandle {
            let url = dir.appending(path: name)
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data(header.utf8))
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            return h
        }
        blocks = try open("blocks.csv", Self.blockColumns.joined(separator: ",") + "\n")
        verdicts = try open("verdicts.csv", "start,end,received,kind,label,alert_score,top_labels,source\n")
        events = try open("events.txt", "")
        display = try open("display.jsonl", "")
        warnings = try open("warnings.csv", "recording_s,event,what,level,azimuth,direction,method\n")
        folder = dir
        audio = dir.appending(path: "audio.caf")
        listen = dir.appending(path: "listen.m4a")
        self.startedAt = startedAt
    }

    var files: [URL] {
        ["audio.caf", "listen.m4a", "blocks.csv", "verdicts.csv", "events.txt", "warnings.csv", "display.jsonl"].map { folder.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// Seconds into the recording's audio at stream time `t` (stream time counts only audio that arrived, like the
    /// audio file, so it stays exact across pauses); nil before any audio was saved.
    func audioTime(_ t: Double) -> Double? { audioStart.map { t - $0 } }

    func screen(_ frame: ScreenFrame) {
        guard let line = try? encoder.encode(frame) else { return }
        try? display.write(contentsOf: line + Data("\n".utf8))
    }

    func block(_ p: Processed, kind: SoundKind, alert: Alert?) {
        let b = p.block, r = b.reading, g = p.motion.gravity
        if audioStart == nil, b.savingAudio { audioStart = b.start }
        func f(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }
        func db(_ p: Double) -> String { f(10 * log10(max(p, 1e-12))) }
        func opt(_ v: Double?) -> String { v.map { f($0) } ?? "" }
        let signal: [String] = [f(b.start, 3), f(b.duration, 4), f(r.db), f(r.directness, 3), opt(p.rawAzimuth),
                                f(p.correction), opt(p.azimuth), opt(p.hum), opt(p.usual), f(p.loudness, 3), f(p.strength, 3)]
        let channels: [String] = [db(r.ww), db(r.xx), db(r.yy), db(r.zz)] + phoneSides.map { f(r.micDB($0)) }
        let rest: [String] = [f(g.x, 3), f(g.y, 3), f(g.z, 3), f(p.motion.yawRate, 4), "\(kind)", alert.map { "\($0.level == .critical ? "critical" : "warning"): \($0.what)" } ?? "",
                              opt(alert?.azimuth), b.savingAudio ? "1" : "0"]
        let cols = signal + channels + rest
        assert(cols.count == Self.blockColumns.count, "blocks.csv row doesn't match its header")
        write(blocks, cols.joined(separator: ","))
    }

    func verdict(_ h: Heard, received: Double) {
        let top = h.top.map { "\($0.id):\(String(format: "%.2f", $0.confidence))" }.joined(separator: " ")
        write(verdicts, [String(format: "%.3f", h.start), String(format: "%.3f", h.end), String(format: "%.3f", received),
                         "\(h.kind)", h.label, String(format: "%.3f", h.alertScore), top,
                         h.beam.map { beamNames[$0] } ?? "all-around"].joined(separator: ","))
    }

    func event(_ line: String) { write(events, line) }

    /// A warning on screen started, turned or ended (WarningLog), at `t` seconds into the recording.
    func warning(_ event: WarningLog.Event, _ a: Alert, method: String, at t: Double?) {
        let row = [t.map { String(format: "%.2f", $0) } ?? "", event.rawValue, a.what, a.level == .critical ? "critical" : "warning",
                   a.azimuth.map { String(Int($0.rounded())) } ?? "", directionWords(a.azimuth), method]
        try? warnings.write(contentsOf: Data(csv([row]).utf8))
    }

    func close() {
        for h in [blocks, verdicts, events, display, warnings] { try? h.close() }
    }

    private func write(_ h: FileHandle, _ line: String) {
        try? h.write(contentsOf: Data((line + "\n").utf8))
    }
}

/// What the main screen showed at one moment of a recording (display.jsonl), to replay a test as it looked live.
nonisolated struct ScreenFrame: Codable, Sendable {
    var t: Double                          // seconds into the recording's audio
    var alert: Alert?
    var kind: SoundKind
    var traffic: Double?, people: Double?  // where most traffic / people sound was ("mostly behind you")
    var recognitionDown: Bool?             // only when true
    var lines: String                      // the radar's lit lines, "index:percent:kind" (a/t/p/o), space-separated

    init(t: Double, alert: Alert?, kind: SoundKind, bins: [Bin], traffic: Double?, people: Double?, recognitionDown: Bool) {
        self.t = (t * 100).rounded() / 100
        self.alert = alert.map { var a = $0; a.azimuth = a.azimuth?.rounded(); return a }
        self.kind = kind
        self.traffic = traffic?.rounded()
        self.people = people?.rounded()
        self.recognitionDown = recognitionDown ? true : nil
        lines = bins.enumerated().compactMap { i, b in
            let percent = Int((b.strength * 100).rounded())
            return percent > 0 ? "\(i):\(percent):\(b.kind.rawValue.prefix(1))" : nil
        }.joined(separator: " ")
    }

    /// The radar's 72 lines.
    var bins: [Bin] {
        var out = [Bin](repeating: Bin(), count: 72)
        for line in lines.split(separator: " ") {
            let f = line.split(separator: ":")
            guard f.count == 3, let i = Int(f[0]), out.indices.contains(i), let percent = Double(f[1]) else { continue }
            out[i] = Bin(strength: percent / 100, kind: SoundKind.allCases.first { $0.rawValue.prefix(1) == f[2] } ?? .other)
        }
        return out
    }
}

/// A recording's screen track; empty if it has none (recorded before there was one).
nonisolated func screenFrames(_ url: URL) -> [ScreenFrame] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let decoder = JSONDecoder()
    return text.split(separator: "\n").compactMap { try? decoder.decode(ScreenFrame.self, from: Data($0.utf8)) }
}

/// The frame on screen at `t`: the last one at or before it.
nonisolated func screenFrame(at t: Double, in frames: [ScreenFrame]) -> ScreenFrame? {
    var lo = 0, hi = frames.count  // first frame after t
    while lo < hi {
        let mid = (lo + hi) / 2
        if frames[mid].t <= t { lo = mid + 1 } else { hi = mid }
    }
    return lo > 0 ? frames[lo - 1] : nil
}

nonisolated func screenFrameSelfCheck() {
    var bins = [Bin](repeating: Bin(), count: 72)
    bins[10] = Bin(strength: 0.8, kind: .traffic)
    bins[11] = Bin(strength: 0.004, kind: .traffic)  // too faint to draw: left out
    bins[70] = Bin(strength: 0.456, kind: .alert)
    let f = ScreenFrame(t: 12.3456, alert: Alert(azimuth: 172.6, what: "Horn", level: .critical, short: "Horn"), kind: .alert, bins: bins,
                        traffic: 181.2, people: nil, recognitionDown: false)
    let json = String(decoding: try! JSONEncoder().encode(f), as: UTF8.self)
    precondition(!json.contains("recognitionDown") && !json.contains("people") && json.count < 220, "compact -> \(json)")
    let back = try! JSONDecoder().decode(ScreenFrame.self, from: Data(json.utf8))
    precondition(back.t == 12.35 && back.alert?.azimuth == 173 && back.alert?.what == "Horn" && back.alert?.level == .critical
                 && back.kind == .alert && back.traffic == 181, "round trip -> \(back)")
    let lit = back.bins.enumerated().filter { $0.element.strength > 0 }
    precondition(lit.map(\.offset) == [10, 70] && lit[0].element.kind == .traffic && abs(lit[1].element.strength - 0.46) < 1e-9
                 && lit[1].element.kind == .alert, "lines -> \(back.lines)")
    let frames = [0.0, 0.1, 0.2, 0.3].map { ScreenFrame(t: $0, alert: nil, kind: .other, bins: [], traffic: nil, people: nil, recognitionDown: false) }
    precondition(screenFrame(at: -0.05, in: frames) == nil && screenFrame(at: 0.15, in: frames)?.t == 0.1 && screenFrame(at: 9, in: frames)?.t == 0.3, "lookup")
}

/// The warning on screen, as the runner gets it: logged when it starts, each time its direction turns by 20° or more
/// (it follows its sound every block), and when it ends, with the direction it showed last.
nonisolated struct WarningLog {
    nonisolated enum Event: String, Sendable { case started, turned, ended }
    static let turnDegrees = 20.0
    private var logged: Alert?  // as last written
    private var shown: Alert?   // as on screen now

    /// What changed since the last call, if worth a line.
    mutating func update(_ a: Alert?) -> (event: Event, alert: Alert)? {
        defer { shown = a }
        guard let a else {
            guard let last = shown ?? logged else { return nil }
            logged = nil
            return (.ended, last)
        }
        guard let old = logged, old.what == a.what, old.level == a.level else {
            logged = a
            return (.started, a)
        }
        let turned = switch (old.azimuth, a.azimuth) {
        case let (x?, y?): angularDistance(x, y) >= Self.turnDegrees
        case (nil, nil): false
        default: true  // gained or lost its direction
        }
        guard turned else { return nil }
        logged = a
        return (.turned, a)
    }

    /// The decisions-log line: "SHOWN (Sound Radar): Watch out, Horn, 135° behind on your left".
    static func line(_ e: Event, _ a: Alert, method: String) -> String {
        let at = a.azimuth.map { "\(Int($0.rounded()))° \(directionWords($0))" } ?? "direction unclear"
        return switch e {
        case .started: "SHOWN (\(method)): \(a.level == .critical ? "Watch out" : "Heads up"), \(a.what), \(at)"
        case .turned: "SHOWN (\(method)): \(a.what) turned to \(at)"
        case .ended: "SHOWN (\(method)): \(a.what) ended, last \(at)"
        }
    }
}

nonisolated func warningLogSelfCheck() {
    func horn(_ az: Double?, _ level: AlertLevel = .critical) -> Alert { Alert(azimuth: az, what: "Horn", level: level, short: "Horn") }
    var w = WarningLog()
    precondition(w.update(nil) == nil, "nothing on screen: nothing to log")
    precondition(w.update(horn(135))?.event == .started, "starts")
    precondition(w.update(horn(145)) == nil && w.update(horn(150)) == nil, "following its sound by a few degrees: no line")
    let turn = w.update(horn(172))
    precondition(turn?.event == .turned && turn?.alert.azimuth == 172, "37° from the logged 135°: turned")
    precondition(w.update(horn(-170)) == nil, "across ±180°: 18° from 172°, not a turn")
    precondition(w.update(horn(nil))?.event == .turned, "lost its direction")
    precondition(w.update(horn(nil, .warning))?.event == .started, "a different level is a new warning")
    _ = w.update(horn(170, .warning))
    _ = w.update(horn(172, .warning))
    let end = w.update(nil)
    precondition(end?.event == .ended && end?.alert.azimuth == 172, "ends with the direction it showed last -> \(String(describing: end))")
    precondition(w.update(nil) == nil, "ended once")
    precondition(WarningLog.line(.started, horn(135), method: "Sound Radar") == "SHOWN (Sound Radar): Watch out, Horn, 135° behind on your left",
                 WarningLog.line(.started, horn(135), method: "Sound Radar"))
}
