# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · [SemVer](https://semver.org/spec/v2.0.0.html)

## [1.2.1] - 2026-08-31

### Fixed
- Helper installation no longer restarts a freshly bootstrapped LaunchDaemon and trips launchd's minimum-runtime throttle, which previously caused a repeated “install helper” loop after upgrading.
- Helper readiness now uses a bounded 20-second retry window, serializes overlapping checks, and rejects stale results so a transient startup delay cannot overwrite a later successful installation.
- `PINGV2` remains responsive while the daemon restores firmware fan control; lease enforcement still runs immediately after each request and during idle polling.
- The one-line installer no longer asks Gatekeeper to assess a standalone Mach-O helper as if it were an app bundle, while retaining its strict Developer ID requirement check.
- Homebrew upgrades now wait for the previous app process to exit, verify the installed helper files, and require a valid versioned health response before reopening fanfan.

### Build
- Release builds now produce and verify a universal `arm64 + x86_64` main app and dSYM as well as a universal helper, fixing the arm64-only v1.2.0 application artifact.
- Public artifacts no longer carry test code-coverage instrumentation.

## [1.2.0] - 2026-08-31

### Security
- Privileged helper protocol v2 adds explicit health and lease-renewal commands. A 10-second daemon lease now restores firmware fan control after app crashes, stalled clients, failed writes, or daemon shutdown.
- Helper installation now shell-quotes bundle paths, stages files in root-owned locations, validates the signed helper and fixed LaunchDaemon plist, and installs under `/Library/PrivilegedHelperTools`.
- The one-line installer now uses a private temporary directory, verifies release checksums and Apple trust, and validates staged privileged files before bootstrap.

### Fixed
- Stale temperature telemetry now expires after 10 seconds and triggers firmware AUTO; a raw 90°C safety channel bypasses user RPM caps, hold windows, hysteresis, and ramp limits.
- SET/AUTO ordering now uses command generations and a serialized teardown barrier, so an older pending SET cannot re-enable manual control after sleep, System mode, or app exit.
- Wake notifications are coalesced, fanless retries are bounded, and Timer creation is synchronous, preventing duplicate or orphaned monitoring/control loops.
- Fan indices remain stable across partial reads, multi-fan unified ranges use their safe intersection, GPU-only overheating triggers alerts, and battery amperage conversion no longer risks integer traps.
- Monitoring interval and auto-switch settings take effect immediately; fanless/no-helper Macs retain temperature and sensor views.

### Build
- The bundled daemon is now a macOS 26.0 universal `arm64 + x86_64` binary, with release-time architecture, deployment-target, version, test, signature, and notarization checks.

## [1.1.2] - 2026-07-09

### Fixed
- **Fan control could appear installed but have no effect after installing the latest release.** macOS could preserve the quarantine attribute on the privileged `fanfan-smcd` LaunchDaemon binary and plist when installing from the downloaded app bundle, causing `launchd` to refuse the daemon with `Refusing to execute/trust quarantined program/file`. The installer and in-app helper repair flow now remove quarantine from the installed daemon files before bootstrapping the service.
- The helper status check no longer treats "files exist on disk" as enough. The UI now requires a live `PING` response from `/var/run/fanfan-smcd.sock`, so a quarantined or stale helper surfaces the repair flow instead of hiding behind a false installed state.

## [1.1.1] - 2026-06-10

### Fixed
- **The high-temperature notification never fired.** It observed the alert-threshold *setting* instead of the live temperature, so it could only trigger if the user dragged the threshold slider while already over temperature. It now follows the live CPU temperature, edge-triggered with a 5 °C re-arm hysteresis so a reading hovering at the alert line doesn't notify on every sample.

### Performance
- All six repeating timers (monitoring, auto control loop, battery, icon refresh, temperature history, fallback animation) now declare a timer tolerance, letting the kernel coalesce wakeups and cut idle CPU/power draw. Control loops measure real elapsed time, so the added jitter has no behavioral effect.
- Fanless Macs (e.g. MacBook Air) no longer re-probe `F0Ac` over IOKit on every 2 s tick; the zero-fan probe is throttled to once per 30 s and still self-heals after transient SMC failures.
- The status-bar title is deduplicated by rendered text — battery-power jitter no longer forces a status-item relayout when the displayed string is unchanged.
- The popover fan-blade animation is capped at 60 fps; on 120 Hz ProMotion panels this halves rotor redraw cost with no perceptible difference.

## [1.1.0] - 2026-05-27

### Added
- **Power-strategy presets.** A segmented picker above the automatic sliders offers Power Saving / Balanced / Performance / Custom; each preset carries its own target temperature, response notch, and RPM-span fraction. Power Saving suppresses the load-aware feedforward entirely. Hand-tuning any slider flips to Custom so no segment appears selected, and the choice persists across launches. SMC writes now dispatch on a serial background queue and coalesce pending targets, so the 2 s auto timer can no longer pile up requests during the ~8 s Ftst unlock window.

### Fixed
- **Apple Silicon (M3/M4) fan control now actually engages.** The daemon previously mistook firmware `0x82` rejections for success, so mode writes silently failed while the fan stayed system-locked. It now performs the Ftst unlock (write `Ftst=1`, wait up to 12 s for `thermalmonitord` to yield, retry `F<n>Md=1` until it sticks), probes mode-key casing (`F%dMd` vs `F%dmd`) at startup for M4/M5 portability, and clears `Ftst=0` when the last manual fan reverts to AUTO so firmware can idle fans back to 0 RPM. The socket receive timeout was raised from 250 ms to 15 s to cover the unlock window.
- Fans could stay stuck at their last manual RPM after quitting the app. `applicationWillTerminate` now hands control back to firmware before monitoring stops.

## [1.0.9] - 2026-05-21

### Changed
- Automatic fan control no longer "pumps" (audible loud→soft→loud cycling). Three compounding causes were addressed: the raw SMC temperature, which jitters several °C between samples, is now smoothed through an EMA before it reaches the PID loop, the trend label, and the load-aware boost; the RPM dead-band and slew rate are now asymmetric (spin up readily at 200 RPM / 800 RPM-per-cycle, glide down reluctantly at 450 RPM / 250 RPM-per-cycle) and the minimum hold grew from 3 s to 8 s, with only large spin-ups allowed to break it; and the default derivative gain dropped from `Kp × 3.0` to `Kp × 2.0`, since the filtered input no longer needs a large gain to fight sensor noise (a large one was amplifying it). Net effect: fans hold a steady speed instead of chasing temperature transients, at the cost of slightly slower, gentler spin-down after load drops.

## [1.0.8] - 2026-05-21

### Fixed
- Automatic fan control could silently stop after the app sat in the background (e.g. lid closed or no foreground window). As an `.accessory` menu-bar app, macOS App Nap froze the monitoring and fan-control `Timer`s, so scheduling never resumed on wake until the user reopened the menu bar. The app now holds a `userInitiatedAllowingIdleSystemSleep` activity token for the lifetime of the process, keeping the timers alive while still letting the system sleep normally (closing the lid still saves power).

## [1.0.7] - 2026-05-16

### Fixed
- Automatic mode could leave the fan stuck on firmware control after `restoreAutomaticControl()` handed it back (e.g. after screen sleep). `lastAppliedSpeed` stayed pinned at the previous saturated value, so when the next PID cycle saturated to the same ceiling the hysteresis check saw `diff == 0` and skipped the write. Re-engagement now re-seeds `lastAppliedSpeed` from the fan's real RPM, matching `startAutoControl()`'s seeding strategy.

### Performance
- `FanControlViewModel` now publishes `maxTemperature`, `ssdTemperature`, and `batterySensorTemperature` as cached `@Published` properties driven by Combine, so the popover and status-bar icon stop running `allSensors.first(where:)` and `max(cpu, gpu)` on every render pass.
- `FanBladeView` short-circuits the `TimelineView(.animation)` subtree when `visualRps == 0`, so an idle blade no longer redraws each vsync. The per-blade `BladeShape` was also collapsed into a single `FanRotorShape`, halving SwiftUI subview count.

## [1.0.6] - 2026-05-16

### Added
- Tag-triggered GitHub Actions workflow now auto-syncs the Homebrew tap (`hoobnn/tap`) on every `v*` release, so `brew upgrade fanfan` picks up new versions without manual cask edits.

### Changed
- Reverted the Simplified Chinese locale directory back to `zh-Hans.lproj` and restored `knownRegions` to `"zh-Hans"` (undoes the rename from 1.0.4).

## [1.0.5] - 2026-05-16

### Fixed
- Fan blade rotation no longer stutters at low RPM. The previous fixed 30 fps schedule drifted against the display vsync (60 / 120 Hz), producing visibly uneven angle steps; rotation now runs off `TimelineView(.animation)` while the static accent bloom and inner dot stay outside the timeline subtree, keeping per-frame work bounded.
- `scripts/install.sh` permission and cleanup issues.

## [1.0.4] - 2026-05-15

### Added
- Settings now includes an **About** section with the installed version/build and a **Check for Updates** button that queries the GitHub Releases API and offers a one-click download if a newer version is available.

### Changed
- Renamed the Simplified Chinese locale directory from `zh-Hans.lproj` to `zh.lproj` and updated `knownRegions` accordingly.

## [1.0.3] - 2026-05-15

### Performance
- Tiered `SystemMonitor` polling: fast tier (CPU/GPU temp + fan RPM) still runs every tick, while the full sensor scan now runs at most every `max(6 s, interval × 3)`, cutting IOKit traffic on Macs with rich SMC catalogues.
- Cache per-fan `Mn` / `Mx` SMC limits once per fan-count instead of re-reading them every tick; caching only commits once every read succeeds so transient startup / wake-from-sleep failures still self-heal.
- `ControlsCard` now consumes a value-typed `ControlsSnapshot` and conforms to `Equatable`, letting SwiftUI skip body re-evaluation on unrelated `@Published` ticks (e.g. 2 s temperature updates) and cancel pending debounced slider writes on `.onDisappear`.
- Cap the rotating fan blade animation to 30 fps (down from display-refresh rate) and lift the static accent bloom + inner dot out of `TimelineView` so they stop re-evaluating every frame.

## [1.0.2] - 2026-05-15

### Performance
- Halved menu-bar icon animation CPU cost: lowered frame rate from 30 fps to 15 fps, skips `setImage:` calls when the quantized rotation slot is unchanged, and switched to template image mode so WindowServer handles tinting centrally.

## [1.0.1] - 2026-05-15

### Added
- App now appears in Launchpad (`LSUIElement` set to `NO`); Dock icon is hidden immediately in `applicationWillFinishLaunching` to minimize the brief flash.

### Fixed
- Eliminated ~40% idle main-thread CPU caused by `FanBladeView`'s `TimelineView(.animation)` ticking at display-refresh rate while the popover was closed. The `NSHostingController` is now mounted on popover open and torn down on close.

## [1.0.0] - 2026-05-15

First public release. Runs on macOS 26+, Apple Silicon and Intel.

### Added
- Real-time CPU/GPU temperature monitoring via IOKit / SMC.
- Three control modes: Manual, Automatic, System.
- Automatic controller with rolling history, ±200 RPM hysteresis, and four presets (Silent / Balanced / Performance / Custom).
- Per-fan independent RPM control on multi-fan machines; graceful no-fan fallback on fanless models.
- Status bar display modes (temperature / power / fan % / icon) and configurable high-temp alert.
- Launch at Login via `ServiceManagement`; English and Simplified Chinese localization.

### Security
- Privileged SMC writes isolated to a minimal C LaunchDaemon (`com.hoobnn.fanfan.smcd`); the app itself runs unprivileged.
- Daemon socket exposes only three commands: `PING`, `SET`, `AUTO`.
- Releases are Developer ID signed and notarized.

[1.0.7]: https://github.com/hoobnn/fanfan/releases/tag/v1.0.7
[1.0.6]: https://github.com/hoobnn/fanfan/releases/tag/v1.0.6
[1.0.5]: https://github.com/hoobnn/fanfan/releases/tag/v1.0.5
[1.0.4]: https://github.com/hoobnn/fanfan/releases/tag/v1.0.4
[1.0.3]: https://github.com/hoobnn/fanfan/releases/tag/v1.0.3
[1.0.2]: https://github.com/hoobnn/fanfan/releases/tag/v1.0.2
[1.0.1]: https://github.com/hoobnn/fanfan/releases/tag/v1.0.1
[1.0.0]: https://github.com/hoobnn/fanfan/releases/tag/v1.0.0
