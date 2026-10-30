import MapKit
import SwiftUI

/// Full-screen run recorder: route map, live stats and the controls. Owned
/// by MainTabView so a recording outlives tab changes; it can't be swiped
/// away while a run records.
struct RunRecorderView: View {
    @ObservedObject var model: RunRecorderModel
    var onClose: () -> Void

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var confirmEnd = false

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 16) {
                header
                map
                stats
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.isRecording || model.phase == .starting)
        .confirmationDialog("End this run?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("Save run") { Task { await model.end() } }
                .accessibilityIdentifier("runRecorder.save")
            Button("Discard run", role: .destructive) { model.discard() }
                .accessibilityIdentifier("runRecorder.discard")
            Button("Keep running", role: .cancel) {}
        } message: {
            Text("Saving adds the run to Apple Health and uploads it to intervals.icu.")
        }
    }

    private var header: some View {
        HStack {
            Text(title).font(Theme.display(34)).foregroundStyle(Theme.text)
            Spacer()
            if !model.isRecording && model.phase != .starting {
                Button {
                    model.reset()
                    onClose()
                } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                }
                .foregroundStyle(Theme.muted)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("runRecorder.close")
            }
        }
        .padding(.top, 8)
    }

    private var title: String {
        switch model.phase {
        case .idle, .starting, .failed: "Outdoor run"
        case .running: "Running"
        case .paused: "Paused"
        case .ending: "Saving"
        case .finished: "Run saved"
        }
    }

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()
            if let points = model.run?.points, points.count > 1 {
                MapPolyline(coordinates: points.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .stroke(Theme.accent, lineWidth: 4)
            }
        }
        .mapControls { MapUserLocationButton() }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxHeight: .infinity)
        .accessibilityLabel("Route map")
    }

    private var stats: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let run = model.run
            let moving = run?.activeSeconds(at: context.date) ?? 0
            let meters = run?.distanceMeters ?? 0
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    stat("Time", RunFormat.duration(moving), large: true, id: "time")
                    stat("Miles", RunFormat.miles(meters), large: true, id: "distance")
                }
                HStack(alignment: .firstTextBaseline) {
                    stat("Pace /mi", RunFormat.pace(run.flatMap(RunPace.current)), id: "pace")
                    stat("Avg /mi", RunFormat.pace(RunPace.average(movingSeconds: moving, meters: meters)),
                         id: "averagePace")
                    stat("Heart rate", heartRate(at: context.date), id: "heartRate")
                }
            }
        }
    }

    private func heartRate(at date: Date) -> String {
        guard let sample = model.latestHeartRate, model.isRecording,
              date.timeIntervalSince(sample.timestamp) < 15 else { return "–" }
        return "\(Int(sample.beatsPerMinute.rounded()))"
    }

    private func stat(_ label: String, _ value: String, large: Bool = false, id: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Theme.number(large ? 40 : 24))
                .foregroundStyle(Theme.text)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(label.uppercased()).font(Theme.mono(11)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("runRecorder.\(id)")
    }

    @ViewBuilder private var controls: some View {
        switch model.phase {
        case .idle:
            primary("Start", systemImage: "play.fill", id: "start") { Task { await model.start() } }
        case .starting:
            ProgressView("Starting…").frame(minHeight: 56)
        case .running:
            HStack(spacing: 12) {
                secondary("Pause", systemImage: "pause.fill", id: "pause") { model.pause() }
                primary("End", systemImage: "stop.fill", id: "end") { confirmEnd = true }
            }
        case .paused:
            HStack(spacing: 12) {
                secondary("Resume", systemImage: "play.fill", id: "resume") { model.resume() }
                primary("End", systemImage: "stop.fill", id: "end") { confirmEnd = true }
            }
        case .ending:
            ProgressView("Saving to Apple Health…").frame(minHeight: 56)
        case .finished:
            VStack(spacing: 12) {
                notes
                primary("Done", systemImage: "checkmark", id: "done") {
                    model.reset()
                    onClose()
                }
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .accessibilityIdentifier("runRecorder.error")
                primary("Try again", systemImage: "arrow.clockwise", id: "retry") { Task { await model.start() } }
            }
        }
    }

    @ViewBuilder private var notes: some View {
        if let note = model.note {
            Text(note).font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        Text(uploadText).font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            .accessibilityIdentifier("runRecorder.upload")
    }

    private var uploadText: String {
        switch model.uploadStatus {
        case .idle: ""
        case .uploading: "Uploading to intervals.icu…"
        case .uploaded: "Uploaded to intervals.icu."
        case .waiting: "Saved on this iPhone. It uploads to intervals.icu when it can, so check your intervals.icu connection in Profile if it doesn’t appear."
        }
    }

    private func primary(_ title: String, systemImage: String, id: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Theme.display(26))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .foregroundStyle(.black)
        .accessibilityIdentifier("runRecorder.\(id)")
    }

    private func secondary(_ title: String, systemImage: String, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Theme.display(26))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
        .tint(Theme.text)
        .accessibilityIdentifier("runRecorder.\(id)")
    }
}
