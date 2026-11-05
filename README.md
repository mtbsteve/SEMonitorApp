# SE Monitor

A standalone watchOS app that displays your SolarEdge PV system on your wrist,
talking **directly to the official SolarEdge Monitoring API v2** — no Home
Assistant, no third-party servers, no iPhone companion required.

> **Disclaimer.** SE Monitor is an independent third-party app. It is **not
> affiliated with, endorsed by, or sponsored by** SolarEdge Technologies, Inc.
> "SolarEdge" is a trademark of SolarEdge Technologies, Inc.; the name is used
> here only to describe the SolarEdge Monitoring API this app reads from.

All information about your PV system comes from the official SolarEdge
Monitoring system. Please review the API terms at
<https://monitoring.solaredge.com/solaredge-web/p/license>.

**Privacy.** There is nothing to collect: no backend, no analytics, no crash
reporting, no third-party SDKs. Your OAuth credentials and the cached readings
stay in the app's own App Group on the watch, and leave it only as HTTPS
requests to `monitoringapi.solaredge.com` for your own site. Since v2.0.0 is a
personal build, you are the only person who ever holds your credentials.

*(The formal German privacy policy that an App Store listing requires was
removed on 2026-11-05 together with the listing. It described the v1 API key
flow, which no longer exists. Earlier revisions are in the git history.)*

---

## ⚠️ v2.0.0 is a breaking change: build-your-own only

**v1.0.0** shipped on the App Store (2026-05-31) and let you paste a SolarEdge
API key into the watch. **That version no longer works at all** — SolarEdge
shut down the v1 Monitoring API on **2026-11-03**.

**v2.0.0** is a full rewrite against the v2 API, and it cannot be distributed
as a ready-to-run app. The reason is structural, not a policy choice:

- v2 drops static API keys for **OAuth 2.0 authorization-code flow**.
- Refreshing an access token requires the **client secret**.
- SolarEdge's own docs are explicit: *"This step should run from your backend,
  not from a browser. The Client Secret must not be exposed to the user."*

A watch app has no backend. Any binary shipped to other people would either
carry **my** secret and grant every installer access to **my** site, or need a
server I'm not going to run for a hobby project. So v2.0.0 has **no
user-enterable credential**: you register your own SolarEdge application, mint
your own grant, and build the app for your own watch. The v1.0.0 App Store listing
was removed on **2026-11-05**, since the API it depends on no longer exists.

If you own a SolarEdge site, a Mac, and a paid Apple Developer account, the
[Build your own](#build-your-own) section gets you there in about 30 minutes.
Everything needed is in this repo.

---

## What it shows

Three vertically-paged views (turn the Digital Crown to page between them):

1. **Overview** — current PV power, today's production, today's grid export,
   per-battery state-of-charge chips, and a refresh button.
2. **Power 24h** — line chart of Solar / Consumption / Grid (net) over the last
   24 hours at 15-minute resolution.
3. **Battery SoC 24h** — per-battery state-of-charge over the last 24 hours.

Plus a watch-face **complication** (circular / inline / corner / rectangular)
showing instantaneous solar power; the rectangular family also lists
per-battery SoC.

**Demo mode** generates a synthetic 24-hour dataset for screenshots and
testing, with no credentials and no network calls.

---

## API endpoints used

Base URL `https://monitoringapi.solaredge.com/v2`, bearer-token auth on every
call. One refresh = **4 calls**.

| Endpoint | Purpose |
|---|---|
| `/sites/{id}/overview` | Today's production / consumption / export totals |
| `/sites/{id}/power` | 24h PV power series (`resolution=QUARTER_HOUR`) |
| `/sites/{id}/meters/telemetry` | 24h consumption + grid import/export |
| `/sites/{id}/storage/telemetry` | 24h per-battery state-of-charge |

Site discovery is **not** an endpoint call: the OAuth callback returns your
`site_id` directly, and it's baked in at build time.

### v2 quirks worth knowing

These each cost real debugging time; they're documented in the source at the
point of use.

- **`storage` and `meters` are dictionaries**, keyed by hardware serial number
  (and, for meters, mixed with virtual names like `CONSUMPTION`). The keys
  differ per site, so the client locates meters by *which fields they carry*,
  never by key, and sorts storage keys so chart colours stay stable.
- **`stateOfEnergy` is a 0…1 fraction despite its unit being `PERCENTAGE`.**
  Verified: 0.18889 against `remainingEnergy` 1,653.76 Wh implies an 8,756 Wh
  pack, and the series hits exactly 1.0 when full. Hence the ×100.
- **Timestamps must be sent as UTC `Z`.** A literal `+` in a query string
  decodes to a space, so `+02:00` offsets produce silent `400`s.
- **Every series shares one envelope**: `{unit, values: [{timestamp, value}]}`.
- **Advanced Monitoring endpoints** (per-destination data, Live Power Flow,
  Weather Guard, Battery Backup Reserve) require Business Pro or above and
  return `403` on the free tier. None are used here.

---

## Energy accounting

**On v2 this is a solved problem, and the code must stay simple.** Read this
before touching `fetchTodayTotals`.

`overview.production.total` is the **panel-side** figure. It includes
`toStorage` — PV that charged the battery DC-side without ever reaching the AC
bus — and excludes energy the battery took *from the grid*, because grid import
isn't a PV destination. That is exactly what the SolarEdge portal shows:

| 2026-11-03 | API | Portal |
|---|---|---|
| Production | 6,942.34 Wh | 6.94 kWh |
| Consumption | 43,311.15 Wh | 43.3 kWh |

Cross-checked three ways: `/energy?resolution=DAY` independently returned
6,942.34 Wh; `toStorage` was 1,844.89 Wh and *inside* the total, proving it's
panel-side; and the battery discharged 13,713 Wh that day against only
1,845 Wh of PV charge, so roughly 11,868 Wh came from the grid and correctly
appears nowhere in `production`.

```
Production Today   = overview.production.total      (panel-side, exact)
Consumption Today  = overview.consumption.total     (exact)
Exported Today     = overview.production.toGrid     (grid-metered, exact)
NOW power          = last sample of /power          (panel-side)
Battery SoC        = storage/telemetry stateOfEnergy × 100
```

The 24h chart's Solar line is the **raw** `/power` series. That endpoint is
panel-side too, confirmed by integrating a full day: the integral came to
7,618 Wh against the day's 6,942 Wh (ratio ≈1.10, the expected rectangle-rule
overshoot on instantaneous samples), whereas a genuinely AC-side series would
have landed *below* the total at ≈0.73.

> ### Do not reintroduce the v1 reconstruction
>
> v1 had to rebuild panel-side production by energy balance, because the v1
> meters were AC-side:
>
> ```
> Production = AC_Production + charge − discharge − grid_charge
> ```
>
> That carried a stable ~3 % shortfall from battery round-trip losses, needed
> `ACGridCharging` telemetry that only the *first* battery reported, and was a
> permanent source of doubt. **All of it is deleted.** v2 reports the figure
> directly and matches the portal exactly. Do not re-add it, and do not apply
> an efficiency correction factor — there is nothing left to correct.

---

## Credit budget

v2 bills **1 credit per endpoint call**, and the free tier is the binding
constraint:

| | Free tier |
|---|---|
| Credits / month | 2,000 |
| Calls / minute | 10 |
| Registered applications | 1 |
| Overage | **not available** |

That last row is the dangerous one. There is no pay-as-you-go on free: hitting
2,000 is a **hard wall until the billing cycle resets**, with no way to buy your
way out. The app therefore rations itself rather than trusting the server to
say no.

`CreditBudget` in `SEConfig.swift` enforces a day-keyed counter in the App
Group:

- `callsPerRefresh = 4`
- `maxCallsPerDay = 48` → 12 refreshes/day, ≈1,488 credits in a 31-day month

A refresh that cannot afford its 4 calls fails with `.budgetExhausted` instead
of issuing them. Raise `maxCallsPerDay` cautiously: 16 refreshes/day is
≈1,984/month, i.e. no margin at all.

**The complication never calls the API.** `getTimeline` only reads the snapshot
the watch app cached. Two reasons, both load-bearing: a widget extension is a
*separate process*, so it would race the watch app for a refresh token that
rotates on every use (see below) and destroy the grant; and its timeline
updates are frequent enough to burn the monthly budget on their own.

---

## OAuth token lifecycle (read this before debugging auth)

The single biggest source of operational trouble, so it's worth being blunt
about the mechanics:

- Access tokens last **2 hours**.
- **The refresh token rotates on every refresh.** The response carries a new
  one and *the old one dies immediately*.
- An unused grant expires after **14 idle days**.
- Recovery from a dead grant requires **browser consent on a Mac**. There is no
  way to do it from the watch.

Three consequences:

**1. Only one consumer per grant.** The app and `tools/se-token.sh` share the
same grant. Once the app is running, **stop using the script** — the first
refresh on either side invalidates the other. If you need the CLI for
exploration, run a second consent flow and keep the two configs separate (note
the free tier allows only one registered *application*, but a grant is
per-authorization).

### One seed, one install

The same rule bites between *installs of the same build*. A build carries
exactly one seed refresh token. The Simulator and a real watch are separate
installs with separate App Group storage but the **same** baked-in seed, so
whichever runs first spends it and the other is dead on arrival with
"Authorization expired".

The Simulator therefore reports itself as **not configured** and falls through
to Demo mode; `SEConfig.isSimulator` gates this, and `SETokenStore` refuses to
refresh there as well. Live data on the Simulator is not worth costing the
watch its grant.

**Recovering without a browser round-trip.** If an install has already spent
the seed, the live token is sitting in *that* install's storage. For a
Simulator, read it out and hand it back to the script rather than re-running
consent:

```bash
plutil -extract se_refresh_token raw ~/Library/Developer/CoreSimulator/Devices/<DEVICE-UDID>/data/Containers/Shared/AppGroup/<GROUP-UUID>/Library/Preferences/group.com.mtbsteve.semonitor.plist
```

Put that value in `SE_REFRESH_TOKEN` in `~/.config/semonitor/se-api.env`, then
`tools/se-token.sh xcconfig > Secrets.xcconfig` — it verifies and rotates
before emitting, so a stale value fails loudly instead of being baked in.

**2. Refreshes must be serialized.** `SETokenStore` is an `actor` with explicit
single-flight coalescing. An actor alone is not enough: every `await` is a
suspension point where a second caller can enter, so two callers could each
start their own refresh and mutually invalidate. The in-flight task is shared
instead. It also persists the rotated refresh token *before* the access token,
so a crash between the two writes loses only a cheap cache, not the grant.

**3. Re-provisioning has to override stored state.** Stored tokens normally win
over the build-time seed — they must, since the seed goes stale the moment the
app's first refresh rotates it. But that alone would make a *deliberately*
refreshed seed unusable: you'd regenerate `Secrets.xcconfig`, rebuild, and the
app would keep preferring a stored token that is itself dead. `SETokenStore`
records which seed it last adopted, so an ordinary relaunch keeps its stored
token while a rebuild carrying **new** credentials resets to it. "Regenerate
and rebuild" is therefore a dependable recovery path.

---

## Requirements

- **macOS** with **Xcode 27.2** or later (watchOS 27.2 SDK)
- **Paid Apple Developer account** — the free tier cannot install watchOS apps
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- `jq` and `curl` for the token helper (`brew install jq`)
- A SolarEdge site **you own**, with monitoring portal access
- Apple Watch running **watchOS 10** or later

---

## Build your own

### 1. Register a SolarEdge application

1. Create a developer account at <https://api-docs.solaredge.com>.
2. Create an **Application** with access type **Site Access** and scope
   **`SITE_DATA`**.
3. Copy the **Client ID** and **Client Secret**. The secret is shown **once** —
   save it now.

### 2. Mint a grant

```bash
git clone https://github.com/mtbsteve/SEMonitorApp.git
cd SEMonitorApp
install -m 700 tools/se-token.sh ~/bin/se-token.sh   # or run it in place
```

```bash
tools/se-token.sh init
```

This prompts for your Client ID and Secret and writes them to
`~/.config/semonitor/se-api.env` (mode 600, **outside the repo**).

```bash
tools/se-token.sh authorize
```

Open the printed URL, approve your site, then copy the **entire** redirect URL
from the address bar:

```bash
tools/se-token.sh exchange '<the full redirect URL>'
```

**Keep the single quotes.** An unquoted `&` splits the command in zsh and the
exchange fails with no obvious reason. The script parses the `code` and
`site_id` out of the URL and stores the refresh token.

### 3. Generate `Secrets.xcconfig`

```bash
tools/se-token.sh xcconfig > Secrets.xcconfig
```

This verifies the grant against the live token endpoint before emitting
anything, so it cannot bake in a dead token. Add your Apple Developer Team ID
to the generated file (`SE_DEVELOPMENT_TEAM`) — see
[`Secrets.xcconfig.example`](Secrets.xcconfig.example) for the full annotated
template.

> **Generate once, then build once.** Each `xcconfig` run rotates the refresh
> token and invalidates the previous one. Running it twice without building in
> between leaves your build with a dead token.

### 4. Use your own bundle identifiers

Bundle IDs are globally unique, so `com.mtbsteve.semonitor` will not sign for
you. Replace the prefix in all of:

- [`project.yml`](project.yml) — four places (`bundleIdPrefix` plus one
  `PRODUCT_BUNDLE_IDENTIFIER` per target)
- [`SEAPIApp Watch App/SEAPIApp.entitlements`](SEAPIApp%20Watch%20App/SEAPIApp.entitlements) — the App Group
- [`SEAPIComplication/SEAPIComplication.entitlements`](SEAPIComplication/SEAPIComplication.entitlements) — the same App Group
- [`SEAPIApp Watch App/Models.swift`](SEAPIApp%20Watch%20App/Models.swift) — `AppConfig.appGroupID`

The App Group string must match in all three places or the complication reads
an empty cache. Register the App Group in your Apple Developer account too.

### 5. Build and install

```bash
xcodegen && open SEAPIApp.xcodeproj
```

Select the **SE Monitor (Watch)** scheme, choose your watch as the destination,
and Run. See [Installing on a real watch](#installing-on-a-real-watch) below —
it is fiddlier than it should be.

Finally, add the complication: long-press the watch face → Edit →
Complications → **SE Monitor**.

---

## Installing on a real watch

Modern watches pair with Xcode **over Wi-Fi**, directly. Connecting your iPhone
by USB does nothing for watch debugging — a common and time-wasting assumption.

Check what Xcode actually sees:

```bash
xcrun devicectl list devices | grep -i watch
```

`connected` is what you want. `available (paired)` means Xcode knows and trusts
the watch but cannot reach it — that's the "Currently Unavailable" state in
Devices & Simulators. In that case:

1. **Put the watch on its charger, unlocked, near the Mac.** While your iPhone
   is nearby over Bluetooth the watch parks its Wi-Fi radio to save power, so
   it's invisible to the Mac *because* everything is working normally. The
   charger keeps Wi-Fi up.
2. **Same Wi-Fi network as the Mac** — and not a guest network, which isolates
   clients and blocks this permanently. If your 2.4 and 5 GHz bands use
   separate SSIDs, put both devices on the same one.
3. **Enable Developer Mode**: watch → Settings → Privacy & Security →
   Developer Mode → On, then restart the watch.
4. **Turn off Theater Mode and Low Power Mode** — both suppress Wi-Fi.

The first install shows "Preparing debugger support for Apple Watch" and can
genuinely take 10–20 minutes with no visible progress. Don't cancel it.

### "Update to recommended settings"

Don't accept it. The `.xcodeproj` is generated by XcodeGen and gitignored, so
anything Xcode writes there is destroyed by the next `xcodegen` run — the
warning returns, and you get a setting that looks applied but silently reverts.
Change `options.xcodeVersion` in [`project.yml`](project.yml) instead; it is
set to `27.2` and is what `LastUpgradeCheck` is generated from.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| **"Authorization expired"** | The refresh token is spent or past its 14-day idle life. Re-run steps 2–3 (`authorize` → `exchange` → `xcconfig`), then rebuild. Only browser consent on a Mac can fix this. |
| **"No SolarEdge credentials in this build"** | The `SE*` keys are missing from the built `Info.plist`. Confirm `Secrets.xcconfig` exists and was present when you ran `xcodegen`. |
| **"Simulator: live data is disabled."** | By design, not a fault — see [One seed, one install](#one-seed-one-install). Use Demo mode in the Simulator. |
| **"Daily API budget used. Showing cached data."** | `CreditBudget` stopped you at 48 calls. Resets at local midnight. |
| **"Rate limit hit. Try again in a minute."** | More than 10 calls/minute. |
| **"Monthly API credit limit reached."** | The 2,000-credit wall. No overage on free — it clears only at the billing-cycle reset. |
| **Complication shows stale data** | By design: it is cache-only and never calls the API. Open the app to refresh. |
| **Charts empty, Overview fine** | `meters`/`storage` keys differ per site. Check `tools/se-token.sh get "/sites/<id>/meters/telemetry?..."` for the field names actually present. |
| **No battery screen** | Sites without storage return `400`/`404` from `storage/telemetry`, which is treated as "no batteries" rather than an error. |

The token helper is the fastest way to inspect the live API by hand:

```bash
tools/se-token.sh today
```

```bash
tools/se-token.sh get "/sites/3958787/overview?from=2026-11-03T00:00:00Z&to=2026-11-04T00:00:00Z"
```

Other subcommands: `init`, `authorize`, `exchange`, `token`, `header`, `get`,
`day`, `energy`, `today`, `refresh`, `revoke`, `xcconfig`. Remember that every
`refresh` rotates the grant out from under the app.

---

## Architecture

```
SEAPIApp Watch App/
  SEAPIApp.swift            — App entry, @main, environment
  ContentView.swift         — Root + SetupView + Loading/Error views
  OverviewView.swift        — Header, NOW card, Production/Exported, SoC chips
  PowerChartView.swift      — Swift Charts 24h power chart
  BatteryChartView.swift    — Swift Charts 24h per-battery SoC chart
  Store.swift               — @MainActor ObservableObject, auto-refresh, cache
  DemoData.swift            — Synthetic 24h dataset for demo mode
  SolarEdgeAPI.swift        — async/await v2 client (bearer auth)
  SETokenStore.swift        — OAuth actor: rotation, single-flight, seed adoption
  SEConfig.swift            — Info.plist credentials + CreditBudget
  Models.swift              — Snapshot / HistorySeries / AppConfig / errors
  Info.plist                — generated by XcodeGen; holds $(SE_*) placeholders
  SEAPIApp.entitlements     — App Group
  PrivacyInfo.xcprivacy

SEAPIComplication/
  SEAPIComplication.swift   — WidgetKit complication (4 families), cache-only
  SEAPIComplication.entitlements
  Info.plist, PrivacyInfo.xcprivacy

tools/
  se-token.sh               — OAuth helper + curl wrapper for the v2 API

project.yml                 — XcodeGen spec (the .xcodeproj is NOT committed)
Secrets.xcconfig.example    — annotated credential template
Secrets.xcconfig            — your credentials (gitignored)
```

The watch app and complication share an **App Group** for the cached snapshot
and history. The complication compiles only `Models.swift` from the watch
app — deliberately *not* `SolarEdgeAPI.swift` or `SEConfig.swift`, so it cannot
acquire credentials or refresh a token even by accident.

Credentials reach the app as custom `Info.plist` keys via an explicit plist,
**not** `INFOPLIST_KEY_*` build settings: those only work for keys on Xcode's
known allowlist and custom names are **silently dropped**. That failure mode
is invisible — the build succeeds and the app launches into the setup screen
with nothing in the logs.

---

## Security notes

- The **client secret** is baked into your build. That is acceptable for an app
  you install on your own watch and nowhere else. **Never distribute a binary
  built from your `Secrets.xcconfig`** — it hands your SolarEdge site to
  whoever installs it, and SolarEdge's terms forbid it.
- Credentials live in exactly two places, both gitignored or outside the repo:
  `Secrets.xcconfig` and `~/.config/semonitor/se-api.env` (mode 600). The
  helper passes secrets to `curl` over **stdin**, so they never appear in `ps`.
- `SEAPIApp Watch App/Info.plist` *is* committed — it contains only
  `$(SE_CLIENT_ID)`-style placeholders, substituted at build time.
- All traffic is HTTPS directly between the watch and
  `monitoringapi.solaredge.com`. Nothing is sent anywhere else.
- Revoke a grant you no longer need: `tools/se-token.sh revoke`.

---

## Known limitations

- **One grant, one consumer.** The app and the CLI helper cannot be used
  against the same grant concurrently.
- **Free-tier credits cap refresh cadence** at 12 refreshes/day by default.
- **Complication data is only as fresh as the last app refresh**, by design.
- **No background refresh.** The 15-minute timer runs only in the foreground;
  watchOS background budgets make a dependable cadence impossible for an app
  that must also stay inside a 2,000-credit month.
- **Advanced Monitoring endpoints are unavailable** on the free tier (`403`), so
  per-destination breakdowns and Live Power Flow are not used.
- **Recovery needs a Mac.** A dead grant cannot be re-minted from the watch.

---

## Version history

| Version | Status |
|---|---|
| **2.0.0** | v2 API rewrite. Personal build only — no user-enterable credential. |
| 1.1 | Developed, never shipped: the v1 API shut down before submission. |
| 1.0.0 (build 2) | First public App Store release, 2026-05-31. Non-functional since the v1 API shut down on 2026-11-03; listing removed from the App Store on 2026-11-05. |
