![fanfan](docs/icon.png)

# fanfan

一款 macOS 菜单栏应用，让你真正掌控风扇。

[![release](https://img.shields.io/github/v/release/hoobnn/fanfan?style=flat-square)](https://github.com/hoobnn/fanfan/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-26.0%2B-black?style=flat-square)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-orange?style=flat-square)](https://swift.org)
[![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

[English](README.md)

## 安装

### Homebrew

```bash
brew tap hoobnn/tap
brew install --cask fanfan
```

### 手动安装

从 [Releases](https://github.com/hoobnn/fanfan/releases/latest) 下载最新 DMG，或运行安装脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/hoobnn/fanfan/main/scripts/install.sh | bash
```

需要 macOS 26+（Apple Silicon 或 Intel）。首次启动输入一次密码，仅此一次。

## 工作原理

写入风扇转速需要 root 权限。fanfan 不让整个应用以 root 运行，
而是安装一个极简的 C LaunchDaemon，由它持有 SMC 句柄，
通过带版本的精简 Unix socket 协议完成健康检查、租约续期、转速写入和
固件控制恢复。若应用崩溃或失去响应，10 秒租约到期后会自动交还固件控制。

```
fanfan.app  ──Unix socket──▶  fanfan-smcd（root）  ──IOKit──▶  SMC
```

应用本身以普通用户身份运行，温度读取直接走 IOKit。

## Star 增长

<a href="https://star-history.com/#hoobnn/fanfan&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=hoobnn/fanfan&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=hoobnn/fanfan&type=Date" />
    <img alt="Star 增长曲线" src="https://api.star-history.com/svg?repos=hoobnn/fanfan&type=Date" />
  </picture>
</a>

## 致谢

Fork 自 [solofan](https://github.com/SoloTeamDev/solofan)，
后者构建于 [ffan](https://github.com/hoobnnlounnas/ffan) 之上。感谢二位。

[MIT](LICENSE) © 2026 hoobnn
