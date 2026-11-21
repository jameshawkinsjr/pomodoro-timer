import AppKit

/// The "Rules…" window: the list of rules with Add, Edit and Delete, and an editor sheet.
/// AppDelegate stores the rules; every change is handed to `onChange`.
@MainActor
final class RulesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var rules: [AwakeRule]
    private let onChange: ([AwakeRule]) -> Void
    private let readNetwork: (@escaping (String) -> Void) -> Void
    private let table = NSTableView()
    private var editButton: NSButton!
    private var deleteButton: NSButton!
    private var editor: RuleEditor?

    init(rules: [AwakeRule], onChange: @escaping ([AwakeRule]) -> Void, readNetwork: @escaping (@escaping (String) -> Void) -> Void) {
        self.rules = rules
        self.onChange = onChange
        self.readNetwork = readNetwork
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Rules"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 260)
        super.init(window: window)

        for (id, title, width) in [("on", "On", 28.0), ("name", "Name", 150), ("summary", "Conditions", 380)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editRule)
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let note = NSTextField(wrappingLabelWithString:
            "With no session running, the Mac stays awake while every condition of an enabled rule is true. "
            + "Each rule has its own action; Keep Display Awake applies to sessions only.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let add = NSButton(title: "Add…", target: self, action: #selector(addRule))
        editButton = NSButton(title: "Edit…", target: self, action: #selector(editRule))
        deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteRule))
        let buttons = NSStackView(views: [add, editButton, deleteButton])

        let stack = NSStackView(views: [note, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window.contentView = stack
        for view in [note, scroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        window.center()
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rule = rules[row]
        switch tableColumn?.identifier.rawValue {
        case "on":
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
            box.state = rule.enabled ? .on : .off
            box.setAccessibilityLabel("Enable \(rule.name)")
            return box
        case "name":
            return label(rule.name)
        default:
            return label(rule.summary())
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = text
        return field
    }

    private func updateButtons() {
        editButton.isEnabled = table.selectedRow >= 0
        deleteButton.isEnabled = table.selectedRow >= 0
    }

    private func save() {
        onChange(rules)
        table.reloadData()
        updateButtons()
    }

    // MARK: - Actions

    @objc private func toggleEnabled(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard rules.indices.contains(row) else { return }
        rules[row].enabled = sender.state == .on
        save()
    }

    @objc private func addRule() {
        openEditor(for: AwakeRule(name: ""), at: nil)
    }

    @objc private func editRule() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rules.indices.contains(row) else { return }
        openEditor(for: rules[row], at: row)
    }

    @objc private func deleteRule() {
        guard rules.indices.contains(table.selectedRow) else { return }
        rules.remove(at: table.selectedRow)
        save()
    }

    private func openEditor(for rule: AwakeRule, at index: Int?) {
        guard editor == nil, let window else { return }
        let editor = RuleEditor(rule: rule, readNetwork: readNetwork) { [weak self] edited in
            guard let self else { return }
            if let edited {
                if let index { self.rules[index] = edited } else { self.rules.append(edited) }
                self.save()
            }
            if let sheet = self.editor?.sheet { window.endSheet(sheet) }
            self.editor = nil
        }
        self.editor = editor
        window.beginSheet(editor.sheet)
    }
}

/// The sheet that edits one rule. Calls `done` with the edited rule, or nil when cancelled.
@MainActor
private final class RuleEditor: NSObject {
    let sheet: NSWindow
    private var rule: AwakeRule
    private let readNetwork: (@escaping (String) -> Void) -> Void
    private let done: (AwakeRule?) -> Void

    private let nameField = NSTextField(string: "")
    private let powerPopup = NSPopUpButton()
    private let wifiPopup = NSPopUpButton()
    private let ssidField = NSTextField(string: "")
    private var useNetworkButton: NSButton!
    private var hoursBox: NSButton!
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private var dayBoxes: [NSButton] = []
    private let actionPopup = NSPopUpButton()

    private static let powers: [(AwakeRule.Power, String)] = [(.any, "Any"), (.pluggedIn, "Plugged in"), (.onBattery, "On battery")]
    private static let actions: [(AwakeRule.Action, String)] = [
        (.system, "Keep Mac awake (screen may sleep)"), (.display, "Keep screen awake"),
    ]
    // Pickers show minutes since midnight as a UTC date on 2001-01-01, so no time-zone maths is needed.
    private static let utc = TimeZone(identifier: "UTC")!

    init(rule: AwakeRule, readNetwork: @escaping (@escaping (String) -> Void) -> Void, done: @escaping (AwakeRule?) -> Void) {
        self.rule = rule
        self.readNetwork = readNetwork
        self.done = done
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()

        nameField.stringValue = rule.name
        nameField.placeholderString = "e.g. At my desk"

        powerPopup.addItems(withTitles: Self.powers.map(\.1))
        powerPopup.selectItem(at: Self.powers.firstIndex { $0.0 == rule.power } ?? 0)

        wifiPopup.addItems(withTitles: ["Any", "Joined to any network", "Joined to network named:"])
        wifiPopup.target = self
        wifiPopup.action = #selector(updateEnabled)
        switch rule.wifi {
        case .any: wifiPopup.selectItem(at: 0)
        case .joined: wifiPopup.selectItem(at: 1)
        case .ssid(let name):
            wifiPopup.selectItem(at: 2)
            ssidField.stringValue = name
        }
        ssidField.placeholderString = "Network name"
        ssidField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        useNetworkButton = NSButton(title: "Use Current Network", target: self, action: #selector(useCurrentNetwork))

        let hours = rule.hours ?? .init(start: 9 * 60, end: 17 * 60, weekdays: [2, 3, 4, 5, 6])
        hoursBox = NSButton(checkboxWithTitle: "Only from", target: self, action: #selector(updateEnabled))
        hoursBox.state = rule.hours == nil ? .off : .on
        for (picker, minutes) in [(startPicker, hours.start), (endPicker, hours.end)] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .hourMinute
            picker.timeZone = Self.utc
            picker.dateValue = Date(timeIntervalSinceReferenceDate: TimeInterval(minutes * 60))
        }
        let calendar = Calendar.current
        for offset in 0..<7 {
            let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
            let box = NSButton(checkboxWithTitle: calendar.shortWeekdaySymbols[weekday - 1], target: nil, action: nil)
            box.tag = weekday
            box.state = hours.weekdays.contains(weekday) ? .on : .off
            dayBoxes.append(box)
        }

        actionPopup.addItems(withTitles: Self.actions.map(\.1))
        actionPopup.selectItem(at: Self.actions.firstIndex { $0.0 == rule.action } ?? 0)

        let hint = NSTextField(wrappingLabelWithString:
            "A window that ends before it starts runs past midnight; equal times mean all day. "
            + "Network names need Location permission.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.preferredMaxLayoutWidth = 380

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "Power:"), powerPopup],
            [NSTextField(labelWithString: "Wi-Fi:"), wifiPopup],
            [NSGridCell.emptyContentView, row([ssidField, useNetworkButton])],
            [NSTextField(labelWithString: "Hours:"), row([hoursBox, startPicker, NSTextField(labelWithString: "to"), endPicker])],
            [NSGridCell.emptyContentView, row(dayBoxes)],
            [NSTextField(labelWithString: "Action:"), actionPopup],
            [NSGridCell.emptyContentView, hint],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.addView(cancel, in: .trailing)
        buttons.addView(saveButton, in: .trailing)

        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        sheet.contentView = stack
        buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        sheet.setContentSize(stack.fittingSize)
        sheet.initialFirstResponder = nameField
        updateEnabled()
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 6
        return stack
    }

    @objc private func updateEnabled() {
        let specific = wifiPopup.indexOfSelectedItem == 2
        ssidField.isEnabled = specific
        useNetworkButton.isEnabled = specific
        let limited = hoursBox.state == .on
        for control in [startPicker, endPicker] as [NSControl] + dayBoxes { control.isEnabled = limited }
    }

    @objc private func useCurrentNetwork() {
        readNetwork { [weak self] ssid in self?.ssidField.stringValue = ssid }
    }

    @objc private func cancel() { done(nil) }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let ssid = ssidField.stringValue
        let days = Set(dayBoxes.filter { $0.state == .on }.map(\.tag))
        if name.isEmpty { return complain("Give the rule a name.") }
        if wifiPopup.indexOfSelectedItem == 2, ssid.isEmpty { return complain("Enter the network name, or use the current network.") }
        if hoursBox.state == .on, days.isEmpty { return complain("Choose at least one day.") }

        rule.name = name
        rule.power = Self.powers[powerPopup.indexOfSelectedItem].0
        rule.wifi = [.any, .joined, .ssid(ssid)][wifiPopup.indexOfSelectedItem]
        rule.hours = hoursBox.state == .on ? .init(start: minutes(startPicker), end: minutes(endPicker), weekdays: days) : nil
        rule.action = Self.actions[actionPopup.indexOfSelectedItem].0
        done(rule)
    }

    private func minutes(_ picker: NSDatePicker) -> Int {
        let total = Int(picker.dateValue.timeIntervalSinceReferenceDate) / 60
        return (total % 1440 + 1440) % 1440
    }

    private func complain(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.beginSheetModal(for: sheet)
    }
}
