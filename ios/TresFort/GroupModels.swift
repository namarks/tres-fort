import Foundation
import SwiftUI

// Codable mirrors for the M2/M3/M4 group accountability endpoints.
//
// Wire shape is authored by the backend (src/db.ts, src/types.ts,
// src/routes/api.ts) — DO NOT speculate on field names or types. Where the
// `.context/m5-ios-spec.md` planning doc disagrees with the shipped backend,
// the backend wins; the spec is a planning artifact.
//
// Diffs against the spec (locked in below):
//   * POST /api/activities body uses `type` + `duration_minutes` (NOT
//     `kind` + `duration_min`). The FEED activity item, however, uses
//     `kind` + `duration_min` — two different shapes around the same
//     row. Don't mix them.
//   * GET /api/groups returns `{ groups: [Group + members[]] }` — no
//     `member_count` or `my_display_name` at the top level. We compute
//     the count from members.length and read the per-user nickname from
//     the member row whose user_id matches the caller.
//   * POST /api/groups body is `{ name }` only — no per-group display name.
//   * POST /api/groups/:id/invites returns `{ code, group_id, expires_at }`
//     — no `share_url`. iOS builds whatever share string the user sees.
//   * POST /api/groups/join returns `{ ok, group }` — the group is wrapped.
//   * GET /api/groups/:id/feed returns `{ group_id, items, next_since,
//     server_time }`. Feed items are discriminated on `type` with nested
//     inner objects (`session`/`ride`/`activity`).
//   * GET /api/groups/:id/stats returns `{ group_id, range, members }`.
//   * There is NO GET /api/me/integrations endpoint (PATCH only). iOS
//     tracks "connected" purely from the PATCH response and the user's
//     own typed-in athlete_id.

// MARK: - Groups (M2)

/// Wire-mirror of the JOIN of `groups` + hydrated `group_members[]`
/// returned by GET /api/groups, GET /api/groups/:id, POST /api/groups,
/// and (wrapped under `group`) POST /api/groups/join.
struct GroupSummary: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let created_by: String
    let created_at: Int
    let members: [GroupMemberRow]

    /// Derived (the wire doesn't carry it explicitly).
    var member_count: Int { members.count }

    /// The caller's nickname in this group, if any. The backend doesn't
    /// stamp `is_me` on /api/groups members today, so we fall back to a
    /// user-id match supplied by the caller. Returns nil if the caller
    /// isn't in this group (shouldn't happen for /api/groups — that only
    /// lists groups you belong to) or hasn't set a per-group name.
    func myDisplayName(callerUserID: String?) -> String? {
        guard let uid = callerUserID else { return nil }
        return members.first(where: { $0.user_id == uid })?.display_name
    }
}

/// One member row from GET /api/groups response.
struct GroupMemberRow: Codable, Identifiable, Equatable {
    /// Composite id — `group_members` has no surrogate id; we synthesize
    /// one from (group_id, user_id) for SwiftUI identity.
    var id: String { "\(group_id):\(user_id)" }
    let group_id: String
    let user_id: String
    /// Per-group nickname override (NULL = "use users.display_name").
    let display_name: String?
    let joined_at: Int
    /// Backend resolves "override OR global" for us — render this.
    let effective_display_name: String?
}

/// Wrapper for POST /api/groups/join success.
struct JoinGroupResponse: Decodable {
    let ok: Bool
    let group: GroupSummary
}

/// POST /api/groups/:id/invites response shape.
struct GroupInviteCode: Decodable, Equatable {
    let code: String
    let group_id: String
    /// epoch ms, or null = never expires.
    let expires_at: Int?
}

/// GET /api/groups/invite/:code response — previews an invite (without
/// consuming it) so the deep-link join-confirm sheet can show "Join <name>?".
struct InvitePreview: Decodable, Equatable {
    /// "valid" | "used" | "expired" | "unknown". Decoded as a raw String so a
    /// future backend status can't fail decoding — GroupModel maps it.
    let status: String
    /// The group's name, or nil when the code is unknown/the group is gone.
    let group_name: String?
}

/// Top-level shape of GET /api/groups.
struct GroupsListResponse: Decodable {
    let groups: [GroupSummary]
}

// MARK: - Feed (M4)

/// Top-level shape of GET /api/groups/:id/feed.
struct GroupFeedResponse: Decodable {
    let group_id: String
    let items: [FeedItem]
    /// epoch_ms of the OLDEST item returned — pass back as `?since=` to
    /// page through history. Null when the response is empty.
    let next_since: Int?
    /// Tie-breaker for the composite (`occurred_at`, `id`) cursor: the id
    /// of the OLDEST item returned. MUST be sent back alongside `since`
    /// (as `?since_id=`) when paginating — otherwise rows that share the
    /// page-boundary `occurred_at` get strict-older semantics applied and
    /// are permanently skipped. Null when the response is empty.
    let next_since_id: String?
    let server_time: Int
}

/// Discriminated union on `type`. SwiftUI sites pattern-match on the
/// enum cases; unknown future `type` values decode as `.unknown` (rather
/// than throwing) so a v2 backend addition can't crash the feed pull.
enum FeedItem: Identifiable, Equatable {
    case session(FeedSessionItem)
    case ride(FeedRideItem)
    case activity(FeedActivityItem)
    /// Forward-compatibility fallback: a row with a `type` we don't yet
    /// understand. Carries the minimum header so the row still renders
    /// with username + date.
    case unknown(FeedUnknownItem)

    var id: String {
        switch self {
        case .session(let s):  return s.id
        case .ride(let r):     return r.id
        case .activity(let a): return a.id
        case .unknown(let u):  return u.id
        }
    }

    var userID: String {
        switch self {
        case .session(let s):  return s.user_id
        case .ride(let r):     return r.user_id
        case .activity(let a): return a.user_id
        case .unknown(let u):  return u.user_id
        }
    }

    var userDisplayName: String {
        switch self {
        case .session(let s):  return s.user_display_name
        case .ride(let r):     return r.user_display_name
        case .activity(let a): return a.user_display_name
        case .unknown(let u):  return u.user_display_name
        }
    }

    var occurredAt: Int {
        switch self {
        case .session(let s):  return s.occurred_at
        case .ride(let r):     return r.occurred_at
        case .activity(let a): return a.occurred_at
        case .unknown(let u):  return u.occurred_at
        }
    }

    var isMe: Bool {
        switch self {
        case .session(let s):  return s.is_me
        case .ride(let r):     return r.is_me
        case .activity(let a): return a.is_me
        case .unknown(let u):  return u.is_me
        }
    }
}

extension FeedItem: Decodable {
    private enum TypeKey: String, CodingKey { case type }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TypeKey.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "session":
            self = .session(try FeedSessionItem(from: decoder))
        case "ride":
            self = .ride(try FeedRideItem(from: decoder))
        case "activity":
            self = .activity(try FeedActivityItem(from: decoder))
        default:
            // M5 chose to soft-decode unknown types because the alternative
            // (throwing) would break the WHOLE feed pull whenever the
            // backend adds a new item type. revisit if backend telemetry
            // shows specific types we want to crash-on for parity.
            var item = try FeedUnknownItem(from: decoder)
            item.type = type
            self = .unknown(item)
        }
    }
}

/// `type == "session"` — a logged strength workout.
struct FeedSessionItem: Codable, Identifiable, Equatable {
    let id: String
    let user_id: String
    let user_display_name: String
    let is_me: Bool
    let date: String        // YYYY-MM-DD device-local
    let occurred_at: Int    // epoch ms
    let session: Inner

    struct Inner: Codable, Equatable {
        let day_name: String?
        let day_label: String?
        let duration_sec: Int?
        let set_count: Int
        let top_sets: [TopSet]
    }

    struct TopSet: Codable, Equatable {
        let exercise: String
        let weight: Double
        let reps: Int
        let unit: String?
        let est_1rm: Double
    }
}

/// `type == "ride"` — an intervals.icu completed endurance activity.
struct FeedRideItem: Codable, Identifiable, Equatable {
    let id: String
    let user_id: String
    let user_display_name: String
    let is_me: Bool
    let date: String
    let occurred_at: Int
    let ride: Inner

    struct Inner: Codable, Equatable {
        let kind: String
        let name: String?
        let distance_m: Double?
        let moving_time_sec: Int?
        let average_watts: Double?
        let training_load: Int?
        let elevation_gain_m: Double?
    }
}

/// `type == "activity"` — a user-logged manual activity (Pilates, walk, …).
struct FeedActivityItem: Codable, Identifiable, Equatable {
    let id: String
    let user_id: String
    let user_display_name: String
    let is_me: Bool
    let date: String
    let occurred_at: Int
    let activity: Inner

    struct Inner: Codable, Equatable {
        let kind: String
        let title: String?
        let duration_min: Int?
        let notes: String?
    }
}

/// Header-only decode for an unknown `type` (forward-compat).
struct FeedUnknownItem: Codable, Identifiable, Equatable {
    let id: String
    let user_id: String
    let user_display_name: String
    let is_me: Bool
    let date: String
    let occurred_at: Int
    /// Filled in by FeedItem.init(from:) after the header decodes. We use
    /// `var` because the header decode happens first, then the discriminator
    /// is read separately from the same decoder.
    var type: String = ""
}

// MARK: - Stats (M4)

/// Top-level shape of GET /api/groups/:id/stats.
struct GroupStatsResponse: Decodable {
    let group_id: String
    let range: String       // "7d" | "14d" | "30d"
    let members: [MemberStat]
}

/// One member's roll-up. `is_me` is server-stamped — trust it.
struct MemberStat: Codable, Identifiable, Equatable {
    var id: String { user_id }
    let user_id: String
    let display_name: String
    let avatar_initials: String
    let is_me: Bool
    let workout_count: Int
    let streak_days: Int
    /// epoch ms of midnight UTC of the most recent active civil date, or
    /// null when the member has no activity in lookback window.
    let last_active: Int?
}

// MARK: - Activity series (week/month/year zoom)

/// Top-level shape of GET /api/groups/:id/activity. One generous pull
/// (default ~371 days) feeds the week/month/year zoom with no refetch on
/// toggle — the client re-buckets `members[].days` per selected range.
struct GroupActivityResponse: Decodable {
    let group_id: String
    let days: Int
    let server_time: Int
    let members: [MemberActivitySeries]
}

/// One member's SPARSE per-day activity counts (only active dates present).
struct MemberActivitySeries: Decodable, Equatable {
    let user_id: String
    let days: [DayActivity]
}

/// Per-day counts kept by SOURCE; the client maps these to WorkoutCategory
/// (so the type→category rule lives in exactly one place — iOS).
struct DayActivity: Decodable, Equatable {
    let date: String                // YYYY-MM-DD civil
    let sessions: Int               // strength → lift
    let rides: Int                  // intervals endurance → endurance
    let activities: [String: Int]   // manual log, keyed by type
}

// MARK: - Activities (M3)

/// Server-returned row from POST /api/activities. The wire calls this
/// `type` + `duration_minutes` — note these are NOT renamed across the
/// network from the iOS-side struct (the spec's `kind`/`duration_min`
/// applies ONLY to the feed inner shape, not the row shape).
struct ActivityRow: Codable, Identifiable, Equatable {
    let id: String
    let user_id: String
    let date: String
    let type: String
    let title: String?
    let duration_minutes: Int?
    let notes: String?
    let logged_at: Int
    let source: String
    let deleted_at: Int?
}

/// Pending activity in the outbox. Mirrors the POST /api/activities body
/// 1:1 so we can persist + replay without re-deriving anything.
struct PendingActivity: Codable, Identifiable, Equatable {
    /// Client-generated UUID; this is the idempotency key — the server
    /// dedups on it, so retries are safe.
    let id: String
    let date: String           // YYYY-MM-DD
    let type: String           // lower-case (pilates|cardio|yoga|walk|…)
    let title: String?
    let duration_minutes: Int?
    let notes: String?
    let logged_at: Int         // epoch ms

    /// Catalog of activity kinds offered in the picker. Lower-case per
    /// backend validation. Order is display order. "lift" is included for
    /// "I lifted somewhere else and want to log it without firing up the
    /// runner" — backend treats it as a generic activity, NOT a strength
    /// session.
    static let kinds: [String] = [
        "pilates", "cardio", "yoga", "walk", "hike",
        "run", "ride", "swim", "lift", "other",
    ]

    /// Human label for the picker (e.g. "Pilates", "Lift (other)").
    static func label(for kind: String) -> String {
        switch kind {
        case "pilates":  return "Pilates"
        case "cardio":   return "Cardio"
        case "yoga":     return "Yoga"
        case "walk":     return "Walk"
        case "hike":     return "Hike"
        case "run":      return "Run"
        case "ride":     return "Ride"
        case "swim":     return "Swim"
        case "lift":     return "Lift (other)"
        case "other":    return "Other"
        default:         return kind.capitalized
        }
    }

    /// SF Symbol per kind (also used by FeedItemRow's activity case).
    static func glyph(for kind: String) -> String {
        switch kind {
        case "pilates", "yoga": return "figure.mind.and.body"
        case "hike":            return "figure.hiking"
        case "swim":            return "figure.pool.swim"
        case "run":             return "figure.run"
        case "ride":            return "bicycle"
        case "lift":            return "dumbbell.fill"
        case "walk":            return "figure.walk"
        case "cardio":          return "figure.mixed.cardio"
        default:                return "figure.mixed.cardio"
        }
    }
}

// MARK: - Account / profile

/// Server-derived account + setup snapshot for the Profile tab
/// (GET /api/me). Connection state comes from the SERVER (not a client
/// mirror), so env/MCP-seeded intervals creds and the claude.ai connector
/// both surface. The api_key is never sent (write-only).
struct MeProfile: Decodable, Equatable {
    let display_name: String?
    let email: String?
    let intervals: IntervalsStatus
    let claude: ClaudeStatus

    struct IntervalsStatus: Decodable, Equatable {
        let connected: Bool
        let athlete_id: String?
        /// Server stamped an auth failure (token expired/revoked): the
        /// connection is gone and the user must reconnect. Optional so an app
        /// built before the server field shipped still decodes; nil == false.
        let needs_reauth: Bool?
    }

    /// Claude coaching is single-owner. `is_owner` = this account is the one
    /// Claude operates on. `connected` = owner AND the claude.ai connector is
    /// authorized. `last_active` = most recent MCP write (epoch ms).
    struct ClaudeStatus: Decodable, Equatable {
        let is_owner: Bool
        let connected: Bool
        let last_active: Int?
    }
}

// MARK: - Integrations (M1)

/// Local mirror of the user's intervals.icu connection state. There's no
/// GET endpoint today — the backend simply UPDATEs columns on `users` —
/// so iOS tracks this from the PATCH response plus the input the user
/// typed. Persist in @AppStorage so a sign-out/in retains it.
struct IntervalsConnection: Codable, Equatable {
    /// The athlete id the user supplied. iOS never re-reads the api_key
    /// (it's write-only on the wire — SecureField on the form).
    let athlete_id: String
    /// epoch ms of when we last successfully PATCHed credentials.
    let connected_at: Int
}

// MARK: - Helpers

/// Friendly relative label for a feed item's `occurred_at` (epoch ms):
///   - within today:     "Today · 9:42 AM"
///   - yesterday:        "Yesterday · 5:01 PM"
///   - within 7 days:    "Mon" (weekday)
///   - older:            "Mar 12"
///
/// Read-only — never set the device clock here.
enum FeedDateFormat {
    static func relative(epochMs: Int, now: Date = Date()) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.locale = Locale(identifier: "en_US_POSIX")
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        if cal.isDate(d, inSameDayAs: now) {
            f.dateFormat = "h:mm a"
            return "Today · \(f.string(from: d))"
        }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
           cal.isDate(d, inSameDayAs: yesterday) {
            f.dateFormat = "h:mm a"
            return "Yesterday · \(f.string(from: d))"
        }
        // CALENDAR-day delta, not integer-day delta (issue #42). Anchoring to
        // startOfDay on both ends matches how the today/yesterday checks
        // above already reason. Without this, a session logged 2 calendar
        // days ago in the EVENING gives `days == 1` (1d 23h truncates) and
        // falls through to "MMM d" instead of the intended weekday format —
        // visible in the issue #39 screenshot as "May 26" sitting between
        // "Sun" and "Thu" in an otherwise-weekday-format column.
        let dStart = cal.startOfDay(for: d)
        let nStart = cal.startOfDay(for: now)
        let days = cal.dateComponents([.day], from: dStart, to: nStart).day ?? 0
        if days >= 2 && days < 7 {
            f.dateFormat = "EEE"
            return f.string(from: d)
        }
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}

/// Format helpers shared across feed row + detail.
enum FeedFormat {
    static func duration(seconds: Int?) -> String {
        guard let s = seconds, s > 0 else { return "—" }
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
    }

    /// Display weight as integer when round, else 1dp.
    static func weight(_ w: Double) -> String {
        w.rounded() == w ? String(Int(w)) : String(format: "%.1f", w)
    }

    /// Meters → "12.3 mi" (US-based athlete; calendar already does this).
    static func distance(meters: Double?) -> String? {
        guard let m = meters, m > 0 else { return nil }
        return String(format: "%.1f mi", m / 1609.344)
    }
}

/// Initials for an avatar bubble. "Sarah Kim" -> "SK", "" -> "?".
/// Matches the backend's `avatarInitials` (db.ts) but iOS may receive
/// `avatar_initials` from MemberStat already-computed; this helper exists
/// for cases (FeedItemRow) where we only have a display name.
func avatarInitials(from name: String) -> String {
    let s = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return "?" }
    let words = s.split(separator: " ").filter { !$0.isEmpty }
    if words.isEmpty { return "?" }
    if words.count == 1 { return String(words[0].first!).uppercased() }
    return (String(words[0].first!) + String(words[1].first!)).uppercased()
}

/// Stable per-user color from a hash of the user id. Mirrors the stub
/// view's palette so the same friend has the same color across rows.
extension Color {
    static func stableAvatarColor(forUserID id: String) -> Color {
        let palette: [Color] = [
            Color(hex: 0xF59E0B), Color(hex: 0x84CC16), Color(hex: 0x06B6D4),
            Color(hex: 0xA855F7), Color(hex: 0xEC4899), Color(hex: 0xF97316),
        ]
        // Swift's hashValue is per-process-randomized — use a stable hash
        // (FNV-1a 32-bit) so a user keeps their colour across app restarts
        // and across devices. The palette is small (6), so even a weak
        // hash is fine for spreading uniformly.
        var h: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            h ^= UInt32(byte)
            h &*= 16_777_619
        }
        return palette[Int(h % UInt32(palette.count))]
    }
}
