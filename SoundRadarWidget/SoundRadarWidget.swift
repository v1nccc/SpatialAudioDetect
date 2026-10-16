import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct SoundRadarWidgets: WidgetBundle {
    var body: some Widget { RadarLiveActivity() }
}

/// Sound Radar in the Dynamic Island and on the Lock Screen: is it listening, is something coming, pause / resume.
struct RadarLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RadarActivity.self) { context in
            LockScreenStatus(state: context.state, startedAt: context.attributes.startedAt, stale: context.isStale)
                .padding()
        } dynamicIsland: { context in
            let state = context.state, stale = context.isStale, tint = state.tint(stale: stale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Sound Radar", systemImage: "ear.badge.waveform")
                        .font(.caption.bold())
                        .foregroundStyle(tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56, alignment: .trailing)  // a timer otherwise grabs all the width and clips
                        .padding(.trailing, 8)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    let warning = state.status == .warning && !stale
                    HStack(spacing: 12) {
                        StatusIcon(state: state, stale: stale).font(warning ? .largeTitle : .title).foregroundStyle(tint)
                        VStack(alignment: .leading) {
                            Text(state.headline(stale: stale))
                                .font(warning ? .title2.bold() : .headline)
                                .foregroundStyle(warning ? tint : .primary)
                            state.sublineText(stale: stale).font(warning ? .title3 : .subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        SessionButtons(paused: state.status == .paused)
                    }
                }
            } compactLeading: {
                if state.status == .warning && !stale {
                    StatusIcon(state: state, stale: stale).foregroundStyle(tint)  // arrow toward the sound
                } else {
                    Image(systemName: "ear.badge.waveform").foregroundStyle(tint)
                }
            } compactTrailing: {
                if state.status == .warning && !stale && !state.short.isEmpty {
                    Text(state.short).font(.caption.bold()).foregroundStyle(tint).lineLimit(1)  // "Horn", "Siren"
                } else {
                    StatusIcon(state: state, stale: stale).foregroundStyle(tint)
                }
            } minimal: {
                StatusIcon(state: state, stale: stale).foregroundStyle(tint)
            }
            .keylineTint(tint)
        }
    }
}

struct LockScreenStatus: View {
    let state: RadarActivity.ContentState
    let startedAt: Date
    let stale: Bool

    var body: some View {
        HStack(spacing: 14) {
            StatusIcon(state: state, stale: stale)
                .font(.largeTitle)
                .foregroundStyle(state.tint(stale: stale))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.headline(stale: stale)).font(.headline)
                state.sublineText(stale: stale).font(.subheadline).foregroundStyle(.secondary)
                Text(startedAt, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            SessionButtons(paused: state.status == .paused)
        }
    }
}

/// Pause / Resume and Stop; both run in the app (LiveActivityIntent), so they reach the microphone.
struct SessionButtons: View {
    let paused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: SetListeningIntent(listen: paused)) { circle(paused ? "play.fill" : "pause.fill") }
                .accessibilityLabel(paused ? "Resume listening" : "Pause listening")
            Button(intent: StopListeningIntent()) { circle("xmark") }
                .accessibilityLabel("Stop Sound Radar")
        }
        .buttonStyle(.plain)
    }

    private func circle(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.title3)
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.2), in: .circle)
    }
}

/// Waveform while listening, an arrow toward a warning, pause / mic-off icons, ? when the app stopped updating.
struct StatusIcon: View {
    let state: RadarActivity.ContentState
    let stale: Bool

    var body: some View {
        if stale {
            Image(systemName: "questionmark.circle.fill")
        } else {
            switch state.status {
            case .listening:
                Image(systemName: "waveform")
            case .paused:
                Image(systemName: "pause.circle.fill")
            case .interrupted:
                Image(systemName: "mic.slash.fill")
            case .warning:
                if let azimuth = state.azimuth {
                    Image(systemName: "arrow.up.circle.fill").rotationEffect(.degrees(-azimuth))  // up = ahead, like the app
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
            }
        }
    }
}

extension RadarActivity.ContentState {
    func tint(stale: Bool) -> Color {
        if stale { return .gray }
        return switch status {
        case .listening: .green
        case .warning: critical ? .red : .orange
        case .interrupted: .yellow
        case .paused: .gray
        }
    }

    func headline(stale: Bool) -> String { stale ? "Not updating" : title }

    func subline(stale: Bool) -> String { stale ? "Sound Radar may have stopped. Open it to check." : detail }

    /// "behind on your left", plus "· 3 sec ago" once the warning has stopped (counts up on its own).
    func sublineText(stale: Bool) -> Text {
        if !stale, status == .warning, let endedAt { return Text("\(detail) · \(endedAt, style: .relative) ago") }
        return Text(subline(stale: stale))
    }
}
