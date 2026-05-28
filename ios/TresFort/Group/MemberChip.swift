import SwiftUI

/// One member's chip in the GroupDetailView top strip:
///   avatar circle (highlighted ring if is_me) → display name → week
///   workout count → streak flame
///
/// `is_me` is server-stamped — trust it (per M5 decision Q9).
struct MemberChip: View {
    let stat: MemberStat

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Avatar(
                    initials: stat.avatar_initials.isEmpty
                        ? avatarInitials(from: stat.display_name)
                        : stat.avatar_initials,
                    color: .stableAvatarColor(forUserID: stat.user_id))
                    .frame(width: 50, height: 50)
                if stat.is_me {
                    Circle()
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .frame(width: 54, height: 54)
                }
            }
            Text(stat.display_name)
                .font(Theme.mono(11, .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 80)
            HStack(spacing: 4) {
                Text("\(stat.workout_count)")
                    .font(Theme.mono(14, .bold))
                    .foregroundStyle(stat.workout_count == 0 ? Theme.muted : Theme.text)
                if stat.streak_days > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accent)
                        Text("\(stat.streak_days)")
                            .font(Theme.mono(10, .bold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .frame(width: 80, height: 110)
    }
}
