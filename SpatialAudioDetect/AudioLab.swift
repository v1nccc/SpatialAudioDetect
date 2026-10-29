import Foundation
import simd

// The Audio Lab prototype's method (sound-detection repo, SoundDetectionPrototype), run beside Sound Radar's on the
// same audio: the Audio Lab tab uses it instead, the Compare tab shows both at once.
// Direction: one dominant direction per 0.1 s window from the full-band intensity (W × X, Y, Z summed over the window;
// no high-pass, no per-frequency split), kept only when the window is louder than −60 dBFS, coherent (≥ 0.3) and not
// clipped; plus 12 virtual cardioid mics every 30°. Classifier: Apple's, on the unfiltered all-around channel, 0.5 s
// windows, 50% overlap. Sound Radar's all-around listener has exactly those settings, so its verdicts are reused, shown
// raw and not tied to a direction.
// Shared with Sound Radar so only the method differs: the mic axis fix, "ahead" from gravity (the prototype measured
// from the phone's top edge lying flat: the same when flat, and this also works upright) and the fine-tune.
// Added so it can warn: an alert sound that classifier scores ≥ 0.3 (Sound Radar's bar, without its confirmation rules)
// points at the dominant direction of the half second it judged. No "getting closer", no name / danger words and no
// arm-swing correction: the prototype has none.

nonisolated enum DetectionMethod: String, Sendable { case soundRadar = "Sound Radar", audioLab = "Audio Lab" }

nonisolated extension Reading {
    static func + (a: Reading, b: Reading) -> Reading {
        Reading(ww: a.ww + b.ww, wx: a.wx + b.wx, wy: a.wy + b.wy, wz: a.wz + b.wz, xx: a.xx + b.xx, yy: a.yy + b.yy,
                zz: a.zz + b.zz, xy: a.xy + b.xy, xz: a.xz + b.xz, yz: a.yz + b.yz)
    }

    static func * (a: Reading, k: Double) -> Reading {
        Reading(ww: a.ww * k, wx: a.wx * k, wy: a.wy * k, wz: a.wz * k, xx: a.xx * k, yy: a.yy * k, zz: a.zz * k,
                xy: a.xy * k, xz: a.xz * k, yz: a.yz * k)
    }
}

nonisolated struct AudioLab: Sendable {
    static let windowSeconds = 0.1, minimumDB = -60.0, minimumCoherence = 0.3, beamRangeDB = 24.0

    /// One 0.1 s window.
    struct Window: Sendable {
        var t: Double             // stream seconds, start
        var azimuth: Double?      // runner frame (0 = ahead, +90 = left); nil = rejected
        var rejection: String?    // why
        var coherence: Double     // 1 = one clean plane wave
        var db: Double            // all-around level, dBFS
        var beams: [Double] = []  // 12 virtual cardioids (dB) from ahead every 30° toward the left; empty when rejected
    }

    private(set) var latest: Window?
    private(set) var top: [(id: String, confidence: Double)] = []  // the all-around classifier's raw top labels
    private(set) var kind = SoundKind.other
    private(set) var alert: Alert?
    private(set) var alertPulse = 0
    private(set) var alerts: [String] = []  // its warnings, newest first: "12.3s  CRITICAL: Horn at 170°"
    private var sum = Reading(), seconds = 0.0, start = 0.0, clipped = false
    private var recent: [Window] = []  // last 8 s
    private var clock = 0.0, alertUntil = -Double.infinity, lastPulse = -Double.infinity

    /// The radar's 72 spokes: the latest window's 12 cardioids, each relative to the strongest over 24 dB.
    var bins: [Bin] {
        var out = [Bin](repeating: Bin(), count: 72)
        guard let beams = latest?.beams, let top = beams.max() else { return out }
        for (k, db) in beams.enumerated() { out[k * 6] = Bin(strength: min(max(1 + (db - top) / Self.beamRangeDB, 0), 1), kind: kind) }
        return out
    }

    mutating func add(_ b: Block, motion: Motion, offset: Double, mirror: Bool) {
        if seconds == 0 { start = b.start }
        sum = sum + b.raw * b.duration
        seconds += b.duration
        clipped = clipped || b.clipped
        clock = b.start + b.duration
        if clock > alertUntil, alert != nil { alert = nil }
        guard seconds >= Self.windowSeconds else { return }
        let w = Self.window(sum * (1 / seconds), clipped: clipped, t: start, gravity: motion.gravity, offset: offset, mirror: mirror)
        latest = w
        recent.append(w)
        recent.removeAll { $0.t < clock - 8 }
        (sum, seconds, clipped) = (Reading(), 0, false)
    }

    static func window(_ r: Reading, clipped: Bool, t: Double, gravity: SIMD3<Double>, offset: Double, mirror: Bool) -> Window {
        let intensity = SIMD3(r.wx, r.wy, r.wz), dipoles = r.xx + r.yy + r.zz
        var w = Window(t: t, coherence: r.ww * dipoles > 0 ? min(simd_length(intensity) / (r.ww * dipoles).squareRoot(), 1) : 0, db: r.db)
        if clipped { w.rejection = "clipped" }
        else if r.db <= minimumDB { w.rejection = "too quiet (≤ −60 dBFS)" }
        else if w.coherence < minimumCoherence || simd_length(intensity) <= 1e-12 { w.rejection = "no clear direction (coherence < 0.3)" }
        guard w.rejection == nil else { return w }
        guard let axes = groundAxes(gravity: gravity) else { w.rejection = "the phone's pose has no \"ahead\""; return w }
        let v = simd_normalize(r.phoneVector), level = SIMD2(simd_dot(v, axes.ahead), simd_dot(v, axes.left))
        guard simd_length(level) > 0.05 else { w.rejection = "straight above or below"; return w }
        w.azimuth = remainder(calibrated(atan2(level.y, level.x) * 180 / .pi, offset: offset, mirror: mirror), 360)
        w.beams = (0..<12).map { k in
            let a = Double(k) * 30 - offset, rad = (mirror ? -a : a) * .pi / 180  // aimed at runner azimuth k × 30°
            return 10 * log10(max(r.beamPower(toward: cos(rad) * axes.ahead + sin(rad) * axes.left, shape: 0.5), 1e-12))
        }
        return w
    }

    /// The all-around listener's verdict (the beams' verdicts are Sound Radar's own and ignored).
    mutating func hear(_ h: Heard) {
        guard h.beam == nil else { return }
        top = h.top
        kind = h.kind
        guard h.kind == .alert else { return }
        let heard = recent.filter { $0.t + Self.windowSeconds > h.start && $0.t < h.end }.compactMap(\.azimuth)
        let azimuth = circularMean(heard.map { ($0, 1) })?.mean, name = alertName(h.label)
        warn(Alert(azimuth: azimuth, what: name.what, level: alertLevel(h.label, azimuth: azimuth, near: false), short: name.short))
    }

    mutating func clearAlert() {
        alert = nil
        latest = nil
    }

    /// Same hold and buzz rules as Sound Radar's: shown 3 s past the last verdict; a warning never hides a critical.
    private mutating func warn(_ a: Alert) {
        if let current = alert, current.level > a.level, clock <= alertUntil { return }
        let isNew = alert?.what != a.what || alert?.level != a.level
        if isNew {
            alerts.insert(String(format: "%.1fs  ", clock) + "\(a.level == .critical ? "CRITICAL" : "WARNING"): \(a.what) "
                          + (a.azimuth.map { "at \(Int($0.rounded()))°" } ?? "(direction unclear)"), at: 0)
            alerts = Array(alerts.prefix(20))
        }
        alert = a
        alertUntil = clock + 3
        if (isNew && clock - lastPulse > 1.5) || clock - lastPulse > 10 {
            alertPulse += 1
            lastPulse = clock
        }
    }
}

nonisolated func audioLabSelfCheck() {
    let flat = SIMD3<Double>(0, 0, -1), upright = SIMD3<Double>(0, -1, 0), dt = 1024.0 / 48000  // ~21 ms blocks
    /// A plane wave from `toward` (phone frame) at `db`: SN3D, so X, Y, Z = W × the direction's ambisonic components.
    func plane(_ toward: SIMD3<Double>, db: Double = -30) -> Reading {
        let p = pow(10, db / 10), d = SIMD3(simd_dot(toward, foaFront), simd_dot(toward, foaLeft), simd_dot(toward, foaUp))
        return Reading(ww: p, wx: p * d.x, wy: p * d.y, wz: p * d.z, xx: p * d.x * d.x, yy: p * d.y * d.y, zz: p * d.z * d.z,
                       xy: p * d.x * d.y, xz: p * d.x * d.z, yz: p * d.y * d.z)
    }
    func feed(_ lab: inout AudioLab, _ r: Reading, blocks: Range<Int>, gravity: SIMD3<Double> = flat, clipped: Bool = false, offset: Double = 0) {
        for k in blocks {
            lab.add(Block(reading: Reading(), start: Double(k) * dt, duration: dt, format: "", savingAudio: false, raw: r, clipped: clipped),
                    motion: Motion(gravity: gravity), offset: offset, mirror: false)
        }
    }
    func window(_ r: Reading, gravity: SIMD3<Double> = flat, clipped: Bool = false, offset: Double = 0) -> AudioLab.Window {
        var lab = AudioLab()
        feed(&lab, r, blocks: 0..<5, gravity: gravity, clipped: clipped, offset: offset)
        return lab.latest!
    }
    let leftEdge = SIMD3<Double>(-1, 0, 0)

    // Phone flat: the left edge is left; one window per 0.1 s (5 blocks), none before.
    var early = AudioLab()
    feed(&early, plane(leftEdge), blocks: 0..<4)
    precondition(early.latest == nil, "85 ms: no window yet")
    let left = window(plane(leftEdge))
    precondition(abs(left.azimuth! - 90) < 1e-6 && abs(left.coherence - 1) < 1e-9, "left -> \(left)")
    precondition(left.beams.count == 12 && left.beams.indices.max { left.beams[$0] < left.beams[$1] } == 3, "loudest cardioid at 90°")
    // Upright in front of you: the screen faces you, so a sound on the screen side is behind.
    precondition(abs(abs(window(plane(SIMD3(0, 0, 1)), gravity: upright).azimuth!) - 180) < 1e-6, "screen side upright = behind")
    precondition(abs(window(plane(leftEdge), offset: 10).azimuth! - 100) < 1e-6, "fine-tune applies")
    // Gates: quiet, diffuse (equal power on every dipole, nothing correlated with W), clipped, straight overhead.
    precondition(window(plane(leftEdge, db: -65)).rejection?.contains("quiet") == true, "too quiet")
    let p = pow(10, -30.0 / 10)
    precondition(window(Reading(ww: p, xx: p / 3, yy: p / 3, zz: p / 3)).rejection?.contains("no clear direction") == true, "diffuse")
    precondition(window(plane(leftEdge), clipped: true).rejection == "clipped", "clipped")
    precondition(window(plane(SIMD3(0, 0, 1))).rejection == "straight above or below", "overhead, phone flat")

    // Warnings: a horn verdict points at the half second it judged; beam verdicts are Sound Radar's; held 3 s.
    var lab = AudioLab()
    feed(&lab, plane(leftEdge), blocks: 0..<30)  // 0.64 s from the left
    lab.hear(Heard(scores: ["car_horn": 0.9], start: 0, end: 0.5, top: [], beam: 2))
    precondition(lab.alert == nil, "beam verdicts ignored")
    lab.hear(Heard(scores: ["car_horn": 0.6, "speech": 0.2], start: 0.1, end: 0.6, top: [("car_horn", 0.6), ("speech", 0.2)], beam: nil))
    precondition(lab.alert?.short == "Horn" && abs(lab.alert!.azimuth! - 90) < 1e-6 && lab.alertPulse == 1 && lab.top.count == 2,
                 "horn from the left -> \(String(describing: lab.alert))")
    lab.hear(Heard(scores: ["speech": 0.8], start: 0.35, end: 0.85, top: [("speech", 0.8)], beam: nil))
    precondition(lab.kind == .people && lab.alertPulse == 1, "speech: no new warning")
    feed(&lab, Reading(), blocks: 30..<180)  // 3.2 s of silence
    precondition(lab.alert == nil && lab.latest?.rejection != nil && lab.bins.allSatisfy { $0.strength == 0 }, "cleared after 3 s")
}
