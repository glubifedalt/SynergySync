# Synergy Sync

A small SwiftUI app that fetches a School Synergy timetable and refreshes a dedicated Apple Calendar. The repository is designed to be edited on Linux and built on a GitHub Actions `macos-latest` runner with XcodeGen.

## Important: fill in the portal request first

The project brief does not include a real School Synergy timetable URL, request method, or response sample. The shipped URL and JSON keys are deliberately placeholders; sync will stop with a configuration error until you edit them. Synergy deployments vary, so there is no safe universal endpoint to assume.

In browser DevTools, open Network, load the timetable, and identify the request returning the actual lesson data. Record its URL and query parameters, method, required headers, and a small redacted response sample. Never commit a real session cookie or personal timetable data.

Edit `Sources/SynergyClient.swift`:

1. Set `endpointTemplate` in `SynergyConfiguration`. `{weekStart}` and `{weekEnd}` are replaced with `yyyy-MM-dd`; change `requestURL` / `fetchWeek` if your portal uses other parameter names, a POST body, or extra required headers.
2. Set the response keys (`lessonsArrayKey`, `subjectKey`, `roomKey`, `teacherKey`, `startKey`, `endKey`) to match the response. If the array is nested, update `parse(data:)` to traverse that JSON path.
3. If the response is HTML, implement a site-specific Foundation-only parser in `parse(data:)`. The starter parser supports JSON arrays only; it does not claim to parse arbitrary HTML.
4. Match the timestamp format in `parseDate(_:)` if the portal returns a different format or timezone convention.

`SynergyClient.swift` imports only Foundation. On Linux, compile it as a standalone module after making the endpoint edits:

```bash
swiftc -parse-as-library -emit-module -module-name SynergyClient Sources/SynergyClient.swift
```

## Build on GitHub

Create a GitHub repository, then from this directory:

```bash
git init -b main
git add .
git commit -m "Add Synergy timetable sync app"
git remote add origin https://github.com/YOUR-USERNAME/YOUR-REPO.git
git push -u origin main
```

The push runs `.github/workflows/build-ipa.yml`. Open the Actions run and download the `SynergySync-unsigned-ipa` artifact. You can also run it from the Actions tab with **Build unsigned iOS IPA → Run workflow**.

The workflow generates `SynergySync.xcodeproj`, builds for generic iOS with code signing disabled, packages `Payload/SynergySync.app` into `SynergySync.ipa`, and uploads the IPA. An unsigned IPA is not installable through ordinary direct iPhone installation; sideloading requires a signing/install method appropriate for your device. This workflow intentionally does not provision a certificate or sign the app.

## Cookie and calendar behavior

The app saves the cookie string in `UserDefaults` on this device so it survives app launches. `UserDefaults` is local app storage, not Keychain; use a Keychain implementation if you want stronger at-rest protection. A cookie grants account access: do not share screenshots or builds containing it, and clear/update it when it expires.

On sync, the app requests full Calendar access, fetches weeks from the current date through 18 June 2027 with a 0.3 second pause between requests, removes existing events in the `School Timetable` calendar for that range, then writes fetched lessons and commits the batch. Subject is the event title; teacher and room go in notes. Empty weeks produce no events. The scraper reports HTTP 401/403 and recognizable login redirects as expired-session errors.

Calendar deletion and lesson writes use EventKit's deferred commits, followed by a single commit after the batch. The app uses the device's default calendar source when creating the dedicated calendar. Verify the endpoint and response mapping against a small test account before relying on a full sync.
