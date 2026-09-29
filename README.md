<div align="center">

<img src="docs/logo.png" width="112" alt="fanfan app icon">

# fanfan — Mac fan control and temperature monitor

**Open-source macOS menu bar app to monitor Mac temperatures and control fan speed — manually, automatically, or by macOS.**

[![release](https://img.shields.io/github/v/release/hoobnn/fanfan?style=flat-square)](https://github.com/hoobnn/fanfan/releases/latest)
[![downloads](https://img.shields.io/github/downloads/hoobnn/fanfan/total?style=flat-square)](https://github.com/hoobnn/fanfan/releases)
[![macOS](https://img.shields.io/badge/macOS-26.0%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon + Intel](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-555?style=flat-square)](#install)
[![Homebrew](https://img.shields.io/badge/brew-fanfan-FBB040?style=flat-square&logo=homebrew&logoColor=white)](#homebrew)
[![Swift](https://img.shields.io/badge/Swift-6-orange?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

English · [简体中文](README.zh.md)

</div>

fanfan is an open-source macOS menu bar app for monitoring Mac temperatures and fan speeds. Set a manual fan speed, use temperature-based automatic control, or return control to macOS. It supports Apple Silicon and Intel Macs running macOS 26 or later, and has no third-party dependencies.

<table>
  <tr>
    <td width="42%" align="center"><img src="docs/view/image.png" alt="fanfan menu bar popover showing Mac temperature, fan RPM, a 60-second temperature chart, CPU/GPU/SSD/battery sensors, and automatic fan control"></td>
    <td width="58%" align="center"><img src="docs/view/setting.png" alt="fanfan settings: menu bar display, monitoring interval, high temperature alert, notifications, auto mode switching, and custom PID gains"></td>
  </tr>
  <tr>
    <td align="center"><sub>Menu bar popover</sub></td>
    <td align="center"><sub>Settings</sub></td>
  </tr>
</table>

## Features

- **Monitor your Mac:** See current fan RPM and CPU, GPU, SSD, and battery temperatures when those sensors are available, plus a 60-second temperature chart and a Sensors tab for detailed readings.
- **Choose how fans run:** Use manual RPM control, temperature-based automatic control, or the Mac's own firmware control. Set each fan separately on Macs with multiple fans.
- **Tune automatic control:** Adjust the target temperature, maximum fan speed, and response, with Power Saving, Balanced, Performance, and Custom settings. Smoothing and asymmetric ramps keep fans from audibly surging up and down.
- **Menu bar at a glance:** Show temperature, power usage, or fan speed % in the menu bar — or nothing.
- **High-temperature alerts:** Get notified above a threshold you set, and optionally switch to automatic control when it's hit.
- **Advanced PID tuning:** Set custom controller gains if the presets don't fit your workload.
- **Keep control recoverable:** A small privileged helper writes fan speeds; if the app stops responding, its 10-second lease expires and the helper returns control to firmware. Quitting the app also hands fans back to macOS.

Fan controls are hidden on Macs without a fan. Available sensors and fan speed ranges depend on the Mac model.

## Install

### Homebrew

```bash
brew tap hoobnn/tap
brew install --cask fanfan
```

### Manual

Download the latest DMG from [Releases](https://github.com/hoobnn/fanfan/releases/latest), or run the install script:

```bash
curl -fsSL https://raw.githubusercontent.com/hoobnn/fanfan/main/scripts/install.sh | bash
```

Requires macOS 26+ (Apple Silicon or Intel). On first launch, click **Install Helper** and allow fanfan in System Settings › General › Login Items & Extensions. No administrator password is needed.

### Uninstall

`brew uninstall --cask fanfan` removes the app and the helper (add `--zap` to also remove preferences). For a manual install, quit fanfan and delete it from Applications — the helper lives inside the app bundle and stops with it.

## FAQ

**Is it safe to control Mac fan speed?**
fanfan only sets speeds within the hardware's own limits — the helper rejects any target outside the fan's reported minimum and maximum RPM. If the app crashes, hangs, or quits, fans return to macOS firmware control automatically.

**Does it work on Apple Silicon (M-series) Macs?**
Yes. fanfan is a universal app for Apple Silicon and Intel Macs on macOS 26 or later. Fanless Macs, such as the Apple Silicon MacBook Air, show temperatures only.

**Why does it ask to run in the background?**
Writing fan speeds to the SMC requires root. Instead of running the whole app with elevated privileges, fanfan registers a tiny root helper that macOS asks you to allow once in Login Items & Extensions. Reading temperatures needs no special permission.

**Is fanfan a free alternative to Macs Fan Control or smcFanControl?**
It covers the same core job — reading SMC sensors and setting fan speeds — as a free, MIT-licensed, open-source menu bar app with no third-party dependencies.

## How it works

Writing fan speeds requires root. Instead of running the whole app as root,
fanfan registers a tiny C LaunchDaemon (via `SMAppService`) that owns the
SMC handle and accepts a small versioned XPC protocol for health checks,
lease renewal, fan targets, and returning control to firmware. Only the
fanfan app signed by its developer can connect. Fans return to firmware
control the moment the app quits or crashes, and a 10-second lease covers an
app that hangs.

```
fanfan.app  ──XPC──▶  fanfan-smcd (root)  ──IOKit──▶  SMC
```

The app itself runs unprivileged. Temperature reads go straight through IOKit.

## Build from source

Requires Xcode with the macOS 26 SDK.

```bash
make -C tools/fanfan-smcd                                   # build the helper
cp tools/fanfan-smcd/fanfan-smcd fanfan/Resources/fanfan-smcd
xcodebuild -project fanfan.xcodeproj -scheme fanfan -configuration Debug build
```

## Star History

<a href="https://star-history.com/#hoobnn/fanfan&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=hoobnn/fanfan&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=hoobnn/fanfan&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=hoobnn/fanfan&type=Date" />
  </picture>
</a>

## Acknowledgements

Forked from [solofan](https://github.com/SoloTeamDev/solofan) (formerly ffan). Thanks to the solofan team.

[MIT](LICENSE) © 2026 hoobnn
