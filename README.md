<div align="center">

<img src="docs/logo.png" width="112" alt="fanfan 应用图标">

# fanfan：Mac 风扇控制与温度监控

开源的 macOS 菜单栏小工具，看温度，调风扇。

[![release](https://img.shields.io/github/v/release/hoobnn/fanfan?style=flat-square)](https://github.com/hoobnn/fanfan/releases/latest)
[![downloads](https://img.shields.io/github/downloads/hoobnn/fanfan/total?style=flat-square)](https://github.com/hoobnn/fanfan/releases)
[![macOS](https://img.shields.io/badge/macOS-26.0%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Homebrew](https://img.shields.io/badge/brew-fanfan-FBB040?style=flat-square&logo=homebrew&logoColor=white)](#homebrew)
[![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

**简体中文** · [English](README.en.md)

</div>

fanfan 常驻在菜单栏，显示 Mac 的温度和风扇转速。风扇可以手动定转速、按温度自动调，也可以交回给 macOS 自己管。Apple Silicon 和 Intel Mac 都能用，要求 macOS 26 及以上，没有第三方依赖。

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

- 显示风扇转速，以及 CPU、GPU、SSD、电池温度（取决于机型有哪些传感器）。面板里有最近 60 秒的温度曲线，「传感器」页能看到全部读数。
- 三种风扇模式：手动设转速、按温度自动调速、交回系统固件控制。有两个风扇的 Mac 可以分别设置。
- 自动调速可以改目标温度、最高转速和响应快慢，内置省电、均衡、性能三档，也可以自定义。转速变化做了平滑，升快降慢，风扇不会一会儿呼呼响一会儿又停。
- 菜单栏可以显示温度、功耗或风扇转速百分比，也可以只放一个图标。
- 温度超过设定值时发通知，可选同时切到自动调速。
- 预设不合适的话，可以直接改 PID 参数。
- 界面支持简体中文、繁體中文、English、日本語、한국어、Deutsch、Français、Español。默认跟随系统语言，也可以在「系统设置 › 通用 › 语言与地区 › 应用程序」里给 fanfan 单独指定。
- 写风扇转速的是一个单独的特权辅助进程。App 卡住超过 10 秒，或者退出、崩溃，风扇都会交回 macOS 控制。

没有风扇的 Mac 不会显示风扇控制。能读到哪些传感器、转速范围多大，都看具体机型。

## 安装

### Homebrew

```bash
brew tap hoobnn/tap
brew install --cask fanfan
```

### 手动安装

到 [Releases](https://github.com/hoobnn/fanfan/releases/latest) 下载最新的 DMG，或者用安装脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/hoobnn/fanfan/main/scripts/install.sh | bash
```

需要 macOS 26 及以上（Apple Silicon 或 Intel）。第一次打开时点「安装助手」，再到「系统设置 › 通用 › 登录项与扩展」里允许 fanfan。不需要输管理员密码。

### 卸载

`brew uninstall --cask fanfan` 会把 App 和辅助进程一起删掉，加 `--zap` 连偏好设置也清掉。手动装的，退出 fanfan 后把它从「应用程序」里删掉就行，辅助进程在 App 包里，会跟着停掉。「登录项与扩展」里如果还留着 fanfan 的条目，在那里手动移除。

## 常见问题

**调风扇转速安全吗？**
fanfan 只会在风扇自己上报的最低和最高转速之间设置，超出范围的请求辅助进程直接拒绝。App 崩溃、卡死或退出时，风扇会自动交回 macOS 固件控制。

**M 系列芯片的 Mac 能用吗？**
能用。fanfan 是 Apple Silicon 和 Intel 通用版，要求 macOS 26 及以上。MacBook Air 这类没有风扇的机型只显示温度。

**为什么要我允许它在后台运行？**
往 SMC 写风扇转速需要 root 权限。为了让 App 本身不用 root 跑，fanfan 只注册了一个很小的 root 辅助进程，macOS 会让你在「登录项与扩展」里允许一次。只读温度的话不需要任何权限。

**和 Macs Fan Control、smcFanControl 比怎么样？**
核心功能一样：读 SMC 传感器、设风扇转速。fanfan 免费开源（MIT），没有第三方依赖。

## 工作原理

App 本身以普通用户身份运行，读温度直接走 IOKit。

写风扇转速需要 root，这部分交给一个用 C 写的 LaunchDaemon（`fanfan-smcd`，通过 `SMAppService` 注册）。它持有 SMC 句柄，通过一个带版本号的小型 XPC 协议接收健康检查、租约续期、目标转速和「交回固件控制」这几类请求，而且只接受开发者签名的 fanfan 连接。App 退出或崩溃时，风扇马上交回固件；App 卡住时，10 秒租约到期后同样交回。

```text
fanfan.app  ──XPC──▶  fanfan-smcd（root）  ──IOKit──▶  SMC
```

## 从源码构建

需要装有 macOS 26 SDK 的 Xcode。

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
