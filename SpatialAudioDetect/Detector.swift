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
        let a = beamShape, x = simd_dot(u, foaFront), y = simd_dot(u, foaLeft), z = simd_dot(u, foaUp)
        let along = x * wx + y * wy + z * wz
        let spread = x * x * xx + y * y * yy + z * z * zz + 2 * (x * y * xy + x * z * xz + y * z * yz)
        return max((1 - a) * (1 - a) * ww + 2 * a * (1 - a) * along + a * a * spread, 0)
    }
}

/// Beam shape: 0.5 = cardioid, 0.63 = supercardioid (full ahead, about −9 dB to the sides, −12 dB behind).
nonisolated let beamShape = 0.63

/// What a supercardioid mic aimed along `w` (ambisonic weights: front, left, up) would record. Channels W, Y, Z, X.
nonisolated func beamSignal(_ ch: [[Float]], _ w: SIMD3<Float>) -> [Float] {
    let a = Float(beamShape)
    var out = vDSP.multiply(1 - a, ch[0])
    out = vDSP.add(multiplication: (ch[3], a * w.x), out)
    out = vDSP.add(multiplication: (ch[1], a * w.y), out)
    return vDSP.add(multiplication: (ch[2], a * w.z), out)
}

/// Real FFT of up to 1024 samples (Hann window, zero-padded): bins 0..<512 as (re, im).
nonisolated final class Spectrum: @unchecked Sendable {
    static let size = 1024
    private let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)

    func callAsFunction(_ x: [Float]) -> (re: [Float], im: [Float]) {
        let n = min(x.count, Self.size), half = Self.size / 2
        let input = vDSP.multiply(Array(x.prefix(n)), Array(window.prefix(n))) + [Float](repeating: 0, count: Self.size - n)
        var inRe = [Float](repeating: 0, count: half), inIm = inRe, outRe = inRe, outIm = inRe
        inRe.withUnsafeMutableBufferPointer { ir in
            inIm.withUnsafeMutableBufferPointer { ii in
                outRe.withUnsafeMutableBufferPointer { or in
                    outIm.withUnsafeMutableBufferPointer { oi in
                        var split = DSPSplitComplex(realp: ir.baseAddress!, imagp: ii.baseAddress!)
                        input.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half)) }
                        var out = DSPSplitComplex(realp: or.baseAddress!, imagp: oi.baseAddress!)
                        fft.forward(input: split, output: &out)
                    }
                }
            }
        }
        return (outRe, outIm)
    }
}

/// Acoustic intensity of each frequency from 300 Hz to 4 kHz: phone-frame vector (xyz, length = directional power)
/// and that frequency's total power |W|² (w). Channels W, Y, Z, X.
nonisolated func binIntensities(_ ch: [[Float]], sampleRate: Double, spectrum: Spectrum) -> [SIMD4<Float>] {
    let df = sampleRate / Double(Spectrum.size), lo = max(Int(300 / df), 1), hi = min(Int(4000 / df), Spectrum.size / 2 - 1)
    guard lo < hi else { return [] }
    let (w, y, z, x) = (spectrum(ch[0]), spectrum(ch[1]), spectrum(ch[2]), spectrum(ch[3]))
    let front = SIMD3<Float>(foaFront), left = SIMD3<Float>(foaLeft), up = SIMD3<Float>(foaUp)
    return (lo...hi).map { k in
        func cross(_ c: (re: [Float], im: [Float])) -> Float { w.re[k] * c.re[k] + w.im[k] * c.im[k] }  // Re(conj(W)·C)
        let v = cross(x) * front + cross(y) * left + cross(z) * up
        return SIMD4(v, w.re[k] * w.re[k] + w.im[k] * w.im[k])
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
    var db = -120.0      // overall level (W, after the high-pass), dBFS
    var spec: [SIMD3<Float>] = []  // per frequency: intensity in the runner's frame (x ahead, y left) and power (z)
}

/// Shortest angle between two directions, degrees (0…180).
nonisolated func angularDistance(_ a: Double, _ b: Double) -> Double { abs(remainder(a - b, 360)) }

/// Directions sounds came from in [start, end), most distinct first. Each frequency gets its own direction (averaged
/// over the window) and one vote weighted by how clearly directional it is, not how loud: a siren's few strong tones
/// then form their own direction even under louder people talking, instead of merging into one in between.
nonisolated func soundSources(_ samples: [DirectionSample], from start: Double, to end: Double) -> [Double] {
    histogramPeaks(sourceHistogram(samples, from: start, to: end))
}

/// The votes behind soundSources: 36 directions (10° each, 0 = ahead, counter-clockwise), each frequency's
/// window-averaged direction voting with its directness².
nonisolated func sourceHistogram(_ samples: [DirectionSample], from start: Double, to end: Double) -> [Double] {
    var sum: [SIMD3<Double>] = []
    for s in samples where s.t >= start && s.t < end && !s.spec.isEmpty {
        if sum.isEmpty { sum = Array(repeating: .zero, count: s.spec.count) }
        guard s.spec.count == sum.count else { continue }
        for k in sum.indices { sum[k] += SIMD3<Double>(s.spec[k]) }
    }
    var h = [Double](repeating: 0, count: 36)
    for b in sum where b.z > 0 {
        let directness = min((b.x * b.x + b.y * b.y).squareRoot() / b.z, 1)
        h[slot(atan2(b.y, b.x) * 180 / .pi, of: h.count)] += directness * directness
    }
    return h
}

/// Peaks of a circular direction histogram (bins of 360/count degrees), strongest first, at most 3.
nonisolated func histogramPeaks(_ h: [Double]) -> [Double] {
    let n = h.count, width = 360 / Double(max(n, 1))
    guard n > 2 else { return [] }
    let smooth = (0..<n).map { 0.5 * h[($0 + n - 1) % n] + h[$0] + 0.5 * h[($0 + 1) % n] }
    guard let top = smooth.max(), top > 0 else { return [] }
    let peaks = (0..<n).filter { i in
        smooth[i] >= 0.15 * top && smooth[i] >= smooth[(i + n - 1) % n] && smooth[i] > smooth[(i + 1) % n]
    }
    return peaks.sorted { smooth[$0] > smooth[$1] }.prefix(3).map { i in  // power-weighted centre of the peak
        var c = 0.0, s = 0.0
        for d in -1...1 {
            let a = Double(i + d) * width * .pi / 180, w = h[(i + d + n) % n]
            c += w * cos(a)
            s += w * sin(a)
        }
        return atan2(s, c) * 180 / .pi
    }
}

/// The 4 directional beams the classifier also listens through (runner's frame): ahead, left, behind, right.
nonisolated let beamAzimuths: [Double] = [0, 90, 180, 270]
nonisolated let beamNames = ["ahead", "left", "behind", "right"]

/// Where the beam scores point: each beam's direction, weighted by how much more it heard the sound than the
/// least-hearing beam. Biased (the clearest beam is the one that best avoids *other* sounds), so only used to
/// choose between the directions in soundSources. Nil without real evidence: the beams barely disagree, or every
/// beam hears the sound clearly (nothing masks it from any side, so the differences are just classifier noise).
// ponytail: 0.25 spread from synthetic scenes; weaker spreads pointed at the wrong source half the time
nonisolated func beamEstimate(_ scores: [Double]) -> Double? {
    guard scores.count == beamAzimuths.count, let lo = scores.min(), let hi = scores.max(),
          hi - lo >= 0.25, lo < alertThreshold else { return nil }
    var c = 0.0, s = 0.0
    for (k, score) in scores.enumerated() {
        c += (score - lo) * cos(beamAzimuths[k] * .pi / 180)
        s += (score - lo) * sin(beamAzimuths[k] * .pi / 180)
    }
    return atan2(s, c) * 180 / .pi
}

/// Which direction a classified sound came from. Confirmed: the heard direction nearest to where its beam scores
/// point. Otherwise, in order: the same sound's last confirmed direction (`previous`, a siren doesn't jump), the
/// beams' rough pointing, the only direction heard, the heard direction nearest the loudest one in that half second
/// (`loudest`, the arrow: an alert sound every beam hears clearly is usually the loudest thing); nil = no direction at all.
nonisolated func pickDirection(sources: [Double], beams: Double?, previous: Double?, loudest: Double? = nil) -> (azimuth: Double, confirmed: Bool)? {
    if let beams {
        if let nearest = sources.min(by: { angularDistance($0, beams) < angularDistance($1, beams) }),
           angularDistance(nearest, beams) <= 90 { return (nearest, true) }
        return (previous ?? beams, false)
    }
    if let previous { return (previous, false) }
    if sources.count == 1 { return (sources[0], false) }
    guard let loudest else { return nil }
    return (sources.min(by: { angularDistance($0, loudest) < angularDistance($1, loudest) }) ?? loudest, false)
}

nonisolated let sirenLabels: Set<String> = ["siren", "police_siren", "ambulance_siren", "fire_engine_siren",
                                             "emergency_vehicle", "civil_defense_siren"]
/// Sounds that last (sirens, reversing beeps, trains): confirmed over time before alerting.
nonisolated let longSounds = sirenLabels.union(["reverse_beeps", "train_horn", "train_whistle"])

/// Whether a sound's recent scores (best of the 5 listeners per window, per family, newest last) are convincing.
/// Measured on siren-like non-sirens (singing, whistling, beeping, kettle) vs synthetic sirens and honks:
/// - long sounds: ≥ 0.5 in 2 of the last 3 windows (no false sirens, all sirens caught within 0.5 s)
/// - horns: one window ≥ 0.3 (short; nothing else was ever scored as a horn)
/// - the rest (screams, skids, bells, barks, shouts): one window ≥ 0.7, or two in a row ≥ 0.5
// ponytail: tuned on synthetic sounds; re-check with replay on real recordings
/// The rule `convincing` applies to `label`, in words.
nonisolated func confirmRule(_ label: String) -> String {
    if horns.contains(label) { return "one window ≥ 0.30" }
    if longSounds.contains(label) { return "≥ 0.50 in 2 of the last 3 windows" }
    return "one window ≥ 0.70, or two in a row ≥ 0.50"
}

/// Why an alert sound got its level, in words (same rules as alertLevel).
nonisolated func levelExplanation(_ label: String, azimuth: Double?, overUsual: Double?) -> String {
    let vsUsual = overUsual.map { String(format: "%+.0f dB vs this street's usual", $0) } ?? "street level not learned yet"
    let what = alertName(label).what
    if let o = overUsual, o >= Detector.nearDB { return "near: \(vsUsual) ≥ +\(Int(Detector.nearDB)) → critical" }
    if alwaysCritical.contains(label) { return "\(what) is always critical (\(vsUsual))" }
    guard horns.contains(label) else { return "\(what) is a warning unless near (\(vsUsual), needs +\(Int(Detector.nearDB)))" }
    guard let azimuth else { return "horn, direction unclear → assume critical" }
    let s = slot(azimuth, of: sectorNames.count)
    return Detector.warnSectors.contains(s) ? "horn \(sectorNames[s]), out of view → critical"
        : "horn \(sectorNames[s]), in view and not near (\(vsUsual)) → warning"
}

nonisolated func convincing(_ label: String, _ trail: [Double]) -> Bool {
    guard let now = trail.last else { return false }
    if horns.contains(label) { return now >= alertThreshold }
    if longSounds.contains(label) { return trail.suffix(3).filter { $0 >= 0.5 }.count >= 2 }
    return now >= 0.7 || (trail.count >= 2 && now >= 0.5 && trail[trail.count - 2] >= 0.5)
}

/// One key per family (all siren variants share one score history).
nonisolated func familyKey(_ label: String) -> String { family(of: label).sorted().first ?? label }

/// Labels that are the same sound to a runner (the classifier flips between them from one half second to the next).
nonisolated func family(of label: String) -> Set<String> {
    sirenLabels.contains(label) ? sirenLabels : horns.contains(label) ? horns : [label]
}

/// What to call an alert sound: one name per family, so a siren doesn't flip between "Siren" and "Emergency vehicle".
nonisolated func alertName(_ label: String) -> (what: String, short: String) {
    if sirenLabels.contains(label) { return ("Siren", "Siren") }
    if horns.contains(label) { return ("Horn", "Horn") }
    return (pretty(label), shortLabel(label))
}

/// Which alert sound to report from one classifier window (best score per label across the all-around mic and the
/// beams) and the last few windows' siren scores: critical kinds first, then the highest score.
/// An ongoing sound (`current`, any label of its family) keeps priority over a new one of the same rank.
nonisolated func pickAlert(_ best: [String: Double], trails: [String: [Double]], current: String? = nil) -> (label: String, score: Double)? {
    let passing = best.filter { convincing($0.key, trails[familyKey($0.key)] ?? [$0.value]) }
    func rank(_ label: String) -> Int { alwaysCritical.contains(label) ? 2 : horns.contains(label) ? 1 : 0 }
    let ongoing = current.map(family(of:)) ?? []
    func key(_ l: String, _ s: Double) -> (Int, Int, Double) { (rank(l), ongoing.contains(l) ? 1 : 0, s) }
    return passing.max { key($0.key, $0.value) < key($1.key, $1.value) }.map { ($0.key, $0.value) }
}

/// Loudest overall level in [start, end), for judging whether a sound was near.
nonisolated func peakDB(_ samples: [DirectionSample], from start: Double, to end: Double) -> Double? {
    samples.filter { $0.t >= start && $0.t < end }.map(\.db).max()
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

/// Weighted circular mean of directions (degrees) and the weighted average distance from it (how much they scatter).
nonisolated func circularMean(_ samples: [(deg: Double, weight: Double)]) -> (mean: Double, spread: Double)? {
    var c = 0.0, s = 0.0, total = 0.0
    for x in samples where x.weight > 0 {
        c += x.weight * cos(x.deg * .pi / 180)
        s += x.weight * sin(x.deg * .pi / 180)
        total += x.weight
    }
    guard total > 0, c != 0 || s != 0 else { return nil }
    let mean = atan2(s, c) * 180 / .pi
    return (mean, samples.filter { $0.weight > 0 }.map { $0.weight * angularDistance($0.deg, mean) }.reduce(0, +) / total)
}

/// The fine-tune that best explains a direction test: the arrow measured with fine-tune off for sounds at known
/// directions. Tries mirror off and on; leftover = average error after the fit (large = not a simple rotation:
/// front/back mix-ups, echoes, or the body blocking). Needs 2 directions 90° apart to tell mirrored from not.
nonisolated func fitFineTune(_ tests: [(truth: Double, measured: Double)]) -> (offset: Double, mirror: Bool, leftover: Double)? {
    guard tests.count >= 2 else { return nil }
    return [false, true].compactMap { mirror -> (offset: Double, mirror: Bool, leftover: Double)? in
        // No offset at all when the candidates cancel out (this mirror setting fits nothing).
        guard let offset = circularMean(tests.map { ((mirror ? -1 : 1) * -$0.measured + $0.truth, 1) })?.mean else { return nil }
        let leftover = tests.map { angularDistance(calibrated($0.measured, offset: offset, mirror: mirror), $0.truth) }.reduce(0, +)
        return (offset, mirror, leftover / Double(tests.count))
    }.min { $0.leftover < $1.leftover }
}

/// Both values, or nil.
nonisolated func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

/// Index of the slice an angle falls in when the circle is cut into `count` equal slices centred on 0°.
nonisolated func slot(_ degrees: Double, of count: Int) -> Int {
    (Int((degrees / 360 * Double(count)).rounded()) % count + count) % count
}

nonisolated enum AlertLevel: Int, Comparable, Sendable {
    case warning   // orange: worth knowing (horn ahead, bike bell, dog, shout, something getting closer, your name)
    case critical  // red: act now (siren, horn from behind or the side, anything near, your danger words)
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Urgent wherever they are and however loud.
nonisolated let alwaysCritical: Set<String> = ["siren", "police_siren", "ambulance_siren", "fire_engine_siren", "emergency_vehicle",
                                                "civil_defense_siren", "vehicle_skidding", "screaming", "train_horn", "train_whistle"]
nonisolated let horns: Set<String> = ["car_horn", "air_horn", "foghorn"]

/// How urgent a classifier alert sound is. Sirens, skidding, screams and trains are always critical. A horn is critical
/// unless it's ahead of you (in view) and not near. Anything else (bike bell, reversing beeps, dog, shout) is a
/// warning. Anything near is critical.
nonisolated func alertLevel(_ label: String, azimuth: Double?, near: Bool) -> AlertLevel {
    if near || alwaysCritical.contains(label) { return .critical }
    guard horns.contains(label) else { return .warning }
    guard let azimuth else { return .critical }  // can't tell where it is: assume the worst
    return Detector.warnSectors.contains(slot(azimuth, of: sectorNames.count)) ? .critical : .warning
}

/// "car_horn" -> "Horn": one word for the compact Dynamic Island.
nonisolated func shortLabel(_ id: String) -> String {
    pretty(id.split(separator: "_").last.map(String.init) ?? id)
}

/// Danger words listened for until the user changes them (Alerts screen).
nonisolated let defaultDangerWords = "watch out, look out, careful"

/// Comma-separated user input -> phrases ("Vincent, Vince" -> ["Vincent", "Vince"]).
nonisolated func phrases(_ list: String) -> [String] {
    list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Which of `phrases` was said in `text`: whole words, ignoring case, accents and punctuation.
nonisolated func matchedPhrase(in text: String, among phrases: [String]) -> String? {
    func words(_ s: String) -> String {
        " " + s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
    }
    let said = words(text)
    return phrases.first { words($0).count > 2 && said.contains(words($0)) }
}

/// "behind on your left" etc., for the status card, notifications and the Dynamic Island.
nonisolated func directionWords(_ azimuth: Double?) -> String {
    guard let azimuth else { return "around you" }
    let names = ["ahead", "ahead on your left", "on your left", "behind on your left",
                 "behind you", "behind on your right", "on your right", "ahead on your right"]
    return names[slot(azimuth, of: names.count)]
}

/// Seconds until an approaching sound reaches you, from how fast it gets louder: loudness falls 6 dB per doubling
/// of distance, so something coming straight at you at a steady speed rises 8.7 / (seconds to reach) dB per second.
/// Needs no calibration and no idea how loud the source is. Reads high for things passing beside you.
nonisolated func secondsToReach(risingDBPerSecond rate: Double) -> Double? {
    rate > 0.5 ? 20 / log(10) / rate : nil
}

/// Experimental: the direction most likely coming at you (stands out from the other directions and is getting
/// louder) and how many seconds until it arrives. Looser than the "getting closer" warning, so it shows earlier.
/// The rise is measured over the last second after 0.3 s smoothing, i.e. it describes ~0.8 s ago.
nonisolated func reachEstimate(_ stats: [ApproachDetector.SectorStat]) -> (sector: Int, seconds: Double)? {
    let rule = ApproachDetector()
    let candidates = stats.indices.filter { stats[$0].lead >= rule.leadDB && stats[$0].db > rule.minDB && stats[$0].recentRise > 0.5 }
    guard let s = candidates.max(by: { stats[$0].db < stats[$1].db }),
          let secs = secondsToReach(risingDBPerSecond: stats[s].recentRise) else { return nil }
    return (s, max(secs - 0.8, 0))
}

/// Distance from loudness alone, given the same sound's level at a known distance (6 dB quieter per doubling).
nonisolated func metersFromLevel(_ db: Double, reference refDB: Double, at refMeters: Double) -> Double {
    refMeters * pow(10, (refDB - db) / 20)
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
        var recentRise: Double   // dB gained in the last second
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
            return SectorStat(db: l[n - 1], rise: rise, biggestJump: jump, lead: lead, sweep: sweep,
                              recentRise: l[n - 1] - l[n - 1 - back], ledFor: Double(led) * tick,
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
    var bins: [SIMD4<Float>] = []  // per-frequency intensity (phone frame) and power (binIntensities)
}

/// Turns one delivered buffer into a Block on the shared stream clock. Used by the live tap and the replay tool.
nonisolated struct BlockMaker {
    // ponytail: below ~200 Hz it's mostly wind on the mics and engine rumble, which drag the direction around; tune with replay
    static let highPassHz = 200.0
    private var frames: AVAudioFramePosition = 0
    private var highPass: [HighPass] = []
    private let spectrum = Spectrum()

    /// The block (direction path high-passed), the unfiltered omni channel and beams (one per `steering` weight) for
    /// the classifiers, and the block's frame position.
    mutating func make(_ buf: AVAudioPCMBuffer, savingAudio: Bool = false, steering: [SIMD3<Float>] = [])
        -> (block: Block, omni: [Float], beams: [[Float]], at: AVAudioFramePosition) {
        let format = buf.format, sr = format.sampleRate
        if highPass.isEmpty { highPass = (0..<4).compactMap { _ in HighPass(cutoff: Self.highPassHz, sampleRate: sr) } }
        let raw = (0..<4).map { samples(buf, channel: $0) }
        let ch = highPass.count == 4 ? (0..<4).map { highPass[$0].apply(raw[$0]) } : raw
        let kind = format.commonFormat == .pcmFormatFloat32 ? "float32" : format.commonFormat == .pcmFormatInt16 ? "int16" : "other"
        let block = Block(reading: foaReading(w: ch[0], y: ch[1], z: ch[2], x: ch[3]),
                          start: Double(frames) / sr, duration: Double(buf.frameLength) / sr,
                          format: "\(Int(sr)) Hz · \(format.channelCount) ch · \(kind)\(format.isInterleaved ? " interleaved" : "") · \(buf.frameLength) frames",
                          savingAudio: savingAudio, bins: binIntensities(ch, sampleRate: sr, spectrum: spectrum))
        let at = frames
        frames += AVAudioFramePosition(buf.frameLength)
        return (block, raw[0], steering.map { beamSignal(raw, $0) }, at)
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
    var rawAzimuth: Double?   // this block, from the phone's pose alone; nil when the pose has no "ahead"
    var correction: Double    // arm-swing correction from the gyro, degrees
    var blockAzimuth: Double? // this block after fine-tune + correction (jumpy: one 21 ms block)
    var azimuth: Double?      // the arrow: blockAzimuth averaged over ~0.3 s; what everything else uses
    var levelDB: Double       // overall level averaged over ~1 s (steadier than one block)
    var hum: Double?          // the street's background level (dB), once known
    var usual: Double?        // the street's usual level (dB), once known
    var loudness: Double      // 0…1: how far above the hum, over 24 dB
    var strength: Double      // radar line length = loudness × directness
}

nonisolated struct Bin: Sendable { var strength = 0.0, kind = SoundKind.other }

nonisolated struct Alert: Equatable, Sendable {
    var azimuth: Double?  // nil = heard it but direction unclear
    var what: String      // "Car horn", "Vehicle getting closer", "Someone called “Vincent”"
    var level: AlertLevel
    var short: String     // one word for the compact Dynamic Island: "Horn", "Siren", "Vehicle", "Name"
}

/// How the latest alert decision was reached (debug screen).
nonisolated struct JudgedWindow: Sendable {
    var label: String              // "" = nothing passed
    var score: Double
    var beamScores: [Double]       // that label's score per beam (ahead, left, behind, right); empty without beams
    var sources: [Double]          // directions heard in that window
    var beamPointing: Double?
    var azimuth: Double?
    var listeners: [ListenerScore] = []  // what each of the 5 listeners heard most (alert sounds only)
    var directionReason = ""
    var levelReason = ""
}

/// One listener's strongest alert sound in a window.
nonisolated struct ListenerScore: Sendable {
    var name: String   // "All-around", "Beam left", …
    var label: String  // "" = no alert sound at all
    var score: Double
}

/// Everything the debug screen shows, refreshed 10×/s so numbers stay readable.
nonisolated struct DebugSnapshot: Sendable {
    var processed: Processed
    var mics: [Double]  // dB per phone side, lightly smoothed
    var sectors: [ApproachDetector.SectorStat]
    var heldBack: [Int: String]  // approaching sectors not warned, by reason (view, usual, settling, passing, kind)
    var heard: Heard?
    var heardLatency: Double
    var lastJudged: JudgedWindow?
    var histogram: [Double]          // sourceHistogram of the last half second
    var trails: [String: [Double]]   // per sound family: best score of the last 3 windows (recently heard ones)
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
    // ponytail: guess; "near" = this much louder than the street usually is. Tune with replay on real recordings.
    static let nearDB = 15.0
    // The arrow averages this long: 3–6× steadier than single blocks in street noise (synthetic benchmark), still
    // follows a moving sound. Longer = steadier but laggier.
    static let arrowSeconds = 0.3

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
    private var levelPower = 0.0  // ~1 s running average of W power
    private var heading = HeadingSmoother()
    private var arrow = SIMD2<Double>.zero  // runner frame (x ahead, y left), length = directional power, ~0.3 s average
    private var recent: [DirectionSample] = []  // last few seconds, for the classifier's and transcriber's late results
    private var lastWords: [String: Double] = [:]  // phrase -> when it last raised an alert
    private var windows: [Int: (omni: Heard?, beams: [Int: Heard])] = [:]  // classifier answers by window start (ms)
    private var scoreTrails: [String: [Double]] = [:]  // per family: best score of the last 3 windows
    private var lastFix: (label: String, azimuth: Double, at: Double)?  // last confirmed direction of an alert sound
    private var currentLabel: String?             // classifier label of the alert being shown
    private var lastJudged: JudgedWindow?
    /// Ambisonic weights (front, left, up) aiming the 4 classifier beams; follows the phone's pose and arm swing.
    private(set) var beamWeights: [SIMD3<Float>] = beamAzimuths.map { SIMD3(Float(cos($0 * .pi / 180)), Float(sin($0 * .pi / 180)), 0) }
    private var mics = [Double](repeating: -120, count: phoneSides.count)
    private var alertUntil = -Double.infinity
    private var alertHeardAt = -Double.infinity  // last time the shown alert's sound was (re)confirmed
    private var lastPulse = -Double.infinity

    /// Strongest recent direction, optionally only among spokes tagged with `kind`.
    func loudestAzimuth(of kind: SoundKind? = nil) -> Double? {
        let pool = bins.indices.filter { kind == nil || bins[$0].kind == kind }
        guard let i = pool.max(by: { bins[$0].strength < bins[$1].strength }), bins[i].strength > 0.05 else { return nil }
        return Double(i) * 360 / Double(bins.count)
    }

    func snapshot() -> DebugSnapshot? {
        last.map { DebugSnapshot(processed: $0, mics: mics, sectors: approach.stats(), heldBack: heldBack, heard: heard,
                                 heardLatency: heardLatency, lastJudged: lastJudged,
                                 histogram: sourceHistogram(recent, from: clock - 0.5, to: clock + 1),
                                 trails: scoreTrails.filter { ($0.value.max() ?? 0) >= 0.1 },
                                 events: events, alert: alert, kind: kind) }
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

    /// One classifier answer: from the all-around mic (h.beam == nil) or one of the 4 beams. The 5 answers for the
    /// same half second are judged together, as soon as all are in (or a newer window overtakes a straggler).
    mutating func hear(_ h: Heard) {
        if h.beam == nil {
            heard = h
            heardLatency = clock - h.end
            if h.kind != kind { log("classifier: \(h.kind)\(h.label.isEmpty ? "" : " (\(pretty(h.label)))")") }
            kind = h.kind
            label = pretty(h.label)
        }
        let key = Int((h.start * 1000).rounded())
        var w = windows[key] ?? (omni: nil, beams: [:])
        if let b = h.beam { w.beams[b] = h } else { w.omni = h }
        windows[key] = w
        for k in windows.keys.sorted() {
            guard let w = windows[k] else { continue }
            if (w.omni != nil && w.beams.count == beamAzimuths.count) || key - k >= 400 {
                windows[k] = nil
                judge(w.omni, w.beams)
            }
        }
    }

    /// Decide whether a window holds an alert sound and where it came from. Critical sounds win over louder or
    /// higher-scoring warnings; the direction is that sound's own, not the loudest thing's.
    private mutating func judge(_ omni: Heard?, _ beams: [Int: Heard]) {
        let all = (omni.map { [$0] } ?? []) + Array(beams.values)
        guard let start = all.first?.start, let end = all.first?.end else { return }
        var best: [String: Double] = [:]
        for h in all { for (l, s) in h.alertScores { best[l] = max(best[l] ?? 0, s) } }
        var familyBest: [String: Double] = [:]
        for (l, v) in best { familyBest[familyKey(l)] = max(familyBest[familyKey(l)] ?? 0, v) }
        for k in Set(scoreTrails.keys).union(familyBest.keys) {
            scoreTrails[k] = Array(((scoreTrails[k] ?? []) + [familyBest[k] ?? 0]).suffix(3))
        }
        var listeners: [ListenerScore] = []
        for (name, h) in [("All-around", omni)] + beamAzimuths.indices.map({ ("Beam \(beamNames[$0])", beams[$0]) }) {
            guard let h else { continue }
            let top = h.alertScores.max { $0.value < $1.value }
            listeners.append(ListenerScore(name: name, label: top?.key ?? "", score: top?.value ?? 0))
        }
        let ongoing = alert != nil && clock <= alertUntil ? currentLabel : nil
        guard let pick = pickAlert(best, trails: scoreTrails, current: ongoing) else {
            lastJudged = JudgedWindow(label: "", score: best.values.max() ?? 0, beamScores: [], sources: [], beamPointing: nil,
                                      azimuth: nil, listeners: listeners)
            return
        }
        // The verdict lands ~0.5 s after the sound, so look back at the exact half second it judged.
        let fam = family(of: pick.label)
        let beamScores = beams.count == beamAzimuths.count
            ? beamAzimuths.indices.map { k in fam.map { beams[k]?.alertScores[$0] ?? 0 }.max() ?? 0 } : []
        let sources = soundSources(recent, from: start, to: end), pointing = beamEstimate(beamScores)
        let previous = lastFix.flatMap { fam.contains($0.label) && clock - $0.at < 3 ? $0.azimuth : nil }
        let loudest = soundDirection(recent, from: start, to: end)?.azimuth
        let picked = pickDirection(sources: sources, beams: pointing, previous: previous, loudest: loudest)
        // Confirmed, or the remembered one reused: keep it alive while the same sound goes on.
        if let picked, picked.confirmed || picked.azimuth == previous { lastFix = (pick.label, picked.azimuth, clock) }
        var azimuth = picked?.azimuth
        // Already showing this sound and following it live (add): keep that, unless this verdict puts it elsewhere.
        // The verdict is about audio from ~0.5–1 s ago, so a moving sound would otherwise jump back.
        let live = alert?.what == alertName(pick.label).what && clock - alertHeardAt < 1 ? alert?.azimuth : nil
        let followed = live.map { l in azimuth.map { angularDistance($0, l) <= 45 } ?? true } ?? false
        if followed { azimuth = live }
        currentLabel = pick.label
        let directionReason = switch picked {
        case _ where followed: "followed live since it was first placed (this verdict agrees)"
        case nil: "unclear: no direction measured (the phone's pose has no \"ahead\")"
        case let p? where p.confirmed: "the heard direction nearest to where the beams point"
        case let p? where p.azimuth == previous: "kept: this sound's last confirmed direction"
        case _ where pointing != nil: "the beams' rough pointing (no heard direction within 90°)"
        case _ where sources.count == 1: "the only direction heard"
        default: "the heard direction nearest the loudest one (the arrow); the beams give no evidence"
        }
        let overUsual = zip2(peakDB(recent, from: start, to: end), levels.usual).map { $0 - $1 }
        lastJudged = JudgedWindow(label: pick.label, score: pick.score, beamScores: beamScores, sources: sources,
                                  beamPointing: pointing, azimuth: azimuth, listeners: listeners, directionReason: directionReason,
                                  levelReason: levelExplanation(pick.label, azimuth: azimuth, overUsual: overUsual))
        let name = alertName(pick.label)
        if kind != .alert { log("classifier: alert (\(name.what), heard over \(kind))") }
        kind = .alert
        label = name.what
        if let azimuth {
            let center = slot(azimuth, of: bins.count), peak = soundDirection(recent, from: start, to: end)?.peak ?? 0.5
            for d in -2...2 {
                let j = (center + d + bins.count) % bins.count
                bins[j] = Bin(strength: max(bins[j].strength, peak * (1 - 0.2 * Double(abs(d)))), kind: .alert)
            }
        }
        let near = (overUsual ?? -.infinity) >= Self.nearDB
        warn(Alert(azimuth: azimuth, what: name.what, level: alertLevel(pick.label, azimuth: azimuth, near: near), short: name.short))
    }

    /// Someone said the user's name (warning) or one of their danger words (critical); [start, end) is when, in
    /// stream seconds, so the direction comes from that audio. Once per phrase per 5 s: live transcripts repeat.
    mutating func heardWords(_ phrase: String, isName: Bool, from start: Double, to end: Double) {
        if let t = lastWords[phrase], clock - t < 5 { return }
        lastWords[phrase] = clock
        let found = soundDirection(recent, from: start, to: max(end, start + 0.5))
        warn(Alert(azimuth: found?.azimuth, what: isName ? "Someone called “\(phrase)”" : "Someone said “\(phrase)”",
                   level: isName ? .warning : .critical, short: isName ? "Name" : pretty(phrase)))
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
        let axes = groundAxes(gravity: m.gravity)
        let raw = axes.map { atan2(simd_dot(r.phoneVector, $0.left), simd_dot(r.phoneVector, $0.ahead)) * 180 / .pi }
        let blockAz = raw.map { remainder(calibrated($0, offset: offset, mirror: mirror) + correction, 360) }
        // The arrow: each block's direction weighted by how loud and directional it is, averaged in the runner's frame
        // (arm swing already taken out, so it doesn't blur). One 21 ms block alone jitters with street noise.
        var az: Double?
        if let blockAz, let axes {
            let v = r.phoneVector, a = blockAz * .pi / 180
            let length = (pow(simd_dot(v, axes.ahead), 2) + pow(simd_dot(v, axes.left), 2)).squareRoot()
            arrow += (SIMD2(length * cos(a), length * sin(a)) - arrow) * min(b.duration / Self.arrowSeconds, 1)
            az = atan2(arrow.y, arrow.x) * 180 / .pi
        }
        // Lines measure how far a sound stands out above this street's hum, not raw loudness.
        levels.add(r.db, at: b.start)
        levelPower += (r.ww - levelPower) * min(b.duration, 1)
        let loudness = min(max((r.db - (levels.hum ?? r.db)) / 24, 0), 1)
        let strength = az == nil ? 0 : loudness * r.directness

        if let az, let axes {
            // Each frequency's own direction in the runner's frame, so simultaneous sounds stay apart (soundSources).
            let spec = b.bins.map { v -> SIMD3<Float> in
                let p = SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z)), ahead = simd_dot(p, axes.ahead), left = simd_dot(p, axes.left)
                let a = (calibrated(atan2(left, ahead) * 180 / .pi, offset: offset, mirror: mirror) + correction) * .pi / 180
                let length = (ahead * ahead + left * left).squareRoot()
                return SIMD3(Float(length * cos(a)), Float(length * sin(a)), v.w)
            }
            recent.append(DirectionSample(t: b.start, azimuth: az, power: r.ww * r.directness, strength: strength, db: r.db, spec: spec))
            recent.removeAll { $0.t < b.start - 8 }
            followAlert()
            let center = slot(az, of: bins.count)
            for (d, k) in [(0, 1.0), (-1, 0.5), (1, 0.5)] {
                let j = (center + d + bins.count) % bins.count
                if strength * k > bins[j].strength { bins[j] = Bin(strength: strength * k, kind: kind) }
            }
        }
        // Horns and sirens are raised in hear(); here only "something is getting closer".
        if let axes {
            /// A runner-frame direction as a phone-frame unit vector (undoing arm-swing correction and fine-tune).
            func onPhone(_ azimuth: Double) -> SIMD3<Double> {
                let a = azimuth - correction - offset, deg = (mirror ? -a : a) * .pi / 180
                return cos(deg) * axes.ahead + sin(deg) * axes.left
            }
            let beams = (0..<ApproachDetector.sectors).map { r.beamPower(toward: onPhone(Double($0) * 360 / Double(ApproachDetector.sectors))) }
            if let rising = approach.update(sectorPower: beams, dt: b.duration) { judgeApproach(rising) }
            beamWeights = beamAzimuths.map { u in
                let p = onPhone(u)
                return SIMD3(Float(simd_dot(p, foaFront)), Float(simd_dot(p, foaLeft)), Float(simd_dot(p, foaUp)))
            }
        }
        let p = Processed(block: b, motion: m, rawAzimuth: raw, correction: correction, blockAzimuth: blockAz, azimuth: az,
                          levelDB: 10 * log10(max(levelPower, 1e-12)), hum: levels.hum, usual: levels.usual,
                          loudness: loudness, strength: strength)
        last = p
        return p
    }

    /// The classifier says what and roughly where, ~0.5–1 s late and 4× a second. While that sound is still being
    /// heard, move the alert every block toward the nearest direction heard in the last 0.3 s (within 30°), so a
    /// passing siren or your own turn shows at once instead of lagging.
    private mutating func followAlert() {
        guard var a = alert, let current = a.azimuth, clock - alertHeardAt < 1,
              let live = histogramPeaks(sourceHistogram(recent, from: clock - 0.3, to: clock + 1))
                  .min(by: { angularDistance($0, current) < angularDistance($1, current) }),
              angularDistance(live, current) <= 30 else { return }
        a.azimuth = remainder(current + 0.2 * remainder(live - current, 360), 360)
        alert = a
        if let fix = lastFix, alertName(fix.label).what == a.what { lastFix = (fix.label, a.azimuth!, clock) }
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
        let near = usual.map { stats[s].db - $0 >= Self.nearDB } ?? false
        warn(Alert(azimuth: Double(s) * 360 / Double(ApproachDetector.sectors),
                   what: kind == .traffic ? "Vehicle getting closer" : "Sound getting closer",
                   level: near ? .critical : .warning, short: kind == .traffic ? "Vehicle" : "Sound"))
    }

    private mutating func warn(_ a: Alert) {
        if let current = alert, current.level > a.level, clock <= alertUntil { return }  // a warning never hides a critical
        if alert?.what != a.what || alert?.level != a.level {
            log("\(a.level == .critical ? "CRITICAL" : "WARNING"): \(a.what) at \(a.azimuth.map { "\(Int($0.rounded()))°" } ?? "unknown direction")")
        }
        let isNew = alert == nil || alert?.what != a.what || alert?.level != a.level
        alert = a
        alertUntil = clock + 3
        alertHeardAt = clock
        if (isNew && clock - lastPulse > 1.5) || clock - lastPulse > 10 {
            alertPulse += 1
            lastPulse = clock
        }
    }
}

nonisolated func selfCheck() {
    // Levels: sirens always critical; horns critical unless ahead and not near; bells, dogs, shouts are warnings until near.
    precondition(alertLevel("police_siren", azimuth: 0, near: false) == .critical, "siren ahead, far")
    precondition(alertLevel("car_horn", azimuth: 180, near: false) == .critical, "horn behind")
    precondition(alertLevel("car_horn", azimuth: 90, near: false) == .critical, "horn on the left")
    precondition(alertLevel("car_horn", azimuth: 10, near: false) == .warning, "horn ahead, far")
    precondition(alertLevel("car_horn", azimuth: 10, near: true) == .critical, "horn ahead, near")
    precondition(alertLevel("car_horn", azimuth: nil, near: false) == .critical, "horn, direction unknown")
    precondition(alertLevel("dog_bark", azimuth: 180, near: false) == .warning, "dog, far")
    precondition(alertLevel("dog_bark", azimuth: 0, near: true) == .critical, "dog, near")
    precondition(shortLabel("police_siren") == "Siren" && shortLabel("shout") == "Shout")
    for (label, az, over) in [("car_horn", 10.0, 3.0), ("car_horn", 180.0, 3.0), ("dog_bark", 0.0, 20.0), ("dog_bark", 0.0, 2.0), ("siren", 0.0, 0.0)] {
        let says = levelExplanation(label, azimuth: az, overUsual: over), level = alertLevel(label, azimuth: az, near: over >= Detector.nearDB)
        precondition(says.contains("critical") == (level == .critical) || says.contains("always critical"), "explanation disagrees: \(says)")
    }
    // Sources: a siren and people talking at once are two directions, not one in between.
    func voice(_ deg: Double, _ k: Int, _ n: Int) -> [SIMD3<Float>] {  // n frequencies, the k-th dominated by a source at deg
        (0..<n).map { i in i % 2 == k ? SIMD3(Float(cos(deg * .pi / 180)), Float(sin(deg * .pi / 180)), 1) : SIMD3(0, 0, 0.01) }
    }
    let both = (0..<20).map { t in DirectionSample(t: Double(t) * 0.02, azimuth: 0, power: 1, strength: 1,
                                                   spec: zip(voice(90, 0, 80), voice(-45, 1, 80)).map { $0 + $1 }) }
    let heard = soundSources(both, from: 0, to: 1)
    precondition(heard.count == 2 && heard.contains { angularDistance($0, 90) < 6 } && heard.contains { angularDistance($0, -45) < 6 },
                 "siren left + chatter ahead-right -> \(heard)")
    // Direction: beams pointing behind-left pick the left source over the ahead-right one.
    precondition(abs(beamEstimate([0.05, 0.76, 0.56, 0.06])! - 124) < 5, "beam pointing")
    precondition(pickDirection(sources: [-45, 90], beams: 124, previous: nil)! == (90, true), "nearest heard direction")
    precondition(beamEstimate([0.30, 0.29, 0.14, 0.11]) == nil, "beams barely disagree: no evidence")
    precondition(beamEstimate([0.62, 0.50, 0.77, 0.57]) == nil, "every beam hears it clearly: no evidence")
    precondition(pickDirection(sources: [-45, 90], beams: nil, previous: nil) == nil, "two sounds, no evidence: unclear")
    precondition(pickDirection(sources: [-45], beams: 124, previous: 88)! == (88, false), "keeps the last confirmed direction")
    precondition(pickDirection(sources: [90], beams: nil, previous: nil)! == (90, false), "only one thing heard")
    precondition(pickDirection(sources: [-45, 90], beams: nil, previous: nil, loudest: 70)! == (90, false),
                 "two sounds, no beam evidence: the one nearest the loudest direction, not 'around you'")
    // Priority and confirmation: critical first; one siren-like moment isn't a siren; a honk counts at once.
    let sk = familyKey("siren")
    precondition(pickAlert(["dog_bark": 0.9, "police_siren": 0.6], trails: [familyKey("dog_bark"): [0.9, 0.9], sk: [0.6, 0.6]])!.label == "police_siren",
                 "siren beats louder dog")
    precondition(pickAlert(["siren": 0.9], trails: [sk: [0.1, 0.9]]) == nil, "one siren-like moment isn't a siren")
    precondition(pickAlert(["siren": 0.6], trails: [sk: [0.6, 0.2, 0.6]]) != nil, "2 of the last 3 is")
    precondition(pickAlert(["car_horn": 0.35], trails: [familyKey("car_horn"): [0.35]]) != nil, "a short honk counts at once")
    precondition(pickAlert(["dog_bark": 0.6], trails: [familyKey("dog_bark"): [0.1, 0.6]]) == nil, "a single 0.6 bark: not yet")
    precondition(pickAlert(["screaming": 0.8, "emergency_vehicle": 0.6], trails: [familyKey("screaming"): [0.8], sk: [0.6, 0.6]],
                           current: "police_siren")!.label == "emergency_vehicle", "ongoing siren keeps priority")
    precondition(alertName("emergency_vehicle").what == "Siren" && alertName("air_horn").short == "Horn", "one name per family")

    // Words: whole words, any case, accents and punctuation ignored.
    precondition(matchedPhrase(in: "Hey VINCENT, watch... out!", among: ["Vincent"]) == "Vincent")
    precondition(matchedPhrase(in: "Hey VINCENT, watch... out!", among: ["watch out"]) == "watch out")
    precondition(matchedPhrase(in: "Vincentius is here", among: ["Vincent"]) == nil, "part of a longer word")
    precondition(matchedPhrase(in: "José!", among: ["jose"]) == "jose")
    precondition(phrases(" Vincent , Vince,, ") == ["Vincent", "Vince"])
    // A warning (dog) never hides a critical (siren) that's still showing; a new critical replaces a warning.
    var d = Detector()
    d.heardWords("watch out", isName: false, from: 0, to: 0.5)
    d.heardWords("Vincent", isName: true, from: 0, to: 0.5)
    precondition(d.alert?.level == .critical && d.alert?.short == "Watch out", "name must not hide 'watch out'")
    d.heardWords("watch out", isName: false, from: 1, to: 1.5)
    precondition(d.alert?.what == "Someone said “watch out”", "same words within 5 s: no repeat")

    // Something 30 m away closing at 10 m/s reaches you in 3 s: measure its rise over a tenth of a second.
    let rise = 20 * log10(30.5 / 29.5) / 0.1
    precondition(abs(secondsToReach(risingDBPerSecond: rise)! - 3) < 0.05, "30 m at 10 m/s -> \(secondsToReach(risingDBPerSecond: rise)!) s")
    precondition(secondsToReach(risingDBPerSecond: 0) == nil, "not getting louder -> no estimate")
    precondition(abs(metersFromLevel(-42, reference: -30, at: 1) - 3.98) < 0.01, "12 dB quieter = 4x as far")

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

    // A car closing at 10 m/s from behind, through street hum: "reaches you in" lands within half a second at 2 s out.
    var car = Detector(), reach: Double?
    for k in 0..<500 {  // until it's 20 m away, 2 s before it reaches you
        let t = Double(k) * 0.02, r = 120 - 10 * t
        car.add(Block(reading: plane(10 * log10(1e-2 / (r * r)), from: 180, bed: -55), start: t, duration: 0.02, format: "", savingAudio: false),
                motion: Motion())
        reach = reachEstimate(car.snapshot()!.sectors)?.seconds
    }
    precondition(abs((reach ?? .infinity) - 2) < 0.5, "car 2 s away -> \(reach.map { "\($0)" } ?? "nothing") s")

    // The arrow: steadier than single blocks in noise, yet follows a sound that moves.
    var steadyDetector = Detector(), blockErrors: [Double] = [], arrowErrors: [Double] = []
    for k in 0..<300 {
        let t = Double(k) * 0.02, truth = t < 4 ? 120.0 : 30.0, wobble = 0.6 * sin(Double(k) * 2.39), wobble2 = 0.6 * cos(Double(k) * 1.71)
        var r = plane(-40, from: truth, bed: -40)
        r.wx += 1e-4 * wobble; r.wy += 1e-4 * wobble2  // street noise: each block's direction jitters
        let p = steadyDetector.add(Block(reading: r, start: t, duration: 0.02, format: "", savingAudio: false), motion: Motion())
        if t > 1 && t < 4 { blockErrors.append(angularDistance(p.blockAzimuth!, truth)); arrowErrors.append(angularDistance(p.azimuth!, truth)) }
        if t > 5 { precondition(angularDistance(p.azimuth!, truth) < 5, "arrow should follow a moved sound within 1 s -> \(p.azimuth!)") }
    }
    precondition(arrowErrors.max()! < blockErrors.max()! / 2, "arrow not steadier: \(arrowErrors.max()!) vs \(blockErrors.max()!)")
    // The alert follows its sound live: a siren on the left moving to ahead at 45°/s, while the classifier's
    // verdicts describe audio from 0.75 s earlier (they alone would lag ~34°).
    func toward(_ deg: Double) -> [SIMD4<Float>] {
        let v = cos(deg * .pi / 180) * foaFront + sin(deg * .pi / 180) * foaLeft
        return Array(repeating: SIMD4(Float(v.x), Float(v.y), Float(v.z), 1), count: 20)
    }
    var follow = Detector(), worstLag = 0.0
    for k in 0..<300 {
        let t = Double(k) * 0.02, now = t < 2 ? 90 : max(90 - 45 * (t - 2), 0)
        follow.add(Block(reading: plane(-40, from: now), start: t, duration: 0.02, format: "", savingAudio: false, bins: toward(now)),
                   motion: Motion())
        if k % 12 == 0, t >= 1 {
            for beam in [nil] + beamAzimuths.indices.map(Optional.some) {
                follow.hear(Heard(kind: .alert, label: "siren", alertScore: 0.9, start: t - 0.75, end: t - 0.25, top: [], beam: beam,
                                  alerts: ["siren": 0.9]))
            }
        }
        if t > 2.5, t < 4 { worstLag = max(worstLag, angularDistance(follow.alert!.azimuth!, now)) }
    }
    precondition(worstLag < 15, "alert should follow a moving siren -> lagged \(worstLag)°")

    // Direction test: a phone that reads everything mirrored and 20° off is recovered.
    let fit = fitFineTune([(0, 20), (90, -70), (180, -160)])!
    precondition(fit.mirror && angularDistance(fit.offset, 20) < 0.5 && fit.leftover < 0.5, "fine-tune fit -> \(fit)")
    precondition(fitFineTune([(90, 90)]) == nil, "one direction can't tell a rotation from a mirror")
    let mirrored = fitFineTune([(0, -22), (90, -112)])!  // unmirrored candidates cancel exactly
    precondition(mirrored.mirror && angularDistance(mirrored.offset, -22) < 0.5, "mirrored phone -> \(mirrored)")

    precondition(classify(["car_horn": 0.35, "speech": 0.9]).kind == .alert, "alerts beat louder chatter")
    precondition(classify(["speech": 0.8, "traffic_noise": 0.5]) == (.people, "speech"))
    precondition(classify(["person_running": 0.9, "breathing": 0.9]).kind == .other, "runner's own sounds ignored")
}
