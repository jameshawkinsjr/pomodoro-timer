import CoreWLAN
import Foundation
import IOKit.ps

/// A rule that holds the Mac awake with no session running while all of its conditions are true.
struct AwakeRule: Codable, Equatable {
    enum Power: String, Codable, CaseIterable { case any, pluggedIn, onBattery }
    enum WiFi: Codable, Equatable {
        case any
        /// Joined to any network.
        case joined
        /// Joined to the network with this name.
        case ssid(String)
    }
    enum Action: String, Codable { case system, display }
    struct Hours: Codable, Equatable {
        /// Minutes since midnight. A start after the end makes a window that crosses midnight; start == end is all day.
        var start: Int
        var end: Int
        /// Calendar weekday numbers (1 = Sunday) the window starts on. Empty never matches; the editor requires a day.
        var weekdays: Set<Int>
    }

    var id = UUID()
    var name: String
    var enabled = true
    var power: Power = .any
    var wifi: WiFi = .any
    var hours: Hours?
    var action: Action = .system

    func matches(onBattery: Bool, wifiJoined: Bool, ssid: String?, now: Date, calendar: Calendar) -> Bool {
        guard enabled else { return false }
        switch power {
        case .any: break
        case .pluggedIn: if onBattery { return false }
        case .onBattery: if !onBattery { return false }
        }
        switch wifi {
        case .any: break
        case .joined: if !wifiJoined { return false }
        // The SSID is nil without Location permission, so this fails safe.
        case .ssid(let name): if name.isEmpty || ssid != name { return false }
        }
        if let hours {
            let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
            let today = calendar.component(.weekday, from: now)
            let yesterday = today == 1 ? 7 : today - 1
            if hours.start < hours.end {
                return minute >= hours.start && minute < hours.end && hours.weekdays.contains(today)
            } else if hours.start > hours.end {
                // After midnight, the window belongs to the day it started.
                if minute >= hours.start { return hours.weekdays.contains(today) }
                return minute < hours.end && hours.weekdays.contains(yesterday)
            }
            return hours.weekdays.contains(today)
        }
        return true
    }

    /// One line for the Rules window, e.g. "Plugged in · Wi-Fi “Home” · 09:00–17:00 Mon, Tue · Screen awake".
    func summary(calendar: Calendar = .current) -> String {
        var parts: [String] = []
        switch power {
        case .any: break
        case .pluggedIn: parts.append("Plugged in")
        case .onBattery: parts.append("On battery")
        }
        switch wifi {
        case .any: break
        case .joined: parts.append("On Wi-Fi")
        case .ssid(let name): parts.append("Wi-Fi “\(name)”")
        }
        if let hours {
            let time = { (m: Int) in String(format: "%02d:%02d", m / 60, m % 60) }
            let days = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }.filter(hours.weekdays.contains)
            let dayText = days.count == 7 ? "every day" : days.map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
            parts.append(hours.start == hours.end ? "All day \(dayText)" : "\(time(hours.start))–\(time(hours.end)) \(dayText)")
        }
        if parts.isEmpty { parts.append("Always") }
        parts.append(action == .display ? "Screen awake" : "Mac awake")
        return parts.joined(separator: " · ")
    }
}

/// Reads the conditions rules depend on, and decides which rule holds the Mac awake.
enum AwakeRules {
    static var onBattery: Bool {
        IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? == kIOPSBatteryPowerValue
    }

    /// SSID of the joined Wi-Fi network. nil when not joined, or when the app lacks Location permission
    /// (macOS 14+ hides the SSID without it).
    static var currentSSID: String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    /// Whether Wi-Fi is joined to some network. The channel, unlike the SSID, doesn't need Location permission.
    static var wifiJoined: Bool {
        CWWiFiClient.shared().interface()?.wlanChannel() != nil
    }

    /// The hold for the enabled rules that match, or nil if none does. Screen awake beats Mac awake;
    /// the reason is the name of the first matching rule with the winning action.
    static func matchingAction(rules: [AwakeRule], onBattery: Bool, wifiJoined: Bool, ssid: String?, now: Date, calendar: Calendar)
        -> (reason: String, keepDisplayAwake: Bool)?
    {
        let matching = rules.filter { $0.matches(onBattery: onBattery, wifiJoined: wifiJoined, ssid: ssid, now: now, calendar: calendar) }
        guard let rule = matching.first(where: { $0.action == .display }) ?? matching.first else { return nil }
        return (rule.name, rule.action == .display)
    }

    /// Rules for the settings of the old "Keep Awake on Battery" / "Keep Awake on Wi-Fi" items,
    /// whose hold followed the global "Keep Display Awake" option.
    static func migrated(keepAwakeOnBattery: Bool, keepAwakeOnWiFi: Bool, ssid: String, keepDisplayAwake: Bool) -> [AwakeRule] {
        let action: AwakeRule.Action = keepDisplayAwake ? .display : .system
        var rules: [AwakeRule] = []
        if keepAwakeOnBattery { rules.append(AwakeRule(name: "On battery", power: .onBattery, action: action)) }
        if keepAwakeOnWiFi, !ssid.isEmpty { rules.append(AwakeRule(name: "On Wi-Fi \(ssid)", wifi: .ssid(ssid), action: action)) }
        return rules
    }
}
