import Accelerate
import AVFAudio
import Foundation
import simd

// The whole decision pipeline, free of capture and UI, so the app and Tools/replay.swift run the same code.

// Which way each ambisonic axis points on the phone, in CoreMotion's frame
// (x = right edge, y = top edge, z = out of the screen).
// ponytail: Apple doesn't document this; assumes the camera convention (front = out the back camera,
// up = top edge). The live mic check in Debug ③ shows whether it holds on a real iPhone.
nonisolated let foaFront = SIMD3<Double>(0, 0, -1)
nonisolated let foaLeft = SIMD3<Double>(-1, 0, 0)
nonisolated let foaUp = SIMD3<Double>(0, 1, 0)


/// A virtual microphone aimed at one side of the phone, built from the ambisonic axes.
nonisolated struct PhoneSide: Sendable {
    var name: String, icon: String
    var axis: Int       // 0 = front/back, 1 = left/right, 2 = up/down
    var sign: Double
}

nonisolated let phoneSides = [
    PhoneSide(name: "Top edge", icon: "arrow.up", axis: 2, sign: 1),
    PhoneSide(name: "Bottom edge", icon: "arrow.down", axis: 2, sign: -1),
    PhoneSide(name: "Left edge", icon: "arrow.left", axis: 1, sign: 1),
    PhoneSide(name: "Right edge", icon: "arrow.right", axis: 1, sign: -1),
    PhoneSide(name: "Screen side", icon: "iphone", axis: 0, sign: -1),
    PhoneSide(name: "Camera side", icon: "camera.fill", axis: 0, sign: 1),
]

/// One block of first-order ambisonics (ACN/SN3D: W omni, X front, Y left, Z up), kept as per-sample means of channel products.
nonisolated struct Reading: Sendable {
    var ww = 0.0, wx = 0.0, wy = 0.0, wz = 0.0, xx = 0.0, yy = 0.0, zz = 0.0, xy = 0.0, xz = 0.0, yz = 0.0

    /// Level of the omni channel, dBFS.
    var db: Double { 10 * log10(max(ww, 1e-12)) }
    /// 0 = diffuse noise, 1 = single clean source.
    var directness: Double { ww > 0 ? min((wx * wx + wy * wy + wz * wz).squareRoot() / ww, 1) : 0 }
    /// Where the sound comes from in the phone's own frame (acoustic intensity vector).
    var phoneVector: SIMD3<Double> { wx * foaFront + wy * foaLeft + wz * foaUp }

    /// What a cardioid mic aimed at `side` would hear: 0.5 * (W ± axis).
    func micDB(_ side: PhoneSide) -> Double {
        let (i, v) = [(wx, xx), (wy, yy), (wz, zz)][side.axis]
        return 10 * log10(max(0.25 * (ww + 2 * side.sign * i + v), 1e-12))
    }

    /// Power a supercardioid beam aimed along `u` (phone frame, unit length) picks up:
    /// full from that direction, about −9 dB from the sides, −12 dB from behind it.
    func beamPower(toward u: SIMD3<Double>) -> Double {
        let a = 0.63, x = simd_dot(u, foaFront), y = simd_dot(u, foaLeft), z = simd_dot(u, foaUp)
        let along = x * wx + y * wy + z * wz
        let spread = x * x * xx + y * y * yy + z * z * zz + 2 * (x * y * xy + x * z * xz + y * z * yz)
        return max((1 - a) * (1 - a) * ww + 2 * a * (1 - a) * along + a * a * spread, 0)
    }
}

nonisolated func foaReading(w: [Float], y: [Float], z: [Float], x: [Float]) -> Reading {
    var ww = 0.0, wx = 0.0, wy = 0.0, wz = 0.0, xx = 0.0, yy = 0.0, zz = 0.0, xy = 0.0, xz = 0.0, yz = 0.0
    for i in w.indices {
        let wi = Double(w[i]), xi = Double(x[i]), yi = Double(y[i]), zi = Double(z[i])
        ww += wi * wi
        wx += wi * xi
        wy += wi * yi
        wz += wi * zi
        xx += xi * xi
        yy += yi * yi
        zz += zi * zi
        xy += xi * yi
        xz += xi * zi
        yz += yi * zi
    }
    let n = Double(max(w.count, 1))
    return Reading(ww: ww / n, wx: wx / n, wy: wy / n, wz: wz / n, xx: xx / n, yy: yy / n, zz: zz / n,
                   xy: xy / n, xz: xz / n, yz: yz / n)
}

/// Direction relative to the runner (degrees, 0 = ahead, +90 = left). Uses gravity so it holds whether the
/// phone is upright, tilted or flat: "ahead" is where the camera + top edge point, flattened onto the ground.
nonisolated func runnerAzimuth(_ phoneVector: SIMD3<Double>, gravity: SIMD3<Double>) -> Double? {
    groundAxes(gravity: gravity).map { atan2(simd_dot(phoneVector, $0.left), simd_dot(phoneVector, $0.ahead)) * 180 / .pi }
}

/// The runner's level "ahead" and "left" in the phone frame; nil when camera + top both point at sky or ground.
nonisolated func groundAxes(gravity: SIMD3<Double>) -> (ahead: SIMD3<Double>, left: SIMD3<Double>)? {
    let up = -simd_normalize(gravity)
    let v = SIMD3<Double>(0, 1, -1)
    let ahead = v - simd_dot(v, up) * up
    guard simd_length(ahead) > 0.3 else { return nil }
    let a = simd_normalize(ahead)
    return (a, simd_cross(up, a))
}

/// Runner azimuth after the user's fine-tune (Debug › Fine-tune direction).
nonisolated func calibrated(_ azimuth: Double, offset: Double, mirror: Bool) -> Double { (mirror ? -azimuth : azimuth) + offset }

/// One direction reading kept briefly, so late classifier verdicts can look back at what they judged.
nonisolated struct DirectionSample: Sendable {
    var t: Double        // seconds since capture start
    var azimuth: Double  // runner-relative
    var power: Double    // direct-sound power, the weight
    var strength: Double // 0…1 as drawn on the radar
}

/// Power-weighted circular mean direction of the samples in [start, end), and the peak strength there.
nonisolated func soundDirection(_ samples: [DirectionSample], from start: Double, to end: Double) -> (azimuth: Double, peak: Double)? {
    var c = 0.0, s = 0.0, peak = 0.0
    for x in samples where x.t >= start && x.t < end {
        c += x.power * cos(x.azimuth * .pi / 180)
        s += x.power * sin(x.azimuth * .pi / 180)
        peak = max(peak, x.strength)
    }
    return c == 0 && s == 0 ? nil : (atan2(s, c) * 180 / .pi, peak)
}

/// Index of the slice an angle falls in when the circle is cut into `count` equal slices centred on 0°.
nonisolated func slot(_ degrees: Double, of count: Int) -> Int {
    (Int((degrees / 360 * Double(count)).rounded()) % count + count) % count
}

/// "behind on your left" etc., for the status card, notifications and the Dynamic Island.
nonisolated func directionWords(_ azimuth: Double?) -> String {
    guard let azimuth else { return "around you" }
    let names = ["ahead", "ahead on your left", "on your left", "behind on your left",
                 "behind you", "behind on your right", "on your right", "ahead on your right"]
    return names[slot(azimuth, of: names.count)]
}

/// The 8 sectors of 45°, counter-clockwise from ahead (runner's frame, after fine-tune).
nonisolated let sectorNames = ["ahead", "ahead-left", "left", "behind-left", "behind", "behind-right", "right", "ahead-right"]

/// Flags a sound that keeps getting louder from one direction (something approaching), but not one that simply
/// switches on, and not the whole street getting louder. 8 sectors of 45°, 0 = front, counter-clockwise.
/// Each sector's level comes from a beam aimed at it, so a quieter vehicle still has a steady level
/// while louder traffic elsewhere dominates.
nonisolated struct ApproachDetector {
    static let sectors = 8
    // ponytail: thresholds are guesses, not measured; tune them with Tools/replay.swift on a real road
    var minDB = -50.0   // ignore anything quieter
    var riseDB = 6.0    // must get this much louder…
    var window = 2.0    // …over this many seconds, spread out rather than in one jump
    var leadDB = 3.0    // and stand this far above the median direction (not the whole street rising)
    private let tick = 0.25
    private var power = [Double](repeating: 0, count: sectors)
    private var history: [[Double]] = []
    private var sinceTick = 0.0

    struct SectorStat: Sendable {
        var db: Double           // now
        var rise: Double         // now minus `window` seconds ago
        var biggestJump: Double  // largest rise between two ticks
        var lead: Double         // now minus the median sector now
        var sweep: Double        // ≈ how fast the source's bearing is moving, °/s over the last second
        var ledFor: Double       // seconds this sector has stood out from the others without a break
        var approaching: Bool
    }

    /// Per-sector view of the last `window` seconds; empty until the window has filled.
    func stats() -> [SectorStat] {
        let n = Int(window / tick) + 1
        guard history.count == n else { return [] }
        let medians = history.map { $0.sorted()[Self.sectors / 2] }, median = medians[n - 1]
        return (0..<Self.sectors).map { i in
            let l = history.map { $0[i] }
            let rise = l[n - 1] - l[0]
            let jump = zip(l, l.dropFirst()).map { $1 - $0 }.max() ?? 0
            let lead = l[n - 1] - median
            // A source holding its bearing keeps the same balance between this sector's two neighbour beams;
            // one sweeping past shifts it, ~1 dB per 6° for these beams 45° either side. Over the last second
            // only, so the comparison isn't against the street hum from before the source stood out.
            let balance = { (h: [Double]) in h[(i + 1) % Self.sectors] - h[(i + Self.sectors - 1) % Self.sectors] }
            let back = Int(1 / tick)
            let sweep = abs(balance(history[n - 1]) - balance(history[n - 1 - back])) * 6
            let led = (0..<n).reversed().prefix { l[$0] - medians[$0] >= leadDB }.count
            return SectorStat(db: l[n - 1], rise: rise, biggestJump: jump, lead: lead, sweep: sweep, ledFor: Double(led) * tick,
                              approaching: l[n - 1] > minDB && rise >= riseDB && jump <= rise / 2 && lead >= leadDB)
        }
    }

    /// Feed one block's beam power per sector. Every 0.25 s returns the sectors steadily getting louder,
    /// loudest first; nil in between.
    mutating func update(sectorPower p: [Double], dt: Double) -> [Int]? {
        let a = min(dt / 0.3, 1)
        for i in power.indices { power[i] += (p[i] - power[i]) * a }
        sinceTick += dt
        guard sinceTick >= tick else { return nil }
        sinceTick -= tick
        history.append(power.map { 10 * log10(max($0, 1e-12)) })
        if history.count > Int(window / tick) + 1 { history.removeFirst() }
        let st = stats()
        return st.indices.filter { st[$0].approaching }.sorted { st[$0].db > st[$1].db }
    }
}

/// 2nd-order Butterworth high-pass (RBJ cookbook) for one channel; keeps its state across blocks.
nonisolated struct HighPass {
    private var biquad: vDSP.Biquad<Float>

    init?(cutoff: Double, sampleRate: Double) {
        let w0 = 2 * Double.pi * cutoff / sampleRate, alpha = sin(w0) / (2 * 0.5.squareRoot()), c = cos(w0), a0 = 1 + alpha
        guard let b = vDSP.Biquad(coefficients: [(1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0],
                                  channelCount: 1, sectionCount: 1, ofType: Float.self) else { return nil }
        biquad = b
    }

    mutating func apply(_ x: [Float]) -> [Float] { biquad.apply(input: x) }
}

/// How loud this street is, from the last 30 s of overall level sampled every 0.25 s.
nonisolated struct LevelHistory {
    private(set) var hum: Double?    // 20th percentile: the background roar
    private(set) var usual: Double?  // median: how loud it normally is here
    private var levels: [Double] = []
    private var nextTick = -Double.infinity

    mutating func add(_ db: Double, at t: Double) {
        guard t >= nextTick else { return }
        nextTick = t + 0.25
        levels.append(db)
        if levels.count > 120 { levels.removeFirst() }
        guard levels.count >= 8 else { return }  // 2 s before trusting it
        let sorted = levels.sorted()
        hum = sorted[sorted.count / 5]
        usual = sorted[sorted.count / 2]
    }
}

/// Cancels arm swing: integrates the gyro's turning about the vertical and keeps a ~2 s average of it.
/// The correction is how far the phone is turned away from that average right now.
nonisolated struct HeadingSmoother {
    var seconds = 2.0
    private var yaw = 0.0  // radians, + = turned left
    private var avgCos = 1.0, avgSin = 0.0

    /// Degrees to add to a phone-relative azimuth to make it relative to the runner's average heading.
    mutating func update(yawRate: Double, dt: Double) -> Double {
        yaw += yawRate * dt
        let a = min(dt / seconds, 1)
        avgCos += (cos(yaw) - avgCos) * a
        avgSin += (sin(yaw) - avgSin) * a
        return remainder(yaw - atan2(avgSin, avgCos), 2 * .pi) * 180 / .pi
    }
}

/// One audio block from the microphones, as delivered (~47 per second).
nonisolated struct Block: Sendable {
    var reading: Reading
    var start: Double     // seconds since capture start (same clock as classifier verdicts)
    var duration: Double
    var format: String    // what iOS actually delivers, for the debug screen
    var savingAudio: Bool // the raw audio of this block went into the recording
}

/// Turns one delivered buffer into a Block on the shared stream clock. Used by the live tap and the replay tool.
nonisolated struct BlockMaker {
    // ponytail: below ~200 Hz it's mostly wind on the mics and engine rumble, which drag the direction around; tune with replay
    static let highPassHz = 200.0
    private var frames: AVAudioFramePosition = 0
    private var highPass: [HighPass] = []

    /// The block (direction path high-passed), the unfiltered omni channel for the classifier, and the block's frame position.
    mutating func make(_ buf: AVAudioPCMBuffer, savingAudio: Bool = false) -> (block: Block, omni: [Float], at: AVAudioFramePosition) {
        let format = buf.format, sr = format.sampleRate
        if highPass.isEmpty { highPass = (0..<4).compactMap { _ in HighPass(cutoff: Self.highPassHz, sampleRate: sr) } }
        let raw = (0..<4).map { samples(buf, channel: $0) }
        let ch = highPass.count == 4 ? (0..<4).map { highPass[$0].apply(raw[$0]) } : raw
        let kind = format.commonFormat == .pcmFormatFloat32 ? "float32" : format.commonFormat == .pcmFormatInt16 ? "int16" : "other"
        let block = Block(reading: foaReading(w: ch[0], y: ch[1], z: ch[2], x: ch[3]),
                          start: Double(frames) / sr, duration: Double(buf.frameLength) / sr,
                          format: "\(Int(sr)) Hz · \(format.channelCount) ch · \(kind)\(format.isInterleaved ? " interleaved" : "") · \(buf.frameLength) frames",
                          savingAudio: savingAudio)
        let at = frames
        frames += AVAudioFramePosition(buf.frameLength)
        return (block, raw[0], at)
    }

    private func samples(_ buf: AVAudioPCMBuffer, channel c: Int) -> [Float] {
        let n = Int(buf.frameLength), s = buf.stride, il = buf.format.isInterleaved
        if let f = buf.floatChannelData {
            let p = f[il ? 0 : c]
            return (0..<n).map { p[$0 * s + (il ? c : 0)] }
        }
        if let q = buf.int16ChannelData {
            let p = q[il ? 0 : c]
            return (0..<n).map { Float(p[$0 * s + (il ? c : 0)]) / 32768 }
        }
        return []
    }
}

/// Phone motion at one block.
nonisolated struct Motion: Sendable {
    var gravity = SIMD3<Double>(0, -1, 0)  // device frame
    var yawRate = 0.0                      // rad/s about the vertical, counter-clockwise seen from above
}

/// What the detector worked out for one block (debug screen, recording, replay).
nonisolated struct Processed: Sendable {
    var block: Block
    var motion: Motion
    var rawAzimuth: Double?   // from the phone's pose alone; nil when the pose has no "ahead"
    var correction: Double    // arm-swing correction from the gyro, degrees
    var azimuth: Double?      // after fine-tune + correction: what everything else uses
    var hum: Double?          // the street's background level (dB), once known
    var usual: Double?        // the street's usual level (dB), once known
    var loudness: Double      // 0…1: how far above the hum, over 24 dB
    var strength: Double      // radar line length = loudness × directness
}

nonisolated struct Bin: Sendable { var strength = 0.0, kind = SoundKind.other }

nonisolated struct Alert: Equatable, Sendable {
    var azimuth: Double?  // nil = heard it but direction unclear
    var what: String
    var isApproach = false  // "getting closer" rather than a horn/siren/bell/shout (picks the haptic pattern)
}

/// Everything the debug screen shows, refreshed 10×/s so numbers stay readable.
nonisolated struct DebugSnapshot: Sendable {
    var processed: Processed
    var mics: [Double]  // dB per phone side, lightly smoothed
    var sectors: [ApproachDetector.SectorStat]
    var heldBack: [Int: String]  // approaching sectors not warned, by reason (view, usual, settling, passing, kind)
    var heard: Heard?
    var heardLatency: Double
    var events: [String]
    var alert: Alert?
    var kind: SoundKind
}

/// Decides what to show and when to warn, from audio blocks and classifier verdicts.
/// Runs on stream time (not the wall clock), so a replay gives the same answers as the live run.
nonisolated struct Detector {
    /// "Getting closer" only warns out of the runner's view: left, behind-left, behind, behind-right, right.
    static let warnSectors: Set<Int> = [2, 3, 4, 5, 6]
    // ponytail: guess; tune with Tools/replay.swift on recorded walks
    static let standOutDB = 6.0  // an approaching sound must be this much louder than the street's usual level
    // °/s: bearing moving faster than this while it gets louder = passing by, not coming at you. Bearing rate is
    // speed × side-offset ÷ distance²: at 6 m, a vehicle on your line (≤1 m off) moves ~13°/s, a road car 4 m off ~40°/s.
    static let maxSweep = 20.0

    var offset = 0.0, mirror = false  // the user's fine-tune
    var bins = [Bin](repeating: Bin(), count: 72)  // 5° per spoke
    private(set) var kind = SoundKind.other
    private(set) var label = ""
    private(set) var alert: Alert?
    private(set) var alertPulse = 0  // bumps to re-fire the haptic while danger lasts
    private(set) var clock = 0.0     // stream seconds, end of the latest block
    private(set) var pendingLog: [String] = []  // new log lines not yet written to a recording
    private var events: [String] = []           // decisions log, newest first
    private var heard: Heard?
    private var heardLatency = 0.0
    private var last: Processed?
    private var approach = ApproachDetector()
    private var heldBack: [Int: String] = [:]   // why each approaching sector isn't warned, to log only changes
    private var levels = LevelHistory()
    private var heading = HeadingSmoother()
    private var recent: [DirectionSample] = []  // last few seconds, for the classifier's late verdicts
    private var mics = [Double](repeating: -120, count: phoneSides.count)
    private var alertUntil = -Double.infinity
    private var lastPulse = -Double.infinity

    /// Strongest recent direction, optionally only among spokes tagged with `kind`.
    func loudestAzimuth(of kind: SoundKind? = nil) -> Double? {
        let pool = bins.indices.filter { kind == nil || bins[$0].kind == kind }
        guard let i = pool.max(by: { bins[$0].strength < bins[$1].strength }), bins[i].strength > 0.05 else { return nil }
        return Double(i) * 360 / Double(bins.count)
    }

    func snapshot() -> DebugSnapshot? {
        last.map { DebugSnapshot(processed: $0, mics: mics, sectors: approach.stats(), heldBack: heldBack, heard: heard,
                                 heardLatency: heardLatency, events: events, alert: alert, kind: kind) }
    }

    mutating func clearPendingLog() { pendingLog = [] }

    /// Paused: drop the current warning and the radar lines (no audio will come to clear them).
    mutating func clearAlert() {
        alert = nil
        for i in bins.indices { bins[i].strength = 0 }
    }

    mutating func log(_ message: String) {
        let line = String(format: "%.1fs  ", clock) + message
        events.insert(line, at: 0)
        if events.count > 80 { events.removeLast() }
        pendingLog.append(line)
    }

    mutating func hear(_ h: Heard) {
        heard = h
        heardLatency = clock - h.end
        if h.kind != kind { log("classifier: \(h.kind)\(h.label.isEmpty ? "" : " (\(pretty(h.label)))")") }
        kind = h.kind
        label = pretty(h.label)
        guard h.kind == .alert else { return }
        // The verdict lands ~0.5 s after the sound (a short honk is already over), so take the direction
        // from the exact slice of audio the classifier judged, and paint it on the radar in red.
        // ponytail: assumes the alert is the loudest thing in that half second; per-source needs beamforming
        let found = soundDirection(recent, from: h.start, to: h.end)
        if let found {
            let center = slot(found.azimuth, of: bins.count)
            for d in -2...2 {
                let j = (center + d + bins.count) % bins.count
                bins[j] = Bin(strength: max(bins[j].strength, found.peak * (1 - 0.2 * Double(abs(d)))), kind: .alert)
            }
        }
        warn(Alert(azimuth: found?.azimuth, what: label))
    }

    @discardableResult
    mutating func add(_ b: Block, motion m: Motion) -> Processed {
        let r = b.reading
        clock = b.start + b.duration
        mics = zip(mics, phoneSides.map(r.micDB)).map { 0.8 * $0 + 0.2 * $1 }
        if clock > alertUntil, alert != nil { alert = nil; log("alert cleared") }
        for i in bins.indices { bins[i].strength *= 0.95 }

        // "Ahead" from gravity on every block (works upright, tilted or flat), then the gyro takes out arm swing.
        let correction = heading.update(yawRate: m.yawRate, dt: b.duration)
        let raw = runnerAzimuth(r.phoneVector, gravity: m.gravity)
        let az = raw.map { remainder(calibrated($0, offset: offset, mirror: mirror) + correction, 360) }
        // Lines measure how far a sound stands out above this street's hum, not raw loudness.
        levels.add(r.db, at: b.start)
        let loudness = min(max((r.db - (levels.hum ?? r.db)) / 24, 0), 1)
        let strength = az == nil ? 0 : loudness * r.directness

        if let az {
            recent.append(DirectionSample(t: b.start, azimuth: az, power: r.ww * r.directness, strength: strength))
            recent.removeAll { $0.t < b.start - 4 }
            let center = slot(az, of: bins.count)
            for (d, k) in [(0, 1.0), (-1, 0.5), (1, 0.5)] {
                let j = (center + d + bins.count) % bins.count
                if strength * k > bins[j].strength { bins[j] = Bin(strength: strength * k, kind: kind) }
            }
        }
        // Horns and sirens are raised in hear(); here only "something is getting closer".
        if let axes = groundAxes(gravity: m.gravity) {
            let beams = (0..<ApproachDetector.sectors).map { k -> Double in
                let onPhone = Double(k) * 360 / Double(ApproachDetector.sectors) - correction - offset  // undo correction + fine-tune
                let deg = (mirror ? -onPhone : onPhone) * .pi / 180
                return r.beamPower(toward: cos(deg) * axes.ahead + sin(deg) * axes.left)
            }
            if let rising = approach.update(sectorPower: beams, dt: b.duration) { judgeApproach(rising) }
        }
        let p = Processed(block: b, motion: m, rawAzimuth: raw, correction: correction, azimuth: az,
                          hum: levels.hum, usual: levels.usual, loudness: loudness, strength: strength)
        last = p
        return p
    }

    /// The street's usual level (median of the last 30 s), once known.
    var usual: Double? { levels.usual }

    /// Warn for the loudest sector that is getting closer, out of view, clearly louder than usual and holding its
    /// bearing (coming at you, not passing by). Held-back sectors get a log line whenever the reason changes.
    private mutating func judgeApproach(_ rising: [Int]) {
        let stats = approach.stats(), usual = levels.usual, kind = kind
        func holdBack(_ s: Int) -> (reason: String, text: String)? {  // nil = warn
            if !Self.warnSectors.contains(s) { return ("view", "(in view)") }
            if let usual, stats[s].db - usual < Self.standOutDB {
                return ("usual", String(format: "only %+.0f dB over usual", stats[s].db - usual))
            }
            // Judge the bearing only once this direction has clearly stood out for a second, not while it emerges from the hum.
            if stats[s].ledFor < 1 { return ("settling", "(bearing not settled yet)") }
            // A car spans neighbouring beams, so take the fastest sweep across this sector and its two neighbours.
            let n = ApproachDetector.sectors, sweep = [n - 1, 0, 1].map { stats[(s + $0) % n].sweep }.max()!
            if sweep > Self.maxSweep { return ("passing", String(format: "passing by (bearing moving ~%.0f°/s)", sweep)) }
            if kind == .people || kind == .alert { return ("kind", "(classifier says \(kind))") }
            return nil
        }
        var now: [Int: String] = [:]
        for s in rising {
            guard let why = holdBack(s) else { continue }
            now[s] = why.reason
            if heldBack[s] != why.reason { log("not warned: getting closer \(sectorNames[s]) \(why.text)") }
        }
        heldBack = now
        guard let s = rising.first(where: { holdBack($0) == nil }) else { return }
        warn(Alert(azimuth: Double(s) * 360 / Double(ApproachDetector.sectors),
                   what: kind == .traffic ? "Vehicle getting closer" : "Sound getting closer", isApproach: true))
    }

    private mutating func warn(_ a: Alert) {
        if alert?.what != a.what { log("WATCH OUT: \(a.what) at \(a.azimuth.map { "\(Int($0.rounded()))°" } ?? "unknown direction")") }
        alert = a
        alertUntil = clock + 3
        if clock - lastPulse > 1.5 {
            alertPulse += 1
            lastPulse = clock
        }
    }
}

nonisolated func selfCheck() {
    let s = (0..<4800).map { Float(sin(Double($0) * 0.3)) }, zero = s.map { _ in Float(0) }
    let upright = SIMD3<Double>(0, -1, 0), flat = SIMD3<Double>(0, 0, -1), tilted = SIMD3<Double>(0, -0.707, -0.707)
    for deg in [0.0, 45, 90, 180, -90] {
        let a = deg * .pi / 180
        let r = foaReading(w: s, y: s.map { $0 * Float(sin(a)) }, z: zero, x: s.map { $0 * Float(cos(a)) })
        let az = runnerAzimuth(r.phoneVector, gravity: upright)!
        precondition(abs(remainder(az - deg, 360)) < 0.5 && r.directness > 0.99, "upright, plane wave \(deg)° -> \(az)")
    }
    // Flat in the hand, top edge forward: top-edge sound is ahead, left-edge sound is left.
    let fromTop = foaReading(w: s, y: zero, z: s, x: zero), fromLeft = foaReading(w: s, y: s, z: zero, x: zero)
    precondition(abs(runnerAzimuth(fromTop.phoneVector, gravity: flat)!) < 0.5, "flat: top edge = ahead")
    precondition(abs(runnerAzimuth(fromLeft.phoneVector, gravity: flat)! - 90) < 0.5, "flat: left edge = left")
    // Tilted 45° back: a level sound from straight ahead hits camera and top edge equally.
    let ahead45 = foaReading(w: s, y: zero, z: s.map { $0 * 0.707 }, x: s.map { $0 * 0.707 })
    precondition(abs(runnerAzimuth(ahead45.phoneVector, gravity: tilted)!) < 0.5, "tilted: still ahead")
    precondition(fromLeft.micDB(phoneSides[2]) - fromLeft.micDB(phoneSides[3]) > 20, "left-edge mic hears a left sound, right-edge doesn't")
    let tone = { (f: Double) in (0..<4800).map { Float(sin(Double($0) * f)) } }
    let diffuse = foaReading(w: s, y: tone(0.71), z: tone(1.13), x: tone(1.57))
    precondition(diffuse.directness < 0.1, "uncorrelated channels should read diffuse -> \(diffuse)")

    func plane(_ db: Double, from deg: Double, bed: Double = -120) -> Reading {  // a plane wave over diffuse hum
        let p = pow(10, db / 10), h = pow(10, bed / 10), c = cos(deg * .pi / 180), s = sin(deg * .pi / 180)
        return Reading(ww: p + h, wx: p * c, wy: p * s, wz: 0, xx: p * c * c + h / 3, yy: p * s * s + h / 3, zz: h / 3, xy: p * c * s)
    }
    func approach(_ dbAt: (Double) -> Double) -> Int? {
        var d = ApproachDetector(), hit: Int?
        let axes = groundAxes(gravity: upright)!
        for k in 0..<300 {
            let r = plane(dbAt(Double(k) * 0.02), from: 180)
            let beams = (0..<8).map { r.beamPower(toward: cos(Double($0) * .pi / 4) * axes.ahead + sin(Double($0) * .pi / 4) * axes.left) }
            if let sector = d.update(sectorPower: beams, dt: 0.02)?.first { hit = sector }
        }
        return hit
    }
    precondition(approach { -70 + 5 * $0 } == 4, "steady rise from behind = approaching")
    precondition(approach { $0 < 2 ? -80 : -30 } == nil, "a sound switching on is not approaching")
    precondition(approach { _ in -30 } == nil, "a steady sound is not approaching")

    // A honk from behind inside the judged window wins over steady, quieter traffic on the left.
    let traffic = (0..<200).map { DirectionSample(t: Double($0) * 0.02, azimuth: 90, power: 1e-5, strength: 0.2) }
    let honk = (100..<115).map { DirectionSample(t: Double($0) * 0.02, azimuth: 180, power: 1e-3, strength: 0.9) }
    let judged = soundDirection(traffic + honk, from: 2.0, to: 2.5)!
    precondition(abs(remainder(judged.azimuth - 180, 360)) < 5 && judged.peak == 0.9, "honk direction -> \(judged)")
    precondition(soundDirection(traffic, from: 10, to: 11) == nil, "nothing heard -> no direction")

    // High-pass: rumble and wind go, speech-band sound stays.
    func throughHighPass(_ hz: Double) -> Double {
        var hp = HighPass(cutoff: BlockMaker.highPassHz, sampleRate: 48000)!
        let out = hp.apply((0..<24000).map { Float(sin(2 * .pi * hz * Double($0) / 48000)) })
        let rms = (out[4800...].map { Double($0 * $0) }.reduce(0, +) / Double(out.count - 4800)).squareRoot()
        return 20 * log10(rms / 0.5.squareRoot())
    }
    precondition(throughHighPass(50) < -15, "50 Hz rumble should drop ≥ 15 dB -> \(throughHighPass(50))")
    precondition(abs(throughHighPass(1000)) < 1, "1 kHz should pass -> \(throughHighPass(1000))")

    // Street level: a short loud event barely moves "usual".
    var street = LevelHistory()
    for k in 0..<80 { street.add(-40, at: Double(k) * 0.25) }
    precondition(abs(street.hum! + 40) < 0.1 && abs(street.usual! + 40) < 0.1, "steady street -> hum = usual = -40")
    for k in 80..<92 { street.add(-28, at: Double(k) * 0.25) }
    precondition(abs(street.usual! + 40) < 2, "3 s event shouldn't move usual -> \(street.usual!)")

    // Getting closer: warn from behind, not from ahead, and not when it's no louder than this street usually is.
    func approachWarned(from bearing: (Double) -> Double, street: Double, then quiet: Double, rampTo top: Double) -> (warned: Bool, log: [String]) {
        var d = Detector(), warned = false, log: [String] = []
        for k in 0..<1300 {  // 20 s of street hum, then quieter hum while something ramps up 5 dB/s to `top`
            let t = Double(k) * 0.02, ramp = t < 20 ? -120 : top - 30 + 5 * (t - 20)
            d.add(Block(reading: plane(ramp, from: bearing(t), bed: t < 20 ? street : quiet), start: t, duration: 0.02, format: "", savingAudio: false),
                  motion: Motion())
            warned = warned || d.alert?.what.contains("getting closer") == true
            log += d.pendingLog
            d.clearPendingLog()
        }
        return (warned, log)
    }
    let quiet = approachWarned(from: { _ in 180 }, street: -50, then: -50, rampTo: -30)
    precondition(quiet.warned, "approach from behind on a quiet street warns -> \(quiet.log)")
    let ahead = approachWarned(from: { _ in 0 }, street: -50, then: -50, rampTo: -30)
    precondition(!ahead.warned && ahead.log.contains { $0.contains("(in view)") }, "approach from ahead is in view -> \(ahead.log)")
    let busy = approachWarned(from: { _ in 180 }, street: -30, then: -50, rampTo: -35)
    precondition(!busy.warned && busy.log.contains { $0.contains("over usual") }, "no louder than this busy street usually is -> \(busy.log)")
    // A car on the road beside you sweeps past at ~25°/s when it's ~8 m away (4 m to the side).
    let passing = approachWarned(from: { 240 - 24 * ($0 - 18) }, street: -50, then: -50, rampTo: -20)
    precondition(!passing.warned && passing.log.contains { $0.contains("passing by") }, "a car sweeping past isn't coming at you -> \(passing.log)")

    // Arm swing: a fixed sound behind stays put while the phone swings ±25° at 1.5 Hz; a real 90° turn is followed.
    var smoother = HeadingSmoother(), worst = 0.0
    for k in 0..<500 {
        let t = Double(k) * 0.02, swing = 25 * sin(2 * .pi * 1.5 * t)
        let rate = 25 * .pi / 180 * 2 * .pi * 1.5 * cos(2 * .pi * 1.5 * t)
        let corrected = (180 - swing) + smoother.update(yawRate: rate, dt: 0.02)
        if t > 3 { worst = max(worst, abs(remainder(corrected - 180, 360))) }
    }
    precondition(worst < 5, "arm swing should cancel -> off by \(worst)°")
    var turned = HeadingSmoother(), correction = 0.0
    for k in 0..<450 { correction = turned.update(yawRate: k < 50 ? .pi / 2 : 0, dt: 0.02) }  // turn left 90° in 1 s, then hold 8 s
    precondition(abs(correction) < 5, "a real turn should become the new ahead -> \(correction)°")

    precondition(classify(["car_horn": 0.35, "speech": 0.9]).kind == .alert, "alerts beat louder chatter")
    precondition(classify(["speech": 0.8, "traffic_noise": 0.5]) == (.people, "speech"))
    precondition(classify(["person_running": 0.9, "breathing": 0.9]).kind == .other, "runner's own sounds ignored")
}
