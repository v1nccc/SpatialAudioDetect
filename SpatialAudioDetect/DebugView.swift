import SwiftUI

/// Every stage of the pipeline, live and in processing order (① mics → ⑧ decision),
/// so a wrong call on the street can be traced to the step that caused it.
struct DebugView: View {
    let radar: SoundRadar
    @Binding var offset: Double
    @Binding var mirror: Bool
    @Environment(\.dismiss) private var dismiss

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
                    classifierSection(d)
                    approachSection(d)
                    decisionSection(d)
                } else {
                    Section { Text("Waiting for audio…").foregroundStyle(.secondary) }
                }
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
                    let secs = radar.debug.map { Int($0.processed.block.start + $0.processed.block.duration - r.startedAt) } ?? 0
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
            Text(d.processed.block.format).font(.callout.monospaced())
            value("Block", "\(f(d.processed.block.duration * 1000, 1)) ms · \(Int((1 / d.processed.block.duration).rounded())) per second")
            value("Stream time", "\(f(d.processed.block.start, 1)) s")
        }
    }

    private func channelSection(_ d: DebugSnapshot) -> some View {
        let r = d.processed.block.reading
        let rows = [("W · all", r.ww), ("X · front–back", r.xx), ("Y · left–right", r.yy), ("Z · up–down", r.zz)]
        return Section {
            meters(rows.map { ($0.0, (db($0.1) + 90) / 90, "\(Int(db($0.1).rounded())) dB", .accentColor) })
        } header: {
            Text("② Ambisonic channels (after \(Int(BlockMaker.highPassHz)) Hz high-pass)")
        } footer: {
            Text("iOS mixes the iPhone's mics into these 4; apps never see the individual mics. Everything below \(Int(BlockMaker.highPassHz)) Hz (wind on the mics, engine rumble) is filtered out first. W is overall loudness. X, Y, Z only point somewhere when they rise and fall together with W, which is Directness in ⑤.")
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
        let g = d.processed.motion.gravity
        let pose = abs(g.z) > 0.8 ? "flat, screen \(g.z < 0 ? "up" : "down")"
            : g.y < -0.7 ? "upright" : g.y > 0.7 ? "upside down" : abs(g.x) > 0.7 ? "sideways" : "tilted"
        return Section {
            value("Holding", pose)
            value("Gravity x, y, z", "\(f(g.x)), \(f(g.y)), \(f(g.z))")
            value("Turning (gyro)", "\(Int((d.processed.motion.yawRate * 180 / .pi).rounded()))°/s")
            value("Arm-swing correction", "\(Int(d.processed.correction.rounded()))°")
        } header: {
            Text("④ Phone pose (motion sensors)")
        } footer: {
            Text(d.processed.azimuth == nil
                 ? "No usable \"ahead\" in this pose (camera and top edge point at sky or ground), so directions are paused."
                 : "\"Ahead\" = where the camera and top edge point, flattened onto the ground. The gyroscope then cancels arm swing: \"ahead\" follows your average heading over ~2 s, not every swing of the phone.")
        }
    }

    private func directionSection(_ d: DebugSnapshot) -> some View {
        let r = d.processed.block.reading
        return Section {
            let p = d.processed
            value("Level (W)", "\(f(r.db, 1)) dBFS")
            value("Street hum · usual", p.hum.map { "\(f($0, 1)) · \(f(p.usual ?? $0, 1)) dBFS" } ?? "learning…")
            value("Directness", f(r.directness))
            if let raw = p.rawAzimuth, let az = p.azimuth {
                value("Direction from pose", "\(Int(raw.rounded()))°")
                value("+ fine-tune + arm swing", "\(Int(az.rounded()))° · \(pretty(sectorNames[slot(az, of: sectorNames.count)]))")
            }
            value("Radar line", "\(f((p.loudness * 24), 0)) dB over hum → \(f(p.loudness)) × \(f(r.directness)) = \(f(p.strength))")
        } header: {
            Text("⑤ Direction and radar line")
        } footer: {
            Text("Hum = the quietest fifth of the last 30 s; usual = its median. A radar line shows how far a sound stands out above the hum (24 dB = full length) × how directional it is, so a steady roar draws nothing.")
        }
    }

    // MARK: ⑥ – ⑧ Decisions

    private func classifierSection(_ d: DebugSnapshot) -> some View {
        Section {
            if let h = d.heard {
                value("Verdict", h.label.isEmpty ? "\(h.kind)" : "\(h.kind) · \(pretty(h.label))")
                LabeledContent("Horn/siren score") {
                    Text("\(f(h.alertScore)) (fires ≥ \(f(alertThreshold)))")
                        .monospacedDigit()
                        .foregroundStyle(h.alertScore >= alertThreshold ? .red : .secondary)
                }
                value("Judged audio", "\(f(h.start)) – \(f(h.end)) s · answer \(Int(d.heardLatency * 1000)) ms later")
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
                        Text("vs usual")
                        Text("Rise")
                        Text("Sweep")
                        Text("")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    ForEach(d.sectors.indices, id: \.self) { i in
                        let s = d.sectors[i], over = d.processed.usual.map { s.db - $0 }
                        let status = statusIcon(approaching: s.approaching, heldBack: d.heldBack[i])
                        GridRow {
                            Text(pretty(sectorNames[i]))
                            Text(over.map { String(format: "%+.0f", $0) } ?? "–")
                                .foregroundStyle((over ?? 0) >= Detector.standOutDB ? .orange : .primary)
                            Text(f(s.rise, 1)).foregroundStyle(s.rise >= rule.riseDB ? .orange : .primary)
                            Text("\(Int(s.sweep.rounded()))°").foregroundStyle(s.sweep > Detector.maxSweep ? .orange : .primary)
                            Image(systemName: status.0).foregroundStyle(status.1)
                        }
                    }
                }
                .monospacedDigit()
            }
        } header: {
            Text("⑦ Getting-closer detector (a beam per 45° sector)")
        } footer: {
            Text("Getting closer = rose ≥ \(f(rule.riseDB, 0)) dB in \(f(rule.window, 0)) s without one big jump, and \(f(rule.leadDB, 0)) dB above the other directions. It only warns ⚠️ if it is also out of view (left, behind or right; 👁 otherwise), ≥ \(f(Detector.standOutDB, 0)) dB over this street's usual level (🔈 otherwise), stood out for 1 s (⏳), and its bearing moves ≤ \(f(Detector.maxSweep, 0))°/s; faster = passing by (↔). Not while the classifier says people or an alert sound.")
        }
    }

    private func decisionSection(_ d: DebugSnapshot) -> some View {
        Section {
            value("Now showing", d.alert.map { "Watch out · \($0.what)" } ?? "\(d.kind)")
            ForEach(Array(d.events.enumerated()), id: \.offset) { _, line in
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

    /// ⑦'s last column: not approaching, warned, or why it was held back.
    private func statusIcon(approaching: Bool, heldBack: String?) -> (String, Color) {
        guard approaching else { return ("minus", .secondary) }
        return switch heldBack {
        case nil: ("exclamationmark.triangle.fill", .red)
        case "view": ("eye", .secondary)
        case "usual": ("speaker.wave.1", .secondary)
        case "settling": ("hourglass", .secondary)
        case "passing": ("arrow.left.and.right", .secondary)
        default: ("waveform", .secondary)
        }
    }

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
