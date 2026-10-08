import simd
import SwiftUI

/// "How it's measured": every step from the microphones to the arrow and the alert, with this moment's numbers
/// put into each formula. Read-only; the Debug screen has the recording and tuning tools.
struct PipelineView: View {
    let radar: SoundRadar
    @AppStorage("rotate") private var offset = 0.0
    @AppStorage("mirror") private var mirror = false
    @AppStorage("listenNames") private var names = ""
    @AppStorage("listenWords") private var words = defaultDangerWords
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let d = radar.debug {
                    List {
                        Section {
                            Text("Live: each step below uses this moment's numbers. The arrow is worked out about 47 times a second; what the sound is, 4 times a second.")
                                .font(.callout)
                        }
                        whereSteps(d)
                        whatSteps(d)
                        closerStep(d)
                        wordsStep
                    }
                    .monospacedDigit()
                } else {
                    ContentUnavailableView("Start listening", systemImage: "waveform",
                                           description: Text("The steps appear here, with live numbers, once the microphone is running."))
                }
            }
            .navigationTitle("How it's measured")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    // MARK: Where is the sound? (the arrow)

    @ViewBuilder private func whereSteps(_ d: DebugSnapshot) -> some View {
        let p = d.processed, r = p.block.reading, ww = max(r.ww, 1e-12)
        let fx = r.wx / ww, fy = r.wy / ww, fz = r.wz / ww
        step("① Microphones → 4 channels",
             "The iPhone has several mics (bottom edge, earpiece, next to the back camera). iOS mixes them into 4 channels; apps never get the single mics. W hears all around, X front–back, Y left–right, Z up–down.") {
            meters([("W · all around", r.ww), ("X · front–back", r.xx), ("Y · left–right", r.yy), ("Z · up–down", r.zz)]
                .map { ($0.0, (db($0.1) + 90) / 90, "\(Int(db($0.1).rounded())) dB", Color.accentColor) })
            let loudest = d.mics.max() ?? 0
            Text("Which side of the phone hears most (virtual mics built from the 4 channels):").font(.caption).foregroundStyle(.secondary)
            meters(phoneSides.indices.map { i in
                (phoneSides[i].name, 1 + (d.mics[i] - loudest) / 24, "\(Int(d.mics[i].rounded())) dB", d.mics[i] == loudest ? .accentColor : .secondary)
            })
        }
        step("② Remove rumble", "Everything below \(Int(BlockMaker.highPassHz)) Hz (wind on the mics, engine rumble) is filtered out before measuring direction; it comes from everywhere and would drag the arrow around.") {
            row("Overall level now", "\(f(r.db, 1)) dBFS")
        }
        step("③ Correlate", "Multiply W by each direction channel, sample by sample, and average. A sound from the front makes X a copy of W (positive); from behind, an upside-down copy (negative). Diffuse noise averages out to about 0.") {
            row("W·X ÷ W² (front +, back −)", s(fx))
            row("W·Y ÷ W² (left +, right −)", s(fy))
            row("W·Z ÷ W² (up +, down −)", s(fz))
            let sq = { (v: Double) in f(v).hasPrefix("-") ? "(\(f(v)))²" : "\(f(v))²" }
            row("Directness = √(\(sq(fx)) + \(sq(fy)) + \(sq(fz)))", "= \(f(r.directness))")
            Text("Directness: 1 = one clear source, 0 = sound from everywhere.").font(.caption).foregroundStyle(.secondary)
        }
        poseStep(d, phone: r.phoneVector / ww)
        step("⑤ Arm swing and fine-tune", "The gyroscope tracks how the phone turns; its 2-second average is your running direction, so arm swing is subtracted. Then your fine-tune from the Debug screen.") {
            row("Turning (gyro)", "\(Int((p.motion.yawRate * 180 / .pi).rounded()))°/s")
            if let raw = p.rawAzimuth, let block = p.blockAzimuth {
                row("\(mirror ? "−" : "")\(deg(raw)) + fine-tune \(deg(offset)) + arm swing \(deg(p.correction))", "= \(deg(block))")
            } else {
                row("Direction", "paused (no “ahead” in this pose)")
            }
        }
        step("⑥ The arrow and the radar line", "One block (21 ms) jitters with street noise, so the arrow averages ⑤ over the last \(f(Detector.arrowSeconds, 1)) s, louder and more direct blocks counting more. 0° = ahead, +90° = left, ±180° = behind, −90° = right. A radar line shows how far the sound stands out above the street's hum (24 dB or more = full length, at or below the hum = none) times how directional it is.") {
            if let az = p.azimuth { row("Arrow (\(f(Detector.arrowSeconds, 1)) s average) \(deg(az))", directionWords(az)) }
            let hum = p.hum ?? r.db
            row("Stands out: (\(f(r.db, 0)) − hum \(f(hum, 0))) ÷ 24", "= \(f(p.loudness))")
            row("Line: \(f(p.loudness)) × directness \(f(r.directness))", "= \(f(p.strength))")
        }
        step("⑦ Each frequency's own direction (last ½ s)", "Every frequency from 300 Hz to 4 kHz gets its own direction and votes by how clearly directional it is, not how loud. Two sounds at once (a siren and people talking) show up as two peaks instead of one arrow in between.") {
            let peaks = histogramPeaks(d.histogram)
            DirectionMap(histogram: d.histogram, peaks: peaks, arrow: p.azimuth)
                .frame(height: 200)
            row("Separate directions heard", peaks.isEmpty ? "–" : peaks.map(deg).joined(separator: ", "))
        }
    }

    @ViewBuilder private func poseStep(_ d: DebugSnapshot, phone v: SIMD3<Double>) -> some View {
        let g = d.processed.motion.gravity
        step("④ From the phone to you", "Gravity says which way is down. “Ahead” = where the camera and top edge point, flattened onto the ground; “left” is at a right angle to it. The sound's arrow is measured against those two.") {
            row("Gravity x, y, z", "\(f(g.x)), \(f(g.y)), \(f(g.z)) · \(poseName(g))")
            if let axes = groundAxes(gravity: g) {
                let a = simd_dot(v, axes.ahead), l = simd_dot(v, axes.left)
                row("Toward ahead", s(a))
                row("Toward left", s(l))
                row("atan2(left \(f(l)), ahead \(f(a)))", "= \(deg(atan2(l, a) * 180 / .pi))")
            } else {
                row("Ahead", "none: camera and top edge point at the sky or ground")
            }
        }
    }

    // MARK: What is it? (the alert)

    @ViewBuilder private func whatSteps(_ d: DebugSnapshot) -> some View {
        let j = d.lastJudged
        step("⑧ Five listeners", "\(radar.engine == .apple ? "Apple's sound classifier" : "Apple's sound classifier, through the SoundML package,") hears each half second through the all-around channel and 4 beams aimed ahead, left, behind and right of you (they follow the phone's pose). A beam aimed away from other noise hears a siren more clearly. Strongest alert sound per listener:") {
            if let ls = j?.listeners, !ls.isEmpty {
                meters(ls.map { l in
                    ("\(l.name): \(l.label.isEmpty ? "nothing alert-like" : alertName(l.label).what)", l.score, f(l.score),
                     l.score >= alertThreshold ? Color.red : .secondary)
                })
            } else {
                Text("Waiting for the classifier…").foregroundStyle(.secondary)
            }
        }
        step("⑨ Confirmation", "One siren-like moment isn't enough. Each sound's best score from the 5 listeners is kept for the last 3 half seconds and must pass its rule:") {
            let fams = d.trails.sorted { ($0.value.max() ?? 0) > ($1.value.max() ?? 0) }
            if fams.isEmpty { Text("No alert-like sound recently").foregroundStyle(.secondary) }
            ForEach(fams, id: \.key) { key, trail in
                let ok = convincing(key, trail)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(alertName(key).what).bold()
                        Spacer()
                        Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? .green : .secondary)
                    }
                    Text("\(trail.map { f($0) }.joined(separator: " → ")) · needs \(confirmRule(key))").font(.caption)
                }
            }
        }
        if let j, !j.label.isEmpty {
            step("⑩ Which sound, and where it is", "Critical sounds (sirens, skids, screams, trains, then horns) win over louder warnings; a sound already alerting keeps priority. Its direction: the heard direction (⑦) that its beam scores point at, not just the loudest thing.") {
                row("Picked", "\(alertName(j.label).what) · \(f(j.score))")
                if let lo = j.beamScores.min(), let hi = j.beamScores.max() {
                    Text("Its score through each beam:").font(.caption).foregroundStyle(.secondary)
                    meters(zip(beamNames, j.beamScores).map { ("Beam \($0)", $1, f($1), $1 == hi ? Color.red : .secondary) })
                    row("Beams point", j.beamPointing.map(deg) ?? "unclear")
                    if j.beamPointing == nil {
                        Text("Pointing needs the weakest beam below \(f(alertThreshold)) and the strongest ≥ 0.25 above it; now \(f(lo)) and \(f(hi)).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    row("Beams point", "unclear (no beam scores yet)")
                }
                row("Directions heard", j.sources.isEmpty ? "–" : j.sources.map(deg).joined(separator: ", "))
                row("Direction used", j.azimuth.map { "\(deg($0)) · \(directionWords($0))" } ?? "unclear")
                Text("Because: \(j.directionReason)").font(.caption).foregroundStyle(.secondary)
            }
            step("⑪ Critical or warning", "Sirens, skids, screams and trains are always critical. A horn is critical unless it's ahead of you and not near. Bells, barks, shouts are warnings unless near (≥ \(Int(Detector.nearDB)) dB louder than this street usually is).") {
                Text(j.levelReason)
            }
        }
        step("⑫ What you get", "Critical: red, the Dynamic Island pops open when it starts, vibration at the start and every 10 s while it lasts. Warning: orange, no pop. An alert is held 3 s after the sound stops.") {
            if let a = d.alert {
                row(a.level == .critical ? "CRITICAL" : "WARNING", "\(a.what) · \(directionWords(a.azimuth))")
            } else {
                row("Now", "nothing to warn about")
            }
        }
    }

    // MARK: Getting closer

    @ViewBuilder private func closerStep(_ d: DebugSnapshot) -> some View {
        let rule = ApproachDetector(), n = ApproachDetector.sectors
        step("⑬ Something getting closer", "Separately, 8 beams (one per 45° around you) track loudness over 2 s. The sector rising most is checked against every condition; all must pass to warn.") {
            if d.sectors.isEmpty {
                Text("Filling the first 2 seconds…").foregroundStyle(.secondary)
            } else {
                let i = d.sectors.indices.max { d.sectors[$0].rise < d.sectors[$1].rise }!, st = d.sectors[i]
                let sweep = [n - 1, 0, 1].map { d.sectors[(i + $0) % n].sweep }.max()!
                row("Rising most", pretty(sectorNames[i]))
                check("Rose ≥ \(f(rule.riseDB, 0)) dB in \(f(rule.window, 0)) s", "\(f(st.rise, 1)) dB", st.rise >= rule.riseDB)
                check("Steadily (no jump > half the rise)", "\(f(st.biggestJump, 1)) dB", st.biggestJump <= st.rise / 2)
                check("≥ \(f(rule.leadDB, 0)) dB above the other directions", "\(f(st.lead, 1)) dB", st.lead >= rule.leadDB)
                check("Louder than \(Int(rule.minDB)) dB", "\(f(st.db, 0)) dB", st.db > rule.minDB)
                check("Out of your view (left, behind, right)", pretty(sectorNames[i]), Detector.warnSectors.contains(i))
                if let usual = d.processed.usual {
                    check("≥ \(f(Detector.standOutDB, 0)) dB over this street's usual", "\(s(st.db - usual, 0)) dB", st.db - usual >= Detector.standOutDB)
                }
                check("Stood out for ≥ 1 s", "\(f(st.ledFor, 2)) s", st.ledFor >= 1)
                check("Bearing moving ≤ \(Int(Detector.maxSweep))°/s (coming at you, not passing)", "\(Int(sweep.rounded()))°/s", sweep <= Detector.maxSweep)
            }
        }
    }

    // MARK: Words

    private var wordsStep: some View {
        step("⑭ Your name and danger words", "Apple's on-device transcriber turns speech into text; a whole-word match (any case, accents and punctuation ignored) gives an alert, with the direction of the voice. Your name: warning. Danger words: critical.") {
            row("Listener", radar.wordStatus)
            row("Listening for", (phrases(names) + phrases(words)).joined(separator: ", ").ifEmpty("nothing"))
            row("Last heard", String(radar.lastTranscript.suffix(60)).ifEmpty("–"))
        }
    }

    // MARK: Pieces

    private func step<Content: View>(_ title: String, _ explain: String, @ViewBuilder _ content: () -> Content) -> some View {
        Section {
            Text(explain).font(.caption).foregroundStyle(.secondary)
            content()
        } header: {
            Text(title)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).multilineTextAlignment(.trailing) }
            .font(.callout)
    }

    private func check(_ label: String, _ value: String, _ ok: Bool) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(value)
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? .green : .red)
            }
        } label: {
            Text(label)
        }
        .font(.callout)
    }

    private func meters(_ rows: [(name: String, fill: Double, text: String, tint: Color)]) -> some View {
        Grid(alignment: .leading, verticalSpacing: 8) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    Text(rows[i].name).font(.callout)
                    ProgressView(value: min(max(rows[i].fill, 0), 1)).tint(rows[i].tint)
                    Text(rows[i].text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                }
            }
        }
    }

    private func db(_ power: Double) -> Double { 10 * log10(max(power, 1e-12)) }
    // Rounded to zero shows as 0, not "-0.00".
    private func f(_ v: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", v.roundsToZero(digits) ? 0 : v) }
    private func s(_ v: Double, _ digits: Int = 2) -> String { String(format: "%+.\(digits)f", v.roundsToZero(digits) ? 0 : v) }
    private func deg(_ v: Double) -> String { "\(Int(remainder(v, 360).rounded()))°" }
}

/// "upright", "flat, screen up", …
func poseName(_ g: SIMD3<Double>) -> String {
    abs(g.z) > 0.8 ? "flat, screen \(g.z < 0 ? "up" : "down")"
        : g.y < -0.7 ? "upright" : g.y > 0.7 ? "upside down" : abs(g.x) > 0.7 ? "sideways" : "tilted"
}

/// Step ⑦'s picture: each direction's frequency votes as a spoke (ahead up, left to the left), peaks as dots,
/// and the arrow from steps ①–⑥.
struct DirectionMap: View {
    let histogram: [Double]
    let peaks: [Double]
    let arrow: Double?

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r1 = min(size.width, size.height) / 2 - 26, r0 = r1 * 0.2
            func point(_ deg: Double, _ r: Double) -> CGPoint {
                let a = deg * .pi / 180
                return CGPoint(x: c.x - sin(a) * r, y: c.y - cos(a) * r)
            }
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r1, y: c.y - r1, width: 2 * r1, height: 2 * r1)), with: .color(.secondary.opacity(0.3)))
            let top = max(histogram.max() ?? 0, 1e-9), width = 360 / Double(max(histogram.count, 1))
            for (i, v) in histogram.enumerated() where v > 0 {
                var p = Path()
                p.move(to: point(Double(i) * width, r0))
                p.addLine(to: point(Double(i) * width, r0 + (r1 - r0) * v / top))
                ctx.stroke(p, with: .color(.accentColor), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
            for peak in peaks {
                let q = point(peak, r1 + 8)
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - 4, y: q.y - 4, width: 8, height: 8)), with: .color(.orange))
            }
            if let arrow {
                var p = Path()
                p.move(to: c)
                p.addLine(to: point(arrow, r1))
                ctx.stroke(p, with: .color(.red), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            for (text, deg, anchor) in [("Ahead", 0.0, UnitPoint.bottom), ("Left", 90, .trailing), ("Behind", 180, .top), ("Right", -90, .leading)] {
                ctx.draw(Text(text).font(.caption2).foregroundStyle(.secondary), at: point(deg, r1 + 14), anchor: anchor)
            }
        }
        .accessibilityLabel("Directions heard per frequency")
    }
}

private extension Double {
    func roundsToZero(_ digits: Int) -> Bool { abs(self) < 0.5 * pow(10, -Double(digits)) }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
