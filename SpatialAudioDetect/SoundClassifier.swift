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

nonisolated func classify(_ scores: [String: Double]) -> (kind: SoundKind, label: String) {
    let hits = scores.compactMap { label, c in soundKinds[label].map { (kind: $0, label: label, c: c) } }
    if let a = hits.filter({ $0.kind == .alert && $0.c >= alertThreshold }).max(by: { $0.c < $1.c }) { return (.alert, a.label) }
    if let b = hits.filter({ $0.kind != .alert && $0.c >= 0.4 }).max(by: { $0.c < $1.c }) { return (b.kind, b.label) }
    return (.other, "")
}

/// One classifier verdict and the slice of audio (seconds since capture start) it judged.
nonisolated struct Heard: Sendable {
    var kind: SoundKind
    var label: String
    var alertScore: Double  // best horn/siren/bell/shout confidence, for tuning on a real street
    var start: Double, end: Double
}

/// Runs Apple's sound classifier on the omni channel; a verdict every 0.25 s.
nonisolated final class SoundClassifier: NSObject, SNResultsObserving, @unchecked Sendable {
    var onResult: (@Sendable (Heard) -> Void)?
    private var analyzer: SNAudioStreamAnalyzer?
    private var format: AVAudioFormat?
    private let queue = DispatchQueue(label: "sound-classify")

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
        queue.async { analyzer.analyze(buf, atAudioFramePosition: at) }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        let scores = Dictionary(r.classifications.map { ($0.identifier, $0.confidence) }, uniquingKeysWith: max)
        let (kind, label) = classify(scores)
        onResult?(Heard(kind: kind, label: label, alertScore: scores.filter { soundKinds[$0.key] == .alert }.values.max() ?? 0,
                        start: r.timeRange.start.seconds, end: r.timeRange.end.seconds))
    }
}
