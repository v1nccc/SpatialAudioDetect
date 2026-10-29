import SwiftUI
import UIKit
import Playgrounds

extension AlertLevel {
    var color: Color { self == .critical ? .red : .orange }
}

extension SoundKind {
    var color: Color {
        switch self {
        case .alert: .red
        case .traffic: .orange
        case .people: .blue
        case .other: .gray
        }
    }
}

enum AppTab: String {
    case soundRadar
    case audioLab
    case compare
    case testing
    case camera
}

struct ContentView: View {
    @State private var radar = SoundRadar.shared
    @State private var selectedTab: AppTab = .soundRadar
    @State private var debugging = false
    @State private var tuningHaptics = false
    @State private var explaining = false
    @State private var evaluating = false
    // Fine-tune, in case the phone's axes differ from what the app assumes.
    @AppStorage("rotate") private var offset = 0.0
    @AppStorage("mirror") private var mirror = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                VStack(spacing: 16) {
                    statusCard
                    radarCard
                    controls
                    Spacer(minLength: 0)
                }
                .padding()
                .background { (radar.alert?.level.color ?? Color(.systemGroupedBackground)).ignoresSafeArea() }
                .navigationTitle("Sound Radar")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("How it's measured", systemImage: "function") { explaining = true }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Evaluate", systemImage: "checklist") { evaluating = true }
                        Button("Alerts", systemImage: "bell.badge") { tuningHaptics = true }
                        Button("Debug", systemImage: "ladybug") { debugging = true }
                    }
                }
                .sheet(isPresented: $debugging) { DebugView(radar: radar, offset: $offset, mirror: $mirror) }
                .sheet(isPresented: $tuningHaptics) { HapticsView(radar: radar) }
                .sheet(isPresented: $explaining) { PipelineView(radar: radar) }
                .sheet(isPresented: $evaluating) { EvaluationView(radar: radar) }
            }
            .tabItem {
                Label("Sound Radar", systemImage: "dot.radiowaves.left.and.right")
            }
            .tag(AppTab.soundRadar)

            // The same screen, driven by the Audio Lab prototype's method (radar.method follows the tab).
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        statusCard
                        radarCard
                        labCard
                        controls
                    }
                    .padding()
                }
                .background { (radar.alert?.level.color ?? Color(.systemGroupedBackground)).ignoresSafeArea() }
                .navigationTitle("Audio Lab")
                .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("Audio Lab", systemImage: "flask")
            }
            .tag(AppTab.audioLab)

            NavigationStack {
                CompareView(radar: radar)
            }
            .tabItem {
                Label("Compare", systemImage: "square.split.2x1")
            }
            .tag(AppTab.compare)

            NavigationStack {
                TestingView(radar: radar) {
                    statusCard
                    radarCard
                }
            }
            .tabItem {
                Label("Testing", systemImage: "record.circle")
            }
            .tag(AppTab.testing)

            NavigationStack {
                CameraView(radar: radar)
            }
            .tabItem {
                Label("Camera", systemImage: "camera.viewfinder")
            }
            .tag(AppTab.camera)
        }
        // The sound tab opened last decides which method warns; Compare, Testing and Camera keep it, and so does
        // switching tabs during a test or evaluation session (its results must come from one method).
        .onChange(of: selectedTab) {
            guard EvalStore.shared.active == nil else { return }
            if selectedTab == .soundRadar { radar.method = .soundRadar }
            if selectedTab == .audioLab { radar.method = .audioLab }
        }
        .onChange(of: offset, initial: true) { radar.setCalibration(offset: offset, mirror: mirror) }
        .onChange(of: mirror) { radar.setCalibration(offset: offset, mirror: mirror) }
        // Not on every direction change: the alert follows its sound many times a second.
        .animation(.easeOut(duration: 0.2), value: radar.alert?.what)
        .animation(.easeOut(duration: 0.2), value: radar.alert?.level)
        .task {
            UIApplication.shared.isIdleTimerDisabled = true  // keep the screen on while running
            radar.cleanUpIfIdle()
        }
    }

    // MARK: Status: one glance tells you what's happening

    private var statusCard: some View {
        let (icon, tint, title, detail): (String, Color, String, String) =
            if let problem = radar.problem {
                ("mic.slash.fill", .secondary, "Not listening", problem)
            } else if !radar.listeningStarted {
                ("ear", .secondary, "Not listening", "Tap Start. The Dynamic Island shows while it listens.")
            } else if radar.paused {
                ("pause.circle.fill", .secondary, "Paused", "Not listening. Resume below or from the Dynamic Island.")
            } else if let trouble = radar.micTrouble {
                ("mic.slash.fill", .orange, "Not hearing anything", trouble)
            } else {
                listeningStatus(alert: radar.alert, kind: radar.kind, recognitionDown: radar.recognitionDown,
                                traffic: radar.loudestAzimuth(of: .traffic), people: radar.loudestAzimuth(of: .people))
            }
        return StatusCard(icon: icon, tint: tint, title: title, detail: detail, alert: radar.alert)
    }

    /// Start a session; then Pause / Resume, or Stop (mic off, Dynamic Island gone).
    private var controls: some View {
        HStack(spacing: 12) {
            if radar.listeningStarted {
                Button { radar.setPaused(!radar.paused) } label: {
                    Label(radar.paused ? "Resume" : "Pause", systemImage: radar.paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .tint(radar.paused ? .green : .gray)
                Button { radar.stop() } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity, minHeight: 44)
                }
                .tint(.red)
            } else {
                Button { Task { await radar.start() } } label: {
                    Label("Start listening", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 44)
                }
                .tint(.green)
            }
        }
        .buttonStyle(.borderedProminent)
        .font(.title3.bold())
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))  // red Stop stays visible on a red alert
    }

    /// What the Audio Lab method hears, and why it gives a direction right now or not.
    private var labCard: some View {
        let lab = radar.detector.lab
        let direction = lab.latest.map { w in
            w.azimuth.map { String(format: "%.0f° · coherence %.2f", $0, w.coherence) } ?? "none: \(w.rejection ?? "")"
        } ?? "–"
        return VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Hears", value: lab.top.isEmpty ? "–"
                           : lab.top.prefix(3).map { "\(pretty($0.id)) \(Int($0.confidence * 100))%" }.joined(separator: ", "))
            LabeledContent("Direction", value: direction)
            Text("""
                The prototype's method: one direction per 0.1 s from all frequencies (only when louder than −60 dBFS and \
                coherent ≥ 0.3), Apple's classifier on the all-around mic, a warning for any alert sound ≥ 30%. Vibration and \
                the Dynamic Island use it from now until you open the Sound Radar tab. The Compare tab shows both at once.
                """)
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
    }

    // MARK: Radar: you in the middle, ahead is up

    private var radarCard: some View { RadarCard(bins: radar.bins, alert: radar.alert) }
}

/// The status card while listening (live, or replayed from a test): the warning, else what kind of sound is around.
func listeningStatus(alert: Alert?, kind: SoundKind, recognitionDown: Bool, traffic: Double?, people: Double?)
    -> (String, Color, String, String) {
    if recognitionDown && alert == nil {
        return ("waveform.slash", .yellow, "Can't recognize sounds", "Sirens and horns aren't being recognized right now. Directions still work; restarting…")
    }
    if let a = alert {
        return (a.azimuth == nil ? "exclamationmark.triangle.fill" : "arrow.up.circle.fill", a.level.color,
                a.level == .critical ? "Watch out!" : "Heads up", "\(a.what) \(directionWords(a.azimuth))")
    }
    switch kind {
    case .traffic: return ("car.fill", .orange, "Traffic nearby", "Normal traffic, mostly \(directionWords(traffic))")
    case .people: return ("person.2.fill", .blue, "People talking", "Mostly \(directionWords(people))")
    default: return ("checkmark.circle.fill", .green, "All clear", "Nothing to watch out for")
    }
}

/// One glance tells you what's happening: an arrow at the danger, a title and a line of detail.
struct StatusCard: View {
    let icon: String, tint: Color, title: String, detail: String
    let alert: Alert?

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(-(alert?.azimuth ?? 0)))  // arrow points at the danger
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.bold()).foregroundStyle(alert == nil ? .primary : tint)
                Text(detail).font(.title3)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}

/// You in the middle, ahead is up: a line per sound direction (coloured by kind), a wedge where the warning points.
struct RadarCard: View {
    let bins: [Bin]
    let alert: Alert?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Canvas { ctx, size in
                    let side = min(size.width, size.height)
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let r0 = side * 0.14, r1 = side * 0.39
                    func point(_ deg: Double, _ r: Double) -> CGPoint {
                        let a = deg * .pi / 180
                        return CGPoint(x: c.x - sin(a) * r, y: c.y - cos(a) * r)
                    }
                    for r in [r0, r1] {
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                                   with: .color(.secondary.opacity(0.35)), lineWidth: 1.5)
                    }
                    if let alert, let az = alert.azimuth {
                        let a = az, arc = Array(stride(from: -25.0, through: 25, by: 5))
                        var wedge = Path()
                        wedge.addLines(arc.map { point(a + $0, r1) } + arc.reversed().map { point(a + $0, r0) })
                        wedge.closeSubpath()
                        ctx.fill(wedge, with: .color(alert.level.color.opacity(0.3)))
                    }
                    for (i, bin) in bins.enumerated() where bin.strength > 0.01 {
                        let a = Double(i) / Double(bins.count) * 360
                        var p = Path()
                        p.move(to: point(a, r0 + 6))
                        p.addLine(to: point(a, r0 + 6 + (r1 - r0) * bin.strength))
                        ctx.stroke(p, with: .color(bin.kind.color), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    }
                }
                Image(systemName: "figure.run").font(.title).foregroundStyle(.secondary)
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                VStack { Text("Ahead"); Spacer(); Text("Behind") }
                HStack { Text("Left"); Spacer(); Text("Right") }
            }
            .font(.subheadline.bold())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

            HStack(spacing: 14) {
                ForEach([(SoundKind.alert, "Watch out"), (.traffic, "Traffic"), (.people, "People"), (.other, "Other")], id: \.1) { kind, name in
                    Label { Text(name) } icon: { Circle().fill(kind.color).frame(width: 10, height: 10) }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
    }
}

#Preview {
    ContentView()
}

#Playground {
    selfCheck()
    audioLabSelfCheck()
    screenFrameSelfCheck()
    warningLogSelfCheck()
    hapticsSelfCheck()
    radarActivitySelfCheck()
    vehicleTrackerSelfCheck()
    depthModelSelfCheck()
    groundPlaneSelfCheck()
    evaluationSelfCheck()
}
