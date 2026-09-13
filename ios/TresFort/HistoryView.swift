import SwiftUI

/// The calendar owns workout dates and the recurring schedule.
struct HistoryView: View {
    @ObservedObject var sync: SyncModel
    @State private var showWeeklySchedule = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                VStack(spacing: 0) {
                    if sync.isUsingCachedState { CachedStateBanner() }
                    CalendarMonthView(sync: sync,
                                      onWeeklySchedule: { showWeeklySchedule = true })
                }
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $showWeeklySchedule) { WeeklyScheduleView(sync: sync) }
        }
        .preferredColorScheme(.dark)
    }
}
