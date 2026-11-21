import Foundation
import Testing
@testable import PomodoroTimer

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}()

/// 2026-11-16 is a Monday (weekday 2).
private func date(day: Int = 16, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func match(_ rules: [AwakeRule], battery: Bool = false, joined: Bool = false, ssid: String? = nil, at now: Date = date(12))
    -> (reason: String, keepDisplayAwake: Bool)?
{
    AwakeRules.matchingAction(rules: rules, onBattery: battery, wifiJoined: joined, ssid: ssid, now: now, calendar: calendar)
}

@Test func powerCondition() {
    let any = AwakeRule(name: "any")
    let plugged = AwakeRule(name: "plugged", power: .pluggedIn)
    let battery = AwakeRule(name: "battery", power: .onBattery)
    #expect(match([any])?.reason == "any")
    #expect(match([plugged])?.reason == "plugged")
    #expect(match([plugged], battery: true) == nil)
    #expect(match([battery]) == nil)
    #expect(match([battery], battery: true)?.reason == "battery")
}

@Test func wifiCondition() {
    let joined = AwakeRule(name: "joined", wifi: .joined)
    let home = AwakeRule(name: "home", wifi: .ssid("Home"))
    #expect(match([joined]) == nil)
    #expect(match([joined], joined: true)?.reason == "joined")
    #expect(match([home], joined: true, ssid: "Home")?.reason == "home")
    #expect(match([home], joined: true, ssid: "Cafe") == nil)
    #expect(match([home], joined: true, ssid: nil) == nil)  // no Location permission
    #expect(match([AwakeRule(name: "blank", wifi: .ssid(""))], joined: true, ssid: "") == nil)
}

@Test func allConditionsMustHold() {
    let rule = AwakeRule(name: "desk", power: .pluggedIn, wifi: .ssid("Home"),
                         hours: .init(start: 9 * 60, end: 17 * 60, weekdays: [2]))
    #expect(match([rule], joined: true, ssid: "Home")?.reason == "desk")
    #expect(match([rule], battery: true, joined: true, ssid: "Home") == nil)
    #expect(match([rule], joined: true, ssid: "Cafe") == nil)
    #expect(match([rule], joined: true, ssid: "Home", at: date(18)) == nil)
}

@Test func hoursWindow() {
    let work = AwakeRule(name: "work", hours: .init(start: 9 * 60, end: 17 * 60, weekdays: [2, 3, 4, 5, 6]))
    #expect(match([work], at: date(8, 59)) == nil)
    #expect(match([work], at: date(9)) != nil)
    #expect(match([work], at: date(16, 59)) != nil)
    #expect(match([work], at: date(17)) == nil)  // end is exclusive
    #expect(match([work], at: date(day: 15, 12)) == nil)  // Sunday
    #expect(match([work], at: date(day: 20, 12)) != nil)  // Friday
    #expect(match([work], at: date(day: 21, 12)) == nil)  // Saturday

    let allDay = AwakeRule(name: "all day", hours: .init(start: 0, end: 0, weekdays: [2]))
    #expect(match([allDay], at: date(0)) != nil)
    #expect(match([allDay], at: date(23, 59)) != nil)
    #expect(match([allDay], at: date(day: 17, 0)) == nil)

    let noDays = AwakeRule(name: "no days", hours: .init(start: 0, end: 0, weekdays: []))
    #expect(match([noDays]) == nil)
}

@Test func hoursAcrossMidnight() {
    // Friday 22:00 to Saturday 02:00.
    let night = AwakeRule(name: "night", hours: .init(start: 22 * 60, end: 2 * 60, weekdays: [6]))
    #expect(match([night], at: date(day: 20, 21, 59)) == nil)
    #expect(match([night], at: date(day: 20, 22)) != nil)
    #expect(match([night], at: date(day: 21, 1, 59)) != nil)  // Saturday morning belongs to Friday
    #expect(match([night], at: date(day: 21, 2)) == nil)
    #expect(match([night], at: date(day: 20, 1)) == nil)  // Friday morning belongs to Thursday
    #expect(match([night], at: date(day: 21, 22)) == nil)  // Saturday evening

    // Saturday 23:00 to Sunday 01:00 wraps the week.
    let saturday = AwakeRule(name: "sat", hours: .init(start: 23 * 60, end: 60, weekdays: [7]))
    #expect(match([saturday], at: date(day: 22, 0, 30)) != nil)
}

@Test func disabledAndStrongestAction() {
    let off = AwakeRule(name: "off", enabled: false)
    #expect(match([off]) == nil)
    #expect(match([]) == nil)

    let system = AwakeRule(name: "system")
    let display = AwakeRule(name: "display", action: .display)
    #expect(match([system])! == ("system", false))
    #expect(match([system, display])! == ("display", true))
    #expect(match([display, system])! == ("display", true))
    #expect(match([AwakeRule(name: "off display", enabled: false, action: .display), system])! == ("system", false))
}

@Test func migration() {
    let none = AwakeRules.migrated(keepAwakeOnBattery: false, keepAwakeOnWiFi: false, ssid: "Home", keepDisplayAwake: true)
    #expect(none.isEmpty)

    let both = AwakeRules.migrated(keepAwakeOnBattery: true, keepAwakeOnWiFi: true, ssid: "Home", keepDisplayAwake: true)
    #expect(both.count == 2)
    #expect(both[0].power == .onBattery && both[0].wifi == .any && both[0].hours == nil && both[0].action == .display)
    #expect(both[1].power == .any && both[1].wifi == .ssid("Home") && both[1].action == .display)

    let system = AwakeRules.migrated(keepAwakeOnBattery: true, keepAwakeOnWiFi: false, ssid: "", keepDisplayAwake: false)
    #expect(system.map(\.action) == [.system])

    // The old Wi-Fi item did nothing without a saved network.
    #expect(AwakeRules.migrated(keepAwakeOnBattery: false, keepAwakeOnWiFi: true, ssid: "", keepDisplayAwake: true).isEmpty)
}

@Test func codableRoundTrip() throws {
    let rules = [
        AwakeRule(name: "a", power: .pluggedIn, wifi: .ssid("Home"), hours: .init(start: 1320, end: 120, weekdays: [1, 7]), action: .display),
        AwakeRule(name: "b", enabled: false, wifi: .joined),
        AwakeRule(name: "c"),
    ]
    let decoded = try JSONDecoder().decode([AwakeRule].self, from: JSONEncoder().encode(rules))
    #expect(decoded == rules)
}

@Test func summary() {
    let rule = AwakeRule(name: "x", power: .pluggedIn, wifi: .ssid("Home"), hours: .init(start: 9 * 60, end: 17 * 60 + 30, weekdays: [2, 3]), action: .display)
    #expect(rule.summary(calendar: calendar) == "Plugged in · Wi-Fi “Home” · 09:00–17:30 Mon, Tue · Screen awake")
    #expect(AwakeRule(name: "y").summary(calendar: calendar) == "Always · Mac awake")
}
