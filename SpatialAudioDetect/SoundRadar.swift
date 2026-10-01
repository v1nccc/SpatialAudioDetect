@preconcurrency import AVFoundation
import CoreMotion
import Observation
import simd

// Which way each ambisonic axis points on the phone, in CoreMotion's frame
// (x = right edge, y = top edge, z = out of the screen).
// ponytail: Apple doesn't document this; assumes the camera convention (front = out the back camera,
// up = top edge). The live mic check in Calibrate shows whether it holds on a real iPhone.
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
    var ww = 0.0, wx = 0.0, wy = 0.0, wz = 0.0, xx = 0.0, yy = 0.0, zz = 0.0

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
}

nonisolated func foaReading(w: [Float], y: [Float], z: [Float], x: [Float]) -> Reading {
    var ww = 0.0, wx = 0.0, wy = 0.0, wz = 0.0, xx = 0.0, yy = 0.0, zz = 0.0
    for i in w.indices {
        let wi = Double(w[i]), xi = Double(x[i]), yi = Double(y[i]), zi = Double(z[i])
        ww += wi * wi
        wx += wi * xi
        wy += wi * yi
        wz += wi * zi
        xx += xi * xi
        yy += yi * yi
        zz += zi * zi
    }
    let n = Double(max(w.count, 1))
    return Reading(ww: ww / n, wx: wx / n, wy: wy / n, wz: wz / n, xx: xx / n, yy: yy / n, zz: zz / n)
}

/// Direction relative to the runner (degrees, 0 = ahead, +90 = left). Uses gravity so it holds whether the
/// phone is upright, tilted or flat: "ahead" is where the camera + top edge point, flattened onto the ground.
nonisolated func runnerAzimuth(_ phoneVector: SIMD3<Double>, gravity: SIMD3<Double>) -> Double? {
    let up = -simd_normalize(gravity)
    let v = SIMD3<Double>(0, 1, -1)
    let ahead = v - simd_dot(v, up) * up
    guard simd_length(ahead) > 0.3 else { return nil }  // camera + top both pointing at sky/ground: no "ahead"
    let a = simd_normalize(ahead), left = simd_cross(up, a)
    return atan2(simd_dot(phoneVector, left), simd_dot(phoneVector, a)) * 180 / .pi
}

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

/// Flags a sound that keeps getting louder from one direction (something approaching),
/// but not one that simply switches on. 8 sectors of 45°, 0 = front, counter-clockwise.
nonisolated struct ApproachDetector {
    static let sectors = 8
    // ponytail: thresholds are guesses, not measured; tune them on a real road
    var minDB = -50.0   // ignore anything quieter
    var riseDB = 6.0    // must get this much louder…
    var window = 2.0    // …over this many seconds, spread out rather than in one jump
    private let tick = 0.25
    private var power = [Double](repeating: 0, count: sectors)
    private var history: [[Double]] = []
    private var sinceTick = 0.0

    struct SectorStat {
        var db: Double           // now
        var rise: Double         // now minus `window` seconds ago
        var biggestJump: Double  // largest rise between two ticks
        var approaching: Bool
    }

    /// Per-sector view of the last `window` seconds; empty until the window has filled.
    func stats() -> [SectorStat] {
        let n = Int(window / tick) + 1
        guard history.count == n else { return [] }
        return (0..<Self.sectors).map { i in
            let l = history.map { $0[i] }
            let rise = l[n - 1] - l[0]
            let jump = zip(l, l.dropFirst()).map { $1 - $0 }.max() ?? 0
            return SectorStat(db: l[n - 1], rise: rise, biggestJump: jump,
                              approaching: l[n - 1] > minDB && rise >= riseDB && jump <= rise / 2)
        }
    }

    /// Feed one direct-sound power reading; returns the sector that has been steadily getting louder.
    mutating func update(azimuth: Double, power p: Double, dt: Double) -> Int? {
        let s = slot(azimuth, of: Self.sectors), a = min(dt / 0.3, 1)
        for i in power.indices { power[i] += ((i == s ? p : 0) - power[i]) * a }
        sinceTick += dt
        guard sinceTick >= tick else { return nil }
        sinceTick -= tick
        history.append(power.map { 10 * log10(max($0, 1e-12)) })
        if history.count > Int(window / tick) + 1 { history.removeFirst() }
        let st = stats()
        return st.indices.filter { st[$0].approaching }.max { st[$0].db < st[$1].db }
    }
}

nonisolated func selfCheck() {
    let s = (0..<4800).map { Float(sin(Double($0) * 0.3)) }, zero = s.map { _ in Float(0) }
    let upright = SIMD3<Double>(0, -1, 0), flat = SIMD3<Double>(0, 0, -1), tilted = SIMD3<Double>(0, -0.707, -0.707)
    for deg in [0.0, 45, 90, 180, -90] {
        let a = deg * .pi / 180
        let r = foaReading(w: s, y: s.map { $0 * Float(sin(a)) }, z: zero, x: s.map { $0 * Float(cos(a)) })
        let az = runnerAzimuth(r.phoneVector, gravity: upright)!
        assert(abs(remainder(az - deg, 360)) < 0.5 && r.directness > 0.99, "upright, plane wave \(deg)° -> \(az)")
    }
    // Flat in the hand, top edge forward: top-edge sound is ahead, left-edge sound is left.
    let fromTop = foaReading(w: s, y: zero, z: s, x: zero), fromLeft = foaReading(w: s, y: s, z: zero, x: zero)
    assert(abs(runnerAzimuth(fromTop.phoneVector, gravity: flat)!) < 0.5, "flat: top edge = ahead")
    assert(abs(runnerAzimuth(fromLeft.phoneVector, gravity: flat)! - 90) < 0.5, "flat: left edge = left")
    // Tilted 45° back: a level sound from straight ahead hits camera and top edge equally.
    let ahead45 = foaReading(w: s, y: zero, z: s.map { $0 * 0.707 }, x: s.map { $0 * 0.707 })
    assert(abs(runnerAzimuth(ahead45.phoneVector, gravity: tilted)!) < 0.5, "tilted: still ahead")
    assert(fromLeft.micDB(phoneSides[2]) - fromLeft.micDB(phoneSides[3]) > 20, "left-edge mic hears a left sound, right-edge doesn't")
    let tone = { (f: Double) in (0..<4800).map { Float(sin(Double($0) * f)) } }
    let diffuse = foaReading(w: s, y: tone(0.71), z: tone(1.13), x: tone(1.57))
    assert(diffuse.directness < 0.1, "uncorrelated channels should read diffuse -> \(diffuse)")

    func approach(_ dbAt: (Double) -> Double) -> Int? {
        var d = ApproachDetector(), hit: Int?
        for k in 0..<300 {
            let t = Double(k) * 0.02
            if let sector = d.update(azimuth: 180, power: pow(10, dbAt(t) / 10), dt: 0.02) { hit = sector }
        }
        return hit
    }
    assert(approach { -70 + 5 * $0 } == 4, "steady rise from behind = approaching")
    assert(approach { $0 < 2 ? -80 : -30 } == nil, "a sound switching on is not approaching")
    assert(approach { _ in -30 } == nil, "a steady sound is not approaching")

    // A honk from behind inside the judged window wins over steady, quieter traffic on the left.
    let traffic = (0..<200).map { DirectionSample(t: Double($0) * 0.02, azimuth: 90, power: 1e-5, strength: 0.2) }
    let honk = (100..<115).map { DirectionSample(t: Double($0) * 0.02, azimuth: 180, power: 1e-3, strength: 0.9) }
    let judged = soundDirection(traffic + honk, from: 2.0, to: 2.5)!
    assert(abs(remainder(judged.azimuth - 180, 360)) < 5 && judged.peak == 0.9, "honk direction -> \(judged)")
    assert(soundDirection(traffic, from: 10, to: 11) == nil, "nothing heard -> no direction")

    assert(classify(["car_horn": 0.35, "speech": 0.9]).kind == .alert, "alerts beat louder chatter")
    assert(classify(["speech": 0.8, "traffic_noise": 0.5]) == (.people, "speech"))
    assert(classify(["person_running": 0.9, "breathing": 0.9]).kind == .other, "runner's own sounds ignored")
}

/// One audio block from the microphones, as delivered (~47 per second).
nonisolated struct Block: Sendable {
    var reading: Reading
    var start: Double     // seconds since capture start (same clock as classifier verdicts)
    var duration: Double
    var format: String    // what iOS actually delivers, for the debug screen
    var savingAudio: Bool // the raw audio of this block went into the recording
}

nonisolated final class FOATap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let classifier = SoundClassifier()
    var onBlock: (@Sendable (Block) -> Void)?
    private var frames: AVAudioFramePosition = 0  // one clock shared by direction and classifier
    private var recordURL: URL?
    private var file: AVAudioFile?

    /// Start (url) or stop (nil) saving the raw 4-channel audio. Call on the capture queue.
    func record(to url: URL?) {
        recordURL = url
        file = nil  // releasing the file finalizes it
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let desc = sampleBuffer.formatDescription, let format = AVAudioFormat(formatDescription: desc),
              format.channelCount >= 4 else { return }
        try? sampleBuffer.withAudioBufferList { abl, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: abl.unsafePointer) else { return }
            if let recordURL, file == nil {
                file = try? AVAudioFile(forWriting: recordURL, settings: format.settings,
                                        commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            }
            let saved = (try? file?.write(from: buf)) != nil
            let ch = (0..<4).map { samples(buf, channel: $0) }
            let kind = format.commonFormat == .pcmFormatFloat32 ? "float32" : format.commonFormat == .pcmFormatInt16 ? "int16" : "other"
            onBlock?(Block(reading: foaReading(w: ch[0], y: ch[1], z: ch[2], x: ch[3]),
                           start: Double(frames) / format.sampleRate, duration: Double(buf.frameLength) / format.sampleRate,
                           format: "\(Int(format.sampleRate)) Hz · \(format.channelCount) ch · \(kind)\(format.isInterleaved ? " interleaved" : "") · \(buf.frameLength) frames",
                           savingAudio: saved))
            classifier.feed(ch[0], sampleRate: format.sampleRate, at: frames)
            frames += AVAudioFramePosition(buf.frameLength)
        }
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

struct Bin { var strength = 0.0, kind = SoundKind.other }

struct Alert: Equatable {
    var azimuth: Double?  // nil = heard it but direction unclear
    var what: String
}

/// Everything the debug screen shows about the latest audio block, refreshed 10×/s so numbers stay readable.
struct DebugSnapshot {
    var block: Block
    var gravity: SIMD3<Double>
    var azimuth: Double?  // runner-relative, before fine-tune; nil when the pose has no "ahead"
    var loudness: Double  // 0…1 from the dB window
    var strength: Double  // loudness × directness = radar line length
    var mics: [Double]    // dB per phone side, lightly smoothed
    var sectors: [ApproachDetector.SectorStat]
}

@Observable final class SoundRadar {
    var bins = [Bin](repeating: Bin(), count: 72)  // 5° per spoke
    var kind = SoundKind.other
    var label = ""
    var alert: Alert?
    var alertPulse = 0  // bumps to re-fire the haptic while danger lasts
    var problem: String?

    // Debug screen
    var debug: DebugSnapshot?
    var heard: Heard?            // latest classifier verdict
    var heardLatency = 0.0       // seconds between the judged audio ending and the verdict arriving
    var events: [String] = []    // decisions log, newest first
    private(set) var recorder: Recorder?
    var recordedFiles: [URL] = []  // last finished recording, for sharing

    private let session = AVCaptureSession()
    private let tap = FOATap()
    private let queue = DispatchQueue(label: "foa-capture")
    private let motion = CMMotionManager()
    private var approach = ApproachDetector()
    private var recent: [DirectionSample] = []  // last few seconds, for the classifier's late verdicts
    private var mics = [Double](repeating: -120, count: phoneSides.count)
    @ObservationIgnored private var clock = 0.0  // stream seconds, end of the latest block
    @ObservationIgnored private var nextDebug = 0.0
    private var alertUntil = Date.distantPast
    private var lastPulse = Date.distantPast

    func start() async {
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates()
        guard await AVCaptureDevice.requestAccess(for: .audio) else { problem = "Microphone access denied"; return }
        guard let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic) else {
            problem = "No microphone found"; return
        }
        guard input.isMultichannelAudioModeSupported(.firstOrderAmbisonics) else {
            problem = "This iPhone can't capture spatial audio"; return
        }
        let output = AVCaptureAudioDataOutput()
        output.spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4
        tap.onBlock = { [weak self] b in
            guard let self else { return }
            Task { @MainActor in self.add(b) }
        }
        tap.classifier.onResult = { [weak self] heard in
            guard let self else { return }
            Task { @MainActor in self.hear(heard) }
        }
        output.setSampleBufferDelegate(tap, queue: queue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration(); problem = "Capture session rejected spatial audio setup"; return
        }
        session.addInput(input)
        input.multichannelAudioMode = .firstOrderAmbisonics
        session.addOutput(output)
        session.commitConfiguration()
        let session = session
        queue.async { session.startRunning() }
        log("listening")
    }

    func toggleRecording() {
        let tap = tap
        if let r = recorder {
            queue.async { tap.record(to: nil) }
            r.close()
            recordedFiles = r.files
            recorder = nil
            log("recording stopped: \(r.folder.lastPathComponent)")
        } else {
            do {
                let r = try Recorder(startedAt: clock)
                recorder = r
                queue.async { tap.record(to: r.audio) }
                log("recording started: \(r.folder.lastPathComponent)")
            } catch {
                log("recording failed: \(error.localizedDescription)")
            }
        }
    }

    /// Strongest recent direction, optionally only among spokes tagged with `kind`.
    func loudestAzimuth(of kind: SoundKind? = nil) -> Double? {
        let pool = bins.indices.filter { kind == nil || bins[$0].kind == kind }
        guard let i = pool.max(by: { bins[$0].strength < bins[$1].strength }), bins[i].strength > 0.05 else { return nil }
        return Double(i) * 360 / Double(bins.count)
    }

    private func hear(_ h: Heard) {
        heard = h
        heardLatency = clock - h.end
        recorder?.verdict(h, received: clock)
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
        warn(Alert(azimuth: found?.azimuth, what: label), .now)
    }

    private func add(_ b: Block) {
        let r = b.reading, now = Date.now
        clock = b.start + b.duration
        mics = zip(mics, phoneSides.map(r.micDB)).map { 0.8 * $0 + 0.2 * $1 }
        if now > alertUntil, alert != nil { alert = nil; log("alert cleared") }
        for i in bins.indices { bins[i].strength *= 0.95 }

        // Re-derive "ahead" from gravity on every block, so turning or tilting the phone takes effect immediately.
        let g = motion.deviceMotion.map { SIMD3($0.gravity.x, $0.gravity.y, $0.gravity.z) } ?? SIMD3(0, -1, 0)
        let az = runnerAzimuth(r.phoneVector, gravity: g)
        // ponytail: fixed -70…-10 dBFS window and per-buffer decay; make them sliders if the street needs it
        let loudness = min(max((r.db + 70) / 60, 0), 1)
        let strength = az == nil ? 0 : loudness * r.directness

        if let az {
            recent.append(DirectionSample(t: b.start, azimuth: az, power: r.ww * r.directness, strength: strength))
            recent.removeAll { $0.t < b.start - 4 }
            let center = slot(az, of: bins.count)
            for (d, k) in [(0, 1.0), (-1, 0.5), (1, 0.5)] {
                let j = (center + d + bins.count) % bins.count
                if strength * k > bins[j].strength { bins[j] = Bin(strength: strength * k, kind: kind) }
            }
            // Horns and sirens are raised in hear(); here only "something is getting closer".
            if let s = approach.update(azimuth: az, power: r.ww * r.directness, dt: b.duration), kind != .people, kind != .alert {
                warn(Alert(azimuth: Double(s) * 360 / Double(ApproachDetector.sectors),
                           what: kind == .traffic ? "Vehicle getting closer" : "Sound getting closer"), now)
            }
        }

        if clock >= nextDebug {
            nextDebug = clock + 0.1
            debug = DebugSnapshot(block: b, gravity: g, azimuth: az, loudness: loudness, strength: strength,
                                  mics: mics, sectors: approach.stats())
        }
        recorder?.block(b, gravity: g, azimuth: az, loudness: loudness, strength: strength, kind: kind, alert: alert)
    }

    private func warn(_ a: Alert, _ now: Date) {
        if alert?.what != a.what { log("WATCH OUT: \(a.what) at \(a.azimuth.map { "\(Int($0.rounded()))°" } ?? "unknown direction")") }
        alert = a
        alertUntil = now + 3
        if now.timeIntervalSince(lastPulse) > 1.5 {
            alertPulse += 1
            lastPulse = now
        }
    }

    private func log(_ message: String) {
        let line = String(format: "%.1fs  ", clock) + message
        events.insert(line, at: 0)
        if events.count > 80 { events.removeLast() }
        recorder?.event(line)
    }
}
