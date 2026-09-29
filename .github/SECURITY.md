# Security Policy · 安全策略

fanfan installs a root LaunchDaemon (`fanfan-smcd`) that accepts fan-control
commands over a local Unix socket. Bugs in that helper, its socket protocol or
its install path can have security impact, so please report them privately.

fanfan 会安装一个以 root 运行的守护进程（`fanfan-smcd`），通过本地 Unix socket
接收风扇控制命令。该 helper、socket 协议或安装流程中的问题可能涉及安全，请私下报告。

## Reporting a vulnerability · 报告漏洞

Use [**Report a vulnerability**](https://github.com/hoobnn/fanfan/security/advisories/new)
(GitHub private vulnerability reporting). Do not open a public issue.

请通过上方链接私下提交，不要公开发 issue。

Please include the fanfan version, macOS version, Mac model and steps to
reproduce. You will get a reply within 7 days.

## Supported versions · 支持的版本

Only the [latest release](https://github.com/hoobnn/fanfan/releases/latest)
receives security fixes. 仅最新版本提供安全修复。

## In scope · 范围

- Privilege escalation or arbitrary SMC writes through `fanfan-smcd` or its socket
- The helper install / upgrade path (`PermissionsManager`, `scripts/install.sh`, the Homebrew cask)
- Fans left under manual control after the app exits or the lease expires
