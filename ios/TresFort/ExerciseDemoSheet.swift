import SwiftUI

/// Modal sheet showing a 2-frame crossfade demo for an exercise.
///
/// Triggered by a small (i) button next to the exercise name in TodayView,
/// the swap-exercise picker, and history detail — anywhere the user might
/// want to confirm "what does this lift actually look like?".
///
/// Renders:
///   - exercise name + primary/secondary muscle map
///   - laterality + load-mode badges (so "per side / each hand" semantics
///     are explicit without forcing the user to a separate doc)
///   - 2-frame auto-cycling animation (~1.4s/frame, tap to pause)
///   - cue card fallback when the catalog row has no demo_slug or both
///     loader calls miss
struct ExerciseDemoSheet: View {
    let exerciseID: String
    let name: String
    let primaryMuscle: String
    let secondaryMuscles: [String]
    let modality: String
    let laterality: String          // "bilateral" | "unilateral"
    let loadMode: String            // "total" | "per_hand"
    let demoSlug: String?
    let jwt: String?

    @StateObject private var loader = DemoImageLoader()
    @State private var showSecondFrame = false
    @State private var isPaused = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(name.uppercased())
                    .font(Theme.display(28))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 4)

                demoFrame
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .onTapGesture { isPaused.toggle() }

                badgesRow
                muscleSection

                if laterality == "unilateral" {
                    Text("Log one set with the per-side numbers — the app counts both legs/arms automatically.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 4)
                }
                if loadMode == "per_hand" {
                    Text("Weight is one dumbbell. Both hands hold the same load.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.muted)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .background(Theme.background)
        .task {
            await loader.load(exerciseID: exerciseID,
                              demoSlug: demoSlug, jwt: jwt)
        }
        .task(id: loader.frames.compactMap { $0 }.count) {
            // Start the cycle once at least one frame is available.
            guard loader.frames.contains(where: { $0 != nil }) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                if !isPaused {
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.45)) {
                            showSecondFrame.toggle()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var demoFrame: some View {
        if loader.isLoading {
            ProgressView()
        } else {
            let f0 = loader.frames.indices.contains(0) ? loader.frames[0] : nil
            let f1 = loader.frames.indices.contains(1) ? loader.frames[1] : nil
            if f0 == nil && f1 == nil {
                cueCardFallback
            } else {
                ZStack {
                    if let f0 {
                        Image(uiImage: f0)
                            .resizable().scaledToFit()
                            .opacity(showSecondFrame ? 0 : 1)
                    }
                    if let f1 {
                        Image(uiImage: f1)
                            .resizable().scaledToFit()
                            .opacity(showSecondFrame ? 1 : 0)
                    }
                }
            }
        }
    }

    @ViewBuilder private var cueCardFallback: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.muted)
            Text("No demo available yet")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.muted)
        }
    }

    private var badgesRow: some View {
        HStack(spacing: 6) {
            badge(modality.uppercased())
            badge(laterality == "unilateral" ? "PER SIDE" : "BILATERAL",
                  tint: laterality == "unilateral" ? Theme.accent : Theme.muted)
            if loadMode == "per_hand" {
                badge("EACH HAND", tint: Theme.accent)
            }
            Spacer()
        }
    }

    private func badge(_ text: String, tint: Color = Theme.muted) -> some View {
        Text(text)
            .font(Theme.mono(10, .bold)).tracking(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint.opacity(0.5), lineWidth: 1)
            )
    }

    private var muscleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MUSCLES")
                .font(Theme.mono(11, .bold)).tracking(1.5)
                .foregroundStyle(Theme.muted)
            Text(primaryMuscle.capitalized + (
                secondaryMuscles.isEmpty
                    ? ""
                    : "  ·  " + secondaryMuscles.map { $0.capitalized }
                        .joined(separator: ", ")
            ))
            .font(.system(size: 15))
            .foregroundStyle(Theme.text)
        }
    }
}

/// Compact tap target — a circled (i) glyph rendered to the right of the
/// exercise name. Calls `onTap` to open ExerciseDemoSheet on the parent.
struct DemoInfoButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "info.circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Theme.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show exercise demo")
    }
}
