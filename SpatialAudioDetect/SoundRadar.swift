import ActivityKit
@preconcurrency import AVFoundation
import CoreMotion
import Observation
import simd
import UIKit

nonisolated final class FOATap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    // All-around, then the beams ahead, left, behind, right; once per sound model (Debug › Sound model).
    let builtIn: [any SoundListener] = [SoundClassifier()] + beamAzimuths.indices.map { SoundClassifier(beam: $0) }
    let viaSoundML: [any SoundListener] = [SoundMLListener()] + beamAzimuths.indices.map { SoundMLListener(beam: $0) }
    private var useSoundML = false  // capture queue only
    let words = WordListener()
    private let steerLock = NSLock()
    private var steering: [SIMD3<Float>] = []

    /// Where to aim the beams (from the Detector, which knows the phone's pose and arm swing). Any thread.
    func steer(_ weights: [SIMD3<Float>]) { steerLock.withLock { steering = weights } }

    /// Blocks the classifiers skipped because the phone couldn't keep up.
    var droppedBlocks: Int { (builtIn + viaSoundML).map(\.droppedBlocks).reduce(0, +) }

    /// Switch sound model; the newly used listeners start a fresh stream. Call on the capture queue.
    func use(_ engine: SoundEngine) {
        guard (engine == .soundML) != useSoundML else { return }
        useSoundML = engine == .soundML
        (useSoundML ? viaSoundML : builtIn).forEach { $0.reset() }
    }
    var onBlock: (@Sendable (Block) -> Void)?
    private var maker = BlockMaker()  // one clock shared by direction and classifier
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
            let made = maker.make(buf, savingAudio: saved, steering: steerLock.withLock { steering })
            onBlock?(made.block)
            let listeners = useSoundML ? viaSoundML : builtIn
            listeners[0].feed(made.omni, sampleRate: format.sampleRate, at: made.at)
            for (k, beam) in made.beams.enumerated() { listeners[k + 1].feed(beam, sampleRate: format.sampleRate, at: made.at) }
            words.feed(made.omni, sampleRate: format.sampleRate, at: made.block.start)
        }
    }
}

/// Live capture + motion feeding the Detector, published for SwiftUI.
@Observable final class SoundRadar {
    /// One per app: the screen, the Dynamic Island buttons and the Lock Screen buttons all drive this.
    static let shared = SoundRadar()

    private(set) var detector = Detector()
    var problem: String?
    var debug: DebugSnapshot?      // refreshed 10×/s for the debug screen
    private(set) var recorder: Recorder?
    var recordedFiles: [URL] = []  // last finished recording, for sharing
    var health = ""                  // processing: blocks per second, skipped blocks, phone temperature
    @ObservationIgnored private var blocksThisSecond = 0
    @ObservationIgnored private var lastThermal = ProcessInfo.ThermalState.nominal
    var wordStatus = "off"           // the name / danger-word listener
    var lastTranscript = ""          // what it last heard, to check it can understand the name
    let haptics = Haptics()
    let hapticTest = HapticTest()
    private(set) var paused = false              // you paused it (screen, Dynamic Island or Lock Screen)
    private(set) var listeningStarted = false

    // What the main screen reads
    var bins: [Bin] { detector.bins }
    var kind: SoundKind { detector.kind }
    var label: String { detector.label }
    var alert: Alert? { detector.alert }
    var alertPulse: Int { detector.alertPulse }
    func loudestAzimuth(of kind: SoundKind? = nil) -> Double? { detector.loudestAzimuth(of: kind) }

    /// Which sound model the 5 listeners use (Debug › Sound model), kept across launches.
    var engine = SoundEngine(rawValue: UserDefaults.standard.string(forKey: "soundEngine") ?? "") ?? .apple {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: "soundEngine")
            let tap = tap, engine = engine
            queue.async { tap.use(engine) }
            log("sound model: \(engine.rawValue)")
        }
    }

    func setCalibration(offset: Double, mirror: Bool) {
        detector.offset = offset
        detector.mirror = mirror
    }

    private let session = AVCaptureSession()
    private let tap = FOATap()
    private let queue = DispatchQueue(label: "foa-capture")
    private let motion = CMMotionManager()
    @ObservationIgnored private var nextDebug = 0.0
    @ObservationIgnored private var lastBlockAt: Date?
    @ObservationIgnored private var lastNotified: (what: String, at: Date)?
    @ObservationIgnored private var startRequested = false
    @ObservationIgnored private var wired = false       // observers, motion and the 1 s tick: set up once
    @ObservationIgnored private var configured = false  // capture session built
    @ObservationIgnored private var interruption: String?  // why iOS took the mic away, until it gives it back
    @ObservationIgnored private var lastTrouble: String?
    @ObservationIgnored private var activity: Activity<RadarActivity>?
    @ObservationIgnored private var shown: (state: RadarActivity.ContentState, at: Date)?
    // The island keeps the last warning 8 s after it ends: it's often still expanded, or glanced at, by then.
    @ObservationIgnored private var held: (alert: Alert, endedAt: Date?)?

    /// Whether audio blocks are still arriving: tells if capture survives the background / lock screen.
    var micStatus: String {
        if paused { return "paused" }
        guard let lastBlockAt else { return "not started" }
        let gap = Date.now.timeIntervalSince(lastBlockAt)
        return gap < 1 ? "listening" : "stalled \(Int(gap)) s"
    }

    /// Not paused, yet no audio arriving: interrupted by iOS, or silently stalled.
    var micTrouble: String? {
        guard listeningStarted, !paused else { return nil }
        if let interruption { return interruption }
        guard let lastBlockAt, Date.now.timeIntervalSince(lastBlockAt) > 2 else { return nil }
        return "No audio from the mic (input: \(AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "none"))"
    }

    /// From the Dynamic Island / Lock Screen buttons, which can run with the app in the background.
    func handle(_ command: RadarCommand) async {
        log("\(command) from the Dynamic Island / Lock Screen (\(appState()))")
        switch command {
        case .resume: if listeningStarted { setPaused(false) } else { await start() }
        case .pause: setPaused(true)
        case .stop: stop()
        }
    }

    /// End the session: mic off, warnings cleared, recording closed, Dynamic Island removed.
    func stop() {
        if listeningStarted {
            if recorder != nil { toggleRecording() }
            listeningStarted = false
            paused = false
            detector.clearAlert()
            held = nil
            let session = session
            queue.async { session.stopRunning() }
            log("stopped")
        }
        endActivities()
    }

    /// App opened without a session running: clear any island left by an earlier run (e.g. after a crash).
    func cleanUpIfIdle() {
        if !listeningStarted { endActivities() }
    }

    /// Mic off (warnings stop, nothing recorded) or back on.
    func setPaused(_ pause: Bool) {
        guard listeningStarted, pause != paused else { return }
        paused = pause
        if pause {
            detector.clearAlert()
            held = nil
        } else {
            lastBlockAt = .now  // give the mic a moment before calling it stalled
        }
        let session = session
        queue.async { pause ? session.stopRunning() : session.startRunning() }
        log(pause ? "paused" : "resumed")
        refreshActivity()
    }

    /// Start (or start again after Stop) a listening session, with its Dynamic Island.
    func start() async {
        guard !listeningStarted, !startRequested else { return }
        startRequested = true
        defer { startRequested = false }
        if !wired {
            wired = true
            haptics.onLog = { [weak self] in self?.log($0) }
            watchLifecycle()
            motion.deviceMotionUpdateInterval = 1.0 / 60
            motion.startDeviceMotionUpdates()
            Task {  // once a second: notice a mic that went quiet, keep the Dynamic Island current
                while true {
                    tick()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        if !configured {
            guard await configureCapture() else { return }
            configured = true
        }
        problem = nil
        let session = session, tap = tap, engine = engine
        queue.async {
            tap.use(engine)
            session.startRunning()
        }
        listeningStarted = true
        paused = false
        lastBlockAt = .now
        log("listening")
        startActivity()
        let optIn = haptics.allowWhileRecording()
        log("haptics while recording: " + (optIn.map { "opt-in failed: \($0)" } ?? "allowed"))
        if HapticSettings.load().notifyWhenAway { await haptics.askForNotifications() }
        await updateWords()
    }

    /// Build the spatial-audio capture session once; false (with `problem` set) if this iPhone can't.
    private func configureCapture() async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { problem = "Microphone access denied"; return false }
        guard let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic) else {
            problem = "No microphone found"; return false
        }
        guard input.isMultichannelAudioModeSupported(.firstOrderAmbisonics) else {
            problem = "This iPhone can't capture spatial audio"; return false
        }
        let output = AVCaptureAudioDataOutput()
        output.spatialAudioChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4
        tap.onBlock = { [weak self] b in
            guard let self else { return }
            Task { @MainActor in self.add(b) }
        }
        for c in tap.builtIn + tap.viaSoundML {
            c.onResult = { [weak self] heard in
                guard let self else { return }
                Task { @MainActor in self.hear(heard) }
            }
        }
        tap.words.onMatch = { [weak self] phrase, isName, start, end in
            guard let self else { return }
            Task { @MainActor in self.heardWords(phrase, isName: isName, from: start, to: end) }
        }
        tap.words.onStatus = { [weak self] status in
            guard let self else { return }
            Task { @MainActor in
                self.wordStatus = status
                self.log("words: \(status)")
            }
        }
        tap.words.onTranscript = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in self.lastTranscript = text }
        }
        output.setSampleBufferDelegate(tap, queue: queue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration(); problem = "Capture session rejected spatial audio setup"; return false
        }
        session.addInput(input)
        input.multichannelAudioMode = .firstOrderAmbisonics
        session.addOutput(output)
        // Let Maps voice prompts, music etc. play alongside instead of the two fighting over the audio session.
        session.configuresApplicationAudioSessionToMixWithOthers = true
        session.commitConfiguration()
        return true
    }

    func toggleRecording() {
        let tap = tap
        if let r = recorder {
            queue.async { tap.record(to: nil) }
            log("recording stopped: \(r.folder.lastPathComponent)")
            r.close()
            recordedFiles = r.files
            recorder = nil
        } else {
            do {
                let r = try Recorder(startedAt: detector.clock)
                recorder = r
                queue.async { tap.record(to: r.audio) }
                log("recording started: \(r.folder.lastPathComponent)")
            } catch {
                log("recording failed: \(error.localizedDescription)")
            }
        }
    }

    private func add(_ b: Block) {
        let m = motion.deviceMotion.map { dm -> Motion in
            let g = SIMD3(dm.gravity.x, dm.gravity.y, dm.gravity.z), spin = SIMD3(dm.rotationRate.x, dm.rotationRate.y, dm.rotationRate.z)
            return Motion(gravity: g, yawRate: simd_dot(spin, -simd_normalize(g)))  // turning about the vertical
        } ?? Motion()
        lastBlockAt = .now
        let pulse = detector.alertPulse
        let p = detector.add(b, motion: m)
        tap.steer(detector.beamWeights)
        blocksThisSecond += 1
        react(since: pulse)
        recorder?.block(p, kind: detector.kind, alert: detector.alert)
        flushLog()
        if detector.clock >= nextDebug {
            nextDebug = detector.clock + 0.1
            debug = detector.snapshot()
        }
    }

    /// Name / danger words changed (Alerts screen), or a session started: (re)start or stop the transcriber.
    func updateWords() async {
        let d = UserDefaults.standard
        await tap.words.configure(names: phrases(d.string(forKey: "listenNames") ?? ""),
                                  words: phrases(d.string(forKey: "listenWords") ?? defaultDangerWords))
    }

    private func heardWords(_ phrase: String, isName: Bool, from start: Double, to end: Double) {
        let pulse = detector.alertPulse
        detector.heardWords(phrase, isName: isName, from: start, to: end)
        react(since: pulse)
        flushLog()
    }

    private func hear(_ h: Heard) {
        let pulse = detector.alertPulse
        detector.hear(h)
        react(since: pulse)
        recorder?.verdict(h, received: detector.clock)
        flushLog()
    }

    /// Feel the warning: the user's pattern for this kind of alert (from here, not a SwiftUI view, so it also
    /// runs while the app is in the background), plus a notification when the app isn't on screen.
    private func react(since pulse: Int) {
        guard detector.alertPulse != pulse, let a = detector.alert else { return }
        refreshActivity()  // straight away, not at the next 1 s tick: this is what pops the island open
        let s = HapticSettings.load(), haptics = haptics
        let body = a.what + " " + directionWords(a.azimuth)
        let pattern = a.level == .critical ? s.critical : s.warning, title = a.level == .critical ? "Watch out" : "Heads up"
        Task {
            let r = await haptics.play(pattern, title: title, body: body, via: s.method)
            if !r.ok { self.log("haptic \(s.method.name): \(r.detail) (\(appState()))") }
        }
        // ponytail: one notification per new warning or per 10 s, so a long siren doesn't flood the lock screen
        // The island pops open on its own (refreshActivity), so a notification on top would only double the buzz.
        let islandUp = activity.map { [.active, .stale].contains($0.activityState) } ?? false
        guard s.notifyWhenAway, s.method != .notification, !islandUp, UIApplication.shared.applicationState != .active,
              lastNotified.map({ $0.what != a.what || Date.now.timeIntervalSince($0.at) > 10 }) ?? true else { return }
        lastNotified = (a.what, .now)
        Task {
            let r = await haptics.play(pattern, title: title, body: body, via: .notification)
            if !r.ok { self.log("notification: \(r.detail)") }
        }
    }

    /// Note app / lock / capture / route changes in the decisions log, to see what iOS does to the mic, and recover.
    private func watchLifecycle() {
        let nc = NotificationCenter.default
        let events: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "app → background"),
            (UIApplication.willEnterForegroundNotification, "app → foreground"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "phone locked"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "phone unlocked"),
        ]
        for (name, text) in events {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.log(text) }
            }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.micTrouble != nil { self?.restartCapture(because: "app opened") }
            }
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            // Swiped away while running: take the Dynamic Island along (iOS allows a few seconds here).
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                for a in Activity<RadarActivity>.activities { await a.end(nil, dismissalPolicy: .immediate) }
                done.signal()
            }
            _ = done.wait(timeout: .now() + 2)
        }
        nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: .main) { [weak self] n in
            let reason = n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let text = reason == AVCaptureSession.InterruptionReason.audioDeviceInUseByAnotherClient.rawValue
                ? "A call, Siri or another app took the mic" : "iOS interrupted the mic (reason \(reason.map(String.init) ?? "unknown"))"
            MainActor.assumeIsolated {
                self?.interruption = text
                self?.log("mic interrupted: \(text)")
                self?.refreshActivity()
            }
        }
        nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.interruption = nil
                self?.log("mic interruption ended")
                self?.refreshActivity()
            }
            // iOS normally restarts the session itself; if audio still isn't flowing a moment later, restart it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated { if self?.micTrouble != nil { self?.restartCapture(because: "no audio after interruption") } }
            }
        }
        nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: .main) { [weak self] n in
            let error = (n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown"
            MainActor.assumeIsolated {
                self?.log("mic capture error: \(error)")
                self?.restartCapture(because: "capture error")
            }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            let names: [AVAudioSession.RouteChangeReason: String] = [
                .newDeviceAvailable: "device connected", .oldDeviceUnavailable: "device disconnected",
                .categoryChange: "category changed", .override: "override", .routeConfigurationChange: "configuration changed",
            ]
            let input = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "none"
            MainActor.assumeIsolated { self?.log("audio route: \(reason.flatMap { names[$0] } ?? "other") · input \(input)") }
        }
    }

    private func restartCapture(because why: String) {
        guard listeningStarted, !paused else { return }
        log("restarting mic: \(why) (\(appState()))")
        lastBlockAt = .now
        let session = session
        queue.async { session.startRunning() }
    }

    /// Log when the mic goes quiet / comes back, and keep the Live Activity current.
    private func tick() {
        // "Works, then stops after a while": blocks arriving slower than ~47/s, skipped blocks or heat show why.
        let thermal = ProcessInfo.processInfo.thermalState
        let heat = ["normal", "warm", "hot (iOS slows the app)", "critical"][min(thermal.rawValue, 3)]
        if thermal != lastThermal {
            log("phone temperature: \(heat)")
            lastThermal = thermal
        }
        let dropped = tap.droppedBlocks
        health = "\(blocksThisSecond) blocks/s · \(dropped) skipped · \(heat)"
        blocksThisSecond = 0
        let trouble = micTrouble
        if trouble != lastTrouble {
            log(trouble.map { "mic trouble: \($0) (\(appState()))" } ?? "audio flowing again")
            lastTrouble = trouble
        }
        refreshActivity()
    }

    // MARK: Dynamic Island / Lock Screen

    private func liveState() -> RadarActivity.ContentState {
        if let a = detector.alert {
            held = (a, nil)
        } else if let h = held, h.endedAt == nil {
            held = (h.alert, .now)
        }
        if let end = held?.endedAt, Date.now.timeIntervalSince(end) > 8 { held = nil }
        return .make(paused: paused, micTrouble: micTrouble,
                     // 15° steps: the alert follows its sound every block; the island needn't update for each degree.
                     warning: held.map { ($0.alert.what, $0.alert.azimuth.map { ($0 / 15).rounded() * 15 }, directionWords($0.alert.azimuth), $0.alert.short,
                                         $0.alert.level == .critical, $0.endedAt) })
    }

    /// While listening, the content goes stale 90 s after the last update, and updates come at least every 30 s,
    /// so a grey "Not updating" island means the app itself stopped (killed or suspended by iOS).
    private func content(_ state: RadarActivity.ContentState) -> ActivityContent<RadarActivity.ContentState> {
        ActivityContent(state: state, staleDate: state.status == .paused ? nil : .now + 90)
    }

    /// Only when a session starts. If you swipe the island away, it stays away until the next Start.
    private func startActivity() {
        guard listeningStarted else { return }
        if let a = activity, [.active, .stale, .pending].contains(a.activityState) { return }
        let leftovers = Activity<RadarActivity>.activities
        if UIApplication.shared.applicationState == .background {
            // Started from an island button while the app wasn't running: iOS won't create an island from the
            // background, so take over the one that was tapped.
            activity = leftovers.first { [.active, .stale].contains($0.activityState) }
            shown = nil
            log(activity == nil ? "Dynamic Island: can't start one from the background" : "Dynamic Island taken over")
            refreshActivity()
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { log("Dynamic Island: Live Activities are off in Settings"); return }
        for old in leftovers { Task { await old.end(nil, dismissalPolicy: .immediate) } }
        do {
            let state = liveState()
            activity = try Activity.request(attributes: RadarActivity(startedAt: .now), content: content(state))
            shown = (state, .now)
            log("Dynamic Island on")
        } catch {
            log("Dynamic Island failed: \(error.localizedDescription) (\(appState()))")  // iOS only starts one from the foreground
        }
    }

    private func endActivities() {
        activity = nil
        shown = nil
        for a in Activity<RadarActivity>.activities { Task { await a.end(nil, dismissalPolicy: .immediate) } }
    }

    private func refreshActivity() {
        guard let activity else { return }
        let state = liveState()
        let heartbeat = state.status != .paused && Date.now.timeIntervalSince(shown?.at ?? .distantPast) > 30
        let popOpen = islandAlertDue(state, previous: shown?.state)
        guard state != shown?.state || heartbeat else { return }
        shown = (state, .now)
        let content = content(state)
        var alert: AlertConfiguration?
        if popOpen {
            // Expands the Dynamic Island for a few seconds (and lights the Lock Screen) showing what and where.
            alert = AlertConfiguration(title: "\(state.title)", body: "\(state.detail)", sound: .default)
            log("Dynamic Island alert: \(state.title) \(state.detail)")
        }
        Task { await activity.update(content, alertConfiguration: alert) }
    }

    private func log(_ message: String) {
        detector.log(message)
        flushLog()
    }

    private func flushLog() {
        guard !detector.pendingLog.isEmpty else { return }
        for line in detector.pendingLog { recorder?.event(line) }
        detector.clearPendingLog()
    }
}
