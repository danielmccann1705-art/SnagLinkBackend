# Analytics events (B8)

The app's `EventTracker` batches events to `POST /api/v1/events`. The handler
(`AnalyticsController`) is **generic** — it accepts any event `name` plus an optional
string→string `properties` bag — so new event types need **no backend change**; they are
stored as rows in `analytics_events` and queried for funnel reporting.

Request shape:

```json
{ "events": [
  { "name": "onboarding_step_viewed", "properties": { "step": "1" },
    "deviceId": "…", "appVersion": "2.0.0", "timestamp": "2026-06-01T12:00:00Z" }
] }
```

Auth is optional — if a Bearer token is present the event is linked to the user, otherwise it
is anonymous (e.g. `paywall_shown` before sign-in).

## PLOT redesign event types (REDESIGN_JUNE_2026 §3 B8)

| Event | Properties | When |
|---|---|---|
| `onboarding_step_viewed` | `step` (1..8) | On each step appear |
| `onboarding_step_completed` | `step` | On continue tap |
| `onboarding_step_skipped` | `step` | On skip tap |
| `onboarding_magic_link_sent` | `channel` | When step 08 fires |
| `paywall_shown` | `entry` ("onboarding"\|"settings") | On paywall appear |
| `paywall_trial_started` | `productId` | On purchase success |
| `paywall_skipped` | `entry` | On skip tap |
| `tier_link_meter_zero_reached` | — | First time meter renders zero |
| `approval_approved` | `snagId`, `secondsToDecide` | On approve |
| `approval_sent_back` | `snagId`, `reason` | On send-back |
| `auth_magic_link_requested` | `email_hash` | On request |
| `auth_magic_link_verified` | `isNewUser` | On verify success |

(All property values are sent as strings in the `properties` bag.)

## Funnels (server-side reporting queries over `analytics_events`)

- **Onboarding:** `onboarding_step_viewed[1]` → `[5]` → `onboarding_magic_link_sent` →
  `paywall_shown` → `paywall_trial_started` (or `paywall_skipped`)
- **Activation:** `onboarding_magic_link_sent` → contractor opens → contractor submits →
  `approval_approved`
- **Subscription:** `paywall_shown` → `paywall_trial_started` → first paid renewal

These are ad-hoc reporting queries (group by `event_name` + parse `properties`); no dedicated
endpoint — §8.B lists `/events` as the only analytics surface.
