![fanfan](docs/icon.png)

# fanfan

A macOS menu bar app that puts you back in charge of your fans.

[![release](https://img.shields.io/github/v/release/hoobnn/fanfan?style=flat-square)](https://github.com/hoobnn/fanfan/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-26.0%2B-black?style=flat-square)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-orange?style=flat-square)](https://swift.org)
[![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

[中文文档](README.zh.md)

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

Requires macOS 26+ (Apple Silicon or Intel). One password prompt on first launch — that's it.

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
