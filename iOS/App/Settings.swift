// Settings.swift
//
// User settings (UserDefaults-backed) and the settings screen. Plain UIKit
// table for iOS 12.

import UIKit

/// A one-tap shortcut on the overlay's macro bar.
struct Macro {
    let id: String
    let title: String
    let detail: String
    let code: Int
    let modifiers: [String]

    static let all: [Macro] = [
        Macro(id: "ctrl-c", title: "⌃C", detail: "Interrupt (terminal)", code: 8, modifiers: ["ctrl"]),
        Macro(id: "ctrl-d", title: "⌃D", detail: "End of input / exit shell", code: 2, modifiers: ["ctrl"]),
        Macro(id: "ctrl-r", title: "⌃R", detail: "Search shell history", code: 15, modifiers: ["ctrl"]),
        Macro(id: "ctrl-l", title: "⌃L", detail: "Clear terminal", code: 37, modifiers: ["ctrl"]),
        Macro(id: "space-left", title: "⌃← Space", detail: "Previous desktop", code: MacKeyCode.left, modifiers: ["ctrl"]),
        Macro(id: "space-right", title: "⌃→ Space", detail: "Next desktop", code: MacKeyCode.right, modifiers: ["ctrl"]),
        Macro(id: "mission-control", title: "Mission Control", detail: "⌃↑", code: MacKeyCode.up, modifiers: ["ctrl"]),
        Macro(id: "app-windows", title: "App Windows", detail: "⌃↓", code: MacKeyCode.down, modifiers: ["ctrl"]),
        Macro(id: "cmd-tab", title: "⌘Tab", detail: "Switch to last app", code: MacKeyCode.tab, modifiers: ["cmd"]),
        Macro(id: "cmd-backtick", title: "⌘`", detail: "Next window of this app", code: 50, modifiers: ["cmd"]),
        Macro(id: "spotlight", title: "Spotlight", detail: "⌘Space", code: MacKeyCode.space, modifiers: ["cmd"]),
        Macro(id: "copy", title: "⌘C", detail: "Copy", code: 8, modifiers: ["cmd"]),
        Macro(id: "paste", title: "⌘V", detail: "Paste", code: 9, modifiers: ["cmd"]),
        Macro(id: "undo", title: "⌘Z", detail: "Undo", code: 6, modifiers: ["cmd"]),
        Macro(id: "save", title: "⌘S", detail: "Save", code: 1, modifiers: ["cmd"]),
        Macro(id: "find", title: "⌘F", detail: "Find", code: 3, modifiers: ["cmd"]),
        Macro(id: "new-tab", title: "⌘T", detail: "New tab", code: 17, modifiers: ["cmd"]),
        Macro(id: "close", title: "⌘W", detail: "Close tab / window", code: 13, modifiers: ["cmd"]),
        Macro(id: "screenshot", title: "⌘⇧4", detail: "Screenshot selection", code: 21, modifiers: ["cmd", "shift"]),
    ]
}

final class AppSettings {

    static let shared = AppSettings()
    static let didChange = Notification.Name("AppSettingsDidChange")

    private let defaults = UserDefaults.standard

    private func double(_ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Key and trackpad background opacity, 0.15...0.9.
    var overlayOpacity: Double {
        get { double("overlayOpacity", 0.4) }
        set { set(newValue, "overlayOpacity") }
    }

    /// Share of the screen height the overlay covers, 0.3...0.6.
    var overlayHeight: Double {
        get { double("overlayHeight", 0.45) }
        set { set(newValue, "overlayHeight") }
    }

    /// Trackpad pointer speed multiplier, 0.5...2.5.
    var trackpadSpeed: Double {
        get { double("trackpadSpeed", 1) }
        set { set(newValue, "trackpadSpeed") }
    }

    /// Content follows the fingers when scrolling (macOS default).
    var naturalScrolling: Bool {
        get { bool("naturalScrolling", true) }
        set { set(newValue, "naturalScrolling") }
    }

    /// Touching the picture clicks there on the Mac. Off = trackpad only.
    var directTouch: Bool {
        get { bool("directTouch", true) }
        set { set(newValue, "directTouch") }
    }

    var enabledMacroIDs: [String] {
        get {
            defaults.stringArray(forKey: "enabledMacros")
                ?? ["ctrl-c", "space-left", "space-right", "mission-control", "cmd-tab", "spotlight", "copy", "paste", "undo"]
        }
        set { set(newValue, "enabledMacros") }
    }

    var enabledMacros: [Macro] {
        let ids = Set(enabledMacroIDs)
        return Macro.all.filter { ids.contains($0.id) }
    }
}

// MARK: - Settings screen

final class SettingsViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case overlay, trackpad, touch, macros, about
    }

    private let settings = AppSettings.shared

    init() {
        super.init(style: .grouped)
        title = "Settings"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self,
                                                            action: #selector(done))
    }

    @objc private func done() {
        dismiss(animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .overlay, .trackpad: return 2
        case .touch, .about: return 1
        case .macros: return Macro.all.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .overlay: return "Keyboard & trackpad overlay"
        case .trackpad: return "Trackpad"
        case .touch: return "Touch"
        case .macros: return "Macro bar"
        case .about: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .touch:
            return "Turn this off to drive the Mac only with the trackpad, so a stray touch on the picture never clicks. Handy with the Mac closed (clamshell)."
        case .macros:
            return "Shortcuts shown above the keyboard. ⌃← / ⌃→ switch desktops when Mission Control's shortcuts are enabled on the Mac."
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch (Section(rawValue: indexPath.section)!, indexPath.row) {
        case (.overlay, 0):
            return SliderCell(title: "Opacity", value: settings.overlayOpacity, range: 0.15...0.9) { [weak self] in
                self?.settings.overlayOpacity = $0
            }
        case (.overlay, _):
            return SliderCell(title: "Height", value: settings.overlayHeight, range: 0.3...0.6) { [weak self] in
                self?.settings.overlayHeight = $0
            }
        case (.trackpad, 0):
            return SliderCell(title: "Speed", value: settings.trackpadSpeed, range: 0.5...2.5) { [weak self] in
                self?.settings.trackpadSpeed = $0
            }
        case (.trackpad, _):
            return SwitchCell(title: "Natural scrolling", isOn: settings.naturalScrolling) { [weak self] in
                self?.settings.naturalScrolling = $0
            }
        case (.touch, _):
            return SwitchCell(title: "Tap the picture to click", isOn: settings.directTouch) { [weak self] in
                self?.settings.directTouch = $0
            }
        case (.macros, let row):
            let macro = Macro.all[row]
            let cell = SwitchCell(title: macro.title, isOn: settings.enabledMacroIDs.contains(macro.id)) { [weak self] on in
                guard let self = self else { return }
                var ids = self.settings.enabledMacroIDs.filter { $0 != macro.id }
                if on { ids.append(macro.id) }
                self.settings.enabledMacroIDs = ids
            }
            cell.detailTextLabel?.text = macro.detail
            return cell
        case (.about, _):
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = "Version"
            cell.detailTextLabel?.text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            cell.selectionStyle = .none
            return cell
        }
    }
}

private final class SwitchCell: UITableViewCell {
    private let onChange: (Bool) -> Void

    init(title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(style: .subtitle, reuseIdentifier: nil)
        selectionStyle = .none
        textLabel?.text = title
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addTarget(self, action: #selector(changed(_:)), for: .valueChanged)
        accessoryView = toggle
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func changed(_ toggle: UISwitch) { onChange(toggle.isOn) }
}

private final class SliderCell: UITableViewCell {
    private let onChange: (Double) -> Void

    init(title: String, value: Double, range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        let label = UILabel()
        label.text = title
        label.setContentHuggingPriority(.required, for: .horizontal)
        let slider = UISlider()
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.value = Float(value)
        slider.addTarget(self, action: #selector(changed(_:)), for: .valueChanged)
        let row = UIStackView(arrangedSubviews: [label, slider])
        row.spacing = 16
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            label.widthAnchor.constraint(equalToConstant: 80),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func changed(_ slider: UISlider) { onChange(Double(slider.value)) }
}
