import SwiftUI

/// Every stage of the pipeline, live and in processing order (① mics → ⑨ decision),
/// so a wrong call on the street can be traced to the step that caused it.
struct DebugView: View {
    let radar: SoundRadar
    @Binding var offset: Double
    @Binding var mirror: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var distanceRef: Double?  // level of the test sound at the reference distance
    @State private var refMeters = 1.0
    @State private var tested: [Double: (mean: Double, spread: Double)] = [:]  // true direction -> arrow, fine-tune off
    @State private var measuring: Double?

    var body: some View {
        NavigationStack {
            Form {
                recordSection
                soundModelSection
                if let d = radar.debug {
                    inputSection(d)
                    channelSection(d)
                    sideSection(d)
                    poseSection(d)
                    directionSection(d)
                    classifierSection(d)
                    approachSection(d)
                    distanceSection(d)
                    decisionSection(d)
                } else {
                    Section { Text("Waiting for audio…").foregroundStyle(.secondary) }
                }
                directionTestSection
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

    private var soundModelSection: some View {
        Section {
            Picker("Sound model", selection: Binding(get: { radar.engine }, set: { radar.engine = $0 })) {
                ForEach(SoundEngine.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Sound model")
        } footer: {
            Text("Apple direct: Apple's built-in sound classifier, exact timing and every score. SoundML: the same Apple model through the SoundML package; it only reports sounds over their threshold and its timing is estimated. Switch any time, even while listening; the decisions log notes each switch, so recordings say which was used.")
        }
    }

    // MARK: ① – ⑤ Signal

    private func inputSection(_ d: DebugSnapshot) -> some View {
        Section("① Microphone input") {
            Text(d.processed.block.format).font(.callout.monospaced())
            value("Block", "\(f(d.processed.block.duration * 1000, 1)) ms · \(Int((1 / d.processed.block.duration).rounded())) per second")
            value("Stream time", "\(f(d.processed.block.start, 1)) s")
            value("Processing", radar.health.isEmpty ? "–" : radar.health)
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
            if let raw = p.rawAzimuth, let block = p.blockAzimuth, let az = p.azimuth {
                value("Direction from pose", "\(Int(raw.rounded()))° (this block)")
                value("+ fine-tune + arm swing", "\(Int(block.rounded()))° (this block)")
                value("Arrow, \(f(Detector.arrowSeconds, 1)) s average", "\(Int(az.rounded()))° · \(pretty(sectorNames[slot(az, of: sectorNames.count)]))")
            }
            value("Radar line", "\(f((p.loudness * 24), 0)) dB over hum → \(f(p.loudness)) × \(f(r.directness)) = \(f(p.strength))")
        } header: {
            Text("⑤ Direction and radar line")
        } footer: {
            Text("One block (21 ms) jitters with street noise, so the arrow averages the last \(f(Detector.arrowSeconds, 1)) s, louder and more direct blocks counting more. Hum = the quietest fifth of the last 30 s; usual = its median. A radar line shows how far a sound stands out above the hum (24 dB = full length) × how directional it is, so a steady roar draws nothing.")
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
            if let j = d.lastJudged, !j.label.isEmpty {
                value("Alert decided", "\(alertName(j.label).what) · \(f(j.score))")
                if !j.beamScores.isEmpty {
                    value("Through each beam", zip(beamNames, j.beamScores).map { "\($0) \(f($1))" }.joined(separator: " · "))
                }
                value("Directions heard", j.sources.isEmpty ? "–" : j.sources.map { "\(Int($0.rounded()))°" }.joined(separator: ", "))
                value("Beams point", j.beamPointing.map { "\(Int($0.rounded()))°" } ?? "no clear evidence")
                value("Direction used", j.azimuth.map { "\(Int($0.rounded()))° · \(directionWords($0))" } ?? "unclear")
            }
        } header: {
            Text("⑥ Sound classifier (all-around + 4 beams, 0.5 s windows)")
        } footer: {
            Text("\(radar.engine == .apple ? "Apple's raw top guesses" : "Sounds over their threshold (SoundML)") (all-around mic); several can be high at once. Bar colour = the app's category (red alert, orange traffic, blue people, grey ignored). Alerts need confirming: sirens and other lasting sounds ≥ 0.5 in 2 of the last 3 windows, horns ≥ \(f(alertThreshold)) once, others ≥ 0.7 once or ≥ 0.5 twice in a row (best of the 5 listeners). Critical sounds win over louder warnings. Direction: each frequency's own direction gives the separate sounds heard; the beam that hears the alert best tells which of them it is (or, without beam evidence, the one nearest the loudest direction). While the sound lasts, the alert then follows it live.")
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
            Text("⑨ Decisions log, newest first")
        }
    }

    /// Experiment: can the phone tell how far away a sound is?
    private func distanceSection(_ d: DebugSnapshot) -> some View {
        let level = d.processed.levelDB
        return Section {
            value("Level (1 s average)", "\(f(level, 1)) dBFS")
            if let ref = distanceRef {
                value("Distance from loudness", "≈ \(f(metersFromLevel(level, reference: ref, at: refMeters), 1)) m")
            }
            Stepper("Reference: \(Int(refMeters)) m", value: $refMeters, in: 1...20)
            Button(distanceRef == nil ? "The sound is \(Int(refMeters)) m away now" : "Reset: it's \(Int(refMeters)) m away now") {
                distanceRef = level
            }
            value("Directness", f(d.processed.block.reading.directness))
            if let e = reachEstimate(d.sectors) {
                value("Reaches you in", "≈ \(f(e.seconds, 1)) s · \(pretty(sectorNames[e.sector])) · +\(f(d.sectors[e.sector].recentRise, 1)) dB/s")
            } else {
                value("Reaches you in", "nothing getting louder")
            }
        } header: {
            Text("⑧ Distance (experiment)")
        } footer: {
            Text("""
                Distance from loudness: play a steady sound from a speaker, stand at the reference distance, tap the button, then walk away. \
                It assumes 6 dB quieter per doubling of distance, so it only holds for the same sound at the same volume. \
                If it doesn't grow when you walk away, iOS is auto-adjusting the mic level.
                Reaches you in: from how fast an approaching sound gets louder; needs no reference. It assumes the sound is \
                coming straight at you at a steady speed and reads high for things passing beside you.
                Directness: nearer sounds usually read more direct (less echo), but street noise lowers it too.
                """)
        }
    }

    /// Play a sound from a known direction, measure where the arrow points: accuracy, scatter, and the fine-tune that fixes it.
    private var directionTestSection: some View {
        let names: [Double: String] = [0: "Ahead", 90: "Left", 180: "Behind", -90: "Right"]
        return Section {
            HStack {
                ForEach([0.0, 90, 180, -90], id: \.self) { truth in
                    Button(names[truth]!) { Task { await measure(truth) } }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(measuring != nil || radar.debug == nil)
            if let m = measuring { ProgressView("Measuring \(names[m]!.lowercased()) for 3 s…") }
            ForEach(tested.keys.sorted(), id: \.self) { truth in
                let t = tested[truth]!, shown = remainder(calibrated(t.mean, offset: offset, mirror: mirror), 360)
                value(names[truth]!, "arrow \(Int(shown.rounded()))° · off \(Int(angularDistance(shown, truth).rounded()))° · wobble ±\(Int(t.spread.rounded()))°")
            }
            if let fit = fitFineTune(tested.map { ($0.key, $0.value.mean) }) {
                value("Best fine-tune", "rotate \(Int(fit.offset.rounded()))°\(fit.mirror ? " + mirror" : "") · then off ±\(Int(fit.leftover.rounded()))°")
                Button("Apply this fine-tune") { offset = fit.offset.rounded(); mirror = fit.mirror }
                Text(fit.leftover < 15
                     ? "One rotation explains the error: apply it and the directions should line up."
                     : "No single rotation fits: some directions are off in different ways. Usually front/back mix-ups, echoes from walls, or your body blocking the sound. Try outdoors away from walls, or hold the phone another way, and test again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !tested.isEmpty { Button("Clear results", role: .destructive) { tested = [:] } }
        } header: {
            Text("Direction test")
        } footer: {
            Text("Stand still, holding the phone the way you'll run with it. Play a steady sound (a traffic or siren video) from a speaker about 2 m away, then tap where it is. Do at least Ahead and Left; all four also shows front/back mix-ups. Outdoors is best: walls echo. Off = how wrong the arrow is; wobble = how much it moves while the sound stays put.")
        }
    }

    /// 3 s of the arrow with the fine-tune taken back out, louder and more direct moments counting more.
    private func measure(_ truth: Double) async {
        measuring = truth
        var samples: [(deg: Double, weight: Double)] = []
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let p = radar.debug?.processed, let az = p.azimuth else { continue }
            let x = az - p.correction - offset
            samples.append((mirror ? -x : x, p.block.reading.ww * p.block.reading.directness))
        }
        tested[truth] = circularMean(samples)
        measuring = nil
    }

    private var fineTuneSection: some View {
        Section {
            LabeledContent("Rotate", value: "\(Int(offset))°")
            Slider(value: $offset, in: -180...180, step: 5)
            Toggle("Mirror left/right", isOn: $mirror)
        } header: {
            Text("Fine-tune direction")
        } footer: {
            Text("Directions follow the motion sensors, so upright, tilted or flat all work. The direction test above sets these for you.")
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
