import Foundation
import simd

/// One debug session in Documents/Recordings/<date time>/ (also visible in the Files app):
/// audio.caf    raw 4-channel ambisonics, exactly what the mics delivered (written by the capture tap)
/// blocks.csv   every audio block (~47/s) and every number computed from it
/// verdicts.csv every classifier verdict (4/s) with Apple's raw top labels
/// events.txt   the decisions log
final class Recorder {
    static let blockColumns = ["t", "duration", "db", "directness", "azimuth", "loudness", "strength",
                               "W_db", "X_db", "Y_db", "Z_db"]
        + phoneSides.map { $0.name.lowercased().replacingOccurrences(of: " ", with: "_") + "_db" }
        + ["gx", "gy", "gz", "kind", "alert", "audio_saved"]

    let folder: URL, audio: URL, startedAt: Double
    private let blocks: FileHandle, verdicts: FileHandle, events: FileHandle

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
        verdicts = try open("verdicts.csv", "start,end,received,kind,label,alert_score,top_labels\n")
        events = try open("events.txt", "")
        folder = dir
        audio = dir.appending(path: "audio.caf")
        self.startedAt = startedAt
    }

    var files: [URL] {
        ["audio.caf", "blocks.csv", "verdicts.csv", "events.txt"].map { folder.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    func block(_ b: Block, gravity g: SIMD3<Double>, azimuth: Double?, loudness: Double, strength: Double,
               kind: SoundKind, alert: Alert?) {
        let r = b.reading
        func f(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }
        func db(_ p: Double) -> String { f(10 * log10(max(p, 1e-12))) }
        let cols = [f(b.start, 3), f(b.duration, 4), f(r.db), f(r.directness, 3), azimuth.map { f($0) } ?? "",
                    f(loudness, 3), f(strength, 3), db(r.ww), db(r.xx), db(r.yy), db(r.zz)]
            + phoneSides.map { f(r.micDB($0)) }
            + [f(g.x, 3), f(g.y, 3), f(g.z, 3), "\(kind)", alert?.what ?? "", b.savingAudio ? "1" : "0"]
        assert(cols.count == Self.blockColumns.count, "blocks.csv row doesn't match its header")
        write(blocks, cols.joined(separator: ","))
    }

    func verdict(_ h: Heard, received: Double) {
        let top = h.top.map { "\($0.id):\(String(format: "%.2f", $0.confidence))" }.joined(separator: " ")
        write(verdicts, [String(format: "%.3f", h.start), String(format: "%.3f", h.end), String(format: "%.3f", received),
                         "\(h.kind)", h.label, String(format: "%.3f", h.alertScore), top].joined(separator: ","))
    }

    func event(_ line: String) { write(events, line) }

    func close() {
        for h in [blocks, verdicts, events] { try? h.close() }
    }

    private func write(_ h: FileHandle, _ line: String) {
        try? h.write(contentsOf: Data((line + "\n").utf8))
    }
}
