# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

`fanfan` is a macOS menu bar app (Swift 5 language mode with Swift 6 approachable-concurrency settings / SwiftUI on an AppKit menu-bar lifecycle) that controls Mac fan speeds. It targets **macOS 26+**, Apple Silicon or Intel, and has **no third-party Swift dependencies**.

The repo also contains a small **C daemon** (`fanfan-smcd`) that runs as a root LaunchDaemon. The Swift app is unprivileged; all root-only SMC writes go through the daemon via a Unix socket.

## Privilege architecture — read this before touching fan-write code

```
fanfan.app (user)  ──Unix socket──▶  fanfan-smcd (root)  ──IOKit──▶  AppleSMC
```

- **Temperature / sensor reads** happen directly from the app via IOKit. No daemon needed, no elevated privileges.
- **Fan writes** must go through the daemon. The versioned socket protocol is intentionally tiny:
  - `PINGV2` → `OK pong 2 <idle|active|restoring>` (health/state query only)
  - `RENEWV2` → `OK` only while an active control lease exists
  - `SETV2 <fan> <rpm>` (fan: 0–7; rpm: hardware-clamped in daemon)
  - `AUTOV2 <fan>` (hand control back to firmware)
  - Legacy `AUTO <fan>` remains release-only compatibility for safely relinquishing old control; legacy SET/PING are rejected.
- Socket path: `/var/run/fanfan-smcd.sock` (mode `0660`, owner `root:admin`).
- Manual control is lease-based: while SET control is active the app renews every
  3 seconds; after 10 seconds without activity the daemon restores firmware AUTO.
- Daemon binary lives at `/Library/PrivilegedHelperTools/fanfan-smcd`; LaunchDaemon plist at `/Library/LaunchDaemons/com.hoobnn.fanfan.smcd.plist`.
- Installation is performed by `PermissionsManager.installHelper` via a single `osascript` "with administrator privileges" call — one password prompt, ever. Do not introduce additional sudo prompts or new commands across the socket without strong justification: the small, audited surface is a deliberate security property.

Swift side of the socket: `fanfan/Core/SMCDaemonClient.swift`. Daemon source: `tools/fanfan-smcd/fanfan-smcd.c` (+ `smc.h`). If you change one, the other almost always needs a matching change.

## Code layout (only the non-obvious parts)

- `fanfan/App/fanfanApp.swift` — `@main` SwiftUI `App` + `AppDelegate`. The app uses `NSApp.setActivationPolicy(.accessory)` (no Dock icon) and a `Settings` scene placeholder; the real UI surfaces are the status-bar popover (`StatusBarManager`) and a separate `Window("settings")` scene.
- `fanfan/Core/`
  - `SystemMonitor.swift` — IOKit-backed sensor/SMC reader (large; the catalogue of SMC keys lives here).
  - `FanController.swift` — automatic-mode controller: EMA-smoothed temperature input, a PID loop, an asymmetric RPM dead-band (easy to spin up, reluctant to spin down) with an 8 s minimum hold, asymmetric ramping (fast up / slow down), and the Silent / Balanced / Performance / Custom presets. The anti-hunting tuning (smoothing + asymmetry) exists specifically to stop audible fan "pumping" — preserve it when refactoring.
  - `StatusBarManager.swift` — menu-bar item, popover lifecycle, and the four status-bar display modes (`temperature`, `power`, `fanPercent`, `iconOnly`) driven by the `StatusBarDisplayModeChanged` notification.
  - `SMCDaemonClient.swift`, `PermissionsManager.swift` — see "Privilege architecture" above.
  - `BatteryMonitor.swift`, `LaunchAtLoginManager.swift` (uses `ServiceManager`, no plist hacks), `UserDefaultsManager.swift`, `FanRPMBounds.swift`.
- `fanfan/ViewModels/FanControlViewModel.swift` — the single Combine `ObservableObject` wiring `SystemMonitor` + `FanController` + user defaults to the views. UI mutations flow through this; treat it as the source of truth for fan state in the UI layer.
- `fanfan/UI/Theme.swift` — design rule the codebase follows literally: **temperature is the only color**. The whole UI is monochrome and a near-invisible warm tint bleeds in from the top of the popover as temps rise. When adding UI, pull colors / accents from `Theme`, do not hardcode hues.
- `fanfan/UI/Views/` — `PopoverView` (menu-bar popover) and `SettingsView`. Reusable bits under `Components/` (`HeroCard`, `ControlsCard`, `HeatBar`, `TempCurveView`, `FanBladeView`, …).
- `fanfan/Resources/`
  - `Assets.xcassets`, localized strings under `en.lproj/` and `zh-Hans.lproj/` (use `NSLocalizedString` — both locales must stay in sync).
  - `fanfan-smcd` (the compiled C daemon, bundled as a resource) and `com.hoobnn.fanfan.smcd.plist`.
  - `fanfan.entitlements` (hardened runtime entitlements for Developer ID signing).
- `tools/fanfan-smcd/` — C daemon source + `Makefile` + `smc.h`.
- `fanfanTests/` — `FanControlTests.swift`, `SystemMonitorTests.swift`, `fanfanTests.swift` (XCTest target).
- `scripts/build-release.sh` — full Developer ID release pipeline (build → sign → notarize → staple → zip + DMG + sha256). `scripts/install.sh` is the public one-liner installer.
- `.github/workflows/release.yml` — CI tag-triggered release build (`v*` tags or manual dispatch).

## Build, run, test

This is an Xcode project — there is no `swift build` / SwiftPM. Use the Xcode CLI:

```bash
# Build (Debug) headlessly
xcodebuild -project fanfan.xcodeproj -scheme fanfan -configuration Debug build

# Run the test bundle
xcodebuild -project fanfan.xcodeproj -scheme fanfan \
  -destination 'platform=macOS' test

# Run a single test method
xcodebuild -project fanfan.xcodeproj -scheme fanfan \
  -destination 'platform=macOS' test \
  -only-testing:fanfanTests/FanControlTests/<methodName>
```

For interactive development, open `fanfan.xcodeproj` in Xcode and use the `fanfan` scheme.

### Building the daemon standalone

```bash
make -C tools/fanfan-smcd            # produces a macOS 26+ arm64/x86_64 universal binary
make -C tools/fanfan-smcd clean
```

When the daemon source changes, **also refresh the bundled copy** that Xcode ships as a resource:

```bash
cp tools/fanfan-smcd/fanfan-smcd fanfan/Resources/fanfan-smcd
```

`scripts/build-release.sh` does this automatically; manual debug builds do not.

### Release builds

```bash
./scripts/build-release.sh 1.2.3
```

Requires the `Developer ID Application: HAOBIN WU (8FUPL8QHFH)` certificate and a `notarytool` keychain profile named `fanfan-notarize` (override with `NOTARY_PROFILE=…`). Output lands in `releases/` as `.zip` + `.dmg` + `.sha256`. CI does the same pipeline on `v*` tags via `.github/workflows/release.yml`.

### Release checklist (do this in order before pushing the tag)

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `fanfan.xcodeproj/project.pbxproj` (both Debug and Release configurations for the main app target).
2. Add a new section to `CHANGELOG.md` for the version being released.
3. Commit both files, then `git tag vX.Y.Z && git push && git push origin vX.Y.Z`.

## Commits — required format

`husky` runs `commitlint` on every commit message. Header must match:

```
<emoji> <type>(<scope>): <subject>
```

Rules (enforced by `commitlint.config.js`):

- `type` must be one of the gitmoji names listed in the config (`bug`, `sparkles`, `tada`, `truck`, `recycle`, `wrench`, `test-tube`, etc.) — see the `EMOJI_TYPE` map.
- The leading emoji is **mandatory** and must be the one paired with that type (1:1). `🐛 bug(...)`, `✨ sparkles(...)`, `🚚 truck(...)`. Mismatches fail the hook.
- `scope` must be lowercase.
- Header ≤ 72 chars; subject non-empty.

Example from this repo: `🐛 bug(ui): close popover when app loses focus`.

If a commit-msg hook fails, fix the message — do not bypass with `--no-verify`.

### AI signature preference

AI-assisted commits in this project should include an AI `Co-Authored-By` trailer. For Codex work, use:

```
Co-Authored-By: Codex <noreply@openai.com>
```

## Conventions worth remembering

- **macOS 26 + Swift 5 language mode** — the project enables approachable-concurrency/upcoming features, but a full strict Swift 6 migration still requires isolating the SMC worker from the main-actor observable facade.
- **No third-party SDKs.** Don't add SwiftPM dependencies casually; the lean dependency surface is intentional.
- **Localization is bilingual.** Every user-visible string lives in both `en.lproj/Localizable.strings` and `zh-Hans.lproj/Localizable.strings`.
- **Fanless Macs are a real case.** Some MacBook Airs report no fans — the UI hides controls entirely instead of showing fake sliders. Don't assume `fanCount > 0`.
- **Per-fan asymmetry is supported.** Multi-fan machines get independent sliders / targets per fan; data structures already model this — preserve it when refactoring.
- The Mach Service / LaunchDaemon name is `com.hoobnn.fanfan.smcd` — keep this in sync across the plist, daemon source, install scripts, and any new tooling.
