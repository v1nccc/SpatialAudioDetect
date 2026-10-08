@preconcurrency import AVFoundation
@preconcurrency import SoundAnalysis

nonisolated enum SoundKind: Sendable { case other, people, traffic, alert }

/// Which of Apple's built-in classifier labels matter to a runner who can't hear them.
nonisolated let soundKinds: [String: SoundKind] = {
    var m: [String: SoundKind] = [:]
    for l in ["car_horn", "air_horn", "siren", "police_siren", "ambulance_siren", "fire_engine_siren", "emergency_vehicle",
              "civil_defense_siren", "bicycle_bell", "reverse_beeps", "vehicle_skidding", "train_horn", "train_whistle",
              "foghorn", "shout", "yell", "screaming", "dog_bark", "dog_growl"] { m[l] = .alert }
    for l in ["traffic_noise", "car_passing_by", "engine", "engine_idling", "engine_starting", "engine_accelerating_revving",
              "truck", "bus", "motorcycle", "race_car", "rail_transport", "train", "train_wheels_squealing", "subway_metro",
              "bicycle", "skateboard"] { m[l] = .traffic }
    // person_running / breathing deliberately left out: that's the runner themselves
    for l in ["speech", "chatter", "crowd", "babble", "laughter", "whispering", "singing", "children_shouting", "cheering"] { m[l] = .people }
    return m
}()

/// Alerts win at a lower bar than the rest: a missed horn is worse than a false buzz.
nonisolated let alertThreshold = 0.3
nonisolated let categoryThreshold = 0.4  // traffic / people

nonisolated func classify(_ scores: [String: Double]) -> (kind: SoundKind, label: String) {
    let hits = scores.compactMap { label, c in soundKinds[label].map { (kind: $0, label: label, c: c) } }
    if let a = hits.filter({ $0.kind == .alert && $0.c >= alertThreshold }).max(by: { $0.c < $1.c }) { return (.alert, a.label) }
    if let b = hits.filter({ $0.kind != .alert && $0.c >= categoryThreshold }).max(by: { $0.c < $1.c }) { return (b.kind, b.label) }
    return (.other, "")
}

/// One classifier verdict and the slice of audio (seconds since capture start) it judged.
nonisolated struct Heard: Sendable {
    var kind: SoundKind
    var label: String
    var alertScore: Double  // best horn/siren/bell/shout confidence, for tuning on a real street
    var start: Double, end: Double
    var top: [(id: String, confidence: Double)]  // Apple's raw top guesses, for the debug screen
    var beam: Int? = nil                        // nil = the all-around mic; else index into beamAzimuths
    var alerts: [String: Double] = [:]          // score of every alert label (horns, sirens, bells, barks…)

    /// Alert scores, also for verdicts made without the full list (tests, old fakes).
    var alertScores: [String: Double] { alerts.isEmpty && kind == .alert ? [label: alertScore] : alerts }
}

/// "car_horn" -> "Car horn"
nonisolated func pretty(_ id: String) -> String {
    let s = id.replacingOccurrences(of: "_", with: " ")
    return s.prefix(1).uppercased() + s.dropFirst()
}

/// Runs Apple's sound classifier on one signal (the all-around mic or one beam); a verdict every 0.25 s.
nonisolated final class SoundClassifier: NSObject, SNResultsObserving, @unchecked Sendable {
    let beam: Int?
    var onResult: (@Sendable (Heard) -> Void)?
    private var analyzer: SNAudioStreamAnalyzer?
    private var format: AVAudioFormat?
    private let queue = DispatchQueue(label: "sound-classify")
    private let lock = NSLock()
    private var pending = 0, dropped = 0
    private let maxBacklog: Int

    /// `realTime`: skip audio rather than fall behind (live). The replay tool feeds faster than real time, so it doesn't.
    init(beam: Int? = nil, realTime: Bool = true) {
        self.beam = beam
        maxBacklog = realTime ? 24 : .max  // ~0.5 s of blocks waiting
    }

    /// Blocks skipped because the phone couldn't keep up (live only).
    var droppedBlocks: Int { lock.withLock { dropped } }

    /// Call from one serial queue (the capture queue). `at` = frames since capture start.
    func feed(_ samples: [Float], sampleRate: Double, at: AVAudioFramePosition) {
        if analyzer == nil, let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
           let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
            // Shortest window Apple allows: a 1 s window drowned out 0.3 s honks in testing.
            request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 1000)
            request.overlapFactor = 0.5
            let a = SNAudioStreamAnalyzer(format: f)
            try? a.add(request, withObserver: self)
            analyzer = a
            format = f
        }
        guard let analyzer, let format, !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = buf.frameCapacity
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let behind = lock.withLock { () -> Bool in
            if pending >= maxBacklog { dropped += 1; return true }
            pending += 1
            return false
        }
        if behind { return }
        queue.async {
            analyzer.analyze(buf, atAudioFramePosition: at)
            self.lock.withLock { self.pending -= 1 }
        }
    }

    /// Process everything fed so far and deliver the last verdicts (replay tool).
    func finish() { queue.sync { analyzer?.completeAnalysis() } }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        let scores = Dictionary(r.classifications.map { ($0.identifier, $0.confidence) }, uniquingKeysWith: max)
        let (kind, label) = classify(scores)
        onResult?(Heard(kind: kind, label: label, alertScore: scores.filter { soundKinds[$0.key] == .alert }.values.max() ?? 0,
                        start: r.timeRange.start.seconds, end: r.timeRange.end.seconds,
                        top: r.classifications.prefix(6).map { ($0.identifier, $0.confidence) }, beam: beam,
                        alerts: scores.filter { soundKinds[$0.key] == .alert }))
    }
}
