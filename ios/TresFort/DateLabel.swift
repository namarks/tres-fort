import Foundation

/// Human-readable labels for the app's device-local `YYYY-MM-DD` dates, so a
/// screen never shows the storage format ("2026-11-01") to a member.
enum DateLabel {
    /// "Sunday, Nov 1". Falls back to the input when it isn't a valid date.
    static func long(_ ymd: String) -> String {
        guard let date = CalendarProjection.date(from: ymd) else { return ymd }
        return longFormatter.string(from: date)
    }

    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = CalendarProjection.calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = CalendarProjection.calendar.timeZone
        f.dateFormat = "EEEE, MMM d"
        return f
    }()
}
