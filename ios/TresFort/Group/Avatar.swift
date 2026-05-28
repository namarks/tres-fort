import SwiftUI

/// Compact circle avatar: initials in a colored ring. Color is a stable
/// per-user hash so the same friend has the same color in every row.
struct Avatar: View {
    let initials: String
    let color: Color

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18))
            Circle().strokeBorder(color, lineWidth: 1.5)
            Text(initials)
                .font(Theme.mono(13, .bold))
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(2)
        }
    }
}
