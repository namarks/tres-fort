import Charts
import SwiftUI

struct BodyWeightView: View {
    @ObservedObject var model: BodyWeightModel
    var onManageAccess: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @State private var days = 30
    @State private var unit: BodyWeightUnit = Locale.current.measurementSystem == .us ? .pounds : .kilograms

    var body: some View {
        Form {
            if model.requiresPersonalSignIn {
                Section { Text("Sign in with your personal account to view Apple Health weight.") }
            } else if !model.isAvailable {
                Section { Text("Apple Health isn’t available on this device.") }
            } else if !model.enabled {
                Section {
                    Text("Weight is optional").font(.headline)
                    Text("Enable weight access in Apple Health settings to see measurements and trends here.")
                    Button("Manage Apple Health", action: onManageAccess)
                        .accessibilityIdentifier("weight.manageAccess")
                }
            } else {
                if let history = model.history, let latest = history.latest {
                    Section("Latest measurement") {
                        LabeledContent("Weight", value: formatted(latest.kilograms))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Latest weight")
                            .accessibilityValue(formatted(latest.kilograms))
                            .accessibilityIdentifier("weight.latest")
                        Text(latest.date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                        Text("From \(latest.source)").font(.footnote).foregroundStyle(.secondary)
                        if let average = history.average(ending: history.asOf) {
                            LabeledContent("7-day average", value: formatted(average))
                        }
                    }
                    trend(history)
                } else if model.enabled && !model.isBusy && model.errorMessage == nil {
                    Section {
                        Text("No weight yet").font(.headline)
                            .accessibilityIdentifier("weight.empty")
                        Text("Add weight in Health or enable weight sharing in your scale’s app. If you already have readings, check weight access for Très Fort in Health → your profile → Apps.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.orange)
                    }
                    if model.isBusy {
                        HStack {
                            ProgressView()
                            Text(model.isConnecting ? "Requesting access…" : "Reading weight…")
                        }
                    } else {
                        Button("Refresh weight") { Task { await model.refresh() } }
                        .accessibilityIdentifier("weight.connectOrRefresh")
                    }
                } footer: {
                    Text("Read your weight from Apple Health, including measurements shared by Withings and other scales. Weight stays on this device and is visible only to you in Très Fort.")
                }

            }
        }
        .navigationTitle("Weight")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Apple Health", action: onManageAccess)
                    .accessibilityIdentifier("weight.settings")
            }
        }
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
        .refreshable { await model.refresh() }
    }

    private func formatted(_ kilograms: Double) -> String {
        "\(unit.value(kilograms).formatted(.number.precision(.fractionLength(1)))) \(unit.rawValue)"
    }

    private func trend(_ history: BodyWeightHistory) -> some View {
        let points = history.recentDays(days)
        let values = points.map { unit.value($0.kilograms) }
            + points.compactMap { history.average(ending: $0.date).map(unit.value) }
        let lower = (values.min() ?? 0) - 1
        let upper = (values.max() ?? 1) + 1
        return Section {
            Picker("Period", selection: $days) {
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }.pickerStyle(.segmented)
            Picker("Unit", selection: $unit) {
                ForEach(BodyWeightUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if points.count > 1 {
                Chart(points) { point in
                    PointMark(x: .value("Date", point.date), y: .value(unit.rawValue, unit.value(point.kilograms)))
                        .foregroundStyle(by: .value("Measurement", "Daily weight"))
                    if let average = history.average(ending: point.date) {
                        LineMark(x: .value("Date", point.date), y: .value(unit.rawValue, unit.value(average)))
                            .foregroundStyle(by: .value("Measurement", "7-day average"))
                    }
                }
                .chartForegroundStyleScale(["Daily weight": Color.secondary, "7-day average": Theme.accent])
                .chartYScale(domain: lower...upper)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                .frame(height: 210)
                .accessibilityIdentifier("weight.chart")
            } else {
                Text(points.isEmpty ? "No measurements in the last \(days) days." : "Another day’s measurement will start your trend.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Trend")
        } footer: {
            Text("Uses the latest measurement each day. The 7-day average includes only days with a measurement; missing days are left out.")
        }
    }
}
