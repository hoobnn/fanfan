<div align="center">

<img src="docs/logo.png" width="112" alt="fanfan 应用图标">

# fanfan：Mac 风扇控制与温度监控

开源的 macOS 菜单栏工具，用于监控温度和调节风扇转速。

[![release](https://img.shields.io/github/v/release/hoobnn/fanfan?style=flat-square)](https://github.com/hoobnn/fanfan/releases/latest)
[![downloads](https://img.shields.io/github/downloads/hoobnn/fanfan/total?style=flat-square)](https://github.com/hoobnn/fanfan/releases)
[![macOS](https://img.shields.io/badge/macOS-26.0%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Homebrew](https://img.shields.io/badge/brew-fanfan-FBB040?style=flat-square&logo=homebrew&logoColor=white)](#homebrew)
[![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

**简体中文** · [English](README.en.md)

</div>

fanfan 常驻菜单栏，显示 Mac 的温度和风扇转速。风扇支持固定转速、按温度自动调节，也可以交还 macOS 控制。支持 Apple Silicon 和 Intel 机型，要求 macOS 26 及以上，无第三方依赖。

<table>
  <tr>
    <td width="42%" align="center"><img src="docs/view/zh-Hans/popover.png" alt="fanfan 菜单栏面板：Mac 温度、风扇转速、60 秒温度曲线、CPU/GPU/SSD/电池传感器与自动调速设置"></td>
    <td width="58%" align="center"><img src="docs/view/zh-Hans/settings.png" alt="fanfan 设置：菜单栏显示、监控间隔、高温警报、通知、自动模式切换与自定义 PID 增益"></td>
  </tr>
  <tr>
    <td align="center"><sub>菜单栏面板</sub></td>
    <td align="center"><sub>设置</sub></td>
  </tr>
</table>

## 功能

- 显示风扇转速，以及 CPU、GPU、SSD、电池温度（取决于机型有哪些传感器）。面板里有最近 60 秒的温度曲线，「传感器」页列出全部读数。
- 三种风扇模式：固定转速、按温度自动调速、交由系统固件控制。双风扇机型可分别设置。
- 自动调速可调整目标温度、最高转速和响应速度，内置省电、均衡、性能三档预设，也支持自定义。转速变化经过平滑处理，升速快、降速慢，避免风扇忽快忽慢。
- 菜单栏可显示温度、功耗或风扇转速百分比，也可以只显示图标。
- 温度超过设定值时发送通知，并可选择同时切换到自动调速。
- 预设不满足需要时，可直接调整 PID 参数。
- 界面支持简体中文、繁體中文、English、日本語、한국어、Deutsch、Français、Español。默认跟随系统语言，也可以在「系统设置 › 通用 › 语言与地区 › 应用程序」里给 fanfan 单独指定。
- 风扇转速由独立的特权辅助进程写入。App 无响应超过 10 秒、退出或崩溃时，风扇都会交还 macOS 控制。

无风扇机型不显示风扇控制。可读取的传感器和转速范围因机型而异。

## 安装

### Homebrew

```bash
brew tap hoobnn/tap
brew install --cask fanfan
```

### 手动安装

从 [Releases](https://github.com/hoobnn/fanfan/releases/latest) 下载最新的 DMG，或使用安装脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/hoobnn/fanfan/main/scripts/install.sh | bash
```

需要 macOS 26 及以上（Apple Silicon 或 Intel）。首次打开时点击「安装助手」，然后在「系统设置 › 通用 › 登录项与扩展」中允许 fanfan。无需输入管理员密码。

### 卸载

`brew uninstall --cask fanfan` 会同时删除 App 和辅助进程，加 `--zap` 可一并清除偏好设置。手动安装的版本，退出 fanfan 后从「应用程序」中删除即可；辅助进程位于 App 包内，会随之停止。如果「登录项与扩展」中仍有 fanfan 条目，请在那里手动移除。

## 常见问题

**调风扇转速安全吗？**
fanfan 只在风扇上报的最低与最高转速之间设置，超出范围的请求会被辅助进程拒绝。App 崩溃、卡死或退出时，风扇会自动交回 macOS 固件控制。

**M 系列芯片的 Mac 能用吗？**
支持。fanfan 是 Apple Silicon 与 Intel 通用版本，要求 macOS 26 及以上。MacBook Air 等无风扇机型仅显示温度。

**为什么需要允许后台运行？**
向 SMC 写入风扇转速需要 root 权限。为避免 App 本身以 root 运行，fanfan 注册了一个精简的 root 辅助进程，macOS 会要求在「登录项与扩展」中允许一次。仅读取温度不需要额外权限。

**与 Macs Fan Control、smcFanControl 有何区别？**
核心功能相同：读取 SMC 传感器、设置风扇转速。fanfan 免费开源（MIT），无第三方依赖。

## 工作原理

App 本身以普通用户身份运行，读温度直接走 IOKit。

写入风扇转速需要 root 权限，这部分由一个 C 语言编写的 LaunchDaemon（`fanfan-smcd`，通过 `SMAppService` 注册）负责。它持有 SMC 句柄，通过一个带版本号的小型 XPC 协议接收健康检查、租约续期、目标转速和「交回固件控制」这几类请求，而且只接受开发者签名的 fanfan 连接。App 退出或崩溃时，风扇立即交还固件控制；App 无响应时，10 秒租约到期后同样交还。

```text
fanfan.app  ──XPC──▶  fanfan-smcd（root）  ──IOKit──▶  SMC
```

## 从源码构建

需要安装了 macOS 26 SDK 的 Xcode。

```bash
make -C tools/fanfan-smcd                                   # 构建辅助进程
cp tools/fanfan-smcd/fanfan-smcd fanfan/Resources/fanfan-smcd
xcodebuild -project fanfan.xcodeproj -scheme fanfan -configuration Debug build
```

## Star 趋势

<a href="https://star-history.com/#hoobnn/fanfan&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=hoobnn/fanfan&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=hoobnn/fanfan&type=Date" />
    <img alt="fanfan 的 Star 趋势图" src="https://api.star-history.com/svg?repos=hoobnn/fanfan&type=Date" />
  </picture>
</a>

## 致谢

fanfan 最早 fork 自 [solofan](https://github.com/SoloTeamDev/solofan)（原名 ffan），感谢 solofan 团队。

[MIT](LICENSE) © 2026 hoobnn
