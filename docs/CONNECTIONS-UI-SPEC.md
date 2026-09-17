# iOS spec: Connections UI

The Connections screen lists the activity sources a member can use now. Keep
setup and recovery actions in each source’s detail screen; show device-routing
help on demand. This is the current repository UI contract, not evidence of a
production deployment or device rollout.

The entry point is **Profile → Connections**. Implementation lives in
[`ConnectionsView.swift`](../ios/TresFort/Group/ConnectionsView.swift) and
[`ProfileView.swift`](../ios/TresFort/Profile/ProfileView.swift). Data flow and
source reconciliation are documented in [`DESIGN.md`](DESIGN.md); provider
expansion in [`MULTISOURCE-INGESTION.md`](MULTISOURCE-INGESTION.md) remains
historical proposal context.

## Screen structure

```text
Profile → Connections
 ├─ Activity sources
 │   ├─ intervals.icu → IntervalsSettingsView
 │   └─ Apple Health  → AppleHealthSettingsView
 └─ Other devices (collapsed disclosure)
```

Use one **Activity sources** section. Give both available sources the same row
hierarchy: source name, one concise status or description, and navigation to its
details. Athlete IDs, setup instructions, import history and permission details
belong in those detail screens.

Do not add unavailable Garmin, Polar or Wahoo rows, disabled Connect actions, or
“Coming soon” promises. A direct connector belongs in this list once it has a
working implementation and usable setup/recovery flow. The **Other devices**
disclosure provides existing routing help without implying direct support.

## Source rows

### intervals.icu

Read status from `groupModel.intervalsStatus` and
`groupModel.intervalsStatusUnavailable`, backed by `GET /api/me`. Apply these
states in order:

| Condition | Row subtitle |
|---|---|
| Status unavailable or not loaded | `Check connection status` |
| Reauthorization needed | `Reconnect needed` |
| Connected, import pending | `Connected · Sync pending` |
| Connected | `Connected` |
| Disconnected | `Workouts and planned rides` |

Missing status is not proof of disconnection. A pending import is not proof that
the saved connection failed. Keep reconnect and retry states distinct.

### Apple Health

When HealthKit is available, the row opens Apple Health settings. When unavailable,
show a disabled **Not available on this device** row.

Workouts and body weight have independent, account-scoped local opt-ins. Observe
both models so changing weight updates the source row immediately:

| Local opt-ins | Row subtitle |
|---|---|
| Neither enabled | `Workouts and body weight` |
| Workouts enabled | `Workouts enabled` |
| Weight enabled | `Weight enabled` |
| Both enabled | `Workouts and weight enabled` |

These labels describe the member’s local choices. Apple hides HealthKit read
permission denial, so an enabled flag does not establish that samples are
available or permission was granted. Sync progress, empty results and errors
remain visible in the detail screen.

## Profile summary

The Profile Connections row summarizes both available sources without an athlete
ID. Preserve Intervals **Check status**, **Reconnect needed**, and **Sync pending**
states; show **intervals.icu connected** when connected with no pending import.
Show **Apple Health enabled** when HealthKit is available and either local opt-in
is enabled. With known disconnected Intervals status and no enabled Health data,
show **Add a connection**.

An Intervals warning and enabled Apple Health can both appear. Do not summarize
all connections as disconnected merely because Intervals is disconnected.

## Other devices disclosure

Keep this help collapsed initially:

- `Connect Garmin, Zwift, Polar or Wahoo to intervals.icu, then connect intervals.icu here.`
- `Strava-synced activities arrive without details. Connect your device to intervals.icu directly.`

Source reconciliation remains governed by the backend contract. Do not add an
unqualified promise that every duplicate activity will always be merged.

## Detail-screen behavior to preserve

### Intervals settings

[`IntervalsSettingsView`](../ios/TresFort/Group/IntervalsSettingsView.swift)
retains OAuth, API-key setup, optional athlete ID, reconnect and disconnect.
It refreshes server status when opened and offers **Refresh status** when status
is unavailable. API keys remain in a secure field.

Connecting imports the last 90 days of activity. A saved connection with an
unfinished import offers **Retry sync** without requiring credentials again.
Otherwise, a connected account offers **Sync recent activities** and shows the
last successful sync when known. Background updates keep planned rides and
completed activities current. Disconnecting or reconnecting preserves imported
history. Busy actions are disabled, and failures remain recoverable in place.

### Apple Health settings

[`AppleHealthSettingsView`](../ios/TresFort/Health/AppleHealthSettingsView.swift)
keeps separate controls for workouts, weight and workout sharing:

- **Workouts:** request on-device HealthKit authorization, show initial backfill
  or sync progress, last successful sync and errors, and provide manual sync.
  Reads are opt-in; Très Fort does not write to Apple Health.
- **Weight:** an independent **Read weight** toggle. Measurements stay on this
  iPhone and are visible only to the member in Très Fort. They appear in
  **Progress → Weight**. Turning this off clears the app’s weight view without
  deleting Health measurements; personal sign-in requirements remain enforced.
- **Workout sharing:** load authoritative sharing state before presenting the
  toggle. Sharing is off by default; **Show in group feed** controls HealthKit
  workout visibility to other group members. It does not change lifting or
  Intervals activity visibility. If state cannot be read, offer retry rather
  than assuming sharing is off. A failed toggle restores the previous value.
- **Disconnect workouts:** stop future workout imports; already-synced history
  remains. An existing sharing opt-in must stay reachable after disconnect,
  because stopping imports does not unshare existing records. A failed sync
  reset remains visible and retryable. Weight is independently controlled.
- **Data use:** explain that authorized workout records are uploaded to the
  service and can be read by an authorized AI app and its configured model
  provider. Keep the privacy-policy link and separate group-sharing explanation.

Implementation details stay in
[`HealthKitSyncModel`](../ios/TresFort/Health/HealthKitSyncModel.swift) and
[`BodyWeightAccessSection`](../ios/TresFort/Health/BodyWeightAccessSection.swift).
The Worker cannot read HealthKit directly. Simplifying the source list does not
change authorization, source reconciliation, sharing, retention or sync behavior.

## Verification

Use synthetic fixtures and simulator journeys to verify source navigation,
status labels, disclosure behavior and layout. Verify actual HealthKit permission
and sample-reading behavior on a physical device with authorized Health data;
a simulator walkthrough alone does not establish that integration works.
