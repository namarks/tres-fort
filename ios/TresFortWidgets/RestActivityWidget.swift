import ActivityKit
import SwiftUI
import WidgetKit

private let accent = Color(red: 0.96, green: 0.62, blue: 0.04)

struct RestActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestActivityAttributes.self) { ctx in
            // Lock Screen / banner
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("REST · \(ctx.attributes.exercise.uppercased())")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    Text(timerInterval: Date()...ctx.state.endDate, countsDown: true)
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .monospacedDigit().foregroundStyle(accent)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("UP NEXT").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(ctx.state.upNext).font(.headline).foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            .padding(16)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Rest", systemImage: "timer").font(.caption).foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...ctx.state.endDate, countsDown: true)
                        .font(.system(.title2, design: .rounded)).bold()
                        .monospacedDigit().foregroundStyle(accent)
                        .frame(maxWidth: 64)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Up next · \(ctx.state.upNext)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(accent)
            } compactTrailing: {
                Text(timerInterval: Date()...ctx.state.endDate, countsDown: true)
                    .monospacedDigit().foregroundStyle(accent).frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }
}

@main
struct TresFortWidgetsBundle: WidgetBundle {
    var body: some Widget { RestActivityWidget() }
}
