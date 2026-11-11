//
//  File: FanRPMBounds.swift / 文件：FanRPMBounds.swift
//  Target: fanfan / 目标：fanfan
//
//  Created by haobin on 2026/5/15. / 创建者：haobin，日期：2026/5/15。
//  Description: Central RPM limits for SMC reads, UI sliders, and writes. / 描述：SMC 读取、界面滑杆和写入操作共用的 RPM 限制。
//

import Foundation

/// Hardware fan RPM bounds used when SMC keys are missing or before telemetry arrives. / 中文：Hardware 风扇 RPM bounds used when SMC 键s are missing or before telemetry arrives.
enum FanRPMBounds {
    /// Typical Intel MacBook Pro ceiling; used only as an absolute write clamp. / 中文：Typical Intel MacBook Pro ceiling; used only as an absolute 写入 夹取.
    static let absoluteWriteMaxRPM = 8000

    /// Lowest speed fanfan drives a fan to: 0 stops it. `F%dMn` is only the firmware's own idle speed, / 中文：fanfan 可下发的最低转速，0 即停转。`F%dMn` 只是固件自己的怠速，
    /// not a write limit — M4 Pro accepts `F%dTg` = 0 in manual mode and the fans stop. / 中文：不是写入下限——M4 Pro 手动模式下接受 `F%dTg` = 0，风扇随即停转。
    static let floorRPM = 0

    /// When `F%dMx` cannot be read, avoid assuming Intel-class 6500 RPM (incorrect on Apple Silicon). / 中文：When `F%dMx` cannot be 读取, avoid assuming Intel-class 6500 RPM (incorrect on Apple Sil图标).
    static let fallbackMaxWhenSMCUnreadable = 5200
}
