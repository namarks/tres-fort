import SwiftUI

/// A still, decorative recognition aid. Technique and history remain one
/// explicitly labelled action; thumbnails never animate or crop equipment.
struct ExerciseThumbnail: View {
    let exerciseID: String
    let demoSlug: String?
    let jwt: String?
    @StateObject private var loader = DemoImageLoader()

    private struct Request: Equatable {
        let exerciseID: String
        let demoSlug: String?
        let jwt: String?
    }

    var body: some View {
        ZStack {
            Theme.surface2
            if let image = loader.frames.compactMap({ $0 }).first {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(width: 64, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: Request(exerciseID: exerciseID, demoSlug: demoSlug, jwt: jwt)) {
            await loader.load(exerciseID: exerciseID, demoSlug: demoSlug, jwt: jwt,
                              presentation: .thumbnail)
        }
    }
}
