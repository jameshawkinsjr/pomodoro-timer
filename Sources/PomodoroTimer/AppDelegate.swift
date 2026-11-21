import AppKit
import CoreLocation
import IOKit.ps
import notify
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum DefaultsKey {
        static let keepDisplayAwake = "keepDisplayAwake"
        static let showCountdown = "showCountdown"
        static let completionSound = "completionSound"
        static let awakeRules = "awakeRules"
        // Replaced by awakeRules; read once to migrate.
        static let keepAwakeOnBattery = "keepAwakeOnBattery"
        static let keepAwakeOnWiFi = "keepAwakeOnWiFi"
        static let keepAwakeSSID = "keepAwakeSSID"
    }

    /// Preset durations offered in the menu, in minutes.
    private static let presets: [Int] = [5, 10, 15, 30, 60, 120, 180, 240, 360, 480]

    private let assertion = SleepAssertion()
    private let updater = Updater()
    private let defaults = UserDefaults.standard
    private let activeIcon = TomatoIcon.menuBarImage(active: true)
    private let inactiveIcon = TomatoIcon.menuBarImage(active: false)

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var endSessionItem: NSMenuItem!
    private var keepDisplayItem: NSMenuItem!
    private var showCountdownItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var soundMenu: NSMenu!
    private var updateStatusItem: NSMenuItem!
    private var installUpdateItem: NSMenuItem!
    private var checkUpdatesItem: NSMenuItem!
    private var autoUpdateItem: NSMenuItem!
    /// Held so a playing sound isn't deallocated mid-playback.
    private var currentSound: NSSound?

    private var isActive = false
    /// nil while active means the session runs indefinitely.
    private var endDate: Date?
    private var ticker: Timer?

    /// Name of the rule holding the Mac awake outside a session; nil when no rule applies.
    private var autoHoldReason: String?
    private var powerSourceToken: Int32 = 0
    /// Created on first use, so the Location prompt only appears when a Wi-Fi rule is set up.
    private var locationManager: CLLocationManager?
    /// Waiting for the Location answer to read the network name for the rule editor.
    private var pendingNetworkHandler: ((String) -> Void)?
    private var rulesWindow: RulesWindowController?

    private var keepDisplayAwake: Bool {
        get { defaults.bool(forKey: DefaultsKey.keepDisplayAwake) }
        set { defaults.set(newValue, forKey: DefaultsKey.keepDisplayAwake) }
    }

    private var showCountdown: Bool {
        get { defaults.bool(forKey: DefaultsKey.showCountdown) }
        set { defaults.set(newValue, forKey: DefaultsKey.showCountdown) }
    }

    /// Keep-awake rules, stored as JSON.
    private var rules: [AwakeRule] {
        get { defaults.data(forKey: DefaultsKey.awakeRules).flatMap { try? JSONDecoder().decode([AwakeRule].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: DefaultsKey.awakeRules) }
    }

    /// Name of the system sound played when a timed session finishes; empty means no sound.
    private var completionSound: String {
        get { defaults.string(forKey: DefaultsKey.completionSound) ?? "" }
        set { defaults.set(newValue, forKey: DefaultsKey.completionSound) }
    }

    /// Sound names from /System/Library/Sounds, e.g. "Glass", "Ping".
    private static let systemSounds: [String] = {
        let directory = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            DefaultsKey.keepDisplayAwake: true,
            DefaultsKey.showCountdown: true,
            DefaultsKey.completionSound: "Glass",
        ])
        migrateRules()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = buildMenu()

        notify_register_dispatch(kIOPSNotifyPowerSource, &powerSourceToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluateRules() }
        }
        // shortcut: polls the SSID every 30 s instead of CoreWLAN events; switch to CWEventDelegate if 30 s lag matters.
        let poll = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluateRules() }
        }
        poll.tolerance = 5
        RunLoop.main.add(poll, forMode: .common)
        reevaluateRules()

        updater.onChange = { [weak self] in self?.updateUI() }
        updater.start()
    }

    /// Turns the old battery / Wi-Fi settings into rules, once: afterwards the rules key exists.
    private func migrateRules() {
        guard defaults.object(forKey: DefaultsKey.awakeRules) == nil else { return }
        rules = AwakeRules.migrated(
            keepAwakeOnBattery: defaults.bool(forKey: DefaultsKey.keepAwakeOnBattery),
            keepAwakeOnWiFi: defaults.bool(forKey: DefaultsKey.keepAwakeOnWiFi),
            ssid: defaults.string(forKey: DefaultsKey.keepAwakeSSID) ?? "",
            keepDisplayAwake: keepDisplayAwake
        )
        for key in [DefaultsKey.keepAwakeOnBattery, DefaultsKey.keepAwakeOnWiFi, DefaultsKey.keepAwakeSSID] {
            defaults.removeObject(forKey: key)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        assertion.release()
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        endSessionItem = NSMenuItem(title: "End Session", action: #selector(endSessionClicked), keyEquivalent: "e")
        endSessionItem.target = self
        menu.addItem(endSessionItem)

        menu.addItem(.separator())
        menu.addItem(sectionHeader("Start New Session"))

        let indefinite = NSMenuItem(title: "Indefinitely", action: #selector(startIndefinitely), keyEquivalent: "i")
        indefinite.target = self
        menu.addItem(indefinite)

        let minutesMenu = NSMenu()
        let hoursMenu = NSMenu()
        for minutes in Self.presets {
            let item = NSMenuItem(title: Self.describe(minutes: minutes), action: #selector(startPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            (minutes < 60 ? minutesMenu : hoursMenu).addItem(item)
        }
        let minutesItem = NSMenuItem(title: "Minutes", action: nil, keyEquivalent: "")
        minutesItem.submenu = minutesMenu
        menu.addItem(minutesItem)
        let hoursItem = NSMenuItem(title: "Hours", action: nil, keyEquivalent: "")
        hoursItem.submenu = hoursMenu
        menu.addItem(hoursItem)

        let custom = NSMenuItem(title: "Custom Duration…", action: #selector(startCustom), keyEquivalent: "d")
        custom.target = self
        menu.addItem(custom)

        menu.addItem(.separator())
        menu.addItem(sectionHeader("Options"))

        keepDisplayItem = NSMenuItem(title: "Keep Display Awake", action: #selector(toggleKeepDisplay), keyEquivalent: "")
        keepDisplayItem.target = self
        keepDisplayItem.toolTip = "For sessions. When off, the screen may sleep but the Mac itself stays awake. Rules use their own setting."
        menu.addItem(keepDisplayItem)

        showCountdownItem = NSMenuItem(title: "Show Countdown in Menu Bar", action: #selector(toggleShowCountdown), keyEquivalent: "")
        showCountdownItem.target = self
        menu.addItem(showCountdownItem)

        soundMenu = NSMenu()
        soundMenu.autoenablesItems = false
        let noSound = NSMenuItem(title: "None", action: #selector(selectSound(_:)), keyEquivalent: "")
        noSound.target = self
        noSound.representedObject = ""
        soundMenu.addItem(noSound)
        soundMenu.addItem(.separator())
        for name in Self.systemSounds {
            let item = NSMenuItem(title: name, action: #selector(selectSound(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            soundMenu.addItem(item)
        }
        let soundItem = NSMenuItem(title: "Completion Sound", action: nil, keyEquivalent: "")
        soundItem.submenu = soundMenu
        menu.addItem(soundItem)

        let rulesItem = NSMenuItem(title: "Rules…", action: #selector(showRules), keyEquivalent: "")
        rulesItem.target = self
        rulesItem.toolTip = "Keep the Mac awake with no session running, e.g. when plugged in on your home Wi-Fi."
        menu.addItem(rulesItem)

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())
        menu.addItem(sectionHeader("Updates"))

        updateStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        updateStatusItem.isEnabled = false
        menu.addItem(updateStatusItem)

        installUpdateItem = NSMenuItem(title: "Install and Restart", action: #selector(installUpdate), keyEquivalent: "")
        installUpdateItem.target = self
        menu.addItem(installUpdateItem)

        checkUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)

        autoUpdateItem = NSMenuItem(title: "Update Automatically", action: #selector(toggleAutoUpdate), keyEquivalent: "")
        autoUpdateItem.target = self
        autoUpdateItem.toolTip = "Installs a new build by itself once you're not using the Mac."
        menu.addItem(autoUpdateItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Pomodoro Timer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateUI()
    }

    // MARK: - Actions

    @objc private func startIndefinitely() {
        startSession(duration: nil)
    }

    @objc private func startPreset(_ sender: NSMenuItem) {
        startSession(duration: TimeInterval(sender.tag * 60))
    }

    @objc private func startCustom() {
        guard let minutes = promptForCustomMinutes(), minutes > 0 else { return }
        startSession(duration: TimeInterval(minutes * 60))
    }

    @objc private func endSessionClicked() {
        endSession()
    }

    @objc private func toggleKeepDisplay() {
        keepDisplayAwake.toggle()
        if isActive {  // rule holds use their own action
            assertion.acquire(keepDisplayAwake: keepDisplayAwake)
        }
        updateUI()
    }

    @objc private func showRules() {
        let controller = rulesWindow ?? RulesWindowController(
            rules: rules,
            onChange: { [weak self] in
                self?.rules = $0
                self?.reevaluateRules()
            },
            readNetwork: { [weak self] in self?.readCurrentNetwork($0) }
        )
        rulesWindow = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Calls `handler` with the joined network's name, asking for Location permission first if needed.
    private func readCurrentNetwork(_ handler: @escaping (String) -> Void) {
        if let ssid = AwakeRules.currentSSID {
            handler(ssid)
            return
        }
        let manager = locationManager ?? CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            // macOS only reveals the SSID to apps with Location permission; retry once the user answers.
            pendingNetworkHandler = handler
            locationManager = manager
            manager.delegate = self
            NSApp.activate(ignoringOtherApps: true)
            manager.requestWhenInUseAuthorization()
            return
        }
        let detail = ![.denied, .restricted].contains(manager.authorizationStatus)
            ? "Make sure Wi-Fi is on and joined to a network, then try again."
            : "macOS only shows the Wi-Fi network name to apps with Location permission. Turn on Pomodoro Timer in System Settings > Privacy & Security > Location Services, then try again."
        showError("Couldn't read the current Wi-Fi network.", detail: detail)
    }

    @objc private func toggleShowCountdown() {
        showCountdown.toggle()
        updateUI()
    }

    @objc private func selectSound(_ sender: NSMenuItem) {
        completionSound = sender.representedObject as? String ?? ""
        playCompletionSound()  // preview
        updateUI()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showError("Couldn't change the login item setting.", detail: error.localizedDescription)
        }
        updateUI()
    }

    @objc private func checkForUpdates() {
        updater.check()
    }

    @objc private func installUpdate() {
        updater.install()
    }

    @objc private func toggleAutoUpdate() {
        updater.autoUpdate.toggle()
        if updater.autoUpdate { updater.check() }
        updateUI()
    }

    // MARK: - Session

    private func startSession(duration: TimeInterval?) {
        guard assertion.acquire(keepDisplayAwake: keepDisplayAwake) else {
            showError("macOS refused to keep the Mac awake.", detail: "The power assertion could not be created.")
            return
        }
        isActive = true
        endDate = duration.map { Date().addingTimeInterval($0) }

        ticker?.invalidate()
        if endDate != nil {
            let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            timer.tolerance = 0.1
            // .common so the countdown keeps updating while the menu is open.
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
        updateUI()
    }

    private func endSession() {
        ticker?.invalidate()
        ticker = nil
        assertion.release()
        isActive = false
        endDate = nil
        reevaluateRules()  // a rule may keep the Mac awake after the session
    }

    /// Holds or releases the assertion for the rules. A manual session owns the assertion while active.
    private func reevaluateRules() {
        let rules = self.rules
        let needsWiFi = rules.contains { $0.enabled && $0.wifi != .any }
        let match = AwakeRules.matchingAction(
            rules: rules,
            onBattery: AwakeRules.onBattery,
            wifiJoined: needsWiFi && AwakeRules.wifiJoined,
            ssid: needsWiFi ? AwakeRules.currentSSID : nil,
            now: Date(),
            calendar: .current
        )
        autoHoldReason = match?.reason
        if !isActive {
            if let match {
                if !assertion.isHeld || assertion.keepsDisplayAwake != match.keepDisplayAwake {
                    assertion.acquire(keepDisplayAwake: match.keepDisplayAwake)
                }
            } else {
                assertion.release()
            }
        }
        updateUI()
    }

    @objc private func tick() {
        if let endDate, endDate.timeIntervalSinceNow <= 0 {
            endSession()
            playCompletionSound()
        } else {
            updateUI()
        }
    }

    // MARK: - UI

    private func updateUI() {
        guard let button = statusItem?.button else { return }

        button.image = assertion.isHeld ? activeIcon : inactiveIcon

        let remaining = endDate.map { max(0, $0.timeIntervalSinceNow) }
        if let remaining, showCountdown {
            button.attributedTitle = NSAttributedString(
                string: " " + Self.format(remaining),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
            )
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }

        if !isActive, assertion.isHeld, let autoHoldReason {
            statusMenuItem.title = "Awake — \(autoHoldReason)"
            button.toolTip = "Pomodoro Timer: awake \(autoHoldReason)"
        } else if !isActive {
            statusMenuItem.title = "Session inactive"
            button.toolTip = "Pomodoro Timer: inactive"
        } else if let remaining, let endDate {
            let endTime = endDate.formatted(date: .omitted, time: .shortened)
            statusMenuItem.title = "Active — \(Self.format(remaining)) left (until \(endTime))"
            button.toolTip = "Pomodoro Timer: \(Self.format(remaining)) remaining"
        } else {
            statusMenuItem.title = "Active — indefinitely"
            button.toolTip = "Pomodoro Timer: active indefinitely"
        }

        endSessionItem.isEnabled = isActive
        keepDisplayItem.state = keepDisplayAwake ? .on : .off
        showCountdownItem.state = showCountdown ? .on : .off
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for item in soundMenu.items where !item.isSeparatorItem {
            item.state = (item.representedObject as? String) == completionSound ? .on : .off
        }

        let (updateText, updateDetail) = updateStatus()
        updateStatusItem.title = updateText
        updateStatusItem.toolTip = updateDetail
        installUpdateItem.isHidden = updater.readyRelease == nil
        installUpdateItem.title = updater.readyRelease.map { "Install \($0.version) and Restart" } ?? "Install and Restart"
        checkUpdatesItem.isEnabled = updater.app != nil && !updater.isBusy
        autoUpdateItem.isEnabled = updater.app != nil
        autoUpdateItem.state = updater.autoUpdate ? .on : .off
    }

    /// The Updates section's status line, and the longer text shown when hovering over it.
    private func updateStatus() -> (String, String?) {
        guard let app = updater.app else { return ("Updates off (development build)", "Only a built Pomodoro Timer.app updates itself.") }
        // Set when the last install was rolled back; cleared by the next Install and Restart.
        if let notice = updater.notice { return ("Last update failed; kept \(app.version)", notice) }
        switch updater.status {
        case .notChecked: return ("Version \(app.label)", nil)
        case .checking: return ("Checking for updates…", nil)
        case .upToDate: return ("Up to date (\(app.version))", "Build \(app.build)")
        case .downloading(let release): return ("Downloading \(release.label)…", nil)
        case .ready(let release): return ("\(release.label) is ready", release.notes)
        case .installing(let release): return ("Installing \(release.label)…", nil)
        case .failed(let message): return ("Couldn't update", message)
        }
    }

    private func playCompletionSound() {
        currentSound?.stop()
        currentSound = completionSound.isEmpty ? nil : NSSound(named: NSSound.Name(completionSound))
        currentSound?.play()
    }

    // MARK: - Dialogs

    private func promptForCustomMinutes() -> Int? {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Custom Duration"
        alert.informativeText = "Keep the Mac awake for:"
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let hoursField = numberField(placeholder: "0")
        let minutesField = numberField(placeholder: "30")
        let row = NSStackView(views: [
            hoursField, NSTextField(labelWithString: "hours"),
            minutesField, NSTextField(labelWithString: "minutes"),
        ])
        row.spacing = 6
        row.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = row
        alert.window.initialFirstResponder = minutesField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let hours = Int(hoursField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        let minutes = Int(minutesField.stringValue.trimmingCharacters(in: .whitespaces))
            ?? (hoursField.stringValue.isEmpty ? 30 : 0)
        let total = max(0, hours) * 60 + max(0, minutes)
        return total > 0 ? total : nil
    }

    private func numberField(placeholder: String) -> NSTextField {
        let field = NSTextField(string: "")
        field.placeholderString = placeholder
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        return field
    }

    private func showError(_ message: String, detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    // MARK: - Formatting

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func describe(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }
}

extension AppDelegate: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let handler = pendingNetworkHandler, manager.authorizationStatus != .notDetermined else { return }
        pendingNetworkHandler = nil
        readCurrentNetwork(handler)
    }
}
