import AVFAudio
import CoreHaptics
import SwiftUI

/// Edit the warning patterns, pick how they're delivered, and run the background / on-the-move test.
struct HapticsView: View {
    let radar: SoundRadar
    @State private var settings = HapticSettings.load()
    @State private var preview = ""
    @State private var check = HapticCheck()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                HapticCheckSection(radar: radar, settings: settings, check: check)
                patternSection("Horn, siren, bell, shout", $settings.horn)
                patternSection("Something getting closer", $settings.approach)
                Section {
                    Picker("Warnings use", selection: $settings.method) {
                        ForEach(HapticMethod.allCases) { Text($0.name).tag($0) }
                    }
                    Toggle("Also notify when the app isn't on screen", isOn: $settings.notifyWhenAway)
                    LabeledContent("Haptic engine", value: radar.haptics.engineStatus)
                    if !preview.isEmpty { LabeledContent("Last preview", value: preview) }
                } header: {
                    Text("Delivery")
                } footer: {
                    Text("Your own rhythms need Core Haptics, which iOS may stop when the app isn't on screen. The test below finds out what still works on this iPhone. A notification uses the phone's own vibration, not your rhythm.")
                }
                HapticTestSection(test: radar.hapticTest, haptics: radar.haptics, settings: settings, mic: { radar.micStatus })
            }
            .onDisappear { check.abandon(radar) }  // never leave the mic off after an unfinished check
            .navigationTitle("Haptics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onChange(of: settings) { settings.save() }
        }
    }

    private func patternSection(_ title: String, _ pattern: Binding<HapticPattern>) -> some View {
        Section {
            HStack {
                TextField("Rhythm", text: pattern.rhythm)
                    .font(.title3.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Menu {
                    ForEach(HapticPattern.presets, id: \.name) { preset in
                        Button("\(preset.name)   \(preset.rhythm)") { pattern.wrappedValue.rhythm = preset.rhythm }
                    }
                } label: {
                    Image(systemName: "list.bullet").font(.title3)
                }
                Button {
                    let p = pattern.wrappedValue
                    Task { preview = await radar.haptics.play(p, title: "Preview", body: title, via: settings.method).detail }
                } label: {
                    Image(systemName: "play.circle.fill").font(.title)
                }
                .accessibilityLabel("Play")
            }
            .buttonStyle(.borderless)
            LabeledContent("Strength") { Slider(value: pattern.intensity, in: 0.2...1) }
            LabeledContent("Feel") {
                Slider(value: pattern.sharpness, in: 0...1) { Text("Feel") } minimumValueLabel: { Text("soft") } maximumValueLabel: { Text("crisp") }
            }
        } header: {
            Text(title)
        } footer: {
            Text(".  short tap      -  long buzz      space  pause")
        }
    }
}

/// Set up, run and read the timed test.
struct HapticTestSection: View {
    @Bindable var test: HapticTest
    let haptics: Haptics
    let settings: HapticSettings
    let mic: () -> String

    var body: some View {
        Section {
            if test.running { runningRows } else { setupRows }
        } header: {
            Text("Test: locked, in the background, on the move")
        } footer: {
            Text("Start, then lock the phone with the side button (or switch to another app) and carry it as chosen. Every \(Int(test.interval)) s it tries the next method, alternating your two patterns. Phone in hand? Tap “I felt it”. Afterwards, count what you felt for each method.")
        }
        if !test.attempts.isEmpty { resultRows }
    }

    @ViewBuilder private var setupRows: some View {
        Picker("Carried in", selection: $test.placement) { ForEach(HapticTest.placements, id: \.self) { Text($0) } }
        Picker("Activity", selection: $test.activity) { ForEach(HapticTest.activities, id: \.self) { Text($0) } }
        ForEach(HapticMethod.allCases) { m in
            Toggle(m.name, isOn: Binding(get: { test.methods.contains(m) },
                                         set: { if $0 { test.methods.insert(m) } else { test.methods.remove(m) } }))
        }
        Stepper("Every \(Int(test.interval)) s", value: $test.interval, in: 5...60, step: 5)
        Stepper("\(test.rounds) rounds", value: $test.rounds, in: 4...40, step: 4)
        Button("Start test") { test.start(haptics, settings: settings, mic: mic) }
            .disabled(test.methods.isEmpty)
    }

    @ViewBuilder private var runningRows: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text("Round \(test.attempts.count + 1) of \(test.rounds) · next in \(Int(max(test.nextAt?.timeIntervalSinceNow ?? 0, 0))) s")
                .monospacedDigit()
        }
        Button { test.feltIt() } label: {
            Label("I felt it", systemImage: "hand.raised.fill")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, minHeight: 100)
        }
        .buttonStyle(.borderedProminent)
        Button("Stop test", role: .destructive) { test.stop() }
    }

    private var resultRows: some View {
        Section {
            ForEach(test.attempts.reversed()) { a in
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(a.round) \(a.method.name) · \(a.category)\(a.feltTaps > 0 ? " · felt ✓" : "")").font(.subheadline.bold())
                    Text("\(a.appState) · mic \(a.mic) → \(a.result)")
                        .font(.caption)
                        .foregroundStyle(a.ok ? Color.secondary : .red)
                }
            }
            if !test.running {
                ForEach(HapticMethod.allCases.filter(test.methods.contains)) { m in
                    let tried = test.attempts.filter { $0.method == m }.count
                    Stepper("Felt \(m.name): \(test.felt[m] ?? 0) of \(tried)",
                            value: Binding(get: { test.felt[m] ?? 0 }, set: { test.felt[m] = $0 }), in: 0...max(tried, 1))
                }
                ShareLink(item: test.report) { Label("Share results", systemImage: "square.and.arrow.up") }
            }
        } header: {
            Text("Results")
        } footer: {
            Text("“played” only means iOS accepted the request; red means it refused. Whether you felt it is what counts.")
        }
    }
}

/// "Why can't I feel it?": what the phone reports right now, plus a step-by-step check that names the cause.
struct HapticCheckSection: View {
    let radar: SoundRadar
    let settings: HapticSettings
    let check: HapticCheck

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { _ in facts }
        } header: {
            Text("Can you feel it? What the phone says")
        } footer: {
            Text("The app can't read these, so check them too: Settings › Accessibility › Touch › Vibration (off = no vibration at all), Settings › Sounds & Haptics › System Haptics, and for the system buzz, Haptics in Silent Mode.")
        }
        Section {
            if !radar.listeningStarted {
                Text("Start listening first (main screen): the check compares vibration with the mic on and off.")
                    .foregroundStyle(.secondary)
            } else if check.steps.isEmpty || check.conclusion != nil {
                Button(check.steps.isEmpty ? "Start step-by-step check" : "Run the check again") { check.begin(radar, settings: settings) }
            }
            ForEach(check.steps) { step in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(step.id). \(step.name)").font(.subheadline.bold())
                        Spacer()
                        if let felt = step.felt {
                            Image(systemName: felt ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(felt ? .green : .red)
                        }
                    }
                    if !step.result.isEmpty {
                        Text(step.result).font(.caption).foregroundStyle(step.result.contains("MUTED") || step.result.contains("failed") ? .red : .secondary)
                    }
                    if check.current == step.id - 1 {
                        Text("Did you feel it?").font(.headline).padding(.top, 4)
                        HStack {
                            Button("Yes") { check.answer(true, radar, settings) }.buttonStyle(.borderedProminent).tint(.green)
                            Button("No") { check.answer(false, radar, settings) }.buttonStyle(.borderedProminent).tint(.red)
                            Spacer()
                            Button("Play again") { Task { await check.play(step.id - 1, radar, settings) } }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if let conclusion = check.conclusion {
                Text(conclusion).font(.callout.bold())
                ShareLink(item: check.report) { Label("Share check", systemImage: "square.and.arrow.up") }
            }
        } header: {
            Text("Step-by-step check")
        } footer: {
            Text("Plays one thing at a time, first with the mic recording and then with it paused, and asks after each. Hold the phone in your hand. The mic restarts at the end.")
        }
    }

    @ViewBuilder private var facts: some View {
        let session = AVAudioSession.sharedInstance()
        let recording = session.category == .playAndRecord || session.category == .record
        let hardware = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        VStack(spacing: 8) {
            fact("Vibration hardware", hardware ? "yes" : "none on this device", bad: !hardware)
            fact("Microphone", radar.micStatus, bad: radar.micTrouble != nil)
            fact("Haptics while recording", !recording ? "not recording" : session.allowHapticsAndSystemSoundsDuringRecording ? "allowed" : "muted by iOS",
                 bad: recording && !session.allowHapticsAndSystemSoundsDuringRecording)
            fact("Haptic engine", radar.haptics.engineStatus, bad: radar.haptics.engineStatus.contains("stopped"))
            fact("Low Power Mode", ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off", bad: false)
            fact("App", appState(), bad: false)
        }
    }

    private func fact(_ name: String, _ value: String, bad: Bool) -> some View {
        LabeledContent(name) {
            Text(value).foregroundStyle(bad ? .red : .secondary).multilineTextAlignment(.trailing)
        }
    }
}
