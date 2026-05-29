# SE Monitor

A standalone watchOS app that displays your SolarEdge PV system on your wrist,
talking **directly to the official SolarEdge Monitoring API** — no Home
Assistant, no third-party servers, no iPhone companion required.

> **Disclaimer.** SE Monitor is an independent third-party app. It is **not
> affiliated with, endorsed by, or sponsored by** SolarEdge Technologies, Inc.
> "SolarEdge" is a trademark of SolarEdge Technologies, Inc.; the name is used
> here only to describe the SolarEdge Monitoring API this app reads from.

**Datenschutz / Privacy policy:** <https://mtbsteve.github.io/SEMonitorApp/Datenschutzrichtlinie.html>
([Markdown source](Datenschutzrichtlinie.md))

** All information about your SolarEdge PV system is derived from the official SolarEdge Monitoring system. Please review the API terms and conditions at this link: <https://monitoring.solaredge.com/solaredge-web/p/license>

## What it shows

Three vertically-paged views on the Watch:

1. **Overview** — current PV power, today's panel-side production, today's
   grid export, per-battery state-of-charge chips, and a refresh button.
2. **Power 24h** — line chart of Solar / Consumption / Grid (net) over the
   last 24 hours, 15-min resolution; the Solar line is panel-side PV
   (AC-side Production + DC battery charge correction).
3. **Battery SoC 24h** — per-battery State-of-Charge over the last 24 hours.

Plus a watch-face **complication** (circular / inline / corner / rectangular)
showing instantaneous solar power; the rectangular family also lists per-stack
battery SoC.

Demo mode generates a synthetic 24h dataset for screenshots, demos, and
testing without an API key.

## API endpoints used

Per the SolarEdge Monitoring API spec (March 2026 revision):

| Endpoint                   | Purpose                                          |
|----------------------------|--------------------------------------------------|
| `/sites/list`              | One-time site discovery from an Account key      |
| `/site/{id}/overview`      | Current power + today/lifetime energy            |
| `/site/{id}/powerDetails`  | 24h Production / Consumption / FeedIn / Purchased |
| `/site/{id}/storageData`   | 24h per-battery State-of-Charge + power          |

Authentication is by `api_key` query parameter on every call, exactly as the
spec mandates. The key is stored only in watchOS `UserDefaults` (App Group),
and is sent only as the query parameter in HTTPS calls to
`monitoringapi.solaredge.com`.

## Energy accounting notes (DC-coupled batteries)

SolarEdge Home Batteries are DC-coupled: PV energy that charges the battery
goes directly **DC→DC** through the battery management hardware and never
crosses the AC inverter. As a consequence the API's `/powerDetails.Production`
meter (AC-side) under-reports total PV by the amount of DC battery charging
and includes battery discharge through the inverter as if it were PV.

This app corrects for both:

- **Production Today** = AC `Production` + today's **net** battery delta
  (charge − discharge from `/storageData`). Energy balance:
  `PV_total = AC_Production + (charge_DC − discharge_DC_via_AC)`.
- **Power chart (Solar line)** applies the same correction per 15-min slot:
  charging adds back the DC bypass; discharging is already in `Production` and
  is subtracted so night-time battery output doesn't masquerade as solar.

The Solar chart and Production Today therefore both reflect what the panels
generated, matching the SolarEdge portal within sampling-resolution noise.

**Exported Today** comes straight from `/powerDetails.FeedIn` (exact).
"Consumption Today" was originally shown but removed because the API's
Consumption meter under-reports relative to the portal by 1–2 kWh on
DC-coupled battery sites, with no formula derivable from the available API
meters that reproduces the portal's number. Showing FeedIn instead keeps the
displayed values exact.

**PV Lifetime** is not shown because the API's lifetime is AC-side and
therefore under-reports cumulative PV by the cumulative DC battery charge
over the site's life. The portal's lifetime can read several MWh higher.

## Rate-limit accounting

SolarEdge enforces **300 calls/day per account token**. The app's 15-minute
foreground refresh cadence × 3 endpoints per refresh = **288 calls/day**,
sitting just under the cap. Manual refresh taps and the complication's
`getTimeline` count against that budget too. To stretch quota further, raise
`AppConfig.refreshInterval` in `SEAPIApp Watch App/Models.swift`.

## Requirements

- macOS Tahoe + Xcode 16+
- Apple Developer account (paid; free tier cannot install watchOS apps)
- A SolarEdge **Account-level API key**: Monitoring Portal → Account Admin →
  Company Details → API Access → Generate API key. (Site-level keys can't
  call `/sites/list` and aren't currently supported by the setup UI.)

## Generating the Xcode project

This repo uses [XcodeGen](https://github.com/yonaskolb/XcodeGen); the
`.xcodeproj` is not committed.

```bash
brew install xcodegen
cd SEAPIApp
xcodegen
open SEAPIApp.xcodeproj
```

## First-time configuration in Xcode

1. Select the project in the Xcode navigator and open the **Signing &
   Capabilities** tab for each target (`SEAPIApp Watch App`,
   `SEAPIComplication`).
2. Set your **Team** (Apple ID).
3. If Xcode complains the bundle IDs are taken, change the prefix
   `com.mtbsteve.semonitor` to a unique one across both targets, then update the
   matching **App Group** (`group.<your-prefix>`) and `keychain-access-group`
   in:
   - `project.yml`
   - `SEAPIApp Watch App/SEAPIApp.entitlements`
   - `SEAPIComplication/SEAPIComplication.entitlements`
   - `SEAPIApp Watch App/Models.swift` (`AppConfig.appGroupID`)
   - `SEAPIComplication/SEAPIComplication.swift` (top-of-file `appGroupID`)
   - Re-run `xcodegen`.
4. Confirm the **App Group** and **Keychain Sharing** capabilities are present
   on both targets and use the same group / access group.

## Running

1. Build & run the **SEAPIApp Watch App** scheme on your Apple Watch.
2. Paste your Account-level API key (dictation is easier than typing).
3. The app calls `/sites/list`, picks the first site, and starts displaying
   live data. Subsequent launches reuse the cached site ID.
4. Add the **SolarEdge Power** complication to a watch face (long-press face →
   Edit → Complications).

Demo mode: tap **Use Demo Data** on the setup screen for a synthetic dataset
that requires no API key and makes no network calls.

## Architecture

```
SEAPIApp Watch App/
  SEAPIApp.swift            — App entry, @main, environment
  ContentView.swift         — Root + SetupView + Loading/Error views
  OverviewView.swift        — Header card + Production/Exported stats + battery chips
  PowerChartView.swift      — Swift Charts 24h power chart (Solar corrected to panel-side)
  BatteryChartView.swift    — Swift Charts 24h per-battery SoC chart
  Store.swift               — @MainActor ObservableObject, auto-refresh, shared cache
  DemoData.swift            — Synthetic 24h dataset for demo mode
  SolarEdgeAPI.swift        — async/await client (api_key query auth)
  Models.swift              — Decodables + Snapshot/HistorySeries + AppConfig
  SEAPIApp.entitlements     — App Group + Keychain sharing
  PrivacyInfo.xcprivacy
  Assets.xcassets/

SEAPIComplication/
  SEAPIComplication.swift   — WidgetKit complication (4 families)
  SEAPIComplication.entitlements
  PrivacyInfo.xcprivacy
  Assets.xcassets/
  Info.plist
```

The Watch app and complication share an **App Group**
(`group.com.mtbsteve.semonitor`) for the cached snapshot, history, and the compact
values the complication reads.

## Security notes

- The API key grants full read access to your SolarEdge site(s). Treat it like
  a password.
- It is stored only in watchOS `UserDefaults` on this device. It is sent over
  HTTPS as a query parameter (per the SolarEdge spec).
- Never commit your key. `.gitignore` excludes `*.token` and `Secrets.xcconfig`.
- SolarEdge recommends rotating keys every 6 months.

## Known limitations

- Site-level API keys can't call `/sites/list`; the setup UI does not yet
  support manual site-ID entry. Use an Account-level key.
- Battery telemetries from some packs may have gaps; the chart skips missing
  samples.
- watchOS background-refresh budgets cap real-world cadence — the in-app
  15-minute timer applies only while the app is in the foreground or the
  complication is fetching its timeline.

## App Store description (template)

A copy-pasteable description for App Store Connect. The trademark disclaimer
at the end should stay.

```
SE Monitor puts your SolarEdge PV system on your wrist.

A standalone Apple Watch app that talks directly to the official SolarEdge
Monitoring API — no Home Assistant, no third-party servers, no iPhone
companion. Enter your SolarEdge Account-level API key once on the Watch and
SE Monitor shows:

• Current PV power (now), updated every 15 minutes
• Today's panel-side production (corrected for DC battery charging on sites
  with SolarEdge Home Batteries)
• Today's energy exported to the grid
• Per-battery State-of-Charge for each of your Home Battery stacks
• A 24-hour line chart of Solar / Consumption / Grid
• A 24-hour chart of battery State-of-Charge per battery
• A watch-face complication (circular, inline, corner, and rectangular
  families) with instantaneous solar power; the rectangular family also
  shows your battery SoC

All data flows directly between your Apple Watch and SolarEdge's servers —
nothing is sent to any other party. Your API key is stored only in watchOS
UserDefaults on this device.

Demo mode generates a synthetic 24-hour dataset for screenshots and demos
without an API key or any network access.

Requirements:
• A SolarEdge Account-level API key (Monitoring Portal → Account Admin →
  Company Details → API Access → Generate API key)
• An Apple Watch running watchOS 10 or later

Disclaimer: SE Monitor is an independent third-party app. It is not
affiliated with, endorsed by, or sponsored by SolarEdge Technologies, Inc.
"SolarEdge" is a trademark of SolarEdge Technologies, Inc.
```
