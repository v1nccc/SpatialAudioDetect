import AVFoundation
import SoundML

/// SoundClassifier's job done through the SoundML package (github.com/chrisladd/SoundML), to compare the two in the app
/// (Debug › Sound model). SoundML runs the same Apple built-in model, but only reports sounds that pass their threshold
/// and doesn't say which half second a verdict is about, so that's worked out by counting verdicts.
nonisolated final class SoundMLListener: SoundListener, @unchecked Sendable {
    let beam: Int?
    var onResult: (@Sendable (Heard) -> Void)?
    var droppedBlocks: Int { 0 }  // SoundML has no backlog limit: on a slow phone it falls behind instead of skipping
    private var analyzer: Analyzer?  // feed queue only
    private let lock = NSLock()
    private var stream: (id: String, start: Double, verdicts: Int)?  // current analyzer, its first second, verdicts so far

    init(beam: Int? = nil) { self.beam = beam }

    func reset() { analyzer = nil }

    func feed(_ samples: [Float], sampleRate: Double, at: AVAudioFramePosition) {
        guard !samples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = buf.frameCapacity
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if analyzer == nil {
            let a = Analyzer()
            // SoundML's way: one group per sound with its own threshold (the same bars the direct classifier uses).
            a.soundGroups = soundKinds.map { label, kind in
                SoundGroup(id: label, sounds: [Sound(label: label, threshold: kind == .alert ? alertThreshold : categoryThreshold)])
            }
            let id = a.id
            a.onUpdate = { [weak self] _, matches in self?.deliver(matches ?? [], from: id) }
            lock.withLock { stream = (id, Double(at) / sampleRate, 0) }
            analyzer = a
        }
        analyzer?.process(buffer: buf, time: AVAudioTime(sampleTime: at, atRate: sampleRate))
    }

    private func deliver(_ matches: [SoundGroup.Match], from id: String) {
        // ponytail: assumes Apple's default overlap (0.5), i.e. a 0.5 s window every 0.25 s from the first buffer.
        // Drifts if SoundML ever skips a verdict; the direct classifier has exact times.
        let start = lock.withLock { () -> Double? in
            guard let s = stream, s.id == id else { return nil }  // a verdict from before a reset
            stream?.verdicts += 1
            return s.start + Double(s.verdicts) * 0.25
        }
        guard let start else { return }
        let scores = Dictionary(matches.map { ($0.sound.label, $0.confidence) }, uniquingKeysWith: max)
        onResult?(Heard(scores: scores, start: start, end: start + 0.5,
                        top: scores.sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) }, beam: beam))
    }
}
