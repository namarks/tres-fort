import SwiftUI
import CoreImage.CIFilterBuiltins
import VisionKit

struct PartnerStationPanel: View {
    @ObservedObject var model: PartnerStationModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Train together").font(.largeTitle.bold())
            if let error = model.error { Text(error).foregroundStyle(.orange) }
            if let offer = model.offer {
                Text(offer.workout.name).font(.title2)
                if let state = model.state {
                    if offer.steps.indices.contains(state.stepIndex) {
                        let step = offer.steps[state.stepIndex]
                        Text("\(step.name) · Set \(step.set)").font(.title.bold())
                            .accessibilityIdentifier("partner.stationStep")
                        rowLayout(spacing: 20).callAsFunction {
                            lane(name: offer.hostName, slot: model.hostSlots.first { $0.hostSlotID == step.slotID },
                                 snapshot: state.host, connected: state.hostConnected, step: step)
                            lane(name: model.partnerName, slot: model.partnerSlots.first { $0.hostSlotID == step.slotID },
                                 snapshot: state.partner, connected: state.partnerConnected, step: step)
                        }
                        if let end = state.restUntil {
                            rowLayout(spacing: 8, alignment: .center).callAsFunction {
                                Text("Rest together").font(.title2)
                                    .accessibilityIdentifier("partner.stationRest")
                                Text(end, style: .timer).monospacedDigit().font(.largeTitle)
                                Button("Skip rest") { model.skipRest() }.buttonStyle(.bordered)
                            }
                        }
                    } else {
                        Text("Workout complete").font(.title.bold())
                        Text("Finish and save on each iPhone.")
                    }
                } else {
                    if let invitation = model.invitation {
                        rowLayout(spacing: 24).callAsFunction {
                            if let image = qr(invitation.code) {
                                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                                    .frame(width: 240, height: 240).padding(12).background(.white)
                                    .accessibilityLabel("Partner invitation QR code")
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                Text("On your partner’s iPhone, open Today → Train together → Scan iPad code.")
                                Text("Use separate accounts. This invitation lasts two minutes.").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let candidate = model.candidateName {
                        rowLayout(spacing: 8, alignment: .center).callAsFunction {
                            Text("Allow \(candidate) to join?").font(.title2)
                            Button("Allow") { model.allow() }.buttonStyle(.borderedProminent)
                            Button("Decline") { model.decline() }.buttonStyle(.bordered)
                        }
                    }
                    Text("\(offer.hostName): \(model.ready.contains(.host) ? "Ready" : "Connecting")")
                    Text("\(model.partnerName): \(model.ready.contains(.partner) ? "Ready" : "Review weights on iPhone")")
                    Button(model.starting ? "Starting both workouts…" : "Start together") { model.start() }
                        .buttonStyle(.borderedProminent).disabled(!model.canStart)
                        .accessibilityIdentifier("partner.startTogether")
                }
            } else { ProgressView("Requesting the workout from your iPhone…") }
            Text(StationLink.cameraCountingAvailable
                 ? "Log each set on your own iPhone. Camera counting is off during partner workouts."
                 : "Log each set on your own iPhone. Your workouts and weights stay separate.")
                .foregroundStyle(.secondary)
            Button(model.state == nil ? "Cancel setup" : "Close Station") { model.end() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("partner.stationClose")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func rowLayout(spacing: CGFloat, alignment: VerticalAlignment = .top) -> AnyLayout {
        #if APP_STORE_BUILD
        if dynamicTypeSize.isAccessibilitySize {
            return AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        }
        #endif
        return AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
    }
    private func lane(name: String, slot: PartnerDisplaySlot?, snapshot: PartnerLaneSnapshot,
                      connected: Bool, step: PartnerStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name).font(.title.bold())
            if let slot = snapshot.display?.hostSlotID == step.slotID ? snapshot.display : slot {
                Text("\(slot.weight ?? 0, specifier: "%g") \(slot.unit) · \(slot.reps) reps").font(.title2)
            }
            Text(snapshot.closed ? "Continuing alone" : !connected ? "Waiting for iPhone" :
                snapshot.logged.contains(step.id) ? "Set logged" : "Your set")
                .font(.headline).foregroundStyle(snapshot.logged.contains(step.id) ? .green : .primary)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 20))
    }
    private func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct PartnerPhoneSetup: View {
    @ObservedObject var model: PartnerPhoneModel
    @ObservedObject var sync: SyncModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var scanning = false
    var body: some View {
        NavigationStack {
            Form {
                if let error = model.error { Section { Text(error).foregroundStyle(.orange); Button("Retry") { Task { await model.retry() } }.disabled(model.busy) } }
                if let value = model.checkpoint {
                    Section(value.offer.workout.name) {
                        Text(value.lane == .host ? "Your workout is ready to share." : "Your weights")
                        Text("Each person keeps their own workout and logs.").font(.subheadline)
                    }
                    if let copy = value.copy {
                        ForEach(copy.slots) { slot in
                            Section(value.offer.workout.exercises.first { value.slotMap[$0.id] == slot.id }?.exercise_name ?? "Exercise") {
                                HStack {
                                    TextField("Weight", value: Binding(get: { slot.target_weight ?? 0 }, set: {
                                        model.changeWeight(slotID: slot.id, weight: $0, unit: slot.target_weight_unit)
                                    }), format: .number).keyboardType(.decimalPad)
                                    Picker("Unit", selection: Binding(get: { slot.target_weight_unit }, set: {
                                        model.changeWeight(slotID: slot.id, weight: slot.target_weight ?? 0, unit: $0)
                                    })) { Text("lb").tag("lb"); Text("kg").tag("kg") }.frame(width: 100)
                                }.disabled(value.phase != .reviewing)
                                Text("\(slot.target_sets) sets · \(slot.target_reps) reps")
                                if slot.is_warmup == 1 || !sync.sets.contains(where: {
                                    $0.exercise_id == slot.exercise_id && $0.is_warmup == 0 && $0.deleted_at == nil
                                }) { Text("Check — copied from the host").foregroundStyle(.orange) }
                            }
                        }
                    }
                    Section {
                        if model.needsReview {
                            Button(value.phase == .saving ? "Retry saving workout" : "Save workout and get ready") { Task { await model.ready() } }
                                .disabled(model.busy).accessibilityIdentifier("partner.ready")
                        } else { Text(value.phase == .active ? "Training together" : "Waiting for Start on the iPad") }
                        if value.start != nil {
                            Button("Continue alone") { Task { await model.leave(cancel: false); if model.checkpoint == nil { dismiss() } } }.disabled(model.busy)
                        }
                        if value.phase != .active {
                            Button("Cancel empty start", role: .destructive) { Task { await model.leave(cancel: true); if model.checkpoint == nil { dismiss() } } }.disabled(model.busy)
                        }
                    }
                } else {
                    Section("Join a partner") {
                        TextField("Your name", text: $model.name).textContentType(.givenName)
                        Button("Scan iPad code") { scanning = true }.disabled(model.joining)
                            .accessibilityIdentifier("partner.scan")
                        TextField("Or paste a join code", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Join") { model.join(code) }.disabled(code.isEmpty || model.joining)
                        if model.joining { ProgressView("Waiting for the host to allow you…"); Button("Cancel") { model.stopJoin() } }
                    }
                    Section("Host on your iPad") {
                        Text("Open a workout on your iPhone and turn on iPad Station. Connect Station on your iPad, then tap Train together before logging any sets.")
                    }
                }
            }
            .navigationTitle("Train together")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $scanning) {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    PartnerCodeScanner { value in scanning = false; model.join(value) }
                        .ignoresSafeArea()
                } else { ContentUnavailableView("Camera unavailable", systemImage: "qrcode.viewfinder", description: Text("Allow camera access in Settings, or paste a join code.")) }
            }
        }
    }
}

struct PartnerPhoneRunner: View {
    @ObservedObject var model: PartnerPhoneModel
    @ObservedObject var sync: SyncModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Training together").font(.title.bold())
                if !model.connected { Text("iPad disconnected. Your lane stays on this step. Reconnect or continue alone.").foregroundStyle(.orange) }
                if let error = model.error { Text(error).foregroundStyle(.orange); Button("Retry") { Task { await model.retry() } } }
                if sync.partnerControl?.complete == true {
                    Text("All steps complete").font(.title2)
                    Button("Finish my workout") {
                        Task { await model.leave(cancel: false); if model.checkpoint == nil { await sync.finishWorkout() } }
                    }.buttonStyle(.borderedProminent)
                } else if let ex = sync.currentExercise {
                    Text(ex.exercise_name).font(.title2.bold())
                    Text("Set \(sync.currentPhysicalSetNumber) of \(ex.target_sets)")
                    HStack {
                        TextField("Weight", value: $sync.weight, format: .number).keyboardType(.decimalPad)
                        Text(ex.targetWeightUnit.rawValue)
                        if !ex.isTimed { Stepper("\(sync.reps) reps", value: $sync.reps, in: 1...100) }
                    }.disabled(sync.isSetEntryBlocked(ex))
                    if ex.isTimed {
                        if sync.timedActive, let end = sync.timedEndDate {
                            Text(end, style: .timer).font(.largeTitle).monospacedDigit()
                            Button("Stop and log") { Task { await sync.stopTimedSet() } }
                        } else {
                            Stepper("\(sync.holdDurationSeconds) seconds", value: $sync.holdDurationSeconds, in: 1...3600)
                            Button("Start timed set") { sync.startTimedSet(expected: ex, expectedSetNumber: sync.currentPhysicalSetNumber) }
                                .disabled(sync.isSetEntryBlocked(ex)).buttonStyle(.borderedProminent)
                        }
                    } else {
                        let set = sync.currentPhysicalSetNumber
                        Button(sync.isSetEntryBlocked(ex) ? "Waiting for this step" : "Log my set") {
                            Task { await sync.logCurrentSet(expected: ex, expectedSetNumber: set) }
                        }.buttonStyle(.borderedProminent).disabled(sync.isSetEntryBlocked(ex))
                            .accessibilityIdentifier("partner.logSet")
                    }
                    if let end = sync.restEndDate {
                        HStack { Text("Rest together"); Text(end, style: .timer).monospacedDigit(); Button("Skip rest") { model.skipRest() } }
                    }
                    Button("Skip this set for both") { sync.skip() }.disabled(!model.connected || sync.timedActive)
                } else { ProgressView("Recovering your workout…") }
                LastRunnerSetReview(sync: sync, compact: false)
                DisclosureGroup("Your logged sets") {
                    SetReviewList(sync: sync, sets: sync.sets.filter { $0.session_id == sync.todaySession?.id && $0.deleted_at == nil },
                                  pending: sync.setOutbox.pending.filter { $0.date == sync.todayString })
                }
                Button("Continue alone") { Task { await model.leave(cancel: false) } }.disabled(model.busy)
                Text("Your sets are saved on this iPhone, including while offline.").font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
}

private struct PartnerCodeScanner: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) { scanner.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let scanned: (String) -> Void
        private var consumed = false
        init(scanned: @escaping (String) -> Void) { self.scanned = scanned }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !consumed else { return }
            for case .barcode(let code) in addedItems {
                guard let text = code.payloadStringValue, text.hasPrefix("tresfort-partner:") else { continue }
                consumed = true; scanner.stopScanning(); scanned(text); return
            }
        }
    }
}
