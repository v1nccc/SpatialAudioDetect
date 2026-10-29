import AVFoundation
import SwiftUI
import UIKit

/// "02:15"
private func clock(_ seconds: Double) -> String {
    Duration.seconds(max(seconds, 0)).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
}

private func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

/// "3 of 4 · 75%"
private func outOf(_ k: Int, _ n: Int) -> String { n > 0 ? "\(k) of \(n) · \(percent(Double(k) / Double(n)))" : "–" }

private extension EvalAlert {
    /// All its verdicts given: the sound, and unless it was a false alarm, the direction and the timing.
    var fullyMarked: Bool { review != nil && (review == .falseAlarm || (directionReview != nil && timingReview != nil)) }
}

/// Sounds you can flag as really happening (so misses count too): the name results use, a short label, an icon.
private let dangerSounds: [(sound: String, short: String, icon: String)] = [
    ("Siren", "Siren", "light.beacon.max.fill"), ("Car horn", "Horn", "horn.blast.fill"), ("Vehicle getting closer", "Vehicle", "car.fill"),
    ("Bike bell", "Bike bell", "bicycle"), ("Dog bark", "Dog", "dog.fill"), ("Shout", "Shout", "megaphone.fill"),
    ("Other danger", "Other", "exclamationmark.triangle.fill"),
]

/// One tap per danger sound, big enough to hit mid-run.
private struct FlagGrid: View {
    let flag: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(dangerSounds, id: \.sound) { d in
                Button { flag(d.sound) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: d.icon).font(.title2)
                        Text(d.short).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Flag \(d.sound)")
            }
        }
    }
}

/// Whether the app warned about a flagged danger, in words.
private func flagResult(_ m: EvalMark, _ s: EvalSession) -> (text: String, caught: Bool) {
    if let a = catcher(m, alerts: s.alerts) { return ("The app warned: \(a.what) ✓", true) }
    if let a = s.alerts.first(where: { near($0, m) }) {
        return ("Missed: the \(a.what) warning nearby is another sound (if it was this one, mark its Sound Wrong)", false)
    }
    return ("Missed: no warning within 8 s", false)
}

/// "Flagged Siren at 2:31   Undo", and under it whether the app warned about it.
private struct LastFlag: View {
    let mark: EvalMark
    let offset: Double
    let result: (text: String, caught: Bool)?  // nil while the test runs: the warning may still come
    let undo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label("Flagged \(mark.sound) at \(clock(offset))", systemImage: "flag.fill")
                Spacer()
                Button("Undo", action: undo).buttonStyle(.borderless)
            }
            if let result { Text(result.text).foregroundStyle(result.caught ? .green : .red) }
        }
        .font(.caption)
    }
}

/// Testing tab: use the app exactly as a runner would while everything is recorded, then go through each session.
struct TestingView<Live: View>: View {
    let radar: SoundRadar
    let live: Live  // the main screen, as a runner sees it
    @State private var store = EvalStore.shared
    @State private var conditions = EvalConditions()
    @State private var method = DetectionMethod.soundRadar
    @State private var keepRaw = true
    @State private var starting = false

    init(radar: SoundRadar, @ViewBuilder live: () -> Live) {
        self.radar = radar
        self.live = live()
    }

    private var test: EvalSession? { store.active.flatMap { $0.recording != nil ? $0 : nil } }
    private var history: [EvalSession] { store.sessions.filter { $0.kind == .realRun } }

    var body: some View {
        if let s = test { running(s) } else { home }
    }

    // MARK: Start, and the history

    private var home: some View {
        List {
            Section {
                Picker("Detection method", selection: $method) {
                    ForEach([DetectionMethod.soundRadar, .audioLab], id: \.self) { Text($0.rawValue) }
                }
                Picker("Phone carried in", selection: $conditions.carry) { ForEach(EvalConditions.carries, id: \.self) { Text($0) } }
                Picker("Activity", selection: $conditions.activity) { ForEach(EvalConditions.activities, id: \.self) { Text($0) } }
                Picker("Place", selection: $conditions.place) { ForEach(EvalConditions.places, id: \.self) { Text($0) } }
                TextField("Notes (route, weather, wind…)", text: $conditions.notes, axis: .vertical)
                Toggle("Also keep the 4-channel audio", isOn: $keepRaw)
                if store.active != nil {
                    Label("An Evaluate session is running. End it first.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let p = radar.problem { Label(p, systemImage: "mic.slash").foregroundStyle(.orange) }
                Button(action: start) {
                    Label(starting ? "Starting…" : "Start test", systemImage: "record.circle.fill")
                        .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(starting || store.active != nil)
            } header: {
                Text("New test")
            } footer: {
                Text("""
                    The app then works exactly as it does for a runner, and records: the sound (to listen back, ~0.5 MB per \
                    minute; the 4-channel audio for replaying on a Mac adds ~46 MB per minute), every alert with its direction \
                    and vibration, the decisions log and battery use. Afterwards open the test and mark each alert true or false.
                    """)
            }
            Section("History (\(history.count))") {
                if history.isEmpty { Text("No tests yet").foregroundStyle(.secondary) }
                ForEach(history) { s in
                    NavigationLink { TestSessionView(radar: radar, id: s.id) } label: { HistoryRow(session: s) }
                }
            }
        }
        .navigationTitle("Testing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func start() {
        starting = true
        Task {
            defer { starting = false }
            radar.method = method
            if !radar.listeningStarted { await radar.start() } else if radar.paused { radar.setPaused(false) }
            guard radar.listeningStarted else { return }
            // Wait for audio to flow (up to 3 s), so the recording starts with the session and alert times line up with it.
            let before = radar.detector.clock
            for _ in 0..<30 where radar.detector.clock == before { try? await Task.sleep(for: .milliseconds(100)) }
            radar.stopRecording()  // a Debug recording in progress would start earlier than the test
            guard let folder = radar.startRecording(raw: keepRaw) else { return }
            store.start(.realRun, automaticConditions(conditions, radar: radar), recording: folder)
        }
    }

    // MARK: While it runs: the runner's screen, plus the recording bar

    private func running(_ s: EvalSession) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label("Recording · \(clock(context.date.timeIntervalSince(s.started)))", systemImage: "record.circle.fill")
                            .font(.headline).foregroundStyle(.red)
                    }
                    Text("\(s.alerts.count) alerts · \(s.marks.count) flagged · \(radar.method.rawValue) · battery \(battery)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Noticed a danger? Tap it the moment you do, so the ones the app misses count too.")
                        .font(.caption).foregroundStyle(.secondary)
                    FlagGrid { sound in
                        let at = radar.recordingTime
                        store.update(s.id) { $0.marks.append(EvalMark(at: .now, sound: sound, audioAt: at)) }
                    }
                    // Always one line here, so Undo going away never slides End test under your finger.
                    if let m = s.marks.last {
                        LastFlag(mark: m, offset: m.audioAt ?? m.at.timeIntervalSince(s.started), result: nil) {
                            store.update(s.id) { $0.marks.removeAll { $0.id == m.id } }
                        }
                    } else {
                        Label("Nothing flagged yet", systemImage: "flag").font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        radar.stopRecording()
                        store.end()
                    } label: {
                        Label("End test", systemImage: "stop.fill").frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
                live
            }
            .padding()
        }
        .background { (radar.alert?.level.color ?? Color(.systemGroupedBackground)).ignoresSafeArea() }
        .navigationTitle("Testing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var battery: String { UIDevice.current.batteryLevel >= 0 ? percent(Double(UIDevice.current.batteryLevel)) : "unknown" }
}

private struct HistoryRow: View {
    let session: EvalSession

    var body: some View {
        let s = session, t = TestSummary(s), v = t.verdicts, open = s.alerts.filter { !$0.fullyMarked }.count
        VStack(alignment: .leading, spacing: 2) {
            Text("\(s.started.formatted(date: .abbreviated, time: .shortened)) · \(clock(t.minutes * 60))\(s.ended == nil ? " · running" : "")")
                .font(.subheadline.bold())
            Text("\(s.conditions.model) · \(s.conditions.carry) · \(s.conditions.activity)").font(.caption).foregroundStyle(.secondary)
            Text("\(s.alerts.count) alerts · \(v.real) real · \(v.falseAlarms) false" + (open > 0 ? " · \(open) to mark" : "")
                 + (t.batteryUsed.map { " · battery −\(percent($0))" } ?? ""))
                .font(.caption).foregroundStyle(open > 0 ? .orange : .secondary)
        }
    }
}

// MARK: - One test, afterwards

struct TestSessionView: View {
    let radar: SoundRadar
    let id: UUID
    @State private var store = EvalStore.shared
    @State private var player: AVAudioPlayer?
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var exportFailed = false
    @State private var confirmDelete = false
    @State private var replayFrom: Double?

    var body: some View {
        if let s = store.sessions.first(where: { $0.id == id }) {
            List {
                results(s)
                bySound(s)
                recording(s)
                timeline(s)
                Section {
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Share \(exportURL.lastPathComponent)", systemImage: "square.and.arrow.up") }
                    } else {
                        Button(exporting ? "Preparing…" : "Export this test (zip)") { export(s) }.disabled(exporting)
                    }
                    if exportFailed { Text("Export failed. Is the phone out of space?").foregroundStyle(.red) }
                } header: {
                    Text("Export")
                } footer: {
                    Text("""
                        One zip: timeline.csv (every alert and flagged sound with its time, direction and your three verdicts), \
                        by_sound.csv, summary.csv, alerts.csv, session.json, and the recording: listen.m4a, audio.caf (replay it \
                        on a Mac with Tools/replay.swift), blocks.csv, verdicts.csv (every classifier answer) and events.txt.
                        """)
                }
                Section {
                    Button("Delete test and its recording", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(s.started.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $replayFrom) { t in ReplayView(radar: radar, id: id, start: t) }
            .onAppear { exportURL = nil }  // back from a replay: verdicts may have changed
            .onDisappear { player?.stop() }
            .confirmationDialog("Delete this test, its recording and your marks?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { store.delete(id) }
            }
        } else {
            ContentUnavailableView("Deleted", systemImage: "trash")
        }
    }

    private func results(_ s: EvalSession) -> some View {
        let t = TestSummary(s), v = t.verdicts, r = s.reliability, open = s.alerts.filter { !$0.fullyMarked }.count
        let battery = zip2(r.batteryStart, r.batteryEnd).map { ends in
            "\(percent(ends.0)) → \(percent(ends.1))" + (r.charging == true ? " · on the charger" : t.batteryPerHour.map { " · ≈ \(percent($0))/h" } ?? "")
        } ?? "unknown"
        return Section {
            LabeledContent("Duration", value: clock(t.minutes * 60))
            LabeledContent("Method", value: s.conditions.model)
            LabeledContent("Carried · activity", value: "\(s.conditions.carry) · \(s.conditions.activity)")
            if !s.conditions.notes.isEmpty { Text(s.conditions.notes).font(.callout) }
            LabeledContent("Alerts", value: "\(s.alerts.count)")
            if open > 0 {
                Label("\(open) alert\(open == 1 ? "" : "s") still to mark below", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
            LabeledContent("Real sound, not a false alarm", value: outOf(v.real, v.real + v.falseAlarms))
            LabeledContent("Named the right sound", value: outOf(v.right, v.real))
            LabeledContent("Pointed right", value: outOf(v.pointedRight, v.aimed) + (v.pointedClose > 0 ? " (+\(v.pointedClose) close)" : ""))
            LabeledContent("On time", value: outOf(v.onTime, v.timed))
            LabeledContent("Angle off · worst", value: v.angleErrors.isEmpty ? "–"
                           : "\(Int(percentile(v.angleErrors, 0.5)!.rounded()))° · \(Int(v.angleErrors.max()!.rounded()))°")
            LabeledContent("Late by · worst", value: v.lateBys.isEmpty ? "–"
                           : "\(Int((percentile(v.lateBys, 0.5)! * 1000).rounded())) ms · \(Int((v.lateBys.max()! * 1000).rounded())) ms")
            LabeledContent("False alarms per 10 min", value: t.falsePer10Minutes.map { String(format: "%.1f", $0) } ?? "–")
            LabeledContent("Flagged sounds caught", value: s.marks.isEmpty ? "none flagged" : "\(t.eventsCaught) of \(s.marks.count)")
            LabeledContent("Battery", value: battery)
            LabeledContent("Phone got", value: r.hottest)
            if r.recognitionDown > 0 || r.micTrouble > 0 {
                LabeledContent("Not recognizing · no audio", value: "\(Int(r.recognitionDown)) s · \(Int(r.micTrouble)) s")
            }
        } header: {
            Text("Results")
        } footer: {
            Text("""
                Direction and timing count the real alerts only. Angle off and late by are typical values (median): 0 for the \
                ones marked right or on time, else what you set. iOS reports the battery in 5% steps: test 20 minutes or more \
                for a useful number.
                """)
        }
    }

    private func bySound(_ s: EvalSession) -> some View {
        Section {
            if s.alerts.isEmpty && s.marks.isEmpty { Text("No alerts and nothing flagged").foregroundStyle(.secondary) }
            ForEach(soundTallies(s)) { t in
                let v = t.verdicts
                let parts = [(v.right, "right"), (v.wrongSound, "wrong sound"), (v.falseAlarms, "false"), (v.unmarked + v.unsure, "sound not marked"),
                             (v.pointedRight, "pointed right"), (v.pointedClose, "close"), (v.pointedWrong, "pointed wrong"),
                             (v.onTime, "on time"), (v.late, "late"), (t.caught, "flagged and caught"), (t.missed, "flagged but missed")]
                    .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
                    + [percentile(v.angleErrors, 0.5).map { "angle off ~\(Int($0.rounded()))°" },
                       percentile(v.lateBys, 0.5).map { "late by ~\(Int(($0 * 1000).rounded())) ms" }].compactMap { $0 }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(t.sound).font(.subheadline.bold())
                        Spacer()
                        Text(t.needsWork ? "Needs work" : v.real > 0 ? "Good" : "–")
                            .font(.caption.bold()).foregroundStyle(t.needsWork ? .red : v.real > 0 ? .green : .secondary)
                    }
                    Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    if t.needsWork { Text("Fix: " + t.problems.joined(separator: ", ")).font(.caption.bold()).foregroundStyle(.red) }
                }
            }
        } header: {
            Text("By sound")
        } footer: {
            Text("Needs work: over 20% of its judged alerts were false alarms, the wrong sound, pointing the wrong way or late, or it missed a sound you flagged.")
        }
    }

    // MARK: The recording

    @ViewBuilder private func recording(_ s: EvalSession) -> some View {
        if let folder = s.recordingFolder {
            let listen = folder.appending(path: "listen.m4a")
            Section {
                if !FileManager.default.fileExists(atPath: listen.path(percentEncoded: false)) {
                    Text("No audio to listen to in this recording").foregroundStyle(.secondary)
                } else if s.ended == nil {
                    Text("Listen back once the test has ended").foregroundStyle(.secondary)
                } else {
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        HStack {
                            Button {
                                if player?.isPlaying == true { player?.pause() } else { play(from: player?.currentTime ?? 0) }
                            } label: {
                                Image(systemName: player?.isPlaying == true ? "pause.circle.fill" : "play.circle.fill").font(.title)
                            }
                            .buttonStyle(.borderless)
                            Slider(value: Binding(get: { player?.currentTime ?? 0 }, set: { player?.currentTime = $0 }),
                                   in: 0...max(player?.duration ?? 1, 1))
                            Text("\(clock(player?.currentTime ?? 0)) / \(clock(player?.duration ?? 0))").font(.caption.monospacedDigit())
                        }
                    }
                    .onAppear { if player == nil { player = try? AVAudioPlayer(contentsOf: listen) } }
                    if screenTrack(s) != nil, store.active?.recording == nil {
                        NavigationLink { ReplayView(radar: radar, id: s.id, start: 0) } label: {
                            Label("Replay with the screen", systemImage: "play.rectangle.fill")
                        }
                    }
                }
                NavigationLink("Decisions log") { LogView(url: folder.appending(path: "events.txt")) }
                LabeledContent("Saved", value: folderSize(folder))
            } header: {
                Text("Recording")
            } footer: {
                Text("""
                    Replay plays the sound with the screen as it looked at that moment; ▶ next to an alert starts it 3 s before. \
                    Listening pauses Sound Radar so it doesn't hear its own playback; resume it on the main screen.
                    """)
            }
        }
    }

    private func play(from t: Double) {
        guard let player, store.active?.recording == nil else { return }
        startPlayback(player, at: t, radar: radar)
    }

    /// The recording's screen track, if it has one (tests recorded before replay existed don't).
    private func screenTrack(_ s: EvalSession) -> URL? {
        s.recordingFolder.map { $0.appending(path: "display.jsonl") }.flatMap { url in
            ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 ? url : nil
        }
    }

    // MARK: Timeline: every alert and flagged sound, by time into the test

    private struct Row: Identifiable {
        var id: UUID
        var offset: Double  // seconds into the recording
        var alert: EvalAlert?
        var mark: EvalMark?
    }

    private func timeline(_ s: EvalSession) -> some View {
        let rows = (s.alerts.map { Row(id: $0.id, offset: $0.audioAt ?? $0.at.timeIntervalSince(s.started), alert: $0) }
                    + s.marks.map { Row(id: $0.id, offset: $0.audioAt ?? $0.at.timeIntervalSince(s.started), mark: $0) })
            .sorted { $0.offset < $1.offset }
        let replay = screenTrack(s) != nil, canPlay = (replay || player != nil) && s.ended != nil && store.active?.recording == nil
        return Section {
            if rows.isEmpty { Text("Nothing happened").foregroundStyle(.secondary) }
            ForEach(rows) { row in
                let offset = row.offset
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(clock(offset)).font(.subheadline.monospacedDigit().bold())
                        if let a = row.alert {
                            Text("\(a.critical ? "Watch out" : "Heads up"): \(a.what)").font(.subheadline.bold())
                                .foregroundStyle(a.critical ? .red : .orange)
                        } else if let m = row.mark {
                            Label("You flagged: \(m.sound)\(m.inReplay == true ? " (in replay)" : "")", systemImage: "flag.fill").font(.subheadline)
                        }
                        Spacer()
                        if let m = row.mark {
                            Menu {
                                Picker("Sound", selection: Binding(get: { m.sound }, set: { v in editMark(s.id, m.id) { $0.sound = v } })) {
                                    ForEach(dangerSounds, id: \.sound) { Text($0.sound).tag($0.sound) }
                                }
                                Button("Delete flag", systemImage: "trash", role: .destructive) {
                                    store.update(s.id) { $0.marks.removeAll { $0.id == m.id } }
                                    exportURL = nil
                                }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .buttonStyle(.borderless)  // in a list row, else the row takes the tap
                        }
                        if canPlay {
                            Button {
                                if replay { player?.pause(); replayFrom = max(offset - 3, 0) } else { play(from: offset - 3) }
                            } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                    if let a = row.alert {
                        Text(details(a)).font(.caption).foregroundStyle(.secondary)
                        AlertVerdicts(alert: a) { change in judge(s.id, a.id, change) }
                    } else if let m = row.mark {
                        let result = flagResult(m, s)
                        Text(result.text).font(.caption).foregroundStyle(result.caught ? .green : .red)
                    }
                }
            }
        } header: {
            Text("Timeline (\(s.alerts.count) alerts, \(s.alerts.filter { !$0.fullyMarked }.count) to mark, \(s.marks.count) flagged)")
        } footer: {
            Text("""
                Sound: Right; Wrong = a real sound but the wrong name (a siren called a horn); False = nothing worth an alert \
                (then direction and timing don't apply). Direction: Right = pointed at it; Close = the right side but off; \
                Wrong = a different side; then set how many degrees clockwise the sound really was (counter-clockwise: below 0). \
                Timing: On time = while the sound was on, early enough to react; Late = only after it mattered; then set how \
                late in ms (in a replay, tap "the sound began now" as you hear it start). Leave ? when you can't tell. \
                Dangers the app missed: flag them in Replay as you hear them; ⋯ on a flag changes its sound or deletes it.
                """)
        }
    }

    private func editMark(_ session: UUID, _ mark: UUID, _ change: @escaping (inout EvalMark) -> Void) {
        store.update(session) { s in if let i = s.marks.firstIndex(where: { $0.id == mark }) { change(&s.marks[i]) } }
        exportURL = nil
    }

    private func judge(_ session: UUID, _ alert: UUID, _ change: @escaping (inout EvalAlert) -> Void) {
        store.update(session) { s in if let i = s.alerts.firstIndex(where: { $0.id == alert }) { change(&s.alerts[i]) } }
        exportURL = nil  // an export made before this verdict is out of date
    }

    private func details(_ a: EvalAlert) -> String {
        var parts = [a.azimuth.map { "\(Int($0.rounded()))° \(directionWords($0))" } ?? "direction unclear"]
        if let settled = a.settledAzimuth, let first = a.azimuth, angularDistance(settled, first) >= 10 {
            parts.append("then \(Int(settled.rounded()))°")
        }
        if a.directionReview != .right, let really = a.trueAzimuth { parts.append("really \(Int(really.rounded()))°") }
        if a.timingReview == .late, let late = a.lateBy { parts.append("\(Int((late * 1000).rounded())) ms late") }
        parts.append(a.appState)
        if let ok = a.hapticOK { parts.append(ok ? "vibrated" : "vibration failed (\(a.haptic ?? "?"))") }
        return parts.joined(separator: " · ")
    }

    private func export(_ s: EvalSession) {
        exporting = true
        exportFailed = false
        Task {
            exportURL = await Task.detached { try? exportTest(s) }.value
            exportFailed = exportURL == nil
            exporting = false
        }
    }
}

/// Play a recording from `t`. Pauses Sound Radar first, so it doesn't hear (and warn about) its own playback.
private func startPlayback(_ player: AVAudioPlayer, at t: Double, radar: SoundRadar) {
    if radar.listeningStarted && !radar.paused { radar.setPaused(true) }
    try? AVAudioSession.sharedInstance().setCategory(.playback)
    try? AVAudioSession.sharedInstance().setActive(true)
    player.currentTime = min(max(t, 0), player.duration)
    player.play()
}

/// An alert's three verdicts: the sound, and unless it was a false alarm, the direction and the timing. "?" = not marked.
/// Close or wrong: how far off it pointed; late: by how much. `now` (replay): the moment on screen, to set the delay by ear.
private struct AlertVerdicts: View {
    let alert: EvalAlert
    var now: Double? = nil
    let edit: (@escaping (inout EvalAlert) -> Void) -> Void
    @State private var angleDraft: Double?  // while a slider is dragged: saved once it's let go
    @State private var lateDraft: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Sound", alert.review == .unsure ? nil : alert.review, [("Right", .real), ("Wrong", .wrongSound), ("False", .falseAlarm)]) { v in
                edit { $0.review = v }
            }
            if alert.review != .falseAlarm {
                row("Direction", alert.directionReview, [("Right", .right), ("Close", .close), ("Wrong", .wrong)]) { v in
                    edit { $0.directionReview = v }
                }
                if alert.directionReview == .close || alert.directionReview == .wrong { directionFix.padding(.leading, 70) }
                row("Timing", alert.timingReview, [("On time", .onTime), ("Late", .late)]) { v in edit { $0.timingReview = v } }
                if alert.timingReview == .late { lateFix.padding(.leading, 70) }
            }
        }
    }

    /// Where the sound really was, as degrees clockwise from the arrow; a little dial shows both.
    @ViewBuilder private var directionFix: some View {
        if let arrow = alert.direction {
            let off = angleDraft ?? alert.directionOffBy, really = off.map { remainder(arrow - $0, 360) }
            HStack(spacing: 10) {
                DirectionDial(arrow: arrow, really: really)
                VStack(alignment: .leading, spacing: 2) {
                    Stepper(value: Binding(get: { off ?? 0 }, set: { v in edit { $0.directionOffBy = v } }), in: -180...180, step: 5) {
                        Text(off.map { $0 == 0 ? "Really where it pointed" : "Really \(Int(abs($0)))° \($0 > 0 ? "clockwise" : "counter-clockwise")" }
                             ?? "How far off was it?")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Slider(value: Binding(get: { off ?? 0 }, set: { angleDraft = $0 }), in: -180...180, step: 5) { editing in
                        if !editing, let v = angleDraft { edit { $0.directionOffBy = v }; angleDraft = nil }
                    }
                    if let really { Text("= \(Int(really.rounded()))° \(directionWords(really))").foregroundStyle(.green) }
                }
            }
            .font(.caption)
        } else {
            Text("It gave no direction to correct").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// How late it came, in ms; while replaying, also "the sound began now".
    private var lateFix: some View {
        let ms = (lateDraft ?? alert.lateBy).map { $0 * 1000 }
        return VStack(alignment: .leading, spacing: 2) {
            Stepper(value: Binding(get: { ms ?? 0 }, set: { v in edit { $0.lateBy = v / 1000 } }), in: 0...10_000, step: 50) {
                Text(ms.map { "\(Int($0.rounded())) ms late" } ?? "How late was it?")
            }
            Slider(value: Binding(get: { ms ?? 0 }, set: { lateDraft = $0 / 1000 }), in: 0...10_000, step: 50) { editing in
                if !editing, let v = lateDraft { edit { $0.lateBy = v }; lateDraft = nil }
            }
            if let now, let at = alert.audioAt, now < at {
                // A plain String, not a localized literal: that would print 2806 as "2.806" in some regions.
                Button(String(format: "The sound began now: %d ms before the warning", Int(((at - now) * 1000).rounded()))) {
                    edit { $0.lateBy = at - now }
                }
                .buttonStyle(.bordered)
            }
        }
        .font(.caption)
    }

    private func row<V: Hashable>(_ title: String, _ value: V?, _ options: [(String, V)], set: @escaping (V?) -> Void) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Picker(title, selection: Binding(get: { value }, set: set)) {
                Text("?").tag(V?.none)
                ForEach(options, id: \.0) { Text($0.0).tag(V?.some($0.1)) }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// The alert's arrow (grey) and where the sound really was (green), from above, ahead up.
private struct DirectionDial: View {
    let arrow: Double
    let really: Double?

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) / 2 - 2
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.secondary.opacity(0.4)))
            func line(_ az: Double, _ color: Color) {
                var p = Path()
                p.move(to: c)
                p.addLine(to: CGPoint(x: c.x - sin(az * .pi / 180) * r, y: c.y - cos(az * .pi / 180) * r))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            line(arrow, .secondary)
            if let really { line(really, .green) }
        }
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
    }
}

// MARK: - Replay: the sound, with the screen as it looked at that moment

struct ReplayView: View {
    let radar: SoundRadar
    let id: UUID
    let start: Double  // seconds into the recording
    @State private var store = EvalStore.shared
    @State private var frames: [ScreenFrame] = []
    @State private var onsets: [Double] = []  // when each warning appeared, to jump between them
    @State private var player: AVAudioPlayer?
    @State private var lastFlag: UUID?  // flagged in this replay, to undo

    private var session: EvalSession? { store.sessions.first { $0.id == id } }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let now = player?.currentTime ?? start, f = screenFrame(at: now, in: frames)
            let status = f.map {
                listeningStatus(alert: $0.alert, kind: $0.kind, recognitionDown: $0.recognitionDown == true, traffic: $0.traffic, people: $0.people)
            } ?? ("ear", Color.secondary, frames.isEmpty ? "Loading…" : "Starting", "The first moment of the test")
            ScrollView {
                VStack(spacing: 16) {
                    StatusCard(icon: status.0, tint: status.1, title: status.2, detail: status.3, alert: f?.alert)
                    RadarCard(bins: f?.bins ?? [], alert: f?.alert)
                    controls(now)
                    // The warning coming up in the next 5 s (so its start can be marked by ear), or shown in the last 10 s.
                    if let s = session, let a = s.alerts.last(where: { offset($0, s) <= now + 5 }), now - offset(a, s) < 10 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(offset(a, s) > now ? String(format: "Coming up in %.1f s: %@", offset(a, s) - now, a.what)
                                                    : "Mark this warning: \(a.what)")
                                .font(.subheadline.bold())
                            AlertVerdicts(alert: a, now: now) { change in
                                store.update(s.id) { s in if let i = s.alerts.firstIndex(where: { $0.id == a.id }) { change(&s.alerts[i]) } }
                            }
                            .id(a.id)
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
                    }
                    if let s = session { flagCard(s, now: now) }
                }
                .padding()
            }
            .background { (f?.alert?.level.color ?? Color(.systemGroupedBackground)).ignoresSafeArea() }
        }
        .navigationTitle("Replay")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { player?.stop() }
    }

    /// A danger heard here that the app didn't warn about: flag it at this moment of the recording.
    private func flagCard(_ s: EvalSession, now: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Heard a danger the app missed? Flag it now").font(.subheadline.bold())
            FlagGrid { sound in
                let m = EvalMark(at: s.started.addingTimeInterval(now), sound: sound, audioAt: now, inReplay: true)
                store.update(s.id) { $0.marks.append(m) }
                lastFlag = m.id
            }
            if let m = s.marks.first(where: { $0.id == lastFlag }) {
                LastFlag(mark: m, offset: m.audioAt ?? 0, result: flagResult(m, s)) {
                    store.update(s.id) { $0.marks.removeAll { $0.id == m.id } }
                    lastFlag = nil
                }
            }
            Text("Blue ticks on the bar: dangers you flagged. A flag counts as caught when a warning for that sound came within 8 s of it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
    }

    private func controls(_ now: Double) -> some View {
        let duration = max(player?.duration ?? 1, 1)
        let flags = session.map { s in s.marks.map { $0.audioAt ?? $0.at.timeIntervalSince(s.started) } } ?? []
        return VStack(spacing: 10) {
            Slider(value: Binding(get: { player?.currentTime ?? 0 }, set: { player?.currentTime = $0 }), in: 0...duration)
                .overlay(alignment: .top) {
                    GeometryReader { g in  // where warnings appeared (red) and where you flagged a danger (blue), above the bar
                        ForEach(onsets, id: \.self) { t in
                            Capsule().fill(.red).frame(width: 3, height: 9).position(x: 14 + (g.size.width - 28) * t / duration, y: -6)
                        }
                        ForEach(Array(flags.enumerated()), id: \.offset) { _, t in
                            Capsule().fill(.blue).frame(width: 3, height: 9).position(x: 14 + (g.size.width - 28) * t / duration, y: -17)
                        }
                    }
                }
            HStack {
                Text(clock(now))
                Spacer()
                Text(clock(player?.duration ?? 0))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            HStack {
                Button("Previous warning", systemImage: "backward.end.fill") { seek((onsets.last { $0 < now - 3.5 } ?? 3) - 3) }
                Spacer()
                Button("Back 5 seconds", systemImage: "gobackward.5") { seek(now - 5) }
                Spacer()
                Button(player?.isPlaying == true ? "Pause" : "Play", systemImage: player?.isPlaying == true ? "pause.circle.fill" : "play.circle.fill") {
                    if player?.isPlaying == true { player?.pause() } else if let player { startPlayback(player, at: player.currentTime, radar: radar) }
                }
                .font(.system(size: 52))
                .disabled(store.active?.recording != nil)
                Spacer()
                Button("Forward 5 seconds", systemImage: "goforward.5") { seek(now + 5) }
                Spacer()
                Button("Next warning", systemImage: "forward.end.fill") { if let n = onsets.first(where: { $0 > now + 3.5 }) { seek(n - 3) } }
                    .disabled(!onsets.contains { $0 > now + 3.5 })
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .buttonStyle(.borderless)
            if store.active?.recording != nil {
                Text("A test is recording: end it to listen back.").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
    }

    private func seek(_ t: Double) { player?.currentTime = min(max(t, 0), player?.duration ?? 0) }

    /// Seconds into the recording the alert came.
    private func offset(_ a: EvalAlert, _ s: EvalSession) -> Double { a.audioAt ?? a.at.timeIntervalSince(s.started) }

    private func load() async {
        guard let folder = session?.recordingFolder else { return }
        let track = folder.appending(path: "display.jsonl")
        let loaded = await Task.detached { screenFrames(track) }.value
        frames = loaded
        onsets = loaded.indices.filter { i in
            guard let a = loaded[i].alert else { return false }
            return i == 0 || loaded[i - 1].alert?.what != a.what || loaded[i - 1].alert?.level != a.level
        }.map { loaded[$0].t }
        guard let p = try? AVAudioPlayer(contentsOf: folder.appending(path: "listen.m4a")) else { return }
        player = p
        if store.active?.recording == nil { startPlayback(p, at: start, radar: radar) } else { p.currentTime = start }
    }
}

private struct LogView: View {
    let url: URL

    var body: some View {
        ScrollView {
            Text(String(((try? String(contentsOf: url, encoding: .utf8)) ?? "No log").suffix(300_000)))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Decisions log")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func folderSize(_ url: URL) -> String {
    let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

/// One zip with the test's spreadsheets, its JSON and its recording.
nonisolated func exportTest(_ s: EvalSession) throws -> URL {
    let fm = FileManager.default, stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd HH-mm"
    let name = "Sound test \(stamp.string(from: s.started))", dir = fm.temporaryDirectory.appending(path: name)
    try? fm.removeItem(at: dir)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(s).write(to: dir.appending(path: "session.json"))
    let sheets = testCSVs(s).merging(evalCSVs([s]).filter { ["alerts.csv", "marks.csv"].contains($0.key) }) { mine, _ in mine }
    for (file, text) in sheets { try text.write(to: dir.appending(path: file), atomically: true, encoding: .utf8) }
    if let folder = s.recordingFolder, let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
        let recording = dir.appending(path: "recording")
        try fm.createDirectory(at: recording, withIntermediateDirectories: true)
        for f in files {  // a hard link: instant, even for a gigabyte of audio
            let to = recording.appending(path: f.lastPathComponent)
            do { try fm.linkItem(at: f, to: to) } catch { try fm.copyItem(at: f, to: to) }
        }
    }
    // Files' own zipping, via a coordinated read "for uploading".
    var zip: URL?, failure: NSError?, moveFailure: Error?
    NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &failure) { zipped in
        let to = fm.temporaryDirectory.appending(path: name + ".zip")
        try? fm.removeItem(at: to)
        do { try fm.moveItem(at: zipped, to: to); zip = to } catch { moveFailure = error }
    }
    if let failure { throw failure }
    if let moveFailure { throw moveFailure }
    guard let zip else { throw CocoaError(.fileWriteUnknown) }
    return zip
}
