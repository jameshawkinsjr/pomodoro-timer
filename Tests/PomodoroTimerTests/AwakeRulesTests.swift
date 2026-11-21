import Testing
@testable import PomodoroTimer

@Test func holdReason() {
    func reason(battery: Bool = false, ssid: String? = nil, batteryRule: Bool = false, wifiRule: Bool = false, saved: String = "") -> String? {
        AwakeRules.holdReason(onBattery: battery, ssid: ssid, batteryRule: batteryRule, wifiRule: wifiRule, savedSSID: saved)
    }
    #expect(reason() == nil)
    #expect(reason(battery: true) == nil)
    #expect(reason(battery: true, batteryRule: true) == "on battery")
    #expect(reason(batteryRule: true) == nil)
    #expect(reason(ssid: "Home", wifiRule: true, saved: "Home") == "on Wi-Fi Home")
    #expect(reason(ssid: "Cafe", wifiRule: true, saved: "Home") == nil)
    #expect(reason(ssid: "Home", saved: "Home") == nil)
    #expect(reason(ssid: nil, wifiRule: true, saved: "") == nil)
    #expect(reason(ssid: "", wifiRule: true, saved: "") == nil)
}
