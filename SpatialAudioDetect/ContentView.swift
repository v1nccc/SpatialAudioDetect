import SwiftUI
import UIKit
import Playgrounds

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

struct ContentView: View {
    @State private var radar = SoundRadar()
    @State private var calibrating = false
    // Calibration: which way the mic's "front" points depends on how the phone is held.
    @AppStorage("rotate") private var offset = 0.0
    @AppStorage("mirror") private var mirror = false

    /// Mic azimuth (0 = front, +90 = left) → on-screen angle (0 = up/ahead, +90 = left).
    private func screenAngle(_ azimuth: Double) -> Double { (mirror ? -azimuth : azimuth) + offset }

    private func whereIs(_ azimuth: Double?) -> String {
        guard let azimuth else { return "around you" }
        let names = ["ahead", "ahead on your left", "on your left", "behind on your left",
                     "behind you", "behind on your right", "on your right", "ahead on your right"]
        return names[slot(screenAngle(azimuth), of: names.count)]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                statusCard
                radarCard
                Spacer(minLength: 0)
            }
            .padding()
            .background { (radar.alert == nil ? Color(.systemGroupedBackground) : .red).ignoresSafeArea() }
            .navigationTitle("Sound Radar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Calibrate", systemImage: "slider.horizontal.3") { calibrating = true }
            }
            .sheet(isPresented: $calibrating) { calibration }
        }
        .sensoryFeedback(.warning, trigger: radar.alertPulse)
        .animation(.easeOut(duration: 0.2), value: radar.alert)
        .task {
            UIApplication.shared.isIdleTimerDisabled = true  // keep the screen on while running
            await radar.start()
        }
    }

    // MARK: Status: one glance tells you what's happening

    private var statusCard: some View {
        let (icon, tint, title, detail): (String, Color, String, String) =
            if let problem = radar.problem {
                ("mic.slash.fill", .secondary, "Not listening", problem)
            } else if let a = radar.alert {
                (a.azimuth == nil ? "exclamationmark.triangle.fill" : "arrow.up.circle.fill", .red, "Watch out!", "\(a.what) \(whereIs(a.azimuth))")
            } else {
                switch radar.kind {
                case .traffic: ("car.fill", .orange, "Traffic nearby", "Normal traffic, mostly \(whereIs(radar.loudestAzimuth(of: .traffic)))")
                case .people: ("person.2.fill", .blue, "People talking", "Mostly \(whereIs(radar.loudestAzimuth(of: .people)))")
                default: ("checkmark.circle.fill", .green, "All clear", "Nothing to watch out for")
                }
            }
        return HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(-(radar.alert?.azimuth.map(screenAngle) ?? 0)))  // arrow points at the danger
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.bold()).foregroundStyle(radar.alert == nil ? .primary : tint)
                Text(detail).font(.title3)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }

    // MARK: Radar: you in the middle, ahead is up

    private var radarCard: some View {
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
                    if let az = radar.alert?.azimuth {
                        let a = screenAngle(az), arc = Array(stride(from: -25.0, through: 25, by: 5))
                        var wedge = Path()
                        wedge.addLines(arc.map { point(a + $0, r1) } + arc.reversed().map { point(a + $0, r0) })
                        wedge.closeSubpath()
                        ctx.fill(wedge, with: .color(.red.opacity(0.3)))
                    }
                    for (i, bin) in radar.bins.enumerated() where bin.strength > 0.01 {
                        let a = screenAngle(Double(i) / Double(radar.bins.count) * 360)
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

    // MARK: Calibration sheet

    private var calibration: some View {
        NavigationStack {
            Form {
                Section {
                    let loudest = radar.mics.max() ?? 0
                    Grid(alignment: .leading, verticalSpacing: 12) {
                        ForEach(phoneSides.indices, id: \.self) { i in
                            GridRow {
                                Label(phoneSides[i].name, systemImage: phoneSides[i].icon)
                                // relative to the loudest side, 24 dB range, so the winner is obvious at a glance
                                ProgressView(value: radar.last == nil ? 0 : min(max(1 + (radar.mics[i] - loudest) / 24, 0), 1))
                                    .tint(radar.mics[i] == loudest ? Color.accentColor : .secondary)
                            }
                        }
                    }
                } header: {
                    Text("Which side of the phone hears it")
                } footer: {
                    Text("Live. Snap your fingers close to each side of the phone: that side's bar should win. If a different bar wins, the phone's axes are mapped differently than assumed.")
                }
                Section {
                    LabeledContent("Rotate", value: "\(Int(offset))°")
                    Slider(value: $offset, in: -180...180, step: 5)
                    Toggle("Mirror left/right", isOn: $mirror)
                } header: {
                    Text("Fine-tune")
                } footer: {
                    Text("Directions follow the phone's motion sensors, so upright, tilted or flat all work. Only adjust these if a clap in front of you still doesn't point to Ahead.")
                }
                Section {
                    LabeledContent("Heard", value: radar.label.isEmpty ? "–" : radar.label)
                    LabeledContent("Horn / siren score") {
                        Text(radar.alertScore, format: .number.precision(.fractionLength(2)))
                            .foregroundStyle(radar.alertScore >= alertThreshold ? .red : .secondary)
                            .monospacedDigit()
                    }
                    if let r = radar.last {
                        LabeledContent("Direction", value: radar.azimuth.map { "\(Int(screenAngle($0).rounded()))°" } ?? "–")
                        LabeledContent("Level", value: "\(Int(r.db.rounded())) dBFS")
                        LabeledContent("Directness", value: r.directness.formatted(.number.precision(.fractionLength(2))))
                    }
                } header: {
                    Text("Live readout")
                } footer: {
                    Text("Horns, sirens, bike bells and shouts trigger Watch out at a score of \(alertThreshold, format: .number.precision(.fractionLength(2))) or higher.")
                }
            }
            .navigationTitle("Calibrate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { calibrating = false } }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    ContentView()
}

#Playground {
    selfCheck()
}
