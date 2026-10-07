import AVFoundation

// Replays 4-channel ambisonic audio through the app's own pipeline (Detector.swift + SoundClassifier.swift)
// on a Mac, so warnings can be counted and thresholds tuned on real street audio. From the project folder:
//
//   swiftc -O SpatialAudioDetect/Detector.swift SpatialAudioDetect/SoundClassifier.swift Tools/replay.swift -o /tmp/replay
//   /tmp/replay <recording folder>   a walk recorded with Debug › Record session (audio.caf + blocks.csv)
//   /tmp/replay --street             a synthetic 90 s street where the right answer is known
//   /tmp/replay --selfcheck          the app's self-check


final class Verdicts: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Heard] = []
    func add(_ h: Heard) { lock.lock(); items.append(h); lock.unlock() }
    var all: [Heard] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Runs every block through the classifier and the Detector in the order they'd happen live, then prints a summary.
func replay(_ name: String, next: () -> AVAudioPCMBuffer?, motion: (Double) -> Motion) {
    var maker = BlockMaker()
    let classifier = SoundClassifier(), verdicts = Verdicts()
    classifier.onResult = { verdicts.add($0) }
    var blocks: [Block] = []
    while let buf = next() {
        let made = maker.make(buf)
        blocks.append(made.block)
        classifier.feed(made.omni, sampleRate: buf.format.sampleRate, at: made.at)
    }
    classifier.finish()
    let heard = verdicts.all.sorted { $0.end < $1.end }

    var d = Detector(), v = 0, lit = 0, log: [String] = []
    var onsets: [(t: Double, what: String, azimuth: Double?)] = []
    func step(_ change: (inout Detector) -> Void) {
        let before = d.alert
        change(&d)
        if let a = d.alert, a.what != before?.what { onsets.append((d.clock, a.what, a.azimuth)) }
        log += d.pendingLog
        d.clearPendingLog()
    }
    for b in blocks {
        while v < heard.count, heard[v].end + 0.12 <= b.start {  // verdicts arrive ~0.12 s after their window live
            let h = heard[v]
            step { $0.hear(h) }
            v += 1
        }
        step { $0.add(b, motion: motion(b.start)) }
        lit += d.bins.filter { $0.strength > 0.1 }.count
    }

    func at(_ az: Double?) -> String { az.map { "\(Int($0.rounded()))° \(sectorNames[slot($0, of: 8)])" } ?? "?" }
    print("== \(name): \(String(format: "%.1f", d.clock)) s, \(blocks.count) blocks, \(heard.count) classifier verdicts")
    print(String(format: "Watch out: %d onsets, %.1f per minute", onsets.count, Double(onsets.count) / max(d.clock / 60, 1e-9)))
    for what in Set(onsets.map(\.what)).sorted() {
        let these = onsets.filter { $0.what == what }
        print("  \(what) ×\(these.count): " + these.map { String(format: "%.1fs ", $0.t) + at($0.azimuth) }.joined(separator: ", "))
    }
    let notWarned = log.filter { $0.contains("not warned") }
    print("Not warned (filtered out): \(notWarned.count)")
    notWarned.forEach { print("  " + $0) }
    print(String(format: "Radar: %.1f of 72 spokes lit on average", Double(lit) / Double(max(blocks.count, 1))))
}

/// A recording made with Debug › Record session: audio.caf, plus phone motion per block from blocks.csv.
func recording(_ folder: URL) throws -> (next: () -> AVAudioPCMBuffer?, motion: (Double) -> Motion) {
    let file = try AVAudioFile(forReading: folder.appending(path: "audio.caf"))
    let format = file.processingFormat
    let next = { () -> AVAudioPCMBuffer? in
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024),
              (try? file.read(into: buf, frameCount: 1024)) != nil, buf.frameLength > 0 else { return nil }
        return buf
    }
    var rows: [(t: Double, m: Motion)] = []
    if let text = try? String(contentsOf: folder.appending(path: "blocks.csv"), encoding: .utf8) {
        let lines = text.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        if let h = lines.first, let it = h.firstIndex(of: "t"),
           let gx = h.firstIndex(of: "gx"), let gy = h.firstIndex(of: "gy"), let gz = h.firstIndex(of: "gz") {
            let yaw = h.firstIndex(of: "yaw_rate"), saved = h.firstIndex(of: "audio_saved")
            rows = lines.dropFirst().compactMap { r in
                guard r.count == h.count, saved.map({ r[$0] == "1" }) ?? true,
                      let t = Double(r[it]), let x = Double(r[gx]), let y = Double(r[gy]), let z = Double(r[gz]) else { return nil }
                return (t, Motion(gravity: SIMD3(x, y, z), yawRate: yaw.flatMap { Double(r[$0]) } ?? 0))
            }
        }
    }
    let t0 = rows.first?.t ?? 0  // the first block whose audio was saved = replay time 0
    var i = 0
    let motion = { (t: Double) -> Motion in
        guard !rows.isEmpty else { return Motion() }
        while i + 1 < rows.count, rows[i + 1].t - t0 <= t + 1e-6 { i += 1 }
        return rows[i].m
    }
    return (next, motion)
}

/// Deterministic noise in -1…1.
struct SplitMix {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 52) - 1
    }
}

let streetTruth = """
Truth: diffuse traffic hum and wind gusts all the time; the arm swings ±25° at 1.5 Hz.
  Road cars pass 4 m to the right every 7 s: from behind (behind-right) at 4, 18, 32, 46, 60, 74, 88 s,
  from ahead (ahead-right) at 11, 25, 39, 53, 67, 81 s. Ordinary traffic: ideally no warnings.
  A vehicle comes up the runner's own path from behind and passes at 62 s: should warn, behind.
  A 0.4 s horn from behind-left at 40 s: should warn, ~135°.
"""

/// A synthetic street, as the iPhone would deliver it (ACN/SN3D, 48 kHz, 1024-frame blocks).
func street() -> (next: () -> AVAudioPCMBuffer?, motion: (Double) -> Motion) {
    let fs = 48000.0, total = Int(90 * fs)
    let swingDeg = 25.0, swingHz = 1.5
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fs, interleaved: false,
                               channelLayout: AVAudioChannelLayout(layout: &layout))
    var rng = SplitMix(state: 7)
    var wind = 0.0, band = [Double](repeating: 0, count: 6)  // one-pole filter states
    var i = 0

    let next = { () -> AVAudioPCMBuffer? in
        guard i < total, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { return nil }
        buf.frameLength = AVAudioFrameCount(min(1024, total - i))
        let ch = buf.floatChannelData!  // ACN order: W, Y, Z, X
        for k in 0..<Int(buf.frameLength) {
            let t = Double(i + k) / fs
            let swing = swingDeg * .pi / 180 * sin(2 * .pi * swingHz * t)  // phone yaw, + = turned left
            var w = 0.0, x = 0.0, y = 0.0, z = 0.0
            func add(_ s: Double, from deg: Double) {  // a plane wave from a world direction (+ = left)
                let a = deg * .pi / 180 - swing
                w += s; x += s * cos(a); y += s * sin(a)
            }
            func tyres(_ k: Int) -> Double {  // band-passed noise stream (~300 Hz – 3 kHz)
                let white = rng.next()
                band[2 * k] += 0.325 * (white - band[2 * k])
                band[2 * k + 1] += 0.0385 * (white - band[2 * k + 1])
                return band[2 * k] - band[2 * k + 1]
            }
            let streams = [tyres(0), tyres(1), tyres(2)]

            w += 0.004 * rng.next(); x += 0.0023 * rng.next(); y += 0.0023 * rng.next(); z += 0.0023 * rng.next()
            wind += 0.013 * (rng.next() - wind)  // < ~100 Hz, reads as a fake source wandering ahead-left
            add(0.5 * wind, from: 40 + 50 * sin(0.4 * t))
            for c in 0..<13 {  // road cars 4 m to the right
                let pass = 4.0 + 7 * Double(c)
                let along = c % 2 == 0 ? 9 * (t - pass) : -15 * (t - pass)  // + = ahead of the runner
                guard abs(along) < 60 else { continue }
                add(streams[c % 2] / max((along * along + 16).squareRoot(), 2), from: atan2(-4, along) * 180 / .pi)
            }
            let path = 7 * (t - 62)  // the vehicle on the runner's own path, 0.8 m to the left
            if path > -60 && path < 10 {
                add(streams[2] / max((path * path + 0.64).squareRoot(), 2), from: atan2(0.8, path) * 180 / .pi)
            }
            if t >= 40 && t < 40.4 {
                func saw(_ f: Double) -> Double { 2 * (t * f - (0.5 + t * f).rounded(.down)) }
                add(0.06 * (saw(420) + saw(525)), from: 135)
            }
            ch[0][k] = Float(w); ch[1][k] = Float(y); ch[2][k] = Float(z); ch[3][k] = Float(x)
        }
        i += Int(buf.frameLength)
        return buf
    }
    let motion = { (t: Double) in
        Motion(yawRate: swingDeg * .pi / 180 * 2 * .pi * swingHz * cos(2 * .pi * swingHz * t))
    }
    return (next, motion)
}

@main enum Replay {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "--selfcheck":
            selfCheck()
            print("self-check OK")
        case "--street":
            print(streetTruth)
            let s = street()
            replay("synthetic street", next: s.next, motion: s.motion)
        case let path?:
            let r = try recording(URL(fileURLWithPath: path))
            replay(URL(fileURLWithPath: path).lastPathComponent, next: r.next, motion: r.motion)
        case nil:
            print("usage: replay <recording folder> | --street | --selfcheck")
        }
    }
}
