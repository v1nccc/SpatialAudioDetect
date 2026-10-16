@preconcurrency import AVFAudio
import Speech

/// Listens for the user's name and danger words with Apple's on-device transcriber (nothing leaves the phone,
/// nothing is stored). Fed the same omni channel as the sound classifier, from the capture queue.
/// ponytail: transcribes continuously while names/words are set (battery); gate on "speech" verdicts if it matters.
nonisolated final class WordListener: @unchecked Sendable {
    /// (phrase, is it the name?, start, end) in stream seconds, so the alert can look up the direction.
    var onMatch: (@Sendable (String, Bool, Double, Double) -> Void)?
    var onStatus: (@Sendable (String) -> Void)?
    var onTranscript: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var names: [String] = [], words: [String] = []
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var offset: Double?  // stream time of the first audio fed: the transcriber's clock starts at 0 there

    /// Start, update or (with nothing to listen for) stop.
    func configure(names: [String], words: [String]) async {
        locked { (self.names, self.words) = (names, words) }
        if names.isEmpty && words.isEmpty { await stop(); onStatus?("off"); return }
        if let analyzer {  // already running: just steer it toward the new words
            let context = AnalysisContext()
            context.contextualStrings[.general] = names + words
            try? await analyzer.setContext(context)
            return
        }
        do {
            try await start()
        } catch {
            onStatus?("failed: \(error.localizedDescription)")
        }
    }

    private func start() async throws {
        let auth = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard SpeechTranscriber.isAvailable else { onStatus?("on-device transcription isn't available on this iPhone"); return }
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus?("downloading the \(locale.identifier) speech model…")
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            onStatus?("no audio format for the transcriber"); return
        }
        let context = AnalysisContext()
        context.contextualStrings[.general] = locked { names + words }  // bias recognition toward the name
        try await analyzer.setContext(context)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        locked {
            self.analyzer = analyzer
            self.format = format
            self.converter = nil
            self.offset = nil
            self.input = input
        }
        onStatus?("listening (\(locale.identifier))" + (auth == .authorized ? "" : " · speech permission: \(auth.rawValue)"))
        Task { [weak self] in
            do {
                for try await result in transcriber.results { self?.check(result) }
            } catch {
                self?.onStatus?("stopped: \(error.localizedDescription)")
            }
        }
    }

    func stop() async {
        let a = locked { () -> SpeechAnalyzer? in
            input?.finish()
            input = nil
            defer { analyzer = nil }
            return analyzer
        }
        await a?.cancelAndFinishNow()
    }

    /// Capture queue: resample one block of the omni channel to what the transcriber wants and hand it over.
    func feed(_ samples: [Float], sampleRate: Double, at streamTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let input, let format, !samples.isEmpty,
              let inFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        inBuf.frameLength = inBuf.frameCapacity
        samples.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if converter == nil { converter = AVAudioConverter(from: inFormat, to: format) }
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(Double(samples.count) * format.sampleRate / sampleRate) + 64) else { return }
        var given = false
        converter.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return inBuf
        }
        guard out.frameLength > 0 else { return }
        if offset == nil { offset = streamTime }
        input.yield(AnalyzerInput(buffer: out))
    }

    private func check(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        onTranscript?(text)
        let (names, words, offset) = locked { (self.names, self.words, self.offset ?? 0) }
        let start = offset + result.range.start.seconds, end = offset + result.range.end.seconds
        if let w = matchedPhrase(in: text, among: words) {
            onMatch?(w, false, start, end)
        } else if let n = matchedPhrase(in: text, among: names) {
            onMatch?(n, true, start, end)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
