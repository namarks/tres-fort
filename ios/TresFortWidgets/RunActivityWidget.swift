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

    private func controls(_ ctx: ActivityViewContext<RunActivityAttributes>) -> some View {
        let id = ctx.attributes.recordingID
        return HStack {
            if ctx.state.isPaused {
                Button("Resume", intent: RunRecorderControlIntent(recordingID: id, action: .resume))
                Button("Finish", intent: RunRecorderControlIntent(recordingID: id, action: .finish))
            } else {
                Button("Pause", intent: RunRecorderControlIntent(recordingID: id, action: .pause))
            }
        }
        .font(.caption.bold()).buttonStyle(.bordered).tint(accent)
    }
}
