import Foundation
import HealthKit
import SwiftUI

/// Deleting a run recorded in the app (docs/plans/run-recorder P5(d)). The
/// owner chose that delete removes every copy the app made: the run and its
/// route in Tres Fort, its intervals.icu upload (the server deletes that
/// first, and deletes nothing when it can't), and the Apple Health workout
/// the recorder saved, which only the app can delete.

/// `DELETE /api/activities/recordings/:id`.
struct RecordedRunDeleteResponse: Decodable, Equatable {
    struct Intervals: Decodable, Equatable {
        /// deleted, not_found (never uploaded) or not_connected.
        let status: String
    }

    let recording_id: String
    let intervals: Intervals
    /// Synced Apple Health copies the server hid for good.
    let health_removed: Int
}

extension APIClient {
    /// Deletes the recording and its intervals.icu upload, and hides the named
    /// Apple Health workouts' synced copies.
    func deleteRecordedRun(recordingID: String, healthWorkoutIDs: [UUID],
                           jwt: String) async throws -> RecordedRunDeleteResponse {
        var path = "api/activities/recordings/\(recordingID.lowercased())"
        if !healthWorkoutIDs.isEmpty {
            path += "?" + healthWorkoutIDs.map { "health_workout_id=\($0.uuidString)" }.joined(separator: "&")
        }
        return try await delete(path, jwt: jwt)
    }
}

/// The Apple Health workouts the recorder saved for a recording, found by the
/// external UUID it tags them with (`RunRecordingHealthTag`).
struct RecordedRunHealthCopies {
    /// Nil when Health couldn't be searched.
    var find: (_ recordingID: UUID) async -> [UUID]?
    /// Deletes the workouts with their route and the strap's heart rate.
    /// False when Health kept any of them. A workout whose samples Health
    /// won't delete (sharing turned off since) is kept too, so trying again
    /// still finds it by its tag.
    var delete: (_ workoutIDs: [UUID]) async -> Bool

    static var live: RecordedRunHealthCopies {
        let store = HKHealthStore()
        return RecordedRunHealthCopies(
            find: { recordingID in
                guard HKHealthStore.isHealthDataAvailable() else { return [] }
                return await workouts(taggedFor: recordingID, in: store)?.map(\.uuid)
            },
            delete: { ids in
                guard HKHealthStore.isHealthDataAvailable(), !ids.isEmpty else { return true }
                let workouts = await workouts(withIDs: ids, in: store) ?? []
                var kept = workouts.count < ids.count
                for workout in workouts {
                    // Samples the app saved with the workout go first, and
                    // the workout only once none is left.
                    let attached = NSCompoundPredicate(andPredicateWithSubpredicates: [
                        HKQuery.predicateForObjects(from: workout),
                        HKQuery.predicateForObjects(from: HKSource.default()),
                    ])
                    var samplesLeft = false
                    for type in [HKSeriesType.workoutRoute(), HKQuantityType(.heartRate)] as [HKSampleType] {
                        // Nothing saved of this type (or sharing it was
                        // never allowed): nothing to delete.
                        if let found = await samples(of: type, matching: attached, limit: 1, in: store),
                           found.isEmpty { continue }
                        if !(await deleteObjects(of: type, matching: attached, in: store)) { samplesLeft = true }
                    }
                    let own = HKQuery.predicateForObjects(with: [workout.uuid])
                    if samplesLeft {
                        kept = true
                    } else if !(await deleteObjects(of: HKObjectType.workoutType(), matching: own, in: store)) {
                        kept = true
                    }
                }
                return !kept
            })
    }

    private static func workouts(taggedFor recordingID: UUID, in store: HKHealthStore) async -> [HKWorkout]? {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyExternalUUID,
            allowedValues: [RunRecordingHealthTag.externalID(for: recordingID)])
        return await samples(of: HKObjectType.workoutType(), matching: predicate, limit: 10, in: store)?
            .compactMap { $0 as? HKWorkout }
    }

    private static func workouts(withIDs ids: [UUID], in store: HKHealthStore) async -> [HKWorkout] {
        (await samples(of: HKObjectType.workoutType(), matching: HKQuery.predicateForObjects(with: Set(ids)),
                       limit: 10, in: store) ?? [])
            .compactMap { $0 as? HKWorkout }
    }

    /// Nil when the query failed.
    private static func samples(of type: HKSampleType, matching predicate: NSPredicate, limit: Int,
                                in store: HKHealthStore) async -> [HKSample]? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: limit, sortDescriptors: nil) { _, samples, error in
                continuation.resume(returning: error == nil ? samples ?? [] : nil)
            }
            store.execute(query)
        }
    }

    private static func deleteObjects(of type: HKObjectType, matching predicate: NSPredicate,
                                      in store: HKHealthStore) async -> Bool {
        await withCheckedContinuation { continuation in
            store.deleteObjects(of: type, predicate: predicate) { success, _, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

/// What the member is told after asking to delete a run.
enum RecordedRunDeleteOutcome: Equatable {
    /// Gone from Tres Fort; the message names where else it went from, and
    /// anything that kept a copy.
    case deleted(String)
    /// Nothing was deleted.
    case failed(String)
}

enum RecordedRunDeletion {
    /// Finds the run's Health workouts, asks the server to delete the run and
    /// its intervals.icu upload, then deletes the Health workouts. Health is
    /// changed only after the server succeeded, so a refused delete leaves
    /// every copy in place. A run the server already deleted (an earlier try
    /// whose answer was lost, or another device) still has its Health
    /// workouts deleted here.
    static func delete(
        recordingID: String,
        health: RecordedRunHealthCopies,
        server: (_ recordingID: String, _ healthWorkoutIDs: [UUID]) async throws -> RecordedRunDeleteResponse
    ) async -> RecordedRunDeleteOutcome {
        guard let uuid = UUID(uuidString: recordingID) else {
            return .failed("This run can’t be deleted from the app.")
        }
        // Without knowing the Health workouts, deleting the run would leave
        // them behind with nothing in the app to delete them from.
        guard let healthIDs = await health.find(uuid) else {
            return .failed("Apple Health couldn’t be checked for this run’s workout, so nothing was deleted. "
                + "Try again in a moment.")
        }
        let intervals: String?
        do {
            intervals = try await server(recordingID, healthIDs).intervals.status
        } catch let error as APIError where error.httpStatus == 404 {
            intervals = nil
        } catch let error as APIError {
            return failure(error)
        } catch {
            return .failed("The run couldn’t be deleted. Check your connection and try again.")
        }
        let healthDeleted = healthIDs.isEmpty ? nil : await health.delete(healthIDs)
        guard let intervals else { return .deleted(alreadyDeleted(healthDeleted: healthDeleted)) }
        return .deleted(message(intervals: intervals, healthDeleted: healthDeleted))
    }

    static func message(intervals: String, healthDeleted: Bool?) -> String {
        var places = ["Tres Fort"]
        if healthDeleted == true { places.append("Apple Health") }
        if intervals == "deleted" { places.append("intervals.icu") }
        let list = places.count > 2
            ? places.dropLast().joined(separator: ", ") + " and " + places.last!
            : places.joined(separator: " and ")
        var text = "Run deleted from \(list)."
        if healthDeleted == false {
            text += " Apple Health kept its copy; you can delete it in the Health app."
        }
        return text
    }

    static func alreadyDeleted(healthDeleted: Bool?) -> String {
        switch healthDeleted {
        case true?: "This run was already deleted. Its Apple Health workout is deleted now too."
        case false?: "This run was already deleted. Apple Health kept its copy; you can delete it in the Health app."
        case nil: "This run was already deleted."
        }
    }

    private static func failure(_ error: APIError) -> RecordedRunDeleteOutcome {
        let code = error.httpBody.flatMap { body in
            (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        }?["error"] as? String
        switch (error.httpStatus ?? 0, code) {
        case (401, _):
            return .failed("Sign in again, then try deleting the run.")
        case (_, "intervals_write_forbidden"):
            return .failed("intervals.icu didn’t let Tres Fort delete its copy, so nothing was deleted. "
                + "Reconnect intervals.icu in Profile, then try again.")
        case (_, "intervals_unavailable"), (_, "intervals_rejected"):
            return .failed("intervals.icu couldn’t delete its copy right now, so nothing was deleted. "
                + "Try again in a moment.")
        default:
            return .failed("The run couldn’t be deleted. Try again in a moment.")
        }
    }
}

extension ExternalActivity {
    /// The recording behind this activity, when it is a run recorded in the
    /// app: the recording itself, or (from its route) the intervals.icu copy
    /// of one.
    func recordedRunID(routeRecordingID: String?) -> String? {
        if source == "recording" { return external_id }
        if source == "intervals", kind == "run" { return routeRecordingID }
        return nil
    }
}

/// "Delete run" under a recorded run, with a confirmation. The outcome is
/// shown by the screen (`recordedRunDeleteAlert`), since a deleted run's card
/// goes away.
struct RecordedRunDeleteButton: View {
    let recordingID: String
    let delete: (_ recordingID: String) async -> Void
    @State private var confirming = false
    @State private var deleting = false

    var body: some View {
        Button(role: .destructive) {
            confirming = true
        } label: {
            HStack(spacing: 6) {
                if deleting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "trash")
                }
                Text(deleting ? "Deleting…" : "Delete run")
            }
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderless)
        .tint(Theme.danger)
        .disabled(deleting)
        .accessibilityIdentifier("activity.deleteRecordedRun")
        .confirmationDialog("Delete this run?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete Run", role: .destructive) {
                Task {
                    deleting = true
                    await delete(recordingID)
                    deleting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It’s removed from Tres Fort, Apple Health and intervals.icu, with its route. This can’t be undone.")
        }
    }
}

extension View {
    /// What happened to a run the member asked to delete.
    func recordedRunDeleteAlert(_ outcome: Binding<RecordedRunDeleteOutcome?>) -> some View {
        alert(outcome.wrappedValue.title, isPresented: Binding(
            get: { outcome.wrappedValue != nil }, set: { if !$0 { outcome.wrappedValue = nil } })) {
            Button("OK", role: .cancel) { outcome.wrappedValue = nil }
        } message: {
            Text(outcome.wrappedValue?.message ?? "")
        }
    }
}

extension RecordedRunDeleteOutcome {
    var message: String {
        switch self {
        case let .deleted(text), let .failed(text): text
        }
    }
}

private extension Optional where Wrapped == RecordedRunDeleteOutcome {
    var title: String {
        if case .failed? = self { return "Run not deleted" }
        return "Run deleted"
    }
}
