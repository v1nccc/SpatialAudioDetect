import SwiftUI
import UIKit

/// Evaluation sessions, kept in Documents/Evaluations/sessions.json (also in the Files app), and what the app does
/// during the running one: every alert, its vibration, uptime, restarts, battery.
@Observable final class EvalStore {
    static let shared = EvalStore()
    private(set) var sessions: [EvalSession] = []
    private(set) var activeID: UUID?
    @ObservationIgnored private var open: (id: UUID, since: Date)?  // the alert being recorded
    @ObservationIgnored private var lastSave = Date.distantPast

    static let folder = URL.documentsDirectory.appending(path: "Evaluations")
    private static let file = folder.appending(path: "sessions.json")

    init() {
        sessions = (try? JSONDecoder().decode([EvalSession].self, from: Data(contentsOf: Self.file))) ?? []
        for i in sessions.indices where sessions[i].ended == nil {  // left running when the app was closed
            sessions[i].ended = sessions[i].alerts.last?.at ?? sessions[i].started
        }
    }

    var active: EvalSession? { activeID.flatMap { id in sessions.first { $0.id == id } } }
    private var activeIndex: Int? { activeID.flatMap { id in sessions.firstIndex { $0.id == id } } }
    private var battery: Double? { UIDevice.current.batteryLevel >= 0 ? Double(UIDevice.current.batteryLevel) : nil }

    func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(sessions).write(to: Self.file, options: .atomic)
        lastSave = .now
    }

    func start(_ kind: EvalKind, _ conditions: EvalConditions) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        var s = EvalSession(kind: kind, started: .now, conditions: conditions)
        s.reliability.batteryStart = battery
        sessions.insert(s, at: 0)
        activeID = s.id
        save()
    }

    func end() {
        guard let i = activeIndex else { return }
        sessions[i].ended = .now
        sessions[i].reliability.batteryEnd = battery
        activeID = nil
        open = nil
        save()
    }

    func update(_ id: UUID, _ change: (inout EvalSession) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[i])
        save()
    }

    func delete(_ id: UUID) {
        if activeID == id { activeID = nil }
        sessions.removeAll { $0.id == id }
        save()
    }

    // MARK: Fed by SoundRadar while a session runs

    /// Every block: record each new alert, and where it pointed ~1 s later (it follows its sound).
    func observe(_ alert: Alert?) {
        guard let i = activeIndex else { return }
        guard let a = alert else { open = nil; return }
        if let o = open, let j = sessions[i].alerts.firstIndex(where: { $0.id == o.id }),
           sessions[i].alerts[j].what == a.what, sessions[i].alerts[j].critical == (a.level == .critical) {
            if sessions[i].alerts[j].settledAzimuth == nil, Date.now.timeIntervalSince(o.since) >= 1, let az = a.azimuth {
                sessions[i].alerts[j].settledAzimuth = az
                save()
            }
            return
        }
        let record = EvalAlert(at: .now, what: a.what, critical: a.level == .critical, azimuth: a.azimuth, appState: appState())
        sessions[i].alerts.append(record)
        open = (record.id, .now)
        save()
    }

    func noteHaptic(ok: Bool, detail: String) {
        guard let i = activeIndex, let o = open, let j = sessions[i].alerts.firstIndex(where: { $0.id == o.id }),
              sessions[i].alerts[j].haptic == nil else { return }
        sessions[i].alerts[j].haptic = detail
        sessions[i].alerts[j].hapticOK = ok
        save()
    }

    func noteRestart() {
        guard let i = activeIndex else { return }
        sessions[i].reliability.restarts += 1
    }

    /// Once a second.
    func tick(listening: Bool, recognitionDown: Bool, micTrouble: Bool, heat: String) {
        guard let i = activeIndex, listening else { return }
        sessions[i].reliability.listening += 1
        if recognitionDown { sessions[i].reliability.recognitionDown += 1 }
        if micTrouble { sessions[i].reliability.micTrouble += 1 }
        let order = ["normal", "warm", "hot (iOS slows the app)", "critical"]
        if (order.firstIndex(of: heat) ?? 0) > (order.firstIndex(of: sessions[i].reliability.hottest) ?? 0) { sessions[i].reliability.hottest = heat }
        if Date.now.timeIntervalSince(lastSave) > 15 { save() }
    }

    /// All data as files to share: the full JSON plus spreadsheet-ready CSVs.
    func export() -> [URL] {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH-mm"
        let dir = Self.folder.appending(path: "Export \(stamp.string(from: .now))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var urls: [URL] = []
        if let json = try? encoder.encode(sessions), (try? json.write(to: dir.appending(path: "evaluation.json"))) != nil {
            urls.append(dir.appending(path: "evaluation.json"))
        }
        for (name, text) in evalCSVs(sessions).sorted(by: { $0.key < $1.key }) where (try? text.write(to: dir.appending(path: name), atomically: true, encoding: .utf8)) != nil {
            urls.append(dir.appending(path: name))
        }
        return urls
    }
}

/// "iPhone17,1"
private func machineName() -> String {
    var u = utsname()
    uname(&u)
    return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

// MARK: - Screen

struct EvaluationView: View {
    let radar: SoundRadar
    @State private var store = EvalStore.shared
    @State private var kind = EvalKind.controlled
    @State private var conditions = EvalConditions()
    @State private var exported: [URL] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let s = store.active {
                    if s.kind == .controlled {
                        ControlledRunner(store: store, session: s)
                    } else {
                        RealRunRunner(store: store, radar: radar, session: s)
                    }
                } else {
                    startSection
                }
                EvalGuide()
                MetricsSections(title: "Results, all sessions", metrics: evalMetrics(store.sessions))
                sessionsSection
                exportSection
            }
            .navigationTitle("Evaluate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private var startSection: some View {
        Section {
            Picker("Test", selection: $kind) { ForEach(EvalKind.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented)
            Picker("Place", selection: $conditions.place) { ForEach(EvalConditions.places, id: \.self) { Text($0) } }
            Picker("Phone carried in", selection: $conditions.carry) { ForEach(EvalConditions.carries, id: \.self) { Text($0) } }
            Picker("Activity", selection: $conditions.activity) { ForEach(EvalConditions.activities, id: \.self) { Text($0) } }
            TextField("Tester", text: $conditions.tester)
            TextField("Helper (plays the sounds)", text: $conditions.helper)
            TextField("Notes (weather, wind, speaker…)", text: $conditions.notes, axis: .vertical)
            LabeledContent("Sound model", value: radar.engine.label)
            if !radar.listeningStarted || radar.paused {
                Label("Sound Radar isn't listening yet. Starting a session starts it.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Button {
                var c = conditions
                let d = UserDefaults.standard
                c.model = radar.engine.rawValue
                c.fineTune = "rotate \(Int(d.double(forKey: "rotate")))°\(d.bool(forKey: "mirror") ? ", mirrored" : "")"
                c.device = machineName()
                c.system = "iOS " + UIDevice.current.systemVersion
                store.start(kind, c)
                if !radar.listeningStarted { Task { await radar.start() } } else if radar.paused { radar.setPaused(false) }
            } label: {
                Label("Start \(kind.rawValue.lowercased())", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } header: {
            Text("New session")
        } footer: {
            Text("Conditions are saved with every result, so you can compare later (e.g. pocket vs armband). Change one thing per session.")
        }
    }

    private var sessionsSection: some View {
        Section("Sessions (\(store.sessions.count))") {
            if store.sessions.isEmpty { Text("None yet").foregroundStyle(.secondary) }
            ForEach(store.sessions) { s in
                NavigationLink {
                    SessionDetail(store: store, id: s.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(s.kind.rawValue) · \(s.started.formatted(date: .abbreviated, time: .shortened))\(s.ended == nil ? " · running" : "")")
                            .font(.subheadline.bold())
                        Text(s.conditions.summary).font(.caption).foregroundStyle(.secondary)
                        Text(s.kind == .controlled ? "\(s.played.count) trials · \(s.alerts.count) alerts"
                                                   : "\(Int(s.reliability.listening / 60)) min · \(s.alerts.count) alerts · \(s.marks.count) marked")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var exportSection: some View {
        Section {
            Button("Prepare export files") { exported = store.export() }
            if !exported.isEmpty {
                ShareLink(items: exported) { Label("Share \(exported.count) files", systemImage: "square.and.arrow.up") }
            }
        } header: {
            Text("Export")
        } footer: {
            Text("summary.csv (every metric with its target), trials.csv (one row per played sound), alerts.csv, marks.csv, sessions.csv, plus evaluation.json with everything. Open the CSVs in Numbers, Excel or Google Sheets. Also in Files › On My iPhone › SpatialAudioDetect › Evaluations.")
        }
    }
}

// MARK: - Controlled test while running

private struct ControlledRunner: View {
    let store: EvalStore
    let session: EvalSession
    @State private var sounds: Set<String> = ["Siren", "Car horn"]
    @State private var quiet: Set<String> = ["Talking", "Music"]
    @State private var repeats = 3
    @State private var quietCount = 6
    @State private var meters = 10.0
    @State private var lockEvery = 0
    @State private var countdown = 10.0

    private var next: EvalTrial? { session.trials.first { $0.at == nil } }
    private var last: EvalTrial? { session.trials.filter { $0.at != nil }.max { $0.at! < $1.at! } }

    var body: some View {
        Section {
            LabeledContent("Played", value: "\(session.played.count) of \(session.trials.count) planned")
            Button("End session", role: .destructive) { store.end() }
        } header: {
            Text("Running: controlled test")
        } footer: {
            Text(session.conditions.summary)
        }
        if let last { LastTrial(store: store, sessionID: session.id, trial: last, alerts: session.alerts) }
        if let next {
            nextTrial(next)
        } else {
            planBuilder
        }
    }

    private func nextTrial(_ t: EvalTrial) -> some View {
        let index = session.trials.firstIndex { $0.id == t.id }.map { $0 + 1 } ?? 0
        return Section {
            Text("\(t.sound) · from \(t.side.rawValue.uppercased()) · \(Int(t.meters)) m\(t.locked ? " · phone LOCKED" : "")")
                .font(.title3.bold())
            Picker("Sound", selection: binding(t, \.sound)) { ForEach(evalAlertSounds + evalQuietSounds, id: \.self) { Text($0) } }
            Picker("From", selection: binding(t, \.side)) { ForEach(Side.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented)
            Stepper("Distance: \(Int(t.meters)) m", value: binding(t, \.meters), in: 1...100, step: 1)
            Toggle("Phone locked for this one", isOn: binding(t, \.locked))
            if t.locked {
                Stepper("Countdown: \(Int(countdown)) s", value: $countdown, in: 5...30, step: 5)
                Button {
                    store.update(session.id) { s in if let i = s.trials.firstIndex(where: { $0.id == t.id }) { s.trials[i].at = .now + countdown } }
                } label: {
                    Label("Start countdown, then lock the phone", systemImage: "lock.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    store.update(session.id) { s in if let i = s.trials.firstIndex(where: { $0.id == t.id }) { s.trials[i].at = .now } }
                } label: {
                    Label("Sound starts NOW", systemImage: "speaker.wave.3.fill").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            Button("Skip this one", role: .destructive) {
                store.update(session.id) { s in s.trials.removeAll { $0.id == t.id } }
            }
        } header: {
            Text("Trial \(index) of \(session.trials.count)")
        } footer: {
            Text(t.locked
                 ? "Tap, then lock with the side button. Your helper starts the sound when the countdown ends (count it together, or they use their own timer). Unlock afterwards to answer."
                 : "Helper: stand \(t.side.rawValue.lowercased()) of the tester, \(Int(t.meters)) m away, at chest height. Tap the moment the sound starts. Wait for “All clear” on the main screen between trials (about 10 s).")
        }
    }

    private func binding<V>(_ t: EvalTrial, _ path: WritableKeyPath<EvalTrial, V>) -> Binding<V> {
        Binding(get: { t[keyPath: path] }, set: { value in
            store.update(session.id) { s in if let i = s.trials.firstIndex(where: { $0.id == t.id }) { s.trials[i][keyPath: path] = value } }
        })
    }

    private var planBuilder: some View {
        Section {
            ForEach(evalAlertSounds, id: \.self) { s in
                Toggle(s, isOn: Binding(get: { sounds.contains(s) }, set: { if $0 { sounds.insert(s) } else { sounds.remove(s) } }))
            }
            Stepper("Each from every side: \(repeats)×", value: $repeats, in: 1...10)
            ForEach(evalQuietSounds, id: \.self) { s in
                Toggle("Harmless: \(s)", isOn: Binding(get: { quiet.contains(s) }, set: { if $0 { quiet.insert(s) } else { quiet.remove(s) } }))
            }
            Stepper("Harmless sounds: \(quietCount)", value: $quietCount, in: 0...40)
            Stepper("Distance: \(Int(meters)) m", value: $meters, in: 1...100, step: 1)
            Picker("Phone locked", selection: $lockEvery) {
                Text("Never").tag(0)
                Text("Every other").tag(2)
                Text("Always").tag(1)
            }
            .pickerStyle(.segmented)
            Button {
                var rng = SystemRandomNumberGenerator()
                let plan = evalPlan(sounds: evalAlertSounds.filter(sounds.contains), repeats: repeats, quiet: evalQuietSounds.filter(quiet.contains),
                                    quietCount: quietCount, meters: meters, lockEvery: lockEvery, using: &rng)
                store.update(session.id) { $0.trials += plan }
            } label: {
                Label("Make a shuffled plan (\(sounds.count * 4 * repeats + (quiet.isEmpty ? 0 : quietCount)) trials)", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(sounds.isEmpty && (quiet.isEmpty || quietCount == 0))
        } header: {
            Text(session.trials.isEmpty ? "Plan the trials" : "Plan more trials")
        } footer: {
            Text("Every alert sound is played from all 4 sides, in random order so nobody can guess. Harmless sounds check for false alarms. For trustworthy numbers aim for 30+ per sound type per condition.")
        }
    }
}

/// The trial just played: live result, then the tester's answers.
private struct LastTrial: View {
    let store: EvalStore
    let sessionID: UUID
    let trial: EvalTrial
    let alerts: [EvalAlert]

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let elapsed = context.date.timeIntervalSince(trial.at!)
                if elapsed < 0 {
                    Text("Sound in \(Int(-elapsed.rounded(.down))) s: lock the phone now").font(.title3.bold()).foregroundStyle(.orange)
                } else {
                    resultView(result(trial, alerts: alerts)!, waiting: elapsed < evalWindow.after)
                    if trial.noticedAt == nil && elapsed < 20 {
                        Button { set { $0.noticedAt = .now } } label: {
                            Label("I noticed it", systemImage: "hand.tap.fill").frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            if trial.shouldAlert {
                HStack {
                    Text("Felt the vibration?")
                    Spacer()
                    answer("Yes", trial.felt == true) { set { $0.felt = true } }
                    answer("No", trial.felt == false) { set { $0.felt = false } }
                }
            }
            TextField("Note (e.g. truck passed, wind)", text: Binding(get: { trial.note }, set: { v in set { $0.note = v } }))
            Button("Delete this trial", role: .destructive) { store.update(sessionID) { s in s.trials.removeAll { $0.id == trial.id } } }
        } header: {
            Text("Last: \(trial.sound) from \(trial.side.rawValue.lowercased())\(trial.locked ? " (locked)" : "")")
        }
    }

    @ViewBuilder private func resultView(_ r: TrialResult, waiting: Bool) -> some View {
        if let a = r.alert {
            let good = trial.shouldAlert
            Label("\(a.critical ? "Critical" : "Warning"): \(a.what)\(r.typeRight || !good ? "" : " (wrong sound)") after \(String(format: "%.1f", r.latency ?? 0)) s",
                  systemImage: good ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(good ? .green : .red)
            if good, let az = a.direction {
                Label("Pointed \(Int(az.rounded()))° (\(directionWords(az))) · \(r.sideRight == true ? "right side" : "WRONG side") · \(Int((r.angleError ?? 0).rounded()))° off",
                      systemImage: r.sideRight == true ? "location.north.fill" : "location.slash")
                    .foregroundStyle(r.sideRight == true ? .green : .orange)
                    .font(.callout)
            }
            Text("Vibration: \(a.haptic ?? "none recorded")").font(.caption).foregroundStyle(.secondary)
        } else if waiting {
            Label("Listening…", systemImage: "ear").foregroundStyle(.secondary)
        } else {
            Label(trial.shouldAlert ? "Missed: no alert within 8 s" : "Correctly stayed quiet",
                  systemImage: trial.shouldAlert ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(trial.shouldAlert ? .red : .green)
        }
        if let n = r.reaction { Text(String(format: "You noticed after %.1f s", n)).font(.caption) }
    }

    private func answer(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.bordered).tint(on ? .accentColor : .secondary)
    }

    private func set(_ change: @escaping (inout EvalTrial) -> Void) {
        store.update(sessionID) { s in if let i = s.trials.firstIndex(where: { $0.id == trial.id }) { change(&s.trials[i]) } }
    }
}

// MARK: - Real run while running

private struct RealRunRunner: View {
    let store: EvalStore
    let radar: SoundRadar
    let session: EvalSession

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                LabeledContent("Running for", value: Duration.seconds(context.date.timeIntervalSince(session.started))
                    .formatted(.time(pattern: .hourMinuteSecond)))
            }
            LabeledContent("Alerts so far", value: "\(session.alerts.count)")
            Toggle("Also record audio (to label later)", isOn: Binding(get: { radar.recorder != nil }, set: { _ in radar.toggleRecording() }))
            Button("End run", role: .destructive) { store.end() }
        } header: {
            Text("Running: real run")
        } footer: {
            Text("Run or ride normally. Every alert is recorded automatically. Afterwards open this session and mark each alert real or false alarm.")
        }
        Section {
            ForEach(["Siren", "Car horn", "Vehicle getting closer", "Dog bark", "Other danger"], id: \.self) { s in
                Button {
                    store.update(session.id) { $0.marks.append(EvalMark(at: .now, sound: s)) }
                } label: {
                    Label(s, systemImage: "plus.circle.fill").frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
            }
            if let m = session.marks.last {
                Text("Last marked: \(m.sound) at \(m.at.formatted(date: .omitted, time: .standard))\(caught(m, alerts: session.alerts) ? " · app alerted ✓" : "")")
                    .font(.caption)
            }
        } header: {
            Text("Mark a real event now")
        } footer: {
            Text("Whoever can hear it (you, or a companion holding a second phone… or this one) taps when a real siren, horn or vehicle happens. Missed some? Add them after the run in the session.")
        }
    }
}

// MARK: - A finished (or running) session

private struct SessionDetail: View {
    let store: EvalStore
    let id: UUID
    @State private var missedSound = "Siren"
    @State private var missedAt = Date.now
    @State private var confirmDelete = false

    var body: some View {
        if let s = store.sessions.first(where: { $0.id == id }) {
            List {
                Section("Conditions") {
                    LabeledContent("Test", value: s.kind.rawValue)
                    LabeledContent("Started", value: s.started.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("Place · carried · activity", value: "\(s.conditions.place) · \(s.conditions.carry) · \(s.conditions.activity)")
                    LabeledContent("Model · fine-tune", value: "\(s.conditions.model) · \(s.conditions.fineTune)")
                    LabeledContent("Phone", value: "\(s.conditions.device) · \(s.conditions.system)")
                    if !s.conditions.tester.isEmpty || !s.conditions.helper.isEmpty {
                        LabeledContent("Tester · helper", value: "\(s.conditions.tester) · \(s.conditions.helper)")
                    }
                    if !s.conditions.notes.isEmpty { Text(s.conditions.notes).font(.callout) }
                }
                MetricsSections(title: "This session", metrics: evalMetrics([s]))
                if s.kind == .controlled { trials(s) } else { review(s) }
                Section {
                    Button("Delete session", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(s.kind.rawValue)
            .confirmationDialog("Delete this session and its data?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { store.delete(id) }
            }
        } else {
            ContentUnavailableView("Deleted", systemImage: "trash")
        }
    }

    private func trials(_ s: EvalSession) -> some View {
        Section("Played trials (\(s.played.count))") {
            ForEach(Array(s.played.enumerated()), id: \.element.id) { i, t in
                let r = result(t, alerts: s.alerts)!
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(i + 1) \(t.sound) · \(t.side.rawValue) · \(Int(t.meters)) m\(t.locked ? " · locked" : "")").font(.subheadline.bold())
                    Text(line(t, r)).font(.caption).foregroundStyle(t.shouldAlert == r.detected ? Color.secondary : Color.red)
                    if !t.note.isEmpty { Text(t.note).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func line(_ t: EvalTrial, _ r: TrialResult) -> String {
        guard let a = r.alert else { return t.shouldAlert ? "Missed" : "Stayed quiet ✓" }
        if !t.shouldAlert { return "False alarm: \(a.what)" }
        var parts = ["\(a.what)\(r.typeRight ? "" : " (wrong sound)") in \(String(format: "%.1f", r.latency ?? 0)) s"]
        if let e = r.angleError { parts.append("\(Int(e.rounded()))° off\(r.sideRight == true ? "" : ", wrong side")") }
        if let f = t.felt { parts.append(f ? "felt" : "not felt") }
        if let n = r.reaction { parts.append(String(format: "noticed %.1f s", n)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func review(_ s: EvalSession) -> some View {
        Section {
            if s.alerts.isEmpty { Text("No alerts in this run").foregroundStyle(.secondary) }
            ForEach(s.alerts) { a in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(a.at.formatted(date: .omitted, time: .standard)) · \(a.critical ? "Critical" : "Warning"): \(a.what) · \(directionWords(a.direction))")
                        .font(.subheadline)
                    Picker("Was it real?", selection: Binding(get: { a.review }, set: { v in
                        store.update(id) { s in if let i = s.alerts.firstIndex(where: { $0.id == a.id }) { s.alerts[i].review = v } }
                    })) {
                        Text("?").tag(EvalAlert.Review?.none)
                        ForEach(EvalAlert.Review.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        } header: {
            Text("Review every alert (\(s.alerts.filter { $0.review != nil }.count)/\(s.alerts.count) done)")
        } footer: {
            Text("Real = there really was a siren, horn or vehicle worth knowing about. Not sure? Listen to the recording if you made one (Debug › Share last recording).")
        }
        Section {
            ForEach(s.marks) { m in
                Label("\(m.at.formatted(date: .omitted, time: .standard)) · \(m.sound)", systemImage: caught(m, alerts: s.alerts) ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(caught(m, alerts: s.alerts) ? .green : .red)
            }
            Picker("Sound", selection: $missedSound) { ForEach(["Siren", "Car horn", "Vehicle getting closer", "Dog bark", "Other danger"], id: \.self) { Text($0) } }
            DatePicker("When", selection: $missedAt, in: s.started...(s.ended ?? .now), displayedComponents: .hourAndMinute)
            Button("Add this event") { store.update(id) { $0.marks.append(EvalMark(at: missedAt, sound: missedSound)) } }
        } header: {
            Text("Real events (\(s.marks.count))")
        } footer: {
            Text("Events marked during the run, plus any you remember afterwards: green = the app alerted within 8 s, red = missed.")
        }
    }
}

// MARK: - Shared pieces

private struct MetricsSections: View {
    let title: String
    let metrics: [EvalMetric]

    var body: some View {
        let groups = metrics.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
        ForEach(groups, id: \.self) { g in
            Section("\(title): \(g)") {
                ForEach(metrics.filter { $0.group == g }) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: m.pass == nil ? "circle.dashed" : m.pass! ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(m.pass == nil ? Color.secondary : m.pass! ? Color.green : Color.red)
                            Text(m.name).font(.subheadline.bold())
                            Spacer()
                            Text(m.value).font(.subheadline.monospacedDigit())
                        }
                        Text("Target \(m.target)\(m.range.isEmpty ? "" : " · likely range \(m.range)") · \(m.explain)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct EvalGuide: View {
    var body: some View {
        Section {
            topic("1. What gets measured", """
                Recognition: how many sirens/horns get an alert, whether it names the right sound, how many harmless sounds wrongly alert, and how fast.
                Direction: how often the arrow shows the right side (ahead/left/behind/right), how many degrees off, and front/back mix-ups.
                Feeling it: whether the vibration was delivered and felt, also locked, and how fast you noticed.
                Real runs: how many alerts were real, false alarms per 10 minutes, and how many real events were caught.
                Reliability: how much of the time recognition and the mic worked, restarts, battery per hour.
                Each number shows its target (✓/✗) and a "likely range": with few trials a result is uncertain, e.g. 9/10 could really be anywhere from about 60% to 98%.
                """)
            topic("2. Before you start", """
                • Charge the phone. Settings › Sounds & Haptics › Haptics: Always Play.
                • Pick the sound model (Debug › Sound model) and run Debug › Direction test once, so the arrow is calibrated.
                • Helper: a Bluetooth speaker and real recordings (search "ambulance siren", "car horn" sound effects). Play at realistic loudness, chest height.
                • Choose an open spot, at least 10 m from walls (walls echo and confuse direction). Note the place and wind in Notes.
                • Hearing testers: wear earplugs or noise-cancelling headphones so you react to the app, not to your ears.
                """)
            topic("3. Controlled test, step by step", """
                1. New session › Controlled test, fill in the conditions, Start.
                2. Make a shuffled plan, e.g. Siren + Car horn, 3× from every side, plus 6 harmless sounds = 30 trials.
                3. The tester stands (or walks/jogs on the spot) facing one direction: that is "ahead". Carry the phone as chosen.
                4. The screen shows the next trial, e.g. "Siren · from BEHIND · 10 m". The helper goes there.
                5. Tap "Sound starts NOW" the moment the helper starts the sound (agree a hand signal). For "phone locked" trials: start the countdown, lock the phone, and the helper starts when it ends.
                6. Let the sound play ~3 s. The result appears within 8 s. If you noticed the alert, tap "I noticed it" right away (reaction time). Answer "Felt the vibration?".
                7. Wait for "All clear" on the main screen (~10 s), then the next trial.
                8. End session. Repeat on another day or with another carry position as a new session.
                """)
            topic("4. Real run, step by step", """
                1. New session › Real run, conditions, Start. Optionally turn on "Also record audio" to check alerts later.
                2. Lock the phone and run or ride as usual.
                3. When a real siren, horn or vehicle happens, whoever can hear it marks it (or add it afterwards with the time).
                4. After the run: End run, open the session, mark every alert Real / False alarm, and add any missed events.
                """)
            topic("5. Getting numbers you can trust", """
                • 30+ trials per sound type per condition. The likely range shrinks as you add more.
                • Change one thing per session (carry position, place, model) so you know what made the difference.
                • Don't tune settings on the same sessions you report. Keep a few sessions aside for the final numbers.
                • Export after each day (Export below) and keep the files.
                • Report each number with its conditions: "Sirens caught 28/30 (78–98%), busy street, armband, running, locked".
                """)
        } header: {
            Text("How to evaluate")
        }
    }

    private func topic(_ title: String, _ text: String) -> some View {
        DisclosureGroup(title) { Text(text).font(.callout).fixedSize(horizontal: false, vertical: true) }
    }
}
