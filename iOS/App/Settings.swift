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

    /// Built-in macros plus the user's own (Settings → Add macro).
    static var all: [Macro] { builtIn + AppSettings.shared.customMacros }

    var isCustom: Bool { id.hasPrefix("custom-") }

    /// "⌘⇧P"-style label for a key code and modifiers.
    static func shortcutLabel(key: String, modifiers: [String]) -> String {
        let symbols = ["ctrl": "⌃", "opt": "⌥", "shift": "⇧", "cmd": "⌘"]
        let prefix = ["ctrl", "opt", "shift", "cmd"].filter(modifiers.contains).compactMap { symbols[$0] }.joined()
        return prefix + (key.count == 1 ? key.uppercased() : key)
    }

    private static let builtIn: [Macro] = [
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

/// Stream quality the Mac encodes at (OpenDisplay's StreamQuality).
enum QualityChoice: String, CaseIterable {
    case best, balanced, fast
    var title: String { rawValue.capitalized }
}

/// How big things look on the Mac display: the panel size announced to the
/// Mac is scaled by this, and the picture is scaled back to fit.
enum DisplaySize: String, CaseIterable {
    case larger, standard, moreSpace

    var title: String {
        switch self {
        case .larger: return "Larger text"
        case .standard: return "Default"
        case .moreSpace: return "More space"
        }
    }

    var panelScale: Double {
        switch self {
        case .larger: return 0.75
        case .standard: return 1
        case .moreSpace: return 1.25
        }
    }
}

/// What a touch on the Mac picture does.
enum PictureTouch: String, CaseIterable {
    /// Trackpad while the overlay is open with its trackpad hidden, else direct.
    case automatic
    /// Click where you tap.
    case direct
    /// The whole picture is a trackpad: drag moves the pointer, tap clicks.
    case trackpad
    /// Ignore touches on the picture (scroll and zoom still work).
    case off

    var title: String {
        switch self {
        case .automatic: return "Auto"
        case .direct: return "Click"
        case .trackpad: return "Trackpad"
        case .off: return "Off"
        }
    }
}

/// What happens when the iPad is held upright.
enum PortraitLayout: String, CaseIterable {
    case gameBoy, rotate, landscape

    var title: String {
        switch self {
        case .gameBoy: return "Picture on top, keyboard below"
        case .rotate: return "Turn the Mac display upright"
        case .landscape: return "Stay in landscape"
        }
    }
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

    var pictureTouch: PictureTouch {
        get {
            if let stored = PictureTouch(rawValue: defaults.string(forKey: "pictureTouch") ?? "") { return stored }
            // Earlier builds had an on/off "Tap the picture to click".
            return bool("directTouch", true) ? .automatic : .off
        }
        set { set(newValue.rawValue, "pictureTouch") }
    }

    /// The overlay's Keyboard / Trackpad switches.
    var overlayKeyboard: Bool {
        get { bool("overlayKeyboard", true) }
        set { set(newValue, "overlayKeyboard") }
    }

    var overlayTrackpad: Bool {
        get { bool("overlayTrackpad", true) }
        set { set(newValue, "overlayTrackpad") }
    }

    /// Tap, then touch again and move to drag (like macOS "tap to drag").
    var tapToDrag: Bool {
        get { bool("tapToDrag", true) }
        set { set(newValue, "tapToDrag") }
    }

    /// A flicked scroll keeps going and slows to a stop.
    var momentumScrolling: Bool {
        get { bool("momentumScrolling", true) }
        set { set(newValue, "momentumScrolling") }
    }

    /// Swipe in from the left edge for the overlay, from the top for controls.
    var edgeSwipes: Bool {
        get { bool("edgeSwipes", true) }
        set { set(newValue, "edgeSwipes") }
    }

    var lowBatteryWarning: Bool {
        get { bool("lowBatteryWarning", true) }
        set { set(newValue, "lowBatteryWarning") }
    }

    var portraitLayout: PortraitLayout {
        get { PortraitLayout(rawValue: defaults.string(forKey: "portraitLayout") ?? "") ?? .gameBoy }
        set { set(newValue.rawValue, "portraitLayout") }
    }

    var quality: QualityChoice {
        get { QualityChoice(rawValue: defaults.string(forKey: "quality") ?? "") ?? .best }
        set { set(newValue.rawValue, "quality") }
    }

    var displaySize: DisplaySize {
        get { DisplaySize(rawValue: defaults.string(forKey: "displaySize") ?? "") ?? .standard }
        set { set(newValue.rawValue, "displaySize") }
    }

    /// Start the last-used mode when the app opens.
    var autoStart: Bool {
        get { bool("autoStart", false) }
        set { set(newValue, "autoStart") }
    }

    /// Mode used last, for autoStart. Not a user-facing setting: no change
    /// notification.
    var lastMode: DisplayMode? {
        get { DisplayMode(rawValue: defaults.string(forKey: "lastMode") ?? "") }
        set { defaults.set(newValue?.rawValue, forKey: "lastMode") }
    }

    var showStatusBar: Bool {
        get { bool("showStatusBar", true) }
        set { set(newValue, "showStatusBar") }
    }

    /// Stay connected while the app is in the background (silent audio,
    /// see BackgroundKeeper), so the picture is back instantly on return.
    var keepAliveInBackground: Bool {
        get { bool("keepAliveInBackground", true) }
        set { set(newValue, "keepAliveInBackground") }
    }

    /// Stream diagnostics between the picture and the keyboard in the Game
    /// Boy layout.
    var debugPanel: Bool {
        get { bool("debugPanel", false) }
        set { set(newValue, "debugPanel") }
    }

    var syncClipboard: Bool {
        get { bool("syncClipboard", true) }
        set { set(newValue, "syncClipboard") }
    }

    var pinchToZoom: Bool {
        get { bool("pinchToZoom", true) }
        set { set(newValue, "pinchToZoom") }
    }

    var zoomFollowsPointer: Bool {
        get { bool("zoomFollowsPointer", true) }
        set { set(newValue, "zoomFollowsPointer") }
    }

    var customMacros: [Macro] {
        get {
            (defaults.array(forKey: "customMacros") as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String, let title = item["title"] as? String,
                      let code = item["code"] as? Int else { return nil }
                return Macro(id: id, title: title, detail: item["detail"] as? String ?? "",
                             code: code, modifiers: item["modifiers"] as? [String] ?? [])
            }
        }
        set {
            set(newValue.map { ["id": $0.id, "title": $0.title, "detail": $0.detail,
                                "code": $0.code, "modifiers": $0.modifiers] as [String: Any] },
                "customMacros")
        }
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
        case portrait, display, zoom, overlay, trackpad, touch, macros, about
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
        case .overlay: return 2
        case .trackpad: return 4
        case .about: return 1
        case .touch: return 3
        case .portrait: return PortraitLayout.allCases.count
        case .display: return 7
        case .zoom: return 2
        case .macros: return Macro.all.count + 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .portrait: return "When the iPad is upright"
        case .display: return "Display"
        case .zoom: return "Zoom"
        case .overlay: return "Keyboard & trackpad overlay"
        case .trackpad: return "Trackpad"
        case .touch: return "Touch"
        case .macros: return "Macro bar"
        case .about: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .portrait:
            switch settings.portraitLayout {
            case .gameBoy: return "The Mac display stays landscape at the top of the screen, with the keyboard and trackpad docked below it, like a Game Boy."
            case .rotate: return "The Mac display turns portrait to fill the screen (Extend mode). macOS rebuilds the display, so windows on it may move."
            case .landscape: return "The app doesn't rotate."
            }
        case .display:
            return "Quality: lower is smoother, especially on Wi-Fi. Size: Larger text makes the Mac's interface bigger (Extend mode). Changing either restarts the picture for a moment. Stay connected in the background keeps the Mac's display up while you use other apps, at some battery cost. Debug panel shows stream statistics under the picture when the iPad is upright in the Game Boy layout."
        case .zoom:
            return "Pinch the picture with two fingers to zoom in on the iPad; double-tap with two fingers to zoom back out. The Mac is unaffected."
        case .touch:
            return "Click: tap where you want to click. Trackpad: drag anywhere on the picture to move the pointer, tap to click, two-finger tap to right-click. Auto: Trackpad while the overlay is open with its trackpad switched off, Click otherwise. Off: touches on the picture do nothing (two-finger scroll and pinch still work)."
        case .macros:
            return "Shortcuts shown above the keyboard. ⌃← / ⌃→ switch desktops when Mission Control's shortcuts are enabled on the Mac. Swipe left on your own macros to delete them."
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .portrait:
            settings.portraitLayout = PortraitLayout.allCases[indexPath.row]
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)
        case .macros where indexPath.row == Macro.all.count:
            let editor = CustomMacroViewController { [weak self] in
                self?.tableView.reloadSections(IndexSet(integer: Section.macros.rawValue), with: .automatic)
            }
            navigationController?.pushViewController(editor, animated: true)
        default:
            break
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .macros && indexPath.row < Macro.all.count
            && Macro.all[indexPath.row].isCustom
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let macro = Macro.all[indexPath.row]
        settings.customMacros = settings.customMacros.filter { $0.id != macro.id }
        settings.enabledMacroIDs = settings.enabledMacroIDs.filter { $0 != macro.id }
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch (Section(rawValue: indexPath.section)!, indexPath.row) {
        case (.portrait, let row):
            let layout = PortraitLayout.allCases[row]
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = layout.title
            cell.accessoryType = layout == settings.portraitLayout ? .checkmark : .none
            return cell
        case (.display, 0):
            return SegmentCell(title: "Quality", items: QualityChoice.allCases.map { $0.title },
                               selected: QualityChoice.allCases.firstIndex(of: settings.quality) ?? 0) { [weak self] in
                self?.settings.quality = QualityChoice.allCases[$0]
            }
        case (.display, 1):
            return SegmentCell(title: "Size", items: DisplaySize.allCases.map { $0.title },
                               selected: DisplaySize.allCases.firstIndex(of: settings.displaySize) ?? 1) { [weak self] in
                self?.settings.displaySize = DisplaySize.allCases[$0]
            }
        case (.display, 2):
            return SwitchCell(title: "Start automatically", isOn: settings.autoStart) { [weak self] in
                self?.settings.autoStart = $0
            }
        case (.display, 3):
            return SwitchCell(title: "Status bar (Mac battery, latency, fps)", isOn: settings.showStatusBar) { [weak self] in
                self?.settings.showStatusBar = $0
            }
        case (.display, 4):
            return SwitchCell(title: "Sync clipboard with the Mac", isOn: settings.syncClipboard) { [weak self] in
                self?.settings.syncClipboard = $0
            }
        case (.display, 5):
            return SwitchCell(title: "Stay connected in the background", isOn: settings.keepAliveInBackground) { [weak self] in
                self?.settings.keepAliveInBackground = $0
            }
        case (.display, _):
            return SwitchCell(title: "Debug panel (Game Boy layout)", isOn: settings.debugPanel) { [weak self] in
                self?.settings.debugPanel = $0
            }
        case (.zoom, 0):
            return SwitchCell(title: "Pinch to zoom", isOn: settings.pinchToZoom) { [weak self] in
                self?.settings.pinchToZoom = $0
            }
        case (.zoom, _):
            return SwitchCell(title: "Zoom follows the pointer", isOn: settings.zoomFollowsPointer) { [weak self] in
                self?.settings.zoomFollowsPointer = $0
            }
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
        case (.trackpad, 2):
            return SwitchCell(title: "Tap to drag", isOn: settings.tapToDrag) { [weak self] in
                self?.settings.tapToDrag = $0
            }
        case (.trackpad, 3):
            return SwitchCell(title: "Momentum scrolling", isOn: settings.momentumScrolling) { [weak self] in
                self?.settings.momentumScrolling = $0
            }
        case (.trackpad, _):
            return SwitchCell(title: "Natural scrolling", isOn: settings.naturalScrolling) { [weak self] in
                self?.settings.naturalScrolling = $0
            }
        case (.touch, 0):
            return SegmentCell(title: "Picture", items: PictureTouch.allCases.map { $0.title },
                               selected: PictureTouch.allCases.firstIndex(of: settings.pictureTouch) ?? 0) { [weak self] in
                self?.settings.pictureTouch = PictureTouch.allCases[$0]
            }
        case (.touch, 1):
            return SwitchCell(title: "Edge swipes (left: keyboard & trackpad, top: controls)", isOn: settings.edgeSwipes) { [weak self] in
                self?.settings.edgeSwipes = $0
            }
        case (.touch, _):
            return SwitchCell(title: "Warn when a battery is low", isOn: settings.lowBatteryWarning) { [weak self] in
                self?.settings.lowBatteryWarning = $0
            }
        case (.macros, let row) where row == Macro.all.count:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = "Add macro…"
            cell.textLabel?.textColor = cell.tintColor
            return cell
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

private final class SegmentCell: UITableViewCell {
    private let onChange: (Int) -> Void

    init(title: String, items: [String], selected: Int, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        let label = UILabel()
        label.text = title
        label.setContentHuggingPriority(.required, for: .horizontal)
        let picker = UISegmentedControl(items: items)
        picker.selectedSegmentIndex = selected
        picker.addTarget(self, action: #selector(changed(_:)), for: .valueChanged)
        let row = UIStackView(arrangedSubviews: [label, picker])
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

    @objc private func changed(_ picker: UISegmentedControl) { onChange(picker.selectedSegmentIndex) }
}

// MARK: - Custom macro editor

/// Name + key + modifiers. The key is a character ("p", "4", "/") or a key
/// name ("esc", "f5", "pageup", "left").
final class CustomMacroViewController: UITableViewController {

    private let onSave: () -> Void
    private let nameField = UITextField()
    private let keyField = UITextField()
    private let modifierNames = ["cmd", "opt", "ctrl", "shift"]
    private let modifierTitles = ["⌘ Command", "⌥ Option", "⌃ Control", "⇧ Shift"]
    private var modifiers = Set<String>()

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        super.init(style: .grouped)
        title = "New macro"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self,
                                                            action: #selector(save))
        nameField.placeholder = "Name (optional), e.g. Command palette"
        keyField.placeholder = "Key: p, 4, /, esc, tab, f5, left, pageup…"
        for field in [nameField, keyField] {
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.clearButtonMode = .whileEditing
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 2 ? modifierNames.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["Name", "Key", "Modifiers"][section]
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        if indexPath.section < 2 {
            let field = indexPath.section == 0 ? nameField : keyField
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
                field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
            ])
        } else {
            let name = modifierNames[indexPath.row]
            cell.textLabel?.text = modifierTitles[indexPath.row]
            let toggle = UISwitch()
            toggle.isOn = modifiers.contains(name)
            toggle.tag = indexPath.row
            toggle.addTarget(self, action: #selector(modifierChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        }
        return cell
    }

    @objc private func modifierChanged(_ toggle: UISwitch) {
        let name = modifierNames[toggle.tag]
        if toggle.isOn { modifiers.insert(name) } else { modifiers.remove(name) }
    }

    @objc private func save() {
        let key = (keyField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard let code = MacKeyCode.code(for: key) else {
            let alert = UIAlertController(title: "Unknown key",
                                          message: "Use a single character (p, 4, /) or a key name: esc, tab, return, space, delete, up, down, left, right, home, end, pageup, pagedown, f1–f12.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let ordered = modifierNames.filter(modifiers.contains)
        let shortcut = Macro.shortcutLabel(key: key, modifiers: ordered)
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespaces)
        let macro = Macro(id: "custom-\(UUID().uuidString)", title: name.isEmpty ? shortcut : name,
                          detail: name.isEmpty ? "Custom" : shortcut, code: code, modifiers: ordered)
        let settings = AppSettings.shared
        settings.customMacros = settings.customMacros + [macro]
        settings.enabledMacroIDs = settings.enabledMacroIDs + [macro.id]
        onSave()
        navigationController?.popViewController(animated: true)
    }
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
