# Imported activity attribution

Intervals.icu identifies Garmin-origin activities by `device_name` containing
Garmin. The app derives a bounded `Garmin [device model]` label from the existing
provider JSON and falls back to `Garmin` when a safe model is unavailable. No new
collection, schema migration, hosted resource, or provider credential is needed.

The label travels with full/delta activity sync, recent activities, account
exports, group feed details, and Claude's activity/brief responses. Group counts
and daily series identify Garmin as a contributing source inside the same date,
membership, blocking and HealthKit-sharing predicates as the underlying data.
Group responses expose attribution, not provider JSON. Claude receives a fixed
instruction to preserve attribution in display/export and derived guidance.

The iOS activity card, history row, month grid, group feed/detail and visible
activity lane show plaintext attribution. Existing snapshots request a full
activity collection once when attribution metadata is missing; unrelated cursors
and pending workout writes retain their existing behavior. This rehydrates
historical rows without rewriting production activity data.

Sources:
- [Intervals API terms and device-name guidance](https://forum.intervals.icu/t/intervals-icu-api-terms-and-conditions/114087)
- [Garmin API brand guidelines](https://developer.garmin.com/downloads/brand/Garmin-Developer-API-Brand-Guidelines.pdf)

Verification covers malformed/absent device metadata, historical full/delta reads,
provider corrections with unchanged workout metrics, no-op resyncs, tenant and
sharing boundaries, exports/MCP, old-cache refresh and visible-range bucketing.
