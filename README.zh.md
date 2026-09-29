# fanfan — Mac 风扇控制与温度监控

fanfan 是一款开源 macOS 菜单栏应用，可查看 Mac 温度和风扇转速，手动设置转速、按温度自动调速，或交还 macOS 固件控制。支持运行 macOS 26 及以上版本的 Apple Silicon 和 Intel Mac。

[![release](https://img.shields.io/github/v/release/hoobnn/fanfan?style=flat-square)](https://github.com/hoobnn/fanfan/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-26.0%2B-black?style=flat-square)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-orange?style=flat-square)](https://swift.org)
[![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

[English](README.md)

![fanfan 菜单栏界面，显示 Mac 温度、风扇转速和自动调速设置](docs/view/image.png)

## 功能

- **监控设备状态：**查看风扇转速，以及可用的 CPU、GPU、SSD 和电池温度传感器读数。
- **选择风扇模式：**支持手动设置转速、按温度自动调速和恢复系统固件控制；多风扇 Mac 可分别设置转速。
- **调整自动调速：**设置目标温度、最大转速和响应速度，并可选省电、均衡、性能或自定义设置。
- **自动恢复控制：**风扇写入由独立的特权辅助进程完成；应用失去响应后，10 秒租约到期会交还固件控制。

无风扇的 Mac 不显示风扇控制项。可用传感器和转速范围因机型而异。

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

需要 macOS 26+（Apple Silicon 或 Intel）。首次启动需输入管理员密码，以安装风扇控制辅助进程。

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
