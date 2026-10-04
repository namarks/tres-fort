import AVFoundation
import SwiftUI
import UIKit

struct StationRecordingsView: View {
    @ObservedObject var access: StationAccess
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
                        StationRecordingDetailView(recording: recording, access: access)
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
                        guard access.validate() else { return }
                        do { try StationRecordingStore(session: access.session).delete(id: id); reload() }
                        catch { self.error = error.localizedDescription }
                        pendingDelete = nil
                    }
                }
        }
        .preferredColorScheme(.dark)
        .onReceive(access.$isActive) { active in
            guard !active else { return }
            recordings = []
            pendingDelete = nil
            damagedRecording = nil
            error = nil
            dismiss()
        }
    }

    private func reload() {
        guard access.validate() else { recordings = []; return }
        do { recordings = try StationRecordingStore(session: access.session).list(); error = nil; damagedRecording = nil }
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
    @ObservedObject var access: StationAccess
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let items = access.validate() ? urls.map { StationShareItem(url: $0, session: access.session) } : []
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        if !access.isActive { uiViewController.dismiss(animated: false) }
    }
}

final class StationShareItem: NSObject, UIActivityItemSource {
    private let url: URL
    private let session: StationSessionGate
    init(url: URL, session: StationSessionGate) { self.url = url; self.session = session }
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        if let allowedURL = try? session.withAccess({ url }) { return allowedURL }
        return ""
    }
    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        try? session.withAccess { url }
    }
}

struct StationRecordingDetailView: View {
    let recording: StationRecording
    @ObservedObject var access: StationAccess
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var replay: StationReplayModel
    @StateObject private var stillModel: StationRecordingStill
    @State private var actualReps = ""
    @State private var actualLeftReps = ""
    @State private var actualRightReps = ""
    @State private var selectedIndex = 0.0
    @State private var error: String?
    @State private var shareItems: StationShareItems?
    @State private var previousIdleTimerDisabled = false
    private enum CountField: Hashable { case single, left, right }
    @FocusState private var editingCount: CountField?

    init(recording: StationRecording, access: StationAccess) {
        self.recording = recording
        self.access = access
        _replay = StateObject(wrappedValue: StationReplayModel(access: access))
        _stillModel = StateObject(wrappedValue: StationRecordingStill(access: access))
    }

    private var still: UIImage? { stillModel.image }
    private var stillError: String? { stillModel.error }

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
                if recording.exercise == .curl {
                    curlCountLabels
                } else { HStack {
                    TextField("Actual reps", text: $actualReps)
                        .keyboardType(.numberPad).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                        .focused($editingCount, equals: .single)
                        .accessibilityIdentifier("station.recordingActualReps")
                    Button("Save count") { saveCount() }
                        .disabled(!actualReps.isEmpty && (Int(actualReps).map { !(0...1000).contains($0) } ?? true))
                } }
                if replay.isRunning {
                    ProgressView(value: Double(replay.completedFrames), total: Double(max(1, recording.frameCount))) {
                        Text("Comparing frame \(replay.completedFrames) of \(recording.frameCount)")
                    }
                    Button("Cancel comparison") { replay.cancel() }
                } else {
                    Button(replay.report == nil ? "Compare Apple and MediaPipe" : "Run comparison again", systemImage: "person.crop.rectangle.badge.plus") {
                        do { replay.start(recording: recording, store: try StationRecordingStore(session: access.session)) }
                        catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("station.replay")
                }

                if let report = replay.report, let frame {
                    if let last = report.frames.last {
                        if recording.exercise == .curl {
                            if let apple = curlCycles(left: last.appleLeftCycles, right: last.appleRightCycles),
                               let mediaPipe = curlCycles(left: last.mediaPipeLeftCycles, right: last.mediaPipeRightCycles) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Full clip angle cycles").font(.headline)
                                    Text("Apple · \(apple)")
                                    Text("MediaPipe · \(mediaPipe)")
                                }.accessibilityIdentifier("station.curlReplayCounts")
                            } else {
                                Text("This comparison has no per-arm counts. Run comparison again to count the left and right arms separately.")
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Text("Full clip angle cycles: Apple \(last.appleCycles) · MediaPipe \(last.mediaPipeCycles)")
                                .font(.headline)
                        }
                    }
                    Text("Frame \(Int(selectedIndex) + 1) / \(report.frames.count) · \(frame.timestamp, specifier: "%.2f") s")
                        .font(.headline).monospacedDigit()
                    if report.frames.count > 1 {
                        Slider(value: $selectedIndex, in: 0...Double(report.frames.count - 1), step: 1)
                            .accessibilityLabel("Video frame")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            posePanel("Apple Vision", pose: frame.apple, cycles: frame.appleCycles,
                                      leftCycles: frame.appleLeftCycles, rightCycles: frame.appleRightCycles).frame(minWidth: 280)
                            posePanel("MediaPipe Full", pose: frame.mediaPipe, cycles: frame.mediaPipeCycles,
                                      leftCycles: frame.mediaPipeLeftCycles, rightCycles: frame.mediaPipeRightCycles).frame(minWidth: 280)
                        }
                        VStack(spacing: 16) {
                            posePanel("Apple Vision", pose: frame.apple, cycles: frame.appleCycles,
                                      leftCycles: frame.appleLeftCycles, rightCycles: frame.appleRightCycles)
                            posePanel("MediaPipe Full", pose: frame.mediaPipe, cycles: frame.mediaPipeCycles,
                                      leftCycles: frame.mediaPipeLeftCycles, rightCycles: frame.mediaPipeRightCycles)
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
            guard access.validate() else { dismiss(); return }
            actualReps = recording.actualReps.map(String.init) ?? ""
            actualLeftReps = recording.actualLeftReps.map(String.init) ?? ""
            actualRightReps = recording.actualRightReps.map(String.init) ?? ""
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        }
        .onChange(of: replay.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running ? true : previousIdleTimerDisabled
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { replay.cancel() } }
        .onDisappear {
            replay.cancel()
            stillModel.clear()
            shareItems = nil
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
        .onReceive(access.$isActive) { active in
            guard !active else { return }
            replay.clear()
            stillModel.clear()
            shareItems = nil
            actualReps = ""
            actualLeftReps = ""
            actualRightReps = ""
            error = nil
            selectedIndex = 0
            editingCount = nil
            dismiss()
        }
        .task(id: frame?.timestamp ?? 0) { await loadStill(at: frame?.timestamp ?? 0) }
        .sheet(item: $shareItems) { items in StationShareSheet(urls: items.urls, access: access) }
    }

    private func posePanel(_ title: String, pose: StationReplayPose, cycles: Int,
                           leftCycles: Int?, rightCycles: Int?) -> some View {
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
            if recording.exercise == .curl {
                Text("\(pose.personCount) people · \(pose.milliseconds, specifier: "%.1f") ms")
                    .font(.caption).monospacedDigit()
                Text(curlCycles(left: leftCycles, right: rightCycles) ?? "Run comparison again for per-arm counts.")
                    .font(.caption).monospacedDigit()
            } else {
                Text("\(pose.personCount) people · \(pose.milliseconds, specifier: "%.1f") ms · \(cycles) angle cycles")
                    .font(.caption).monospacedDigit()
            }
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
        guard access.validate() else { return }
        do {
            let store = try StationRecordingStore(session: access.session)
            if recording.exercise == .curl {
                guard validRepInput(actualLeftReps), validRepInput(actualRightReps) else { throw StationRecordingError.invalidReps }
                try store.updateActualCurlReps(left: Int(actualLeftReps), right: Int(actualRightReps), for: recording.id)
            } else {
                try store.updateActualReps(actualReps.isEmpty ? nil : Int(actualReps), for: recording.id)
            }
            editingCount = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private var curlCountLabels: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Actual reps by arm").font(.headline)
            Text("Left and right refer to your body, not the sides of the screen. Leave a count blank if unknown.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Left arm")
                    TextField("Actual left reps", text: $actualLeftReps)
                        .keyboardType(.numberPad).textFieldStyle(.roundedBorder).focused($editingCount, equals: .left)
                        .accessibilityIdentifier("station.recordingActualLeftReps")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Right arm")
                    TextField("Actual right reps", text: $actualRightReps)
                        .keyboardType(.numberPad).textFieldStyle(.roundedBorder).focused($editingCount, equals: .right)
                        .accessibilityIdentifier("station.recordingActualRightReps")
                }
            }
            Button("Save arm counts") { saveCount() }
                .disabled(!validRepInput(actualLeftReps) || !validRepInput(actualRightReps))
                .accessibilityIdentifier("station.saveRecordingArmCounts")
            if let previous = recording.actualReps {
                Text("Previous single count: \(previous) (arm unspecified). This older label is kept separately.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("station.recordingLegacyCurlCount")
            }
        }
    }

    private func validRepInput(_ value: String) -> Bool {
        value.isEmpty || Int(value).map { (0...1_000).contains($0) } == true
    }

    private func curlCycles(left: Int?, right: Int?) -> String? {
        guard let left, let right else { return nil }
        return "Left arm \(left) · Right arm \(right)"
    }

    private func share() {
        guard access.validate() else { return }
        do {
            let store = try StationRecordingStore(session: access.session)
            let urls = try store.shareURLs(for: recording.id)
            shareItems = StationShareItems(urls: urls)
        } catch { self.error = error.localizedDescription }
    }

    private func loadStill(at seconds: Double) async {
        guard access.validate() else { stillModel.clear(); return }
        do {
            let store = try StationRecordingStore(session: access.session)
            await stillModel.load(recording: recording, at: seconds, store: store)
        } catch is CancellationError { }
        catch { if access.validate(), !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
