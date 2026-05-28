import SwiftUI

/// One row in the group feed. Avatar + name + relative date on top,
/// glyph + one-line summary below. Tappable from the parent — the row
/// itself is `.contentShape(Rectangle())` so the whole card is the tap
/// target.
struct FeedItemRow: View {
    let item: FeedItem

    var body: some View {
        HStack(spacing: 12) {
            Avatar(
                initials: avatarInitials(from: item.userDisplayName),
                color: .stableAvatarColor(forUserID: item.userID))
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.userDisplayName)
                        .font(Theme.mono(13, .bold))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    Text(FeedDateFormat.relative(epochMs: item.occurredAt))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.muted)
                }
                HStack(spacing: 6) {
                    Image(systemName: glyph)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(glyphColor)
                    Text(summary)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(Theme.surface)
        )
        .contentShape(Rectangle())
    }

    private var glyph: String {
        switch item {
        case .session:           return "dumbbell.fill"
        case .ride(let r):       return rideGlyph(kind: r.ride.kind)
        case .activity(let a):   return PendingActivity.glyph(for: a.activity.kind)
        case .unknown:           return "figure.mixed.cardio"
        }
    }

    private var glyphColor: Color {
        switch item {
        case .session:  return Theme.accent
        case .ride:     return Theme.muted
        case .activity: return Color(hex: 0xA855F7)
        case .unknown:  return Theme.dim
        }
    }

    private var summary: String {
        switch item {
        case .session(let s):
            let label = s.session.day_label.map { "\($0) · " } ?? ""
            let dayName = s.session.day_name ?? "Strength"
            let sets = "\(s.session.set_count) sets"
            let time = FeedFormat.duration(seconds: s.session.duration_sec)
            return "\(label)\(dayName) · \(sets) · \(time)"
        case .ride(let r):
            let name = r.ride.name ?? r.ride.kind.capitalized
            let dist = FeedFormat.distance(meters: r.ride.distance_m) ?? ""
            let time = FeedFormat.duration(seconds: r.ride.moving_time_sec)
            return [name, dist, time].filter { !$0.isEmpty }
                .joined(separator: " · ")
        case .activity(let a):
            let title = a.activity.title ?? PendingActivity.label(for: a.activity.kind)
            let dur = a.activity.duration_min.map { "\($0) min" } ?? ""
            return [title, dur].filter { !$0.isEmpty }
                .joined(separator: " · ")
        case .unknown(let u):
            return "Did something \(FeedDateFormat.relative(epochMs: u.occurred_at))"
        }
    }

    private func rideGlyph(kind: String) -> String {
        switch kind {
        case "run":   return "figure.run"
        case "swim":  return "figure.pool.swim"
        case "ride":  return "bicycle"
        default:      return "figure.mixed.cardio"
        }
    }
}
