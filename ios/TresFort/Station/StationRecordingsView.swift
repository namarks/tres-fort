import AVFoundation
import SwiftUI
import UIKit

struct StationRecordingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recordings: [StationRecording] = []
    @State private var error: String?
    @State private var pendingDelete: UUID?
    @State private var damagedRecording: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Short, silent tests saved only on this iPad. Open a test to compare Apple and MediaPipe on the same video. Share transfers only the test you select.")
                        .font(.subheadline)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let damagedRecording {
                    Button("Delete damaged test", role: .destructive) { pendingDelete = damagedRecording }
                }
                if recordings.isEmpty {
                    ContentUnavailableView("No saved tests", systemImage: "video",
                                           description: Text("Turn on the camera, then choose Record test."))
                }
                ForEach(recordings) { recording in
                    NavigationLink {
                        StationRecordingDetailView(recording: recording)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(recording.exercise.title).font(.headline)
                            Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text("\(recording.durationSeconds, specifier: "%.1f") seconds · \(recording.frameCount) frames")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { pendingDelete = recording.id }
                    }
                }
            }
            .navigationTitle("Saved tests")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear(perform: reload)
            .confirmationDialog("Delete this test and its video?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                    Button("Delete test", role: .destructive) {
                        guard let id = pendingDelete else { return }
                        do { try StationRecordingStore().delete(id: id); reload() }
                        catch { self.error = error.localizedDescription }
                        pendingDelete = nil
                    }
                }
        }
        .preferredColorScheme(.dark)
    }

    private func reload() {
        do { recordings = try StationRecordingStore().list(); error = nil; damagedRecording = nil }
        catch StationRecordingError.damagedRecording(let id) {
            damagedRecording = id
            error = "A saved test is damaged. Delete it to view the remaining tests."
        }
        catch { self.error = error.localizedDescription }
    }
}

private struct StationShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct StationShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

struct StationRecordingDetailView: View {
    let recording: StationRecording
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var replay = StationReplayModel()
    @State private var actualReps = ""
    @State private var selectedIndex = 0.0
    @State private var still: UIImage?
    @State private var stillError: String?
    @State private var error: String?
    @State private var shareItems: StationShareItems?
    @State private var previousIdleTimerDisabled = false
    @FocusState private var editingCount: Bool

    private var frame: StationReplayFrame? {
        guard let frames = replay.report?.frames, !frames.isEmpty else { return nil }
        return frames[min(Int(selectedIndex), frames.count - 1)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("\(recording.durationSeconds, specifier: "%.1f") seconds · \(recording.frameCount) frames · \(recording.droppedFrameCount) encoder skips")
                    .font(.subheadline).foregroundStyle(.secondary)
                if recording.finishReason == .cameraStopped || recording.finishReason == .orientationChanged {
                    Text("This clip ended early because the camera stopped or moved. Label only the reps completed within this saved clip.")
                        .foregroundStyle(.orange)
                }
                Text("Both detectors process every saved frame. Drag the slider to inspect exactly the same moment in both views.")
                if let error { Text(error).foregroundStyle(.red) }
                if let error = replay.error { Text(error).foregroundStyle(.red) }
                HStack {
                    TextField("Actual reps", text: $actualReps)
                        .keyboardType(.numberPad).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                        .focused($editingCount)
                        .accessibilityIdentifier("station.recordingActualReps")
                    Button("Save count") { saveCount() }
                        .disabled(!actualReps.isEmpty && (Int(actualReps).map { !(0...1000).contains($0) } ?? true))
                }
                if replay.isRunning {
                    ProgressView(value: Double(replay.completedFrames), total: Double(max(1, recording.frameCount))) {
                        Text("Comparing frame \(replay.completedFrames) of \(recording.frameCount)")
                    }
                    Button("Cancel comparison") { replay.cancel() }
                } else {
                    Button(replay.report == nil ? "Compare Apple and MediaPipe" : "Run comparison again", systemImage: "person.crop.rectangle.badge.plus") {
                        do { replay.start(recording: recording, store: try StationRecordingStore()) }
                        catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("station.replay")
                }

                if let report = replay.report, let frame {
                    if let last = report.frames.last {
                        Text("Full clip angle cycles: Apple \(last.appleCycles) · MediaPipe \(last.mediaPipeCycles)")
                            .font(.headline)
                    }
                    Text("Frame \(Int(selectedIndex) + 1) / \(report.frames.count) · \(frame.timestamp, specifier: "%.2f") s")
                        .font(.headline).monospacedDigit()
                    if report.frames.count > 1 {
                        Slider(value: $selectedIndex, in: 0...Double(report.frames.count - 1), step: 1)
                            .accessibilityLabel("Video frame")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            posePanel("Apple Vision", pose: frame.apple, cycles: frame.appleCycles).frame(minWidth: 280)
                            posePanel("MediaPipe Full", pose: frame.mediaPipe, cycles: frame.mediaPipeCycles).frame(minWidth: 280)
                        }
                        VStack(spacing: 16) {
                            posePanel("Apple Vision", pose: frame.apple, cycles: frame.appleCycles)
                            posePanel("MediaPipe Full", pose: frame.mediaPipe, cycles: frame.mediaPipeCycles)
                        }
                    }
                    if let stillError { Text(stillError).foregroundStyle(.red) }
                    Text("The two scores have different meanings: Apple confidence and the lower of MediaPipe visibility/presence. Green uses the prototype's 0.6 cutoff; it does not establish equal accuracy. Both cycle counts use the same side-view angle rule, which is not validated for front-facing squats.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Offline comparison · \(report.frames.count) shared frames. Processing times exclude video decoding; MediaPipe includes pixel rotation. These are not live camera performance measurements.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if !replay.isRunning {
                    if let still { Image(uiImage: still).resizable().scaledToFit().frame(maxHeight: 420) }
                    if let stillError { Text(stillError).foregroundStyle(.red) }
                }
                Button("Share this test", systemImage: "square.and.arrow.up") { share() }
                    .disabled(replay.isRunning)
                Text("Sharing includes the silent video, recorded measurements, count label and any completed comparison. Nothing is uploaded automatically. Delete saved tests from the list when you no longer need them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(24)
        }
        .navigationTitle(recording.exercise.title + " test")
        .onAppear {
            actualReps = recording.actualReps.map(String.init) ?? ""
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        }
        .onChange(of: replay.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running ? true : previousIdleTimerDisabled
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { replay.cancel() } }
        .onDisappear { replay.cancel(); UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled }
        .task(id: frame?.timestamp ?? 0) { await loadStill(at: frame?.timestamp ?? 0) }
        .sheet(item: $shareItems) { items in StationShareSheet(urls: items.urls) }
    }

    private func posePanel(_ title: String, pose: StationReplayPose, cycles: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ZStack {
                Color.black
                if let still {
                    Image(uiImage: still).resizable().scaledToFit()
                    StationPoseOverlay(frame: StationComparisonFrame(
                        sample: pose.sample(at: frame?.timestamp ?? 0), applePose: nil,
                        visionMilliseconds: pose.milliseconds, imageAspectRatio: recording.imageAspectRatio))
                } else { ProgressView() }
            }
            .aspectRatio(recording.imageAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("\(pose.personCount) people · \(pose.milliseconds, specifier: "%.1f") ms · \(cycles) angle cycles")
                .font(.caption).monospacedDigit()
            Text(jointSummary(pose)).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func jointSummary(_ pose: StationReplayPose) -> String {
        let names: [StationJoint] = recording.exercise == .squat
            ? [.leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
            : [.leftShoulder, .rightShoulder, .leftElbow, .rightElbow, .leftWrist, .rightWrist]
        return names.map { name in
            let value = pose.joints[name.rawValue].map { String(format: "%.2f", $0.score) } ?? "missing"
            return "\(name.rawValue): \(value)"
        }.joined(separator: "\n")
    }

    private func saveCount() {
        do {
            try StationRecordingStore().updateActualReps(actualReps.isEmpty ? nil : Int(actualReps), for: recording.id)
            editingCount = false
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func share() {
        do {
            let store = try StationRecordingStore()
            var urls = [store.videoURL(for: recording.id), store.measurementsURL(for: recording.id),
                        store.manifestURL(for: recording.id)]
            let result = store.directoryURL(for: recording.id).appendingPathComponent("comparison.json")
            if FileManager.default.fileExists(atPath: result.path) { urls.append(result) }
            shareItems = StationShareItems(urls: urls)
        } catch { self.error = error.localizedDescription }
    }

    private func loadStill(at seconds: Double) async {
        still = nil
        stillError = nil
        do {
            let url = try StationRecordingStore().videoURL(for: recording.id)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 1280)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600_000))
            try Task.checkCancellation()
            still = UIImage(cgImage: result.image)
        } catch is CancellationError { }
        catch { if !Task.isCancelled { stillError = "Could not display this video frame." } }
    }
}
