# Release Notes Template for fanfan

## v1.0.0 - Initial Release (2026-01-12)

### 🎉 First Public Release!

**fanfan** is now available! A lightweight, powerful macOS fan control application with real-time temperature monitoring.

---

### ✨ What's New
- 🌡️ **Temperature Monitoring**: Real-time CPU/GPU temperature readings from SMC
- 💨 **Fan Control**: Manual speed control or intelligent automatic mode
- 📊 **Animated Icon**: Menu bar icon rotates based on actual fan speed
- 🎨 **Beautiful UI**: Modern liquid glass design with SwiftUI
- 🚀 **Launch at Login**: Start automatically when you log in
- 🔋 **Battery Monitoring**: Track battery status and health
- 🎯 **Smart Auto Mode**: Temperature-based control with configurable aggressiveness
- 🔒 **Privacy-First**: All processing happens locally, zero telemetry

### 📦 Installation

**Quick Install:**
```bash
curl -L https://github.com/USERNAME/fanfan/releases/download/v1.0.0/fanfan-v1.0.0-macos.zip -o fanfan.zip
unzip fanfan.zip && mv fanfan.app /Applications/ && rm fanfan.zip
```

**Enable Fan Control:**
Launch fanfan and click **Install Helper** when prompted. This installs the privileged fan daemon.

### 📥 Downloads

| File | Size | Description |
|------|------|-------------|
| [fanfan-v1.0.0-macos.zip](link) | ~2MB | Recommended - Direct download |
| [fanfan-v1.0.0-macos.dmg](link) | ~3MB | Professional installer |

**SHA256 Checksums:**
```
[checksum]  fanfan-v1.0.0-macos.zip
[checksum]  fanfan-v1.0.0-macos.dmg
```

### 💻 System Requirements
- **macOS 26.0 or later** (matches `MACOSX_DEPLOYMENT_TARGET` in `fan.xcodeproj`)
- Intel x86_64 or Apple Silicon (M1/M2/M3+)
- ~10MB disk space

### 🎯 Key Features Explained

#### Temperature Monitoring
- Reads from SMC sensors: TC0P, TC0D, TC0E, TC0F (CPU)
- GPU temperature support (TG0P, TG0D)
- Color-coded indicators: 🟢 → 🟡 → 🟠 → 🔴
- Works without special privileges

#### Fan Control Modes
- **Manual Mode**: Set RPM using **per-fan SMC min/max** (optional per-fan sliders)
- **Automatic Mode**: 
  - Configurable temperature threshold
  - Adjustable max speed limit
  - Three aggressiveness levels
  - Smooth speed transitions

#### Safety Features
- Min/max speed enforcement from SMC per fan (with safe fallbacks if a key is missing)
- Automatic restoration of system control on quit
- Graceful error handling
- No writes without explicit user consent

### ⚠️ Important Notes

**First Launch:**
- Right-click → Open (first time only)
- macOS Gatekeeper may show warning (app is not notarized)

**Fan Control:**
- Requires `sudo` access for SMC writes
- Allow the fan-control helper once in System Settings › Login Items & Extensions
- Temperature reading works without sudo

**Permissions:**
- No special permissions needed for temp monitoring
- Fan control needs root (SMC write protection)

### 🐛 Known Issues
- [ ] Some M-series Macs have fewer exposed SMC sensors
- [ ] External GPU temps not yet supported  
- [ ] Per-fan control not implemented (controls all fans together)
- [ ] No custom fan curves yet

See all issues: https://github.com/USERNAME/fanfan/issues

### 📚 Documentation
- [Full Documentation](https://github.com/USERNAME/fanfan/blob/main/docs/README.md)
- [FAQ](https://github.com/USERNAME/fanfan/blob/main/docs/README.md#-faq)
- [Architecture Overview](https://github.com/USERNAME/fanfan/blob/main/docs/README.md#-architecture)

### 🤝 Contributing
Contributions welcome! Areas of interest:
- Testing on different Mac models
- Enhanced Apple Silicon support
- Per-fan control
- Custom temperature curves
- Localization

See [Contributing Guide](https://github.com/USERNAME/fanfan/blob/main/docs/README.md#-contributing)

### 🙏 Acknowledgments
- SMC reverse engineering community
- Beta testers
- Everyone who provided feedback

### 📄 License
MIT License - free and open source forever

---

**🌟 Enjoying fanfan? Please star the repo and share with others!**

**Questions?** Open an [issue](https://github.com/USERNAME/fanfan/issues)

**Full Changelog**: https://github.com/USERNAME/fanfan/commits/v1.0.0
