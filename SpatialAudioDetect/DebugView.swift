import SwiftUI

/// Every stage of the pipeline, live and in processing order (① mics → ⑧ decision),
/// so a wrong call on the street can be traced to the step that caused it.
struct DebugView: View {
    let radar: SoundRadar
    @Binding var offset: Double
    @Binding var mirror: Bool
    @Environment(\.dismiss) private var dismiss

    private let sectorNames = ["Ahead", "Ahead-left", "Left", "Behind-left", "Behind", "Behind-right", "Right", "Ahead-right"]

    var body: some View {
        NavigationStack {
            Form {
                recordSection
                if let d = radar.debug {
                    inputSection(d)
                    channelSection(d)
                    sideSection(d)
                    poseSection(d)
                    directionSection(d)
                } else {
                    Section { Text("Waiting for audio…").foregroundStyle(.secondary) }
                }
                classifierSection
                if let d = radar.debug { approachSection(d) }
                decisionSection
                fineTuneSection
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Record

    private var recordSection: some View {
        Section {
            Toggle(isOn: Binding(get: { radar.recorder != nil }, set: { _ in radar.toggleRecording() })) {
                if let r = radar.recorder {
                    let secs = radar.debug.map { Int($0.block.start + $0.block.duration - r.startedAt) } ?? 0
                    Label("Recording · \(secs) s", systemImage: "record.circle.fill").foregroundStyle(.red)
                } else {
                    Label("Record session", systemImage: "record.circle")
                }
            }
            if radar.recorder == nil, !radar.recordedFiles.isEmpty {
                ShareLink(items: radar.recordedFiles) {
                    Label("Share last recording (\(radar.recordedFiles.count) files)", systemImage: "square.and.arrow.up")
                }
            }
        } footer: {
            Text("Saves the raw 4-channel audio plus every number on this screen, block by block (up to ~46 MB per minute). Also in Files › On My iPhone › SpatialAudioDetect › Recordings.")
        }
    }

    // MARK: ① – ⑤ Signal

    private func inputSection(_ d: DebugSnapshot) -> some View {
        Section("① Microphone input") {
            Text(d.block.format).font(.callout.monospaced())
            value("Block", "\(f(d.block.duration * 1000, 1)) ms · \(Int((1 / d.block.duration).rounded())) per second")
            value("Stream time", "\(f(d.block.start, 1)) s")
        }
    }

    private func channelSection(_ d: DebugSnapshot) -> some View {
        let r = d.block.reading
        let rows = [("W · all", r.ww), ("X · front–back", r.xx), ("Y · left–right", r.yy), ("Z · up–down", r.zz)]
        return Section {
            meters(rows.map { ($0.0, (db($0.1) + 90) / 90, "\(Int(db($0.1).rounded())) dB", .accentColor) })
        } header: {
            Text("② Raw ambisonic channels")
        } footer: {
            Text("iOS mixes the iPhone's mics into these 4; apps never see the individual mics. W is overall loudness. X, Y, Z only point somewhere when they rise and fall together with W, which is Directness in ⑤.")
        }
    }

    private func sideSection(_ d: DebugSnapshot) -> some View {
        let loudest = d.mics.max() ?? 0
        return Section {
            meters(phoneSides.indices.map { i in
                (phoneSides[i].name, 1 + (d.mics[i] - loudest) / 24, "\(Int(d.mics[i].rounded())) dB",
                 d.mics[i] == loudest ? .accentColor : .secondary)
            })
        } header: {
            Text("③ Which side of the phone hears it")
        } footer: {
            Text("Virtual mics aimed at each side, built from ②. Bars are relative to the loudest side (24 dB range). Snap your fingers next to a side: its bar should win. If another wins, the axis mapping is off.")
        }
    }

    private func poseSection(_ d: DebugSnapshot) -> some View {
        let g = d.gravity
        let pose = abs(g.z) > 0.8 ? "flat, screen \(g.z < 0 ? "up" : "down")"
            : g.y < -0.7 ? "upright" : g.y > 0.7 ? "upside down" : abs(g.x) > 0.7 ? "sideways" : "tilted"
        return Section {
            value("Holding", pose)
            value("Gravity x, y, z", "\(f(g.x)), \(f(g.y)), \(f(g.z))")
        } header: {
            Text("④ Phone pose (motion sensors)")
        } footer: {
            Text(d.azimuth == nil
                 ? "No usable \"ahead\" in this pose (camera and top edge point at sky or ground), so directions are paused."
                 : "\"Ahead\" = where the camera and top edge point, flattened onto the ground. Recomputed every block.")
        }
    }

    private func directionSection(_ d: DebugSnapshot) -> some View {
        let r = d.block.reading
        return Section {
            value("Level (W)", "\(f(r.db, 1)) dBFS")
            value("Directness", f(r.directness))
            if let az = d.azimuth {
                value("Direction", "\(Int(az.rounded()))° · \(sectorNames[slot(az, of: sectorNames.count)])")
                value("After fine-tune", "\(Int(remainder(calibrated(az, offset: offset, mirror: mirror), 360).rounded()))°")
            }
            value("Radar line", "\(f(d.loudness)) loud × \(f(r.directness)) direct = \(f(d.strength))")
        } header: {
            Text("⑤ Direction and radar line")
        } footer: {
            Text("Loudness maps −70…−10 dBFS to 0…1. Directness: 0 = sound from everywhere (traffic hum, wind, echoes), 1 = one clear source. Busy traffic is loud; if it also reads high directness, that's why the radar fills up.")
        }
    }

    // MARK: ⑥ – ⑧ Decisions

    private var classifierSection: some View {
        Section {
            if let h = radar.heard {
                value("Verdict", h.label.isEmpty ? "\(h.kind)" : "\(h.kind) · \(pretty(h.label))")
                LabeledContent("Horn/siren score") {
                    Text("\(f(h.alertScore)) (fires ≥ \(f(alertThreshold)))")
                        .monospacedDigit()
                        .foregroundStyle(h.alertScore >= alertThreshold ? .red : .secondary)
                }
                value("Judged audio", "\(f(h.start)) – \(f(h.end)) s · answer \(Int(radar.heardLatency * 1000)) ms later")
                meters(h.top.map { t in
                    (pretty(t.id), t.confidence, f(t.confidence), soundKinds[t.id]?.color ?? .secondary)
                })
            } else {
                Text("No verdict yet").foregroundStyle(.secondary)
            }
        } header: {
            Text("⑥ Sound classifier (0.5 s windows, every 0.25 s)")
        } footer: {
            Text("Apple's raw top guesses; several can be high at once. Bar colour = the app's category (red alert, orange traffic, blue people, grey ignored). Alerts count at ≥ \(f(alertThreshold)), traffic and people at ≥ \(f(categoryThreshold)).")
        }
    }

    private func approachSection(_ d: DebugSnapshot) -> some View {
        let rule = ApproachDetector()
        return Section {
            if d.sectors.isEmpty {
                Text("Filling the \(f(rule.window, 0)) s window…").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("Sector").gridColumnAlignment(.leading)
                        Text("Now dB")
                        Text("Rise")
                        Text("Jump")
                        Text("")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    ForEach(d.sectors.indices, id: \.self) { i in
                        let s = d.sectors[i]
                        GridRow {
                            Text(sectorNames[i])
                            Text("\(Int(s.db.rounded()))").foregroundStyle(s.db > rule.minDB ? .primary : .secondary)
                            Text(f(s.rise, 1)).foregroundStyle(s.rise >= rule.riseDB ? .orange : .primary)
                            Text(f(s.biggestJump, 1))
                            Image(systemName: s.approaching ? "exclamationmark.triangle.fill" : "minus")
                                .foregroundStyle(s.approaching ? .red : .secondary)
                        }
                    }
                }
                .monospacedDigit()
            }
        } header: {
            Text("⑦ Getting-closer detector (45° sectors)")
        } footer: {
            Text("Fires when a sector ends above \(Int(rule.minDB)) dB, rose ≥ \(f(rule.riseDB, 0)) dB over \(f(rule.window, 0)) s, and no single 0.25 s jump was more than half the rise. Skipped while the classifier says people or an alert sound.")
        }
    }

    private var decisionSection: some View {
        Section {
            value("Now showing", radar.alert.map { "Watch out · \($0.what)" } ?? "\(radar.kind)")
            ForEach(Array(radar.events.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced())
            }
        } header: {
            Text("⑧ Decisions log, newest first")
        }
    }

    private var fineTuneSection: some View {
        Section {
            LabeledContent("Rotate", value: "\(Int(offset))°")
            Slider(value: $offset, in: -180...180, step: 5)
            Toggle("Mirror left/right", isOn: $mirror)
        } header: {
            Text("Fine-tune direction")
        } footer: {
            Text("Directions follow the motion sensors, so upright, tilted or flat all work. Only adjust if a clap in front of you still doesn't point to Ahead.")
        }
    }

    // MARK: Helpers

    private func value(_ title: String, _ text: String) -> some View {
        LabeledContent(title) { Text(text).monospacedDigit() }
    }

    /// Aligned rows of name · bar (0…1) · number.
    private func meters(_ rows: [(name: String, fill: Double, text: String, tint: Color)]) -> some View {
        Grid(alignment: .leading, verticalSpacing: 10) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    Text(rows[i].name)
                    ProgressView(value: min(max(rows[i].fill, 0), 1)).tint(rows[i].tint)
                    Text(rows[i].text).monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                }
            }
        }
    }

    private func db(_ power: Double) -> Double { 10 * log10(max(power, 1e-12)) }
    private func f(_ v: Double, _ digits: Int = 2) -> String { v.formatted(.number.precision(.fractionLength(digits))) }
}
