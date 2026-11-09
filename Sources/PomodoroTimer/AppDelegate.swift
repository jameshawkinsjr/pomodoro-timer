import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum DefaultsKey {
        static let keepDisplayAwake = "keepDisplayAwake"
        static let showCountdown = "showCountdown"
        static let completionSound = "completionSound"
    }

    /// Preset durations offered in the menu, in minutes.
    private static let presets: [Int] = [5, 10, 15, 30, 60, 120, 180, 240, 360, 480]

    private let assertion = SleepAssertion()
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
    /// Held so a playing sound isn't deallocated mid-playback.
    private var currentSound: NSSound?

    private var isActive = false
    /// nil while active means the session runs indefinitely.
    private var endDate: Date?
    private var ticker: Timer?

    private var keepDisplayAwake: Bool {
        get { defaults.bool(forKey: DefaultsKey.keepDisplayAwake) }
        set { defaults.set(newValue, forKey: DefaultsKey.keepDisplayAwake) }
    }

    private var showCountdown: Bool {
        get { defaults.bool(forKey: DefaultsKey.showCountdown) }
        set { defaults.set(newValue, forKey: DefaultsKey.showCountdown) }
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

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = buildMenu()
        updateUI()
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
        keepDisplayItem.toolTip = "When off, the screen may sleep but the Mac itself stays awake."
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

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

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
        if isActive {
            assertion.acquire(keepDisplayAwake: keepDisplayAwake)
        }
        updateUI()
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

        button.image = isActive ? activeIcon : inactiveIcon

        let remaining = endDate.map { max(0, $0.timeIntervalSinceNow) }
        if let remaining, showCountdown {
            button.attributedTitle = NSAttributedString(
                string: " " + Self.format(remaining),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
            )
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }

        if !isActive {
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
