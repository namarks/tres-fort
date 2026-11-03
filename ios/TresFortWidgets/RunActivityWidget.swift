import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private let accent = BrandPalette.liveAccent

/// A recorded run on the Lock Screen and in the Dynamic Island. Finishing
/// takes a pause first, so a pocket tap can't end the run.
struct RunActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { ctx in
            ActivityFamilyLayout {
                wristLayout(ctx)
            } standard: {
                lockScreenLayout(ctx)
            }
            .activityBackgroundTint(BrandPalette.liveBackground)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(ctx.state.isPaused ? "Paused" : "Run", systemImage: "figure.run")
                        .font(.caption).foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    clock(ctx.state)
                        .font(.system(.title2, design: .rounded)).bold()
                        .monospacedDigit().foregroundStyle(accent)
                        .frame(maxWidth: 96)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack {
                        Text("\(distance(ctx.state)) · \(pace(ctx.state))")
                            .font(.caption).foregroundStyle(.secondary)
                        controls(ctx)
                    }
                }
            } compactLeading: {
                Image(systemName: "figure.run").foregroundStyle(accent)
            } compactTrailing: {
                clock(ctx.state).monospacedDigit().foregroundStyle(accent).frame(maxWidth: 52)
            } minimal: {
                Image(systemName: ctx.state.isPaused ? "pause.fill" : "figure.run").foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
        .watchSmartStackFamily()
    }

    /// Lock Screen and banner.
    private func lockScreenLayout(_ ctx: ActivityViewContext<RunActivityAttributes>) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ctx.state.isPaused ? "PAUSED" : "RUN")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                clock(ctx.state)
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .monospacedDigit().foregroundStyle(accent)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(distance(ctx.state)).font(.headline).foregroundStyle(.white)
                Text(pace(ctx.state)).font(.caption).foregroundStyle(.secondary)
                controls(ctx)
            }
        }
        .padding(16)
    }

    /// Apple Watch Smart Stack: time first, then distance and pace, then the
    /// same controls as the Lock Screen (Finish only while paused).
    private func wristLayout(_ ctx: ActivityViewContext<RunActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(ctx.state.isPaused ? "PAUSED" : "RUN")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(distance(ctx.state))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .monospacedDigit()
            }
            clock(ctx.state)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .monospacedDigit().foregroundStyle(accent)
            HStack(spacing: 6) {
                Text(pace(ctx.state))
                    .font(.caption2).foregroundStyle(.secondary)
                    .monospacedDigit().lineLimit(1)
                Spacer(minLength: 0)
                controls(ctx, font: .caption2.bold())
            }
        }
    }

    @ViewBuilder private func clock(_ state: RunActivityAttributes.ContentState) -> some View {
        if let paused = state.pausedSeconds {
            Text(RunFormat.duration(paused))
        } else {
            Text(state.clockStart, style: .timer)
        }
    }

    private func distance(_ state: RunActivityAttributes.ContentState) -> String {
        "\(RunFormat.distance(state.meters, in: state.unit)) \(state.unit.abbreviation)"
    }

    private func pace(_ state: RunActivityAttributes.ContentState) -> String {
        "\(RunFormat.pace(state.currentPace)) /\(state.unit.abbreviation)"
    }

    private func controls(_ ctx: ActivityViewContext<RunActivityAttributes>,
                          font: Font = .caption.bold()) -> some View {
        let id = ctx.attributes.recordingID
        return HStack {
            if ctx.state.isPaused {
                Button("Resume", intent: RunRecorderControlIntent(recordingID: id, action: .resume))
                Button("Finish", intent: RunRecorderControlIntent(recordingID: id, action: .finish))
            } else {
                Button("Pause", intent: RunRecorderControlIntent(recordingID: id, action: .pause))
            }
        }
        .font(font).buttonStyle(.bordered).tint(accent)
    }
}
