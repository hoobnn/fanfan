# CLAUDE.md

本文件为 Claude Code (claude.ai/code) 在本仓库中工作时提供指引。

## 项目概况

`fanfan` 是控制 Mac 风扇转速的 macOS 菜单栏应用（Swift 5 语言模式 + Swift 6 approachable-concurrency / SwiftUI on AppKit 菜单栏生命周期），目标 **macOS 26+**，Apple Silicon 或 Intel，**无任何第三方 Swift 依赖**。

仓库另含一个以 root LaunchDaemon 运行的 **C 守护进程**（`fanfan-smcd`）。Swift 应用不带特权，所有 root-only 的 SMC 写入都经 Unix socket 交给它。

## 权限架构 —— 改动风扇写入代码前必读

```
fanfan.app (user)  ──Unix socket──▶  fanfan-smcd (root)  ──IOKit──▶  AppleSMC
```

- **传感器读取**由应用直接经 IOKit 完成，不需要守护进程，也不需要提权。
- **风扇写入**必须走守护进程。带版本的 socket 协议刻意保持极简：
  - `PINGV2` → `OK pong 2 <idle|active|restoring>`（仅健康 / 状态查询）
  - `RENEWV2` → `OK`，仅在存在活跃控制租约时返回
  - `SETV2 <fan> <rpm>`（fan：0–7；rpm 由守护进程按硬件上下限钳制）
  - `AUTOV2 <fan>`（把控制权交还固件）
  - 遗留 `AUTO <fan>` 仅为发布版兼容保留，用于安全释放旧版控制；遗留 SET / PING 一律拒绝。
- Socket 路径 `/var/run/fanfan-smcd.sock`（`0660`，属主 `root:admin`）。
- 手动控制基于租约：SET 活跃时应用每 3 秒续租；10 秒无活动则守护进程恢复固件 AUTO。
- 二进制在 `/Library/PrivilegedHelperTools/fanfan-smcd`，plist 在 `/Library/LaunchDaemons/com.hoobnn.fanfan.smcd.plist`。
- 安装由 `PermissionsManager.installHelper` 经单次 `osascript` "with administrator privileges" 完成，全程只弹一次密码。**不要在没有充分理由的情况下新增 sudo 提示或跨 socket 的命令** —— 这个经过审计的最小接口面是刻意为之的安全属性。

两侧代码：`fanfan/Core/SMCDaemonClient.swift` 与 `tools/fanfan-smcd/fanfan-smcd.c`（+ `smc.h`）。改一侧，另一侧几乎总要同步改。

## 代码结构（仅记录读代码看不出来的部分）

- `FanController.swift` —— 自动模式控制器：EMA 平滑温度输入、PID 环、非对称 RPM 死区（易升难降）带 8 秒最短保持、非对称爬坡（升快降慢），以及 Silent / Balanced / Performance / Custom 预设。**抗震荡调参（平滑 + 非对称）是为消除可听见的风扇"喘振"而存在，重构时务必保留。**
- `FanControlViewModel.swift` —— 唯一的 Combine `ObservableObject`，UI 层风扇状态的事实来源，所有 UI 变更从这里流转。
- `Theme.swift` —— 设计规则严格执行：**温度是唯一的颜色**。UI 全单色，温度升高时一层几乎不可见的暖色从 popover 顶部渗入。新增 UI 一律从 `Theme` 取色，不要硬编码。
- `SystemMonitor.swift` —— IOKit 传感器 / SMC 读取器，SMC 键位目录在这里。
- `StatusBarManager.swift` —— 四种状态栏显示模式由 `StatusBarDisplayModeChanged` 通知驱动。
- 本地化字符串在 `en.lproj/` 和 `zh-Hans.lproj/`，用 `NSLocalizedString`，两种语言必须同步。

## 构建、运行、测试

Xcode 项目，没有 `swift build` / SwiftPM：

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

守护进程单独构建（`make -C tools/fanfan-smcd`，产出 macOS 26+ arm64/x86_64 通用二进制；`clean` 清理）。**源码改动后还要刷新 Xcode 打包的那份副本**，否则调试构建用的还是旧二进制：

```bash
cp tools/fanfan-smcd/fanfan-smcd fanfan/Resources/fanfan-smcd
```

`scripts/build-release.sh` 会自动做，手动 debug 构建不会。

### 发布

```bash
./scripts/build-release.sh 1.2.3
```

需要 `Developer ID Application: HAOBIN WU (8FUPL8QHFH)` 证书和名为 `fanfan-notarize` 的 `notarytool` 钥匙串配置（`NOTARY_PROFILE=…` 可覆盖）。产物在 `releases/`。CI 经 `.github/workflows/release.yml` 在 `v*` tag 上跑同一套流水线。

推 tag 前按顺序：

1. 更新 `fanfan.xcodeproj/project.pbxproj` 的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`（主 target 的 Debug 和 Release 都要改）。
2. 在 `CHANGELOG.md` 新增该版本一节（发布说明由 `release-notes.sh` 从这里提取，缺了会导致发布失败）。
3. 提交后 `git tag vX.Y.Z && git push && git push origin vX.Y.Z`。

## 提交 —— 强制格式

`husky` 对每条提交信息运行 `commitlint`，header 必须匹配 `<emoji> <type>(<scope>): <subject>`：

| emoji | type | | emoji | type | | emoji | type |
|------|------|---|------|------|---|------|------|
| ✨ | `feat` | | 🎨 | `style` | | 📦️ | `build` |
| 🐛 | `fix` | | ♻️ | `refactor` | | 👷 | `ci` |
| 📝 | `docs` | | ⚡️ | `perf` | | 🔧 | `chore` |
| | | | ✅ | `test` | | ⏪️ | `revert` |

- emoji **必须存在**且与 type 1:1 配对，配错则钩子失败。
- `scope` 小写；header ≤ 72 字符；subject 非空。
- 示例：`🐛 fix(ui): close popover when app loses focus`。
- 钩子报错就改信息，**不要用 `--no-verify` 绕过**。

AI 协助的提交**应当**带 `Co-Authored-By` trailer，按实际干活的工具署名，只用一条：

```
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Co-Authored-By: Codex <noreply@openai.com>
```

2026-09-07 之前的提交无 trailer、且用 gitmoji 名作 type（`🐛 bug(ui): …`）—— 属预期，不回溯修改，也不要照着历史提交的风格写新提交。

## 值得记住的约定

- **macOS 26 + Swift 5 语言模式** —— 已启用 approachable-concurrency，但完整的 Swift 6 严格并发迁移还需先把 SMC worker 与 main-actor 上的 observable 门面隔离。
- **不加第三方 SDK。** 精简依赖面是刻意为之。
- **无风扇的 Mac 真实存在。** 部分 MacBook Air 报告没有风扇，UI 完全隐藏控制项而非显示假滑块。不要假定 `fanCount > 0`。
- **支持逐风扇非对称控制。** 多风扇机器每个风扇有独立滑块 / 目标值，数据结构已如此建模，重构时保留。
- Mach Service / LaunchDaemon 名称 `com.hoobnn.fanfan.smcd` —— 在 plist、守护进程源码、安装脚本及任何新工具中保持一致。
