import SwiftUI

/// "34° ahead-left"
private func angleText(_ az: Double) -> String { "\(Int(az.rounded()))° \(sectorNames[slot(az, of: 8)])" }

private func alertText(_ a: Alert?) -> String {
    a.map { "\($0.level == .critical ? "Watch out" : "Heads up"): \($0.what) " + ($0.azimuth.map(angleText) ?? "(direction unclear)") } ?? "No warning"
}

/// A small radar, ahead up and left left: spokes (degrees, 0…1), an arrow for the direction, a wedge for the warning.
struct MiniRadar: View {
    var spokes: [(deg: Double, strength: Double, color: Color)]
    var arrow: Double?
    var alert: Alert?

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) / 2 - 2
            func point(_ deg: Double, _ radius: Double) -> CGPoint {
                CGPoint(x: c.x - sin(deg * .pi / 180) * radius, y: c.y - cos(deg * .pi / 180) * radius)
            }
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.secondary.opacity(0.35)))
            if let alert, let az = alert.azimuth {
                var wedge = Path()
                wedge.move(to: c)
                wedge.addLines(stride(from: -25.0, through: 25, by: 5).map { point(az + $0, r) })
                wedge.closeSubpath()
                ctx.fill(wedge, with: .color(alert.level.color.opacity(0.3)))
            }
            for s in spokes where s.strength > 0.01 {
                var p = Path()
                p.move(to: point(s.deg, r * 0.2))
                p.addLine(to: point(s.deg, r * (0.2 + 0.8 * s.strength)))
                ctx.stroke(p, with: .color(s.color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            if let arrow {
                var p = Path()
                p.move(to: c)
                p.addLine(to: point(arrow, r))
                ctx.stroke(p, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(origin: point(arrow, r), size: .zero).insetBy(dx: -4, dy: -4)), with: .color(.accentColor))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .top) { Text("Ahead").font(.caption2).foregroundStyle(.secondary) }
        .accessibilityHidden(true)
    }
}

/// Sound Radar's method and the Audio Lab prototype's on the same audio, live and side by side.
struct CompareView: View {
    let radar: SoundRadar
    @State private var gaps: [(t: Double, gap: Double?)] = []  // last 10 s: degrees between the two directions; nil = not both

    var body: some View {
        List {
            if let d = radar.debug, radar.listeningStarted, !radar.paused {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        soundRadarColumn(d)
                        Divider()
                        audioLabColumn(d.lab)
                    }
                } footer: {
                    Text("Blue arrow: the direction each method gives now. Warnings (vibration, Dynamic Island) follow \(radar.method.rawValue), the sound tab you opened last.")
                }
                agreementSection(d)
                Section("Recent warnings") {
                    warnings("Sound Radar", d.events.filter { $0.contains("WARNING:") || $0.contains("CRITICAL:") })
                    warnings("Audio Lab", d.lab.alerts)
                }
            } else {
                Section {
                    Text(radar.listeningStarted ? "Paused" : "Not listening").font(.headline)
                    if let problem = radar.problem { Text(problem).foregroundStyle(.secondary) }
                    Button("Start listening", systemImage: "play.fill") {
                        Task { radar.listeningStarted ? radar.setPaused(false) : await radar.start() }
                    }
                }
            }
            Section("How they differ") {
                Text("""
                    Sound Radar: a direction for every frequency from 300 Hz to 4 kHz (wind and engine rumble below 200 Hz cut \
                    out), averaged over ~0.3 s with arm swing removed. Sounds are named by 5 listeners (all-around + 4 beams) with \
                    confirmation rules, and each warning gets that sound's own direction. Also warns when something gets closer.
                    """)
                Text("""
                    Audio Lab (prototype): one direction per 0.1 s from all frequencies together, only when it's louder than \
                    −60 dBFS and coherent (≥ 0.3), otherwise none. Apple's classifier on the all-around mic (same 0.5 s windows), \
                    raw top labels not tied to a direction; warns on any alert sound ≥ 30%, pointed at the main direction of that \
                    moment. Both use the same mic axis fix and fine-tune.
                    """)
            }
            .font(.caption)
        }
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: radar.debug?.processed.block.start) { track() }
    }

    private func soundRadarColumn(_ d: DebugSnapshot) -> some View {
        let p = d.processed
        return VStack(alignment: .leading, spacing: 4) {
            Text("Sound Radar").font(.headline)
            MiniRadar(spokes: d.bins.enumerated().map { (Double($0.offset) * 5, $0.element.strength, $0.element.kind.color) },
                      arrow: p.strength > 0.02 ? p.azimuth : nil, alert: d.alert)
            Text(p.strength > 0.02 ? p.azimuth.map(angleText) ?? "–" : "no clear sound").font(.subheadline.bold())
            Text(String(format: "directness %.2f · %@ over hum", p.block.reading.directness,
                        p.hum.map { String(format: "%+.0f dB", p.levelDB - $0) } ?? "–"))
            Text("Hears: " + (d.lastJudged.flatMap { $0.label.isEmpty ? nil : "\(pretty($0.label)) \(Int($0.score * 100))%" }
                              ?? (d.kind == .other ? "nothing to warn about" : "\(d.kind)")))
            Text(alertText(d.alert)).foregroundStyle(d.alert?.level.color ?? .secondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func audioLabColumn(_ lab: AudioLab) -> some View {
        let w = lab.latest, top = w?.beams.max() ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("Audio Lab").font(.headline)
            MiniRadar(spokes: (w?.beams ?? []).enumerated().map {
                (Double($0.offset) * 30, min(max(1 + ($0.element - top) / AudioLab.beamRangeDB, 0), 1), lab.kind.color)
            }, arrow: w?.azimuth, alert: lab.alert)
            Text(w?.azimuth.map(angleText) ?? "none: \(w?.rejection ?? "waiting")").font(.subheadline.bold())
            Text(w.map { String(format: "coherence %.2f · %.0f dBFS", $0.coherence, $0.db) } ?? "–")
            Text("Hears: " + (lab.top.isEmpty ? "–" : lab.top.prefix(3).map { "\(pretty($0.id)) \(Int($0.confidence * 100))%" }.joined(separator: ", ")))
            Text(alertText(lab.alert)).foregroundStyle(lab.alert?.level.color ?? .secondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func agreementSection(_ d: DebugSnapshot) -> some View {
        let both = gaps.compactMap(\.gap).sorted(), now = gaps.last
        let shares = both.isEmpty ? nil : String(format: "within 30° %.0f%% of that time · typical gap %.0f°",
                                                  100 * Double(both.filter { $0 <= 30 }.count) / Double(both.count), both[both.count / 2])
        return Section("Agreement") {
            LabeledContent("Now", value: now?.gap.map { "\(Int($0.rounded()))° apart" } ?? "not both giving a direction")
            LabeledContent("Last 10 s", value: gaps.isEmpty ? "–" : String(format: "both gave a direction %.0f%% of the time",
                                                                            100 * Double(both.count) / Double(gaps.count)))
            if let shares { Text(shares).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func warnings(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.bold())
            if lines.isEmpty { Text("None yet").foregroundStyle(.secondary) }
            ForEach(Array(lines.prefix(5).enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
        }
    }

    /// One sample per debug refresh (10×/s) of how far apart the two directions are.
    private func track() {
        guard let d = radar.debug else { return }
        let ours = d.processed.strength > 0.02 ? d.processed.azimuth : nil
        let gap = zip2(ours, d.lab.latest?.azimuth).map { angularDistance($0, $1) }
        gaps.append((d.processed.block.start, gap))
        gaps.removeAll { $0.t < d.processed.block.start - 10 }
    }
}
