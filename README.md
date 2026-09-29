# fanfan — Mac fan control and temperature monitor

fanfan is an open-source macOS menu bar app for monitoring Mac temperatures and fan speeds. Set a manual fan speed, use temperature-based automatic control, or return control to macOS. It supports Apple Silicon and Intel Macs running macOS 26 or later.

[![release](https://img.shields.io/github/v/release/hoobnn/fanfan?style=flat-square)](https://github.com/hoobnn/fanfan/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-26.0%2B-black?style=flat-square)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-orange?style=flat-square)](https://swift.org)
[![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

[中文文档](README.zh.md)

![fanfan menu bar app showing Mac temperatures, fan speed, and automatic fan controls](docs/view/image.png)

## Features

- **Monitor your Mac:** See current fan RPM and CPU, GPU, SSD, and battery temperatures when those sensors are available.
- **Choose how fans run:** Use manual RPM control, temperature-based automatic control, or the Mac's own firmware control. Set each fan separately on Macs with multiple fans.
- **Tune automatic control:** Adjust the target temperature, maximum fan speed, and response, with Power Saving, Balanced, Performance, and Custom settings.
- **Keep control recoverable:** A small privileged helper writes fan speeds; if the app stops responding, its 10-second lease expires and the helper returns control to firmware.

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

Requires macOS 26+ (Apple Silicon or Intel). First launch asks for an administrator password to install the fan-control helper.

## How it works

Writing fan speeds requires root. Instead of running the whole app as root,
fanfan installs a tiny C LaunchDaemon that owns the SMC handle and accepts
a small versioned Unix-socket protocol for health checks, lease renewal,
fan targets, and returning control to firmware. A 10-second lease restores
firmware control automatically if the app crashes or stops responding.

```
fanfan.app  ──unix socket──▶  fanfan-smcd (root)  ──IOKit──▶  SMC
```

The app itself runs unprivileged. Temperature reads go straight through IOKit.

## Star History

<a href="https://star-history.com/#hoobnn/fanfan&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=hoobnn/fanfan&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=hoobnn/fanfan&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=hoobnn/fanfan&type=Date" />
  </picture>
</a>

## Acknowledgements

Forked from [solofan](https://github.com/SoloTeamDev/solofan). Thanks to the solofan team.

[MIT](LICENSE) © 2026 hoobnn
