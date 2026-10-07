import ActivityKit
@preconcurrency import AVFoundation
import CoreMotion
import Observation
import simd
import UIKit

nonisolated final class FOATap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let classifier = SoundClassifier()
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
            let made = maker.make(buf, savingAudio: saved)
            onBlock?(made.block)
            classifier.feed(made.omni, sampleRate: format.sampleRate, at: made.at)
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
        let session = session
        queue.async { session.startRunning() }
        listeningStarted = true
        paused = false
        lastBlockAt = .now
        log("listening")
        startActivity()
        let optIn = haptics.allowWhileRecording()
        log("haptics while recording: " + (optIn.map { "opt-in failed: \($0)" } ?? "allowed"))
        if HapticSettings.load().notifyWhenAway { await haptics.askForNotifications() }
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
        tap.classifier.onResult = { [weak self] heard in
            guard let self else { return }
            Task { @MainActor in self.hear(heard) }
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
        react(since: pulse)
        recorder?.block(p, kind: detector.kind, alert: detector.alert)
        flushLog()
        if detector.clock >= nextDebug {
            nextDebug = detector.clock + 0.1
            debug = detector.snapshot()
        }
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
        let s = HapticSettings.load(), haptics = haptics
        let body = a.what + " " + directionWords(a.azimuth)
        Task {
            let r = await haptics.play(a.isApproach ? s.approach : s.horn, title: "Watch out", body: body, via: s.method)
            if !r.ok { self.log("haptic \(s.method.name): \(r.detail) (\(appState()))") }
        }
        // ponytail: one notification per new warning or per 10 s, so a long siren doesn't flood the lock screen
        guard s.notifyWhenAway, s.method != .notification, UIApplication.shared.applicationState != .active,
              lastNotified.map({ $0.what != a.what || Date.now.timeIntervalSince($0.at) > 10 }) ?? true else { return }
        lastNotified = (a.what, .now)
        Task {
            let r = await haptics.play(a.isApproach ? s.approach : s.horn, title: "Watch out", body: body, via: .notification)
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
        let trouble = micTrouble
        if trouble != lastTrouble {
            log(trouble.map { "mic trouble: \($0) (\(appState()))" } ?? "audio flowing again")
            lastTrouble = trouble
        }
        refreshActivity()
    }

    // MARK: Dynamic Island / Lock Screen

    private func liveState() -> RadarActivity.ContentState {
        .make(paused: paused, micTrouble: micTrouble,
              warning: detector.alert.map { ($0.what, $0.azimuth, directionWords($0.azimuth)) })
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
        guard state != shown?.state || heartbeat else { return }
        shown = (state, .now)
        let content = content(state)
        Task { await activity.update(content) }
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
