import CoreWLAN
import Foundation
import IOKit.ps

/// Reads the conditions the "keep awake on battery / on Wi-Fi" rules depend on.
enum AwakeRules {
    static var onBattery: Bool {
        IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? == kIOPSBatteryPowerValue
    }

    /// SSID of the joined Wi-Fi network. nil when not joined, or when the app lacks Location permission
    /// (macOS 14+ hides the SSID without it).
    static var currentSSID: String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    /// Why the Mac should be held awake without a session, or nil if no rule applies.
    static func holdReason(onBattery: Bool, ssid: String?, batteryRule: Bool, wifiRule: Bool, savedSSID: String) -> String? {
        if batteryRule && onBattery { return "on battery" }
        if wifiRule, let ssid, !ssid.isEmpty, ssid == savedSSID { return "on Wi-Fi \(ssid)" }
        return nil
    }
}
