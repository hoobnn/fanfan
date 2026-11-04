//
//  File: FanSchedule.swift / 文件：FanSchedule.swift
//  Target: fanfan / 目标：fanfan
//
//  Description: Time-of-day schedule entries and the pure resolver that finds / 描述：按时间切换模式的定时条目，以及找出“最近一次已到达触发点”的纯解析逻辑。
//  the most recent trigger. / 中文：

import Foundation

/// Which days an entry fires on. / 中文：条目在哪些日子触发。
enum ScheduleDays: String, Codable, CaseIterable {
    case everyDay
    case weekdays
    case weekends

    /// Whether this rule covers a `Calendar` weekday (1 = Sunday … 7 = Saturday). / 中文：该规则是否覆盖某个 `Calendar` 星期值（1 = 周日 … 7 = 周六）。
    func covers(weekday: Int) -> Bool {
        switch self {
        case .everyDay: return true
        case .weekdays: return (2...6).contains(weekday)
        case .weekends: return weekday == 1 || weekday == 7
        }
    }
}

/// One time point at which the fans switch to a mode (and strategy, in auto). / 中文：某个时间点把风扇切换到某模式（自动模式时还包括策略）。
struct ScheduleEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var hour: Int
    var minute: Int
    var days: ScheduleDays
    var mode: ControlMode
    /// Only meaningful when `mode == .automatic`. nil means "keep the active strategy". / 中文：仅在 `mode == .automatic` 时有意义；nil 表示保持当前策略。
    var strategyID: String?

    static func new(hour: Int = 9, minute: Int = 0) -> ScheduleEntry {
        ScheduleEntry(id: UUID(), hour: hour, minute: minute, days: .everyDay, mode: .automatic, strategyID: nil)
    }
}

/// A trigger point that has already been reached. / 中文：已经到达的一个触发点。
struct ScheduleTrigger: Equatable {
    let entry: ScheduleEntry
    let date: Date
}

enum ScheduleResolver {
    /// The most recent trigger at or before `now`, looking back up to one week. / 中文：`now` 之前（含）最近的一个触发点，最多回溯一周。
    static func latestTrigger(in entries: [ScheduleEntry], now: Date, calendar: Calendar = .current) -> ScheduleTrigger? {
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            var best: ScheduleTrigger?
            for entry in entries where entry.days.covers(weekday: weekday) {
                guard let candidate = calendar.date(
                    bySettingHour: entry.hour, minute: entry.minute, second: 0, of: day
                ), candidate <= now else { continue }
                if best == nil || candidate > best!.date {
                    best = ScheduleTrigger(entry: entry, date: candidate)
                }
            }
            // Earlier days can only hold older triggers, so the first hit wins. / 中文：更早的日子只会有更旧的触发点，首个命中即最新。
            if let best { return best }
        }
        return nil
    }
}
