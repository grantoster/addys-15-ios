# Addy's 15% (iPad + iPhone)

Addy snaps kids' clothes and shoes on her iPad; Claude reads the photos, writes the Facebook
Marketplace listing and looks up what similar items sell for. The listing syncs to Mom's iPhone,
where she saves the photos, copies the text and posts it in Facebook, then marks it sold. Addy gets
15% of each sale in her piggy bank.

One app, two modes (chosen on first launch). Sync uses the app's CloudKit public database: both
devices enter the same 6-letter family code, each device writes only its own records, and records
are fetched by name (no queries). See `Addys15/Sources/CloudSync.swift`.

Facebook has no public API for personal Marketplace listings, so posting is copy and paste.

## One-time setup
1. **Bundle ID with iCloud**: developer.apple.com > Identifiers > + > App IDs > App, e.g.
   `com.yourname.addys15`. Turn on **iCloud** (CloudKit) and assign a container named
   `iCloud.<bundle id>` (create it under Identifiers > iCloud Containers).
2. **CloudKit schema**: in the CloudKit Console, create the record types in `cloudkit/schema.ckdb`
   (A15AddyIndex, A15Item, A15MomLedger) in Development, then **Deploy Schema Changes** to Production.
   TestFlight builds use Production.
3. **App record**: App Store Connect > Apps > + > New App, pick the bundle ID.
4. **Repository secrets**: `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (same as the
   other apps), `BUNDLE_ID`, and optionally `ANTHROPIC_API_KEY` (built into the app so no one types
   it on the iPad; otherwise paste it in the app's Settings).

## Building
Every push to `main`, the 1st of each month, or Actions > iOS > Run workflow builds on a macOS
runner and uploads to TestFlight. The monthly build keeps TestFlight's 90-day expiry from removing
the app.

## Rules the app follows
- Prices: a suggestion only when Claude found at least 3 real prices online; it's the median,
  rounded to the dollar (halves up). Otherwise Mom sets the price.
- Addy's share: 15% of each sale, rounded to the cent (halves up); her total is the sum of those.
- Menu (⋯) on Addy's screens: Start over, My piggy bank, Settings (grown-ups: press and hold 2 seconds). Mom: gear button.
