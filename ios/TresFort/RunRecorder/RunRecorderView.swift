import MapKit
import SwiftUI
import UIKit

/// Full-screen run recorder: route map, live stats and the controls. Owned
/// by MainTabView so a recording outlives tab changes; it can't be swiped
/// away while a run records.
struct RunRecorderView: View {
    @ObservedObject var model: RunRecorderModel
    var onClose: () -> Void

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var confirmEnd = false
    @State private var settingUpHeartRate = false

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 16) {
                header
                if model.isRecording && !model.planSteps.isEmpty {
                    RunPlanStepBanner(model: model)
                }
                if model.isRecording && model.showsGlance {
                    RunGlanceView(model: model)
                } else {
                    map
                    if model.phase == .finished {
                        summary
                    } else {
                        stats
                    }
                }
                if let plannedRun = model.plannedRun, !model.isRecording, model.phase != .finished {
                    PlannedRunCard(run: plannedRun, unit: model.unit)
                }
                if model.phase == .idle || isFailed {
                    gpsStatus
                    heartRateStatus
                    preferences
                }
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        // On opening, and whenever a discarded run returns to the start screen.
        .task(id: model.phase) {
            if model.phase == .idle || isFailed { await model.warmUpGPS() }
        }
        .onAppear { model.opened() }
        .onDisappear {
            model.closed()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // The running layout is read mid-stride, and the cool-down is
        // watched standing, so the screen stays on for both.
        .onChange(of: (model.isRecording && model.showsGlance) || model.isMeasuringRecovery,
                  initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .sheet(isPresented: $settingUpHeartRate) {
            HeartRateMonitorSetupView(monitor: model.heartRateMonitor)
        }
        .interactiveDismissDisabled(model.isRecording || model.phase == .starting || model.phase == .recovering)
        .confirmationDialog("End this run?", isPresented: $confirmEnd, titleVisibility: .visible) {
            if !model.isTooShortToSave {
                Button("Save run") { Task { await model.end() } }
                    .accessibilityIdentifier("runRecorder.save")
            }
            Button("Discard run", role: .destructive) { model.discard() }
                .accessibilityIdentifier("runRecorder.discard")
            Button("Keep running", role: .cancel) {}
        } message: {
            Text(model.isTooShortToSave
                 ? "Runs under a minute or 100 m aren’t saved."
                 : (model.plannedRun == nil
                    ? "Saving keeps the run and its route in Tres Fort and Apple Health, and sends it to intervals.icu if it’s connected."
                    : "Saving keeps the run and its route in Tres Fort and Apple Health, and sends it to intervals.icu if it’s connected. It also marks the planned run done."))
        }
    }

    private var header: some View {
        HStack {
            Text(title).font(Theme.display(34)).foregroundStyle(Theme.text)
            Spacer()
            if model.isRecording {
                Button {
                    model.showsGlance.toggle()
                } label: {
                    Image(systemName: model.showsGlance ? "map" : "textformat.size")
                        .font(.headline).frame(width: 44, height: 44)
                }
                .foregroundStyle(Theme.muted)
                .accessibilityLabel(model.showsGlance ? "Show the map" : "Show large numbers")
                .accessibilityIdentifier("runRecorder.glance")
                Button {
                    model.announcesSplits.toggle()
                } label: {
                    Image(systemName: model.announcesSplits ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.headline).frame(width: 44, height: 44)
                }
                .foregroundStyle(model.announcesSplits ? Theme.accent : Theme.muted)
                .accessibilityLabel(model.announcesSplits ? "Stop announcing splits" : "Announce splits")
                .accessibilityIdentifier("runRecorder.announce")
            }
            if !model.isRecording && model.phase != .starting && model.phase != .recovering {
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
        case .idle, .recovering, .starting, .failed: "Outdoor run"
        case .running: "Running"
        case .paused: model.isAutoPaused ? "Auto-paused" : "Paused"
        case .ending: "Saving"
        case .finished: "Run saved"
        }
    }

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    /// Whether GPS has locked on. A run can start either way; until the first
    /// good fix its route stays empty.
    private var gpsStatus: some View {
        Label(model.gpsReady ? "GPS ready" : "Finding GPS…",
              systemImage: model.gpsReady ? "location.fill" : "location")
            .font(.callout)
            .foregroundStyle(model.gpsReady ? Theme.accent : Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("runRecorder.gps")
    }

    /// The Bluetooth strap: what's connected, or a way to set one up.
    private var heartRateStatus: some View {
        HeartRateStatusRow(monitor: model.heartRateMonitor) { settingUpHeartRate = true }
    }

    /// Units and spoken splits, chosen before the run starts. Splits can be
    /// muted from the header while running.
    private var preferences: some View {
        VStack(spacing: 8) {
            Picker("Units", selection: $model.unit) {
                ForEach(RunDistanceUnit.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("runRecorder.unit")
            Toggle(model.plannedRun?.plan == nil
                   ? "Announce each \(model.unit.spokenName)"
                   : "Announce each \(model.unit.spokenName), step and target",
                   isOn: $model.announcesSplits)
                .font(.callout)
                .foregroundStyle(Theme.text)
                .tint(Theme.accent)
                .accessibilityIdentifier("runRecorder.announceSplits")
            Toggle("Pause when I stop", isOn: $model.autoPauses)
                .font(.callout)
                .foregroundStyle(Theme.text)
                .tint(Theme.accent)
                .accessibilityIdentifier("runRecorder.autoPause")
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
            let unit = model.unit
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    stat("Time", RunFormat.duration(moving), large: true, id: "time")
                    stat(unit.title, RunFormat.distance(meters, in: unit), large: true, id: "distance")
                }
                HStack(alignment: .firstTextBaseline) {
                    stat("Pace /\(unit.abbreviation)", RunFormat.pace(run.flatMap { RunPace.current($0, unit: unit) }),
                         id: "pace")
                    stat("Avg /\(unit.abbreviation)",
                         RunFormat.pace(RunPace.average(movingSeconds: moving, meters: meters, unit: unit)),
                         id: "averagePace")
                    stat("Heart rate", heartRate(at: context.date), id: "heartRate")
                }
            }
        }
    }

    /// The saved run (P7): time, distance and average pace frozen at the
    /// stop, the run's average heart rate, and the strap's reading live
    /// while it streams, or the run's maximum once it doesn't. The pace
    /// at the stop meant nothing after the run, so it isn't shown.
    private var summary: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let run = model.run
            // What was saved: the builder's moving time, frozen at the stop.
            let moving = run.map { $0.movingSeconds > 0 ? $0.movingSeconds : $0.activeSeconds(at: context.date) } ?? 0
            let meters = run?.distanceMeters ?? 0
            let unit = model.unit
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    stat("Time", RunFormat.duration(moving), large: true, id: "time")
                    stat(unit.title, RunFormat.distance(meters, in: unit), large: true, id: "distance")
                }
                HStack(alignment: .firstTextBaseline) {
                    stat("Avg /\(unit.abbreviation)",
                         RunFormat.pace(RunPace.average(movingSeconds: moving, meters: meters, unit: unit)),
                         id: "averagePace")
                    stat("Avg HR", Self.bpm(run?.averageHeartRate), id: "averageHeartRate")
                    if let live = model.liveHeartRate(at: context.date) {
                        stat("Heart rate", Self.bpm(live), live: true, id: "heartRate")
                    } else {
                        stat("Max HR", Self.bpm(run?.maximumHeartRate), id: "heartRate")
                    }
                }
                if let recovery = model.recovery {
                    recoveryCard(recovery, at: context.date)
                }
            }
        }
    }

    /// The cool-down while it's measured, then how far heart rate fell.
    private func recoveryCard(_ recovery: HeartRateRecoveryMeasurement, at date: Date) -> some View {
        let measuring = model.isMeasuringRecovery
        let elapsed = min(max(0, date.timeIntervalSince(recovery.stoppedAt)), HeartRateRecoveryMeasurement.duration)
        let result = recovery.result
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(measuring ? "COOLING DOWN" : "HEART RATE RECOVERY")
                    .font(Theme.mono(11, .bold)).tracking(2)
                    .foregroundStyle(Theme.muted)
                Spacer()
                if measuring {
                    Text(RunFormat.duration(elapsed))
                        .font(Theme.number(24)).monospacedDigit()
                        .foregroundStyle(Theme.text)
                }
            }
            if measuring {
                Text("Stand or walk easy for 2 minutes so your recovery compares between runs.")
                    .font(.callout).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let result, let text = result.summary {
                Text(text)
                    .font(Theme.mono(15, .bold)).foregroundStyle(Theme.text)
                Text("Drop from \(result.atStop) bpm at the stop")
                    .font(.caption).foregroundStyle(Theme.muted)
            } else if !measuring {
                Text("No reading came one or two minutes after the stop, so no recovery was kept.")
                    .font(.callout).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("runRecorder.recovery")
    }

    private static func bpm(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))" } ?? "–"
    }

    private func heartRate(at date: Date) -> String {
        guard let sample = model.latestHeartRate, model.isRecording,
              date.timeIntervalSince(sample.timestamp) < 15 else { return "–" }
        return "\(Int(sample.beatsPerMinute.rounded()))"
    }

    private func stat(_ label: String, _ value: String, large: Bool = false, live: Bool = false,
                      id: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Theme.number(large ? 40 : 24))
                .foregroundStyle(Theme.text)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            HStack(spacing: 4) {
                if live {
                    // The strap is still streaming after the run.
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text("LIVE").font(Theme.mono(11, .bold)).foregroundStyle(Theme.accent)
                }
                Text(label.uppercased()).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("runRecorder.\(id)")
    }

    @ViewBuilder private var controls: some View {
        switch model.phase {
        case .idle:
            primary("Start", systemImage: "play.fill", id: "start") { Task { await model.start() } }
        case .recovering:
            ProgressView("Checking for an unfinished run…").frame(minHeight: 56)
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
        if let workout = model.completedWorkoutName {
            Label("\(workout) is marked done.", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.done)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("runRecorder.workoutDone")
        }
        if let note = model.note {
            Text(note).font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        Text(model.isMeasuringRecovery ? "Saved on this iPhone. It uploads after the cool-down." : uploadText)
            .font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            .accessibilityIdentifier("runRecorder.upload")
    }

    private var uploadText: String {
        switch model.uploadStatus {
        case .idle: ""
        case .uploading: "Saving the run…"
        case .uploaded: "Saved in Tres Fort and sent to intervals.icu."
        case .keptInTresFort: "Saved in Tres Fort with its route."
        case .waitingForIntervals: "Saved in Tres Fort. The copy for intervals.icu retries later; check the connection in Profile if it doesn’t appear there."
        case .waiting: "Saved on this iPhone. It uploads when the iPhone is back online."
        case .notConnected: "Saved to Apple Health with its route. intervals.icu isn’t connected, so nothing else was sent."
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
        .foregroundStyle(Theme.onAccent)
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
