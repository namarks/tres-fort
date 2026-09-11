#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftUI

/// Explicit, simulator-only launch fixtures. Release/device builds contain none
/// of this code. An unknown fixture fails closed before constructing real auth.
enum UIFixtureScenario: String, CaseIterable {
    case signIn = "sign-in", empty, loadFailure = "load-failure"
    case ordinary, bodyweight, timed, pending, onboarding, groups, library
    case appStore = "app-store"
    case groupSafety = "group-safety"
    case timedNavigation = "timed-navigation", timedPreviewCompletion = "timed-preview-completion"
    var isTimerNavigation: Bool { self == .timedNavigation || self == .timedPreviewCompletion }
    case planChanges = "plan-changes"
    case activationOwner = "activation-owner", activationInvite = "activation-invite"
    case activationManual = "activation-manual", activationCoach = "activation-coach"
    case serverFailure = "server-failure", cachedEmpty = "cached-empty", cachedPlan = "cached-plan"
    var isActivation: Bool { rawValue.hasPrefix("activation-") }
    case historySmall = "history-small", historyLarge = "history-large"

    case intervalsConnect = "intervals-connect", intervalsRetry = "intervals-retry"
    case intervalsReauth = "intervals-reauth"
    var isIntervals: Bool { rawValue.hasPrefix("intervals-") }

    case historyProgress = "history-progress"

    var isHistory: Bool { self == .historySmall || self == .historyLarge || self == .historyProgress }
    case correctionFailure = "correction-failure", readyToFinish = "ready-to-finish"

    static let selected: Self? = {
        guard let raw = ProcessInfo.processInfo.environment["TRESFORT_UI_FIXTURE"] else { return nil }
        guard let value = Self(rawValue: raw) else { fatalError("Unknown synthetic UI fixture") }
        return value
    }()
}

private final class FixtureTokenStore: AppTokenStore {
    func load() -> String? { nil }
    func save(_ token: String) {}
    func clear() {}
}

@MainActor
enum UIFixtureModel {
    // One synthetic namespace; reset before every launch. Never load Keychain
    // or the standard defaults used by an installed user's account.
    static let defaults: LocalPersistence = {
        let name = "com.nmarkspdx.tresfort.synthetic-ui"
        let value = LocalPersistence(suiteName: name)!
        if ProcessInfo.processInfo.environment["TRESFORT_UI_REUSE_PLAN_CHANGES"] != "1"
            && ProcessInfo.processInfo.environment["TRESFORT_UI_REUSE_FEEDBACK"] != "1"
            && !(UIFixtureScenario.selected?.isHistory == true && ProcessInfo.processInfo.environment["TRESFORT_UI_REUSE_HISTORY"] == "1") {
            value.removePersistentDomain(forName: name)
        }
        return value
    }()
    static func makeAuth() -> AuthModel {
        let auth = AuthModel(tokenStore: FixtureTokenStore(), defaults: defaults)
        if UIFixtureScenario.selected != .signIn && UIFixtureScenario.selected?.isActivation != true {
            auth.userID = "synthetic-ui-user"
            auth.jwt = UIFixtureScenario.selected?.isIntervals == true || [.appStore, .groupSafety].contains(UIFixtureScenario.selected)
                ? UIFixtureServer(scenario: UIFixtureScenario.selected!).syntheticJWT : "synthetic-ui-bearer"
            auth.onboardingComplete = UIFixtureScenario.selected != .onboarding
            auth.phase = .signedIn
        }
        if UIFixtureScenario.selected == .activationInvite {
            auth.handleDeepLink(Config.apiBaseURL.appendingPathComponent("join/ABC234"))
        }
        if let scenario = UIFixtureScenario.selected, [.cachedEmpty, .cachedPlan].contains(scenario) {
            let plan = scenario == .cachedEmpty ? nil : PlanTree(id: "cached-plan", name: "Saved training", version: 1, workouts: [], meta: nil)
            StateSnapshotStore.save(StateResponse(plan: plan, plan_version: plan == nil ? 0 : 1,
                sessions: [], sets: [], external_events: [], external_activities: [], activities: [], server_time: 1),
                userID: auth.userID, defaults: defaults)
        }
        if let scenario = UIFixtureScenario.selected, scenario.isHistory,
           ProcessInfo.processInfo.environment["TRESFORT_UI_REUSE_HISTORY"] != "1" {
            let history = scenario == .historyProgress ? HistoryFixtureData.progressDataset()
                : HistoryFixtureData.dataset(sessionCount: scenario == .historySmall ? 12 : 1_040)
            let state = StateResponse(plan: PlanTree(id: "synthetic-plan", name: "Synthetic history", version: 1, workouts: [], meta: nil),
                plan_version: 1, sessions: history.sessions, sets: history.sets,
                external_events: [], external_activities: [], activities: [], server_time: history.server_time)
            StateSnapshotStore.save(state, userID: auth.userID, defaults: defaults)
            let catalog = (0..<40).map { ExerciseCatalog(id: "exercise-\($0)", name: "Exercise \($0)",
                primary_muscle: "legs", modality: "barbell", unit: "lb", laterality: nil, load_mode: nil, demo_slug: nil) }
            ExerciseCatalogSnapshotStore.save(catalog, userID: auth.userID, defaults: defaults)
            _ = StateSyncAccountStore.activate(userID: auth.userID, defaults: defaults)

        }
        return auth
    }
}

struct UIFixtureView: View {
    @Environment(\.dynamicTypeSize) private var systemDynamicTypeSize
    @ObservedObject var auth: AuthModel
    let scenario: UIFixtureScenario

    var body: some View {
        Group {
            if scenario == .appStore {
                // Capture the production view hierarchy with fictional data.
                // QA fixtures retain their banner; this dedicated asset mode
                // is excluded from release and physical-device builds.
                RootView(defaults: UIFixtureModel.defaults,
                         now: { CalendarProjection.date(from: "2026-09-08")! }).environmentObject(auth)
            } else if scenario == .signIn || scenario.isActivation || scenario.isIntervals || scenario == .groupSafety {
                VStack(spacing: 0) {
                    Text("SYNTHETIC · \(scenario.rawValue)")
                        .font(.caption).dynamicTypeSize(.large)
                        .accessibilityIdentifier("fixture.scenario")
                    RootView(defaults: UIFixtureModel.defaults,
                             now: { CalendarProjection.date(from: "2026-09-08")! }).environmentObject(auth)
                }
            } else {
                UIFixtureTrainingView(auth: auth, scenario: scenario)
            }
        }
        .defaultAppStorage(UIFixtureModel.defaults.preferences)
        .tint(Theme.accent)
        .environment(\.openURL, OpenURLAction { _ in .discarded })
        .environment(\.dynamicTypeSize,
            ProcessInfo.processInfo.environment["TRESFORT_UI_LARGE_TEXT"] == "1" ? .accessibility5 : systemDynamicTypeSize)
    }
}

/// RootView owns its own SyncModel. Construct the standalone training model
/// only for fixtures that render it, so an unused subscriber cannot supersede
/// the visible app's state request in the shared account snapshot store.
private struct UIFixtureTrainingView: View {
    @ObservedObject var auth: AuthModel
    let scenario: UIFixtureScenario
    @StateObject private var sync: SyncModel

    init(auth: AuthModel, scenario: UIFixtureScenario) {
        self.auth = auth
        self.scenario = scenario
        _sync = StateObject(wrappedValue: SyncModel(
            auth: auth, defaults: UIFixtureModel.defaults,
            now: { scenario.isTimerNavigation ? Date() : CalendarProjection.date(from: "2026-09-08")! },
            restActivityUpdater: { _, _ in }, restActivityEnder: {},
            restNotificationCanceller: {}))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("SYNTHETIC · \(scenario.rawValue)")
                .font(.caption).dynamicTypeSize(.large)
                .accessibilityIdentifier("fixture.scenario")
                .accessibilityValue(Text(verbatim: fixtureEvidence))
            if scenario == .onboarding && !auth.onboardingComplete {
                OnboardingView(auth: auth)
            } else if scenario.isHistory {
                HistoryView(sync: sync)
            } else {
                TodayView(sync: sync, auth: auth)
            }
        }
        .task {
            guard !scenario.isHistory else { return }
            await sync.load()
            if ProcessInfo.processInfo.environment["TRESFORT_UI_REUSE_FEEDBACK"] == "1" { return }
            if ![.empty, .loadFailure, .serverFailure, .cachedEmpty, .cachedPlan, .onboarding, .groups, .library, .planChanges].contains(scenario) {
                sync.startWorkout()
                if scenario.isTimerNavigation {
                    sync.jump(to: 1)
                }
                if [.readyToFinish, .correctionFailure].contains(scenario) {
                    sync.finished = true
                }
                if scenario == .pending, let exercise = sync.currentExercise {
                    await sync.logCurrentSet(expected: exercise, expectedSetNumber: sync.currentPhysicalSetNumber)
                    sync.skipRest()
                }
            }
        }
    }

    private var fixtureEvidence: String {
        if scenario.isHistory { return "\(sync.sets.count) sets" }
        guard scenario.isTimerNavigation else { return "" }
        let bike = sync.sets.filter { $0.template_exercise_id == "synthetic-bike" }
        return "bike:\(bike.count);other:\(sync.sets.count - bike.count);seconds:\(bike.first?.duration_s ?? 0);warmup:\(bike.first?.is_warmup ?? 0)"
    }
}

/// This ephemeral URLSession has exactly one protocol. Every request is either
/// answered from memory or rejected; no request is forwarded to a network.
final class UIFixtureProtocol: URLProtocol {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UIFixtureProtocol.self]
        return URLSession(configuration: config)
    }()
    private static let lock = NSLock()
    private static var server = UIFixtureServer(scenario: UIFixtureScenario.selected ?? .empty)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let result = Result { try Self.server.respond(request) }
        Self.lock.unlock()
        do {
            let (status, data) = try result.get()
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// A bounded transport fixture, not a second implementation of the backend.
/// Stateful responses exist only for the creation/log/correction/finish smoke.
private struct UIFixtureServer {
    let scenario: UIFixtureScenario
    var plan: [String: Any]?
    var sessions: [[String: Any]] = []
    var sets: [[String: Any]] = []
    var groupReceipts: [String: [String: Any]] = [:]
    var returnedFeedbackConflict = false
    var failCreatedWorkoutRefresh = false
    var failedEnsureRequest = false
    var returnedMoveConflict = false
    var signInAttempts = 0
    var stateAttempts = 0
    var inviteAttempts = 0
    var joined = false
    var coachConnected = false
    var intervalsConnected = false
    var intervalsReauth = false
    var intervalsPending = false
    var intervalsGeneration = 0
    var importedActivities: [[String: Any]] = []
    var intervalsStatus: [String: Any] {
        ["connected": intervalsConnected, "needs_reauth": intervalsReauth,
         "athlete_id": intervalsConnected ? "synthetic-athlete" as Any : NSNull(),
         "credential_generation": intervalsGeneration, "sync_pending": intervalsPending,
         "last_synced_at": intervalsConnected && !intervalsPending ? revision as Any : NSNull()]
    }
    mutating func importIntervalsActivity() {
        importedActivities = [["id": "synthetic-imported-ride", "source": "intervals", "external_id": "ride-1",
            "date": "2026-09-08", "kind": "ride", "name": "Morning ride", "start_date_local_ms": revision,
            "duration_s": 1800, "load": 25, "synced_at": revision]]
    }
    var syntheticUserID: String { scenario == .activationOwner ? "synthetic-owner" : "synthetic-ui-user" }
    var syntheticJWT: String {
        let data = try! JSONSerialization.data(withJSONObject: ["sub": syntheticUserID, "exp": 4_000_000_000], options: [.sortedKeys])
        return "header." + data.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".synthetic"
    }
    let safetyPeerID = "c3223561-0e27-4727-b369-681078533ca6"
    var safetyBlocked = false
    var safetyRestricted = false
    var syntheticGroup: [String: Any] {
        var members: [[String: Any]] = [["group_id": "synthetic-group", "user_id": syntheticUserID,
            "display_name": "Synthetic member", "effective_display_name": "Synthetic member", "joined_at": 1]]
        if scenario == .groupSafety && !safetyBlocked {
            members.append(["group_id": "synthetic-group", "user_id": safetyPeerID,
                "display_name": "Sample member", "effective_display_name": "Sample member", "joined_at": 2])
        }
        return ["id": "synthetic-group", "name": "Synthetic Crew", "created_by": "synthetic-owner", "created_at": 1, "members": members]
    }
    var planRestored = false
    var revision = 1_788_912_000_000
    let dayID = "synthetic-day", sessionID = "synthetic-session"

    init(scenario: UIFixtureScenario) {
        self.scenario = scenario
        if scenario == .groupSafety { joined = true }
        coachConnected = [.activationOwner, .activationCoach, .activationInvite].contains(scenario)
        if ![.signIn, .empty, .loadFailure, .serverFailure, .cachedEmpty, .cachedPlan, .onboarding, .activationManual].contains(scenario) {
            plan = makePlan()
            sessions = [.groups, .library, .planChanges].contains(scenario) ? [] : [makeSession()]
            if scenario == .planChanges { plan?["version"] = 3 }
            if [.readyToFinish, .correctionFailure].contains(scenario) {
                sets = [["id": "synthetic-set", "session_id": sessionID,
                    "exercise_id": "synthetic-exercise", "template_exercise_id": "synthetic-slot",
                    "set_index": 1, "weight": 45, "reps": 5, "is_warmup": 0,
                    "logged_at": revision, "updated_at": revision, "is_timed": 0]]
            }
        }
        if scenario.isIntervals { sessions = [] }
        if scenario == .appStore {
            sessions = AppStoreScreenshotData.sessions
            sets = AppStoreScreenshotData.sets
            if ProcessInfo.processInfo.environment["TRESFORT_UI_UNASSIGNED_DATE"] == "1" {
                sessions.append(["id": "unassigned-date", "date": "2026-09-09",
                    "status": "planned", "workout_id": NSNull(), "attempt": 1,
                    "updated_at": revision, "write_protocol": "attempt-v1"])
            }
            if let status = ProcessInfo.processInfo.environment["TRESFORT_UI_UNRESOLVED_TODAY"] {
                var unresolved = makeSession(status: status)
                unresolved["workout_id"] = status == "planned" ? NSNull() : "removed-workout" as Any
                sessions.append(unresolved)
                if status == "planned" { plan?["meta"] = "{}" }
                if status == "in_progress", var set = sets.first {
                    set["id"] = "unresolved-set"; set["session_id"] = sessionID
                    sets.append(set)
                }
            }
        }
        if scenario == .intervalsReauth {
            intervalsReauth = true
            importIntervalsActivity()
        }
        if let fixture = coachingFixture {
            sessions = [fixture["session"] as! [String: Any]]
            sets = fixture["sets"] as! [[String: Any]]
            let meta = try! JSONSerialization.data(withJSONObject: fixture["meta"]!)
            plan?["meta"] = String(decoding: meta, as: UTF8.self)
        }

    }

    var coachingFixture: [String: Any]? {
        guard let raw = ProcessInfo.processInfo.environment["TRESFORT_UI_COACHING_CONTRACT"],
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // The same contract is consumed by real-D1 and unit tests. Only the UI
    // test bundle carries the file; the app receives it via launch environment.
    var groupFixture: [String: Any] {
        guard let raw = ProcessInfo.processInfo.environment["TRESFORT_UI_GROUP_CONTRACT"],
              let data = raw.data(using: .utf8),
              let fixture = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            preconditionFailure("Missing synthetic group contract")
        }
        return fixture
    }

    func makeSession(status: String = "in_progress", attempt: Int = 1) -> [String: Any] {
        ["id": sessionID, "date": scenario.isTimerNavigation ? CalendarProjection.dateString(Date()) : "2026-09-08", "status": status,
         "workout_id": dayID, "updated_at": revision,
         "attempt": attempt, "write_protocol": "attempt-v1"]
    }
    func makePlan(name: String = "Synthetic Training", workouts: Bool = true) -> [String: Any] {
        if scenario == .appStore { return AppStoreScreenshotData.plan }
        if scenario.isTimerNavigation {
            let slots: [[String: Any]] = [
                ["id": "synthetic-squat", "exercise_id": "synthetic-squat-exercise",
                 "exercise_name": "Goblet Squat", "exercise_modality": "dumbbell",
                 "exercise_unit": "lb", "order_index": 0, "target_sets": 2,
                 "target_reps": 8, "target_weight": 25, "rest_seconds": 60],
                ["id": "synthetic-bike", "exercise_id": "synthetic-bike-exercise",
                 "exercise_name": "Stationary Bike", "exercise_modality": "cardio",
                 "exercise_unit": "lb", "order_index": 1, "target_sets": 1,
                 "target_reps": 1, "target_duration_s": scenario == .timedNavigation ? 300 : 15,
                 "is_warmup": 1, "rest_seconds": 0],
                ["id": "synthetic-pushup", "exercise_id": "synthetic-pushup-exercise",
                 "exercise_name": "Push-Up", "exercise_modality": "bw",
                 "exercise_unit": "lb", "order_index": 2, "target_sets": 2,
                 "target_reps": 10, "rest_seconds": 60]
            ]
            return ["id": "synthetic-plan", "name": name, "version": 1,
                "meta": "{\"schedule\":{\"version\":1,\"week\":{\"\(CalendarProjection.weekdayKey(for: Date()))\":\"synthetic-day\"}}}",
                "days": [["id": dayID, "name": "Strength + Bike", "order_index": 0,
                          "exercises": slots]]]
        }
        if scenario == .library {
            return ["id": "synthetic-plan", "name": "My Workouts", "version": 1,
                "meta": "{\"schedule\":{\"version\":1,\"week\":{\"tue\":\"synthetic-day\"}}}",
                "days": [["id": dayID, "name": "Gym", "order_index": 0, "exercises": []],
                         ["id": "hotel", "name": "Hotel", "order_index": 1, "exercises": []]]]
        }
        if scenario == .groups {
            return ["id": "synthetic-plan", "name": groupFixture["name"]!, "version": 1,
                "meta": "{\"schedule\":{\"version\":1,\"week\":{\"tue\":\"synthetic-day\"}}}",
                "days": [["id": dayID, "name": groupFixture["day_name"]!, "order_index": 0,
                          "exercises": groupFixture["slots"]!]]]
        }
        let modality = scenario == .bodyweight ? "bw" : scenario == .timed ? "timed" : "barbell"
        var slot: [String: Any] = ["id": "synthetic-slot", "exercise_id": "synthetic-exercise",
            "exercise_name": scenario == .bodyweight ? "Pull-Up" : scenario == .timed ? "Plank" : "Barbell Squat",
            "exercise_unit": "lb", "exercise_modality": modality, "order_index": 0,
            "target_sets": 1, "target_reps": 5, "rest_seconds": 0,
            "target_weight": modality == "barbell" ? 45 : 0]
        if scenario == .timed { slot["target_duration_s"] = 5 }
        let meta = scenario == .activationManual ? "{}"
            : "{\"schedule\":{\"version\":1,\"week\":{\"tue\":\"synthetic-day\"}}}"
        return ["id": "synthetic-plan", "name": name, "version": 1, "meta": meta,
            "days": workouts ? [["id": dayID, "name": "Workout A", "order_index": 0,
                              "exercises": [slot]]] : []]
    }

    mutating func respond(_ request: URLRequest) throws -> (Int, Data) {
        guard request.url?.host == "ui-fixture.invalid" else { throw URLError(.unsupportedURL) }
        guard !scenario.isHistory else { throw URLError(.notConnectedToInternet) }
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        if scenario.isActivation && path != "/auth/apple" {
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(syntheticJWT)" else {
                throw URLError(.userAuthenticationRequired)
            }
        }
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            var body = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count < 0 { throw URLError(.cannotDecodeContentData) }
                if count == 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
            data = body
        }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        revision += 1
        var response: Any
        var status = 200
        switch (method, path) {
        case ("POST", "/auth/apple"):
            signInAttempts += 1
            if ProcessInfo.processInfo.environment["TRESFORT_UI_AUTH_RETRY"] == "1", signInAttempts == 1 {
                throw URLError(.notConnectedToInternet)
            }
            response = ["jwt": syntheticJWT, "user": ["id": syntheticUserID, "display_name": "Synthetic member"]]
        case ("GET", "/api/me"):
            response = ["display_name": "Synthetic member", "email": NSNull(),
                "intervals": intervalsStatus,
                "claude": ["is_owner": scenario == .activationOwner, "connected": coachConnected],
                "health": ["sharing_in_group": false]]
        case ("PATCH", "/api/me/integrations/intervals") where scenario.isIntervals:
            intervalsGeneration += 1
            intervalsConnected = body["api_key"] is String
            intervalsReauth = false
            intervalsPending = intervalsConnected && scenario == .intervalsRetry
            if intervalsConnected && !intervalsPending { importIntervalsActivity() }
            response = ["connected": intervalsConnected, "credential_generation": intervalsGeneration]
        case ("POST", "/api/me/integrations/intervals/sync") where scenario.isIntervals:
            guard body["expected_generation"] as? Int == intervalsGeneration, intervalsConnected
            else { throw URLError(.badServerResponse) }
            intervalsPending = false
            importIntervalsActivity()
            response = ["status": "synced", "connection": intervalsStatus]
        case ("POST", "/api/me/mcp-passphrase"):
            response = ["ok": true]
        case ("GET", "/api/me/group-safety"):
            response = ["blocks": safetyBlocked ? [["user_id": safetyPeerID, "created_at": revision]] : [],
                "restriction": NSNull(), "can_moderate": true]
        case ("PUT", "/api/me/group-blocks/\(safetyPeerID)"):
            safetyBlocked = body["active"] as? Bool ?? false
            response = ["ok": true]
        case ("PUT", "/api/group-safety/restrictions/\(safetyPeerID)"):
            safetyRestricted = body["active"] as? Bool ?? false
            response = ["ok": true]
        case ("GET", "/api/groups"):
            response = ["groups": joined ? [syntheticGroup] : []]
        case ("GET", "/api/groups/invite/ABC234"):
            inviteAttempts += 1
            if ProcessInfo.processInfo.environment["TRESFORT_UI_INVITE_RETRY"] == "1", inviteAttempts == 1 {
                throw URLError(.notConnectedToInternet)
            }
            response = ["status": "valid", "group_name": "Synthetic Crew"]
        case ("POST", "/api/groups/join"):
            guard body["code"] as? String == "ABC234" else { throw URLError(.badServerResponse) }
            joined = true
            response = ["ok": true, "group": syntheticGroup]
        case ("GET", "/api/groups/synthetic-group"):
            response = syntheticGroup
        case ("GET", "/api/groups/synthetic-group/feed"):
            let items: [[String: Any]] = scenario == .groupSafety && !safetyBlocked && !safetyRestricted
                ? [["type": "activity", "id": "synthetic-shared-walk", "user_id": safetyPeerID,
                    "user_display_name": "Sample member", "is_me": false, "date": "2026-09-08", "occurred_at": revision,
                    "activity": ["kind": "walk", "title": "Evening walk", "duration_min": 20, "notes": "A gentle loop"]]] : []
            response = ["group_id": "synthetic-group", "items": items, "next_since": NSNull(), "server_time": revision]
        case ("GET", "/api/groups/synthetic-group/stats"):
            response = ["group_id": "synthetic-group", "range": "week", "members": []]
        case ("GET", "/api/groups/synthetic-group/activity"):
            response = ["group_id": "synthetic-group", "days": 371, "server_time": revision, "members": []]
        case ("GET", "/api/state"):
            stateAttempts += 1
            if failCreatedWorkoutRefresh {
                failCreatedWorkoutRefresh = false
                throw URLError(.notConnectedToInternet)
            }
            if [.loadFailure, .cachedEmpty, .cachedPlan].contains(scenario) { throw URLError(.notConnectedToInternet) }
            if scenario == .serverFailure && stateAttempts == 1 {
                status = 500; response = ["error": "synthetic_server_failure"]; break
            }
            if scenario == .groups {
                guard request.value(forHTTPHeaderField: "X-TresFort-Capabilities")?
                    .split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "groups" }) == true
                else { throw URLError(.badServerResponse) }
            }
            response = ["plan": plan as Any? ?? NSNull(), "plan_version": plan?["version"] ?? 0,
                "sessions": sessions, "sets": sets, "server_time": revision, "plan_groups_version": 1,
                "activities": [], "external_events": [], "external_activities": importedActivities]
        case ("GET", "/api/plan/history"):
            let version = plan?["version"] as? Int ?? 1
            var items: [[String: Any]] = []
            if scenario == .planChanges {
                items = [
                    ["version": 3, "actor": "ios", "operation": "update_exercise", "reason": "Prefer five reps",
                     "created_at": 1_788_883_200_000, "previous_version": 2, "affected": ["Workout A · Barbell Squat"]],
                    ["version": 2, "actor": "mcp", "operation": "update_exercise", "reason": "Reduced load after your feedback",
                     "created_at": 1_788_879_600_000, "previous_version": 1, "affected": ["Workout A · Barbell Squat"]],
                    ["version": 1, "actor": "ios", "operation": "create_plan", "created_at": 1_788_793_200_000],
                ]
                if planRestored {
                    items.insert(["version": 4, "actor": "ios", "operation": "restore_plan", "reason": "Restored from Workout history",
                                  "created_at": 1_788_886_800_000, "previous_version": 3, "affected": ["Workout A · Barbell Squat"]], at: 0)
                }
            }
            response = ["plan_id": "synthetic-plan", "current_version": version, "items": items]
        case ("GET", let path) where path.hasPrefix("/api/plan/history/") && path.hasSuffix("/compare") && scenario == .planChanges:
            let from = Int(path.split(separator: "/")[3])!
            let to = plan?["version"] as? Int ?? 3
            response = ["plan_id": "synthetic-plan", "from_version": from, "to_version": to,
                "changes": from == to ? [] : [["kind": "exercise", "path": "Workout A · Barbell Squat", "before": "65 lb", "after": "45 lb"]],
                "summary": ["plan_fields": 0, "schedule_days": 0, "days_added": 0, "days_removed": 0,
                            "days_changed": 0, "exercises_added": 0, "exercises_removed": 0, "exercises_changed": 1]]
        case ("POST", "/api/plan/history/1/restore") where scenario == .planChanges:
            guard body["expected_plan_id"] as? String == "synthetic-plan", body["expected_version"] as? Int == 3 else {
                throw URLError(.badServerResponse)
            }
            planRestored = true
            plan?["version"] = 4
            response = ["ok": true, "plan_id": "synthetic-plan", "restored_from_version": 1, "version": 4]
        case ("GET", "/api/exercises") where scenario == .groups:
            response = (groupFixture["slots"] as! [[String: Any]]).map { slot in
                ["id": slot["exercise_id"]!, "name": slot["exercise_name"]!,
                 "modality": slot["exercise_modality"]!, "unit": "lb", "primary_muscle": "full body"]
            }
        case ("GET", "/api/exercises"):
            if let fixture = coachingFixture { response = fixture["catalog"]!; break }
            if scenario == .appStore { response = AppStoreScreenshotData.catalog; break }
            response = [["id": "synthetic-exercise",
                "name": scenario == .bodyweight ? "Pull-Up" : scenario == .timed ? "Plank" : "Barbell Squat",
                "modality": scenario == .bodyweight ? "bw" : scenario == .timed ? "timed" : "barbell",
                "unit": "lb", "primary_muscle": "legs"]]
        case ("PUT", "/api/plan/active"):
            let ensureFailure = ProcessInfo.processInfo.environment["TRESFORT_UI_ENSURE_FAILURE"]
            if ensureFailure == "request", !failedEnsureRequest {
                failedEnsureRequest = true
                status = 503; response = ["error": "Synthetic ensure failure"]; break
            }
            plan = makePlan(name: body["name"] as? String ?? "My Training", workouts: false)
            failCreatedWorkoutRefresh = ensureFailure == "refresh"
            response = ["plan": ["id": "synthetic-plan", "name": plan!["name"]!, "version": 1], "created": true]
        case ("PUT", "/api/plan/schedule") where scenario == .library:
            let version = (plan?["version"] as? Int ?? 1) + 1
            let schedule: [String: Any] = ["version": 1, "week": body["week"] ?? [:]]
            plan?["meta"] = String(data: try JSONSerialization.data(withJSONObject: ["schedule": schedule]), encoding: .utf8)
            plan?["version"] = version
            response = ["ok": true, "version": version, "schedule": schedule]
        case ("PUT", let path) where path.hasPrefix("/api/calendar/"):
            let date = String(path.split(separator: "/").last!)
            let prior = sessions.first { $0["date"] as? String == date }
            guard body["expected_attempt"] as? Int == (prior?["attempt"] as? Int ?? 0) else {
                status = 409; response = ["error": "synthetic_calendar_attempt_mismatch"]; break
            }
            let workout = body["day_template_id"] as? String
            let row: [String: Any] = ["id": prior?["id"] ?? "assignment-\(date)", "date": date,
                "status": workout == nil ? "skipped" : "planned",
                "day_template_id": workout as Any? ?? NSNull(),
                "attempt": (prior?["attempt"] as? Int ?? 0) + 1, "updated_at": revision]
            sessions.removeAll { $0["date"] as? String == date }; sessions.append(row)
            response = ["ok": true, "session": row]
        case ("POST", "/api/calendar/2026-09-08/move") where scenario == .appStore:
            guard body["to_date"] as? String == "2026-09-09", body["today"] as? String == "2026-09-08",
                  body["day_template_id"] as? String == dayID,
                  body["expected_plan_id"] as? String == "synthetic-plan",
                  body["expected_version"] as? Int == plan?["version"] as? Int,
                  body["expected_from_attempt"] as? Int == 0, body["expected_to_attempt"] as? Int == 0,
                  UUID(uuidString: body["id"] as? String ?? "") != nil else { throw URLError(.badServerResponse) }
            if ProcessInfo.processInfo.environment["TRESFORT_UI_MOVE_CONFLICT"] == "1", !returnedMoveConflict {
                returnedMoveConflict = true
                plan?["version"] = 2
                status = 409; response = ["error": "calendar_move_conflict"]; break
            }
            let from: [String: Any] = ["id": "move-from", "date": "2026-09-08", "status": "skipped", "attempt": 1, "updated_at": revision]
            let to: [String: Any] = ["id": "move-to", "date": "2026-09-09", "status": "planned", "day_template_id": dayID, "attempt": 1, "updated_at": revision]
            sessions += [from, to]
            response = ["ok": true, "from": from, "to": to]
        case ("DELETE", "/api/days/hotel") where scenario == .library:
            let remaining = (plan?["days"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != "hotel" }
            let version = (plan?["version"] as? Int ?? 1) + 1
            plan?["days"] = remaining
            plan?["version"] = version
            response = ["ok": true, "version": plan?["version"] ?? 1]
        case ("POST", "/api/days/\(dayID)/exercises") where scenario == .activationManual:
            guard body["exercise"] as? String == "synthetic-exercise" else { throw URLError(.badServerResponse) }
            var days = plan!["days"] as! [[String: Any]]
            let source = makePlan()["days"] as! [[String: Any]]
            var slot = (source[0]["exercises"] as! [[String: Any]])[0]
            for key in ["target_sets", "target_reps", "target_weight", "rest_seconds"] {
                slot[key] = body[key] ?? slot[key]
            }
            slot["target_weight"] = body["target_weight"] ?? NSNull()
            days[0]["exercises"] = [slot]; plan?["days"] = days; plan?["version"] = 3
            response = ["id": "synthetic-slot"]
        case ("POST", "/api/days"):
            var days = plan?["days"] as? [[String: Any]] ?? []
            let id = days.isEmpty ? dayID : "created-workout"
            let day: [String: Any] = ["id": id, "name": body["name"] ?? "Workout A",
                                      "order_index": days.count, "exercises": []]
            days.append(day)
            let version = (plan?["version"] as? Int ?? 0) + 1
            plan?["days"] = days; plan?["version"] = version
            failCreatedWorkoutRefresh = ProcessInfo.processInfo.environment["TRESFORT_UI_CREATE_REFRESH_FAILURE"] == "1"
            response = ["id": id]
        case ("PUT", "/api/days/\(dayID)/groups") where scenario == .groups:
            let receiptKey = String(data: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8)!
            if let receipt = groupReceipts[receiptKey] { response = receipt; break }
            guard let version = plan?["version"] as? Int, body["expected_version"] as? Int == version else {
                status = 409; response = ["conflict": true, "current_version": plan?["version"] ?? 0]; break
            }
            guard let groupID = body["group_id"] as? String, UUID(uuidString: groupID) != nil,
                  let ids = body["exercises"] as? [String] else { throw URLError(.badServerResponse) }
            var days = plan!["days"] as! [[String: Any]]
            var slots = days[0]["exercises"] as! [[String: Any]]
            if !ids.isEmpty {
                // Only the two prescribed selections in this journey are accepted.
                let expected = (groupFixture["groups"] as! [[String: Any]]).first { group in
                    let indices = group["member_indices"] as! [Int]
                    let original = groupFixture["slots"] as! [[String: Any]]
                    return indices.map { original[$0]["id"] as! String } == ids
                }
                guard let expected,
                      body["round_rest"] as? Int == expected["round_rest"] as? Int,
                      body["transition_rest"] as? Int == expected["transition_rest"] as? Int,
                      body["target_sets"] as? Int == expected["rounds"] as? Int else {
                    throw URLError(.badServerResponse)
                }
            }
            for index in slots.indices where ids.contains(slots[index]["id"] as! String)
                || (ids.isEmpty && slots[index]["group_id"] as? String == groupID) {
                slots[index]["group_id"] = ids.isEmpty ? NSNull() : groupID as Any
                slots[index]["group_rest_seconds"] = ids.isEmpty ? NSNull() : body["round_rest"]!
                slots[index]["group_transition_seconds"] = ids.isEmpty ? NSNull() : body["transition_rest"]!
                if !ids.isEmpty { slots[index]["target_sets"] = body["target_sets"]! }
            }
            days[0]["exercises"] = slots; plan?["days"] = days; plan?["version"] = version + 1
            let ack: [String: Any] = ["ok": true, "plan_id": "synthetic-plan", "version": version + 1,
                "group_id": groupID, "day_id": dayID, "members": ids,
                "round_rest": body["round_rest"] ?? NSNull(), "transition_rest": body["transition_rest"] ?? NSNull(),
                "target_sets": body["target_sets"] ?? NSNull(), "cleared": ids.isEmpty]
            groupReceipts[receiptKey] = ack
            response = ack
        case ("POST", "/api/sessions"):
            if sessions.isEmpty {
                guard body["expected_attempt"] as? Int == 0 else { throw URLError(.badServerResponse) }
                sessions = [makeSession(attempt: 0)]
            }
            response = sessions[0]
        case ("POST", "/api/sessions/\(sessionID)/sets"):
            if scenario == .pending { throw URLError(.notConnectedToInternet) }
            if scenario == .groups, !sets.contains(where: { $0["id"] as? String == body["id"] as? String }) {
                let indices = groupFixture["execution_indices"] as! [Int]
                let slots = groupFixture["slots"] as! [[String: Any]]
                guard sets.count < indices.count,
                      body["template_exercise_id"] as? String == slots[indices[sets.count]]["id"] as? String else {
                    // A wrong member is observable as a failed set; never bless a
                    // sequential runner just because it eventually logs eight sets.
                    status = 422; response = ["error": "Synthetic member sequence mismatch"]; break
                }
            }
            var set = body
            set["is_warmup"] = (body["is_warmup"] as? Bool == true) ? 1 : 0
            set["is_timed"] = (body["is_timed"] as? Bool == true) ? 1 : 0
            set["session_id"] = sessionID; set["updated_at"] = revision
            set["logged_at"] = revision
            sets.removeAll { ($0["id"] as? String) == (set["id"] as? String) }
            sets.append(set)
            sessions = [makeSession(attempt: sessions.first?["attempt"] as? Int ?? 0)]
            response = ["set": set, "session": sessions[0], "deduped": false]
        case ("PATCH", "/api/sets/synthetic-set"):
            status = 422; response = ["error": "Synthetic correction rejected"]
        case ("PATCH", "/api/sessions/\(sessionID)"):
            if ProcessInfo.processInfo.environment["TRESFORT_UI_FINISH_FAILURE"] == "1",
               body["status"] as? String == "completed" {
                status = 503; response = ["error": "Synthetic finish failure"]; break
            }
            if ProcessInfo.processInfo.environment["TRESFORT_UI_FEEDBACK_CONFLICT"] == "1", !returnedFeedbackConflict {
                returnedFeedbackConflict = true
                sessions[0]["notes"] = "Newer saved feedback"
                sessions[0]["perceived_fatigue"] = 8
                sessions[0]["updated_at"] = revision
                status = 409
                response = ["error": "session_feedback_conflict", "current_session": sessions[0]]
                break
            }
            var completed = makeSession(status: "completed", attempt: sessions.first?["attempt"] as? Int ?? 0)
            completed["notes"] = body["notes"] ?? sessions.first?["notes"]
            completed["perceived_fatigue"] = body["perceived_fatigue"] ?? sessions.first?["perceived_fatigue"]
            sessions = [completed]
            response = sessions[0]
        case ("GET", "/api/sessions/\(sessionID)/summary"):
            let workingSets = sets.filter { $0["is_warmup"] as? Int == 0 }
            let totalReps = workingSets.reduce(0) { $0 + ($1["reps"] as? Int ?? 0) }
            let externalVolume = workingSets.reduce(0.0) {
                $0 + ($1["weight"] as? Double ?? 0) * Double($1["reps"] as? Int ?? 0)
            }
            response = ["version": 1, "session_id": sessionID, "date": "2026-09-08", "attempt": sessions.first?["attempt"] ?? 0,
                "final": sessions.first?["status"] as? String == "completed", "working_sets": workingSets.count,
                "total_reps": totalReps, "external_load_volume": externalVolume,
                "cohorts": [], "records": [], "targets_available": false, "targets": []]
        default:
            // Unsupported UI interactions are visible failures, never passthrough.
            status = 501; response = ["error": "No synthetic response for \(method) \(path)"]
        }
        return (status, try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]))
    }
}
/// Exercises the real editor lifecycle without microphone, provider, or network access.
@MainActor
final class SyntheticFeedbackTranscriber: WorkoutFeedbackTranscribing {
    private var callback: (@MainActor (WorkoutFeedbackTranscription) -> Void)?
    func start(result: @escaping @MainActor (WorkoutFeedbackTranscription) -> Void) async throws {
        callback = result
        switch ProcessInfo.processInfo.environment["TRESFORT_FEEDBACK_SPEECH"] {
        case "denied": throw FeedbackRecordingError.denied
        case "unavailable": throw FeedbackRecordingError.unavailable
        case "empty": result(.transcript(""))
        default: result(.transcript(ProcessInfo.processInfo.environment["TRESFORT_FEEDBACK_TRANSCRIPT"] ?? "Left shoulder felt fine overhead."))
        }
    }
    func finish() { callback?(.finished); callback = nil }
    func stop() { callback = nil }
}
#endif
