// InputPanels.swift
//
// The see-through input overlay for driving the Mac while streaming: a Mac
// keyboard on the left three quarters, a trackpad on the right quarter, and
// a macro bar above both. Sent as "key" / "mouse" / "scroll" control
// messages, which the patched OpenDisplay Mac app injects
// (patches/02-keyboard-trackpad.patch). Plain UIKit for iOS 12.

import UIKit

/// macOS virtual key codes (US ANSI positions). The Mac's own keyboard
/// layout turns them into characters, like a real keyboard would.
enum MacKeyCode {
    static let returnKey = 36, tab = 48, space = 49, delete = 51, escape = 53
    static let left = 123, right = 124, down = 125, up = 126
}

/// A view that swallows stray touches, so taps on the overlay's gaps never
/// reach the view controller as clicks on the Mac.
class PanelView: UIView {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}
}

private func overlayButton(_ title: String) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.tintColor = .white
    button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
    button.layer.cornerRadius = 8
    button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    return button
}

/// A chevron drawn with a shape layer (no SF Symbols on iOS 12).
private func chevronLayer(pointingUp: Bool, in size: CGSize) -> CAShapeLayer {
    let path = UIBezierPath()
    let midX = size.width / 2, midY = size.height / 2
    let dy: CGFloat = pointingUp ? -4 : 4
    path.move(to: CGPoint(x: midX - 8, y: midY - dy))
    path.addLine(to: CGPoint(x: midX, y: midY + dy))
    path.addLine(to: CGPoint(x: midX + 8, y: midY - dy))
    let layer = CAShapeLayer()
    layer.path = path.cgPath
    layer.strokeColor = UIColor.white.cgColor
    layer.fillColor = UIColor.clear.cgColor
    layer.lineWidth = 2.5
    layer.lineCap = .round
    layer.lineJoin = .round
    return layer
}

// MARK: - Overlay

final class InputOverlay: PanelView {

    var onKey: ((Int, [String]) -> Void)?
    var onMove: ((Double, Double) -> Void)?
    var onClick: ((String) -> Void)?
    var onButton: ((String, Bool) -> Void)?
    var onScroll: ((Double, Double) -> Void)?
    var onSettings: (() -> Void)?
    var onHide: (() -> Void)?

    private let macroBar = MacroBar()
    private let keyboard = MacKeyboardView()
    private let trackpad = TrackpadView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        keyboard.onKey = { [weak self] code, modifiers in self?.onKey?(code, modifiers) }
        macroBar.onMacro = { [weak self] macro in self?.onKey?(macro.code, macro.modifiers) }
        macroBar.onSettings = { [weak self] in self?.onSettings?() }
        macroBar.onHide = { [weak self] in self?.onHide?() }
        macroBar.onButton = { [weak self] button, down in self?.onButton?(button, down) }
        trackpad.onMove = { [weak self] dx, dy in self?.onMove?(dx, dy) }
        trackpad.onClick = { [weak self] button in self?.onClick?(button) }
        trackpad.onButton = { [weak self] button, down in self?.onButton?(button, down) }
        trackpad.onScroll = { [weak self] dx, dy in self?.onScroll?(dx, dy) }
        [macroBar, keyboard, trackpad].forEach(addSubview)
        applySettings()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func applySettings() {
        let settings = AppSettings.shared
        let opacity = CGFloat(settings.overlayOpacity)
        keyboard.keyOpacity = opacity
        trackpad.padOpacity = opacity
        macroBar.buttonOpacity = opacity
        macroBar.macros = settings.enabledMacros
    }

    /// Docked under the picture (Game Boy layout), the overlay can't be hidden.
    var showsHideButton: Bool {
        get { macroBar.showsHide }
        set { macroBar.showsHide = newValue }
    }

    /// Releases any key or button still held, e.g. when the overlay hides.
    func releaseAll() {
        keyboard.releaseAll()
        trackpad.releaseButtons()
        macroBar.releaseButtons()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: UIEdgeInsets(top: 0, left: 8, bottom: 8, right: 8))
        let barHeight: CGFloat = 40
        macroBar.frame = CGRect(x: area.minX, y: area.minY, width: area.width, height: barHeight)
        let body = CGRect(x: area.minX, y: area.minY + barHeight + 6,
                          width: area.width, height: area.height - barHeight - 6)
        let keyboardWidth = (body.width - 8) * 0.75
        keyboard.frame = CGRect(x: body.minX, y: body.minY, width: keyboardWidth, height: body.height)
        trackpad.frame = CGRect(x: body.minX + keyboardWidth + 8, y: body.minY,
                                width: body.width - keyboardWidth - 8, height: body.height)
    }
}

/// The small arrow in the bottom-right corner that opens the overlay.
final class OverlayToggleButton: UIButton {
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 30))
        backgroundColor = UIColor(white: 0, alpha: 0.35)
        layer.cornerRadius = 10
        alpha = 0.45
        layer.addSublayer(chevronLayer(pointingUp: true, in: bounds.size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // A bigger touch target than the visible arrow.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -12, dy: -12).contains(point)
    }
}

// MARK: - Macro bar

private final class MacroBar: UIView {

    var onMacro: ((Macro) -> Void)?
    var onSettings: (() -> Void)?
    var onHide: (() -> Void)?
    /// Mouse button held (true) or released (false) from the bar's L / R.
    var onButton: ((String, Bool) -> Void)?

    var macros: [Macro] = [] { didSet { rebuild() } }
    var buttonOpacity: CGFloat = 0.4 { didSet { restyle() } }
    var showsHide = true { didSet { hideButton.isHidden = !showsHide; setNeedsLayout() } }

    // Left-hand mouse buttons, so the left thumb clicks while the right hand
    // is on the trackpad. Hold one and move on the trackpad to drag.
    private let leftClick = overlayButton("L")
    private let rightClick = overlayButton("R")
    private var heldButtons = Set<String>()
    private let scroll = UIScrollView()
    private let row = UIStackView()
    private let settingsButton = overlayButton("Settings")
    private let hideButton = UIButton(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        addSubview(scroll)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
        addSubview(settingsButton)
        hideButton.layer.cornerRadius = 8
        hideButton.layer.addSublayer(chevronLayer(pointingUp: false, in: CGSize(width: 44, height: 40)))
        hideButton.addTarget(self, action: #selector(hideTapped), for: .touchUpInside)
        addSubview(hideButton)
        for (button, name) in [(leftClick, "left"), (rightClick, "right")] {
            button.accessibilityIdentifier = name
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor(white: 1, alpha: 0.18).cgColor
            button.addTarget(self, action: #selector(clickDown(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(clickUp(_:)),
                             for: [.touchUpInside, .touchUpOutside, .touchCancel])
            addSubview(button)
        }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let clickWidth: CGFloat = 56
        leftClick.frame = CGRect(x: 0, y: 0, width: clickWidth, height: bounds.height)
        rightClick.frame = CGRect(x: clickWidth + 6, y: 0, width: clickWidth, height: bounds.height)
        let hideWidth: CGFloat = showsHide ? 44 : 0
        let settingsWidth = settingsButton.intrinsicContentSize.width
        hideButton.frame = CGRect(x: bounds.maxX - hideWidth, y: 0, width: hideWidth, height: bounds.height)
        settingsButton.frame = CGRect(x: bounds.maxX - hideWidth - (showsHide ? 6 : 0) - settingsWidth, y: 0,
                                      width: settingsWidth, height: bounds.height)
        let scrollX = rightClick.frame.maxX + 12
        scroll.frame = CGRect(x: scrollX, y: 0, width: settingsButton.frame.minX - 10 - scrollX,
                              height: bounds.height)
    }

    private func rebuild() {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, macro) in macros.enumerated() {
            let button = overlayButton(macro.title)
            button.tag = index
            button.addTarget(self, action: #selector(macroTapped(_:)), for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        restyle()
    }

    private func restyle() {
        let background = UIColor(white: 0.08, alpha: buttonOpacity)
        for case let button as UIButton in row.arrangedSubviews + [settingsButton, hideButton, leftClick, rightClick] {
            button.backgroundColor = background
        }
    }

    @objc private func macroTapped(_ button: UIButton) { onMacro?(macros[button.tag]) }

    @objc private func clickDown(_ button: UIButton) {
        let name = button.accessibilityIdentifier ?? "left"
        heldButtons.insert(name)
        onButton?(name, true)
    }

    @objc private func clickUp(_ button: UIButton) {
        let name = button.accessibilityIdentifier ?? "left"
        guard heldButtons.remove(name) != nil else { return }
        onButton?(name, false)
    }

    func releaseButtons() {
        heldButtons.forEach { onButton?($0, false) }
        heldButtons.removeAll()
    }
    @objc private func settingsTapped() { onSettings?() }
    @objc private func hideTapped() { onHide?() }
}

// MARK: - Keyboard

/// A Mac (US ANSI) keyboard drawn as see-through keys. Modifiers work two
/// ways: hold one while tapping a key, or tap it to latch it for the next key.
private final class MacKeyboardView: UIView {

    var onKey: ((Int, [String]) -> Void)?
    var keyOpacity: CGFloat = 0.4 { didSet { caps.indices.forEach(style) } }

    private struct Key {
        let label: String
        let shiftedLabel: String?
        let code: Int
        let width: CGFloat
        var modifier: String? = nil
        var repeats = false
        var half: Half? = nil   // the stacked ↑/↓ arrow keys

        enum Half { case top, bottom }

        static func char(_ label: String, _ shifted: String?, _ code: Int) -> Key {
            Key(label: label, shiftedLabel: shifted, code: code, width: 1)
        }
    }

    // Widths in key units; every row adds up to 14.5.
    private static let rows: [[Key]] = [
        [.char("`", "~", 50), .char("1", "!", 18), .char("2", "@", 19), .char("3", "#", 20),
         .char("4", "$", 21), .char("5", "%", 23), .char("6", "^", 22), .char("7", "&", 26),
         .char("8", "*", 28), .char("9", "(", 25), .char("0", ")", 29), .char("-", "_", 27),
         .char("=", "+", 24), Key(label: "⌫", shiftedLabel: nil, code: MacKeyCode.delete, width: 1.5, repeats: true)],
        [Key(label: "tab", shiftedLabel: nil, code: MacKeyCode.tab, width: 1.5),
         .char("q", "Q", 12), .char("w", "W", 13), .char("e", "E", 14), .char("r", "R", 15),
         .char("t", "T", 17), .char("y", "Y", 16), .char("u", "U", 32), .char("i", "I", 34),
         .char("o", "O", 31), .char("p", "P", 35), .char("[", "{", 33), .char("]", "}", 30),
         .char("\\", "|", 42)],
        [Key(label: "esc", shiftedLabel: nil, code: MacKeyCode.escape, width: 1.75),
         .char("a", "A", 0), .char("s", "S", 1), .char("d", "D", 2), .char("f", "F", 3),
         .char("g", "G", 5), .char("h", "H", 4), .char("j", "J", 38), .char("k", "K", 40),
         .char("l", "L", 37), .char(";", ":", 41), .char("'", "\"", 39),
         Key(label: "return", shiftedLabel: nil, code: MacKeyCode.returnKey, width: 1.75)],
        [Key(label: "⇧", shiftedLabel: nil, code: 56, width: 2.25, modifier: "shift"),
         .char("z", "Z", 6), .char("x", "X", 7), .char("c", "C", 8), .char("v", "V", 9),
         .char("b", "B", 11), .char("n", "N", 45), .char("m", "M", 46), .char(",", "<", 43),
         .char(".", ">", 47), .char("/", "?", 44),
         Key(label: "⇧", shiftedLabel: nil, code: 60, width: 2.25, modifier: "shift")],
        [Key(label: "⌃", shiftedLabel: nil, code: 59, width: 1.25, modifier: "ctrl"),
         Key(label: "⌥", shiftedLabel: nil, code: 58, width: 1.25, modifier: "opt"),
         Key(label: "⌘", shiftedLabel: nil, code: 55, width: 1.5, modifier: "cmd"),
         Key(label: "", shiftedLabel: nil, code: MacKeyCode.space, width: 4.75, repeats: true),
         Key(label: "⌘", shiftedLabel: nil, code: 54, width: 1.5, modifier: "cmd"),
         Key(label: "⌥", shiftedLabel: nil, code: 61, width: 1.25, modifier: "opt"),
         Key(label: "←", shiftedLabel: nil, code: MacKeyCode.left, width: 1, repeats: true),
         Key(label: "↑", shiftedLabel: nil, code: MacKeyCode.up, width: 1, repeats: true, half: .top),
         Key(label: "↓", shiftedLabel: nil, code: MacKeyCode.down, width: 1, repeats: true, half: .bottom),
         Key(label: "→", shiftedLabel: nil, code: MacKeyCode.right, width: 1, repeats: true)],
    ]
    private static let rowUnits: CGFloat = 14.5
    private static let modifierOrder = ["cmd", "opt", "ctrl", "shift"]

    private var keys: [Key] = []
    private var caps: [UIView] = []
    private var labels: [UILabel] = []
    private var frames: [CGRect] = []

    private var touchKeys: [ObjectIdentifier: Int] = [:]
    private var pressed = Set<Int>()
    private var held = Set<String>()        // modifiers whose key is down
    private var heldUnused = Set<String>()  // ...and not yet used by a key
    private var latched = Set<String>()     // tapped modifiers, for the next key
    private var repeatTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        keys = Self.rows.flatMap { $0 }
        for _ in keys {
            let cap = UIView()
            cap.isUserInteractionEnabled = false
            cap.layer.cornerRadius = 6
            cap.layer.borderWidth = 1
            let label = UILabel()
            label.textAlignment = .center
            label.textColor = .white
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.8
            label.layer.shadowRadius = 2
            label.layer.shadowOffset = .zero
            cap.addSubview(label)
            addSubview(cap)
            caps.append(cap)
            labels.append(label)
        }
        caps.indices.forEach(style)
        updateLabels()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap: CGFloat = 5
        let rowHeight = bounds.height / CGFloat(Self.rows.count)
        let unit = bounds.width / Self.rowUnits
        let fontSize = min(22, rowHeight * 0.36)
        frames = []
        for (rowIndex, row) in Self.rows.enumerated() {
            var x: CGFloat = 0
            let y = CGFloat(rowIndex) * rowHeight
            for key in row {
                var frame = CGRect(x: x, y: y, width: key.width * unit, height: rowHeight)
                switch key.half {
                case .top?: frame.size.height /= 2
                case .bottom?:
                    // Stacked under ↑, in the same column (↑ didn't advance x).
                    frame = CGRect(x: x, y: y + rowHeight / 2, width: unit, height: rowHeight / 2)
                case nil: break
                }
                frames.append(frame)
                if key.half != .top { x += key.width * unit }
            }
        }
        for (index, frame) in frames.enumerated() {
            caps[index].frame = frame.insetBy(dx: gap / 2, dy: gap / 2)
            labels[index].frame = caps[index].bounds.insetBy(dx: 3, dy: 0)
            labels[index].font = .systemFont(ofSize: keys[index].label.count > 1 ? fontSize * 0.7 : fontSize,
                                             weight: .medium)
        }
    }

    private func style(_ index: Int) {
        let key = keys[index]
        let lit = pressed.contains(index)
            || key.modifier.map { held.contains($0) || latched.contains($0) } == true
        caps[index].backgroundColor = lit
            ? UIColor(red: 0.04, green: 0.52, blue: 1, alpha: max(keyOpacity, 0.6))
            : UIColor(white: 0.08, alpha: keyOpacity)
        caps[index].layer.borderColor = UIColor(white: 1, alpha: 0.18).cgColor
    }

    private func updateLabels() {
        let shift = held.contains("shift") || latched.contains("shift")
        for (index, key) in keys.enumerated() {
            labels[index].text = shift ? (key.shiftedLabel ?? key.label) : key.label
        }
    }

    private func refresh() {
        caps.indices.forEach(style)
        updateLabels()
    }

    private func keyIndex(at point: CGPoint) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let index = keyIndex(at: touch.location(in: self)) else { continue }
            touchKeys[ObjectIdentifier(touch)] = index
            press(index)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let index = touchKeys.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            release(index)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    func releaseAll() {
        touchKeys.removeAll()
        pressed.removeAll()
        held.removeAll()
        heldUnused.removeAll()
        latched.removeAll()
        stopRepeat()
        refresh()
    }

    private func press(_ index: Int) {
        let key = keys[index]
        pressed.insert(index)
        if let modifier = key.modifier {
            held.insert(modifier)
            heldUnused.insert(modifier)
            refresh()
            return
        }
        let active = held.union(latched)
        let modifiers = Self.modifierOrder.filter { active.contains($0) }
        heldUnused.subtract(held)
        latched.removeAll()
        onKey?(key.code, modifiers)
        refresh()
        if key.repeats { startRepeat(code: key.code, modifiers: modifiers) }
    }

    private func release(_ index: Int) {
        let key = keys[index]
        pressed.remove(index)
        if let modifier = key.modifier {
            held.remove(modifier)
            // Tapped on its own (not used while held): latch or unlatch it.
            if heldUnused.remove(modifier) != nil {
                if latched.contains(modifier) { latched.remove(modifier) } else { latched.insert(modifier) }
            }
        } else if key.repeats {
            stopRepeat()
        }
        refresh()
    }

    private func startRepeat(code: Int, modifiers: [String]) {
        stopRepeat()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
                self?.onKey?(code, modifiers)
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

// MARK: - Trackpad

/// One finger moves the cursor, tap clicks, two-finger tap right-clicks,
/// two-finger drag scrolls. Hold L or R and move with another finger to drag.
private final class TrackpadView: UIView {

    /// dx/dy in Mac points.
    var onMove: ((Double, Double) -> Void)?
    var onClick: ((String) -> Void)?
    var onButton: ((String, Bool) -> Void)?
    var onScroll: ((Double, Double) -> Void)?
    var padOpacity: CGFloat = 0.4 { didSet { restyle() } }

    private let pad = UIView()
    private let left = overlayButton("L")
    private let right = overlayButton("R")
    private var heldButtons = Set<String>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        pad.layer.cornerRadius = 12
        pad.layer.borderWidth = 1
        pad.layer.borderColor = UIColor(white: 1, alpha: 0.18).cgColor
        addSubview(pad)
        for (button, name) in [(left, "left"), (right, "right")] {
            button.accessibilityIdentifier = name
            button.addTarget(self, action: #selector(buttonDown(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(buttonUp(_:)),
                             for: [.touchUpInside, .touchUpOutside, .touchCancel])
            addSubview(button)
        }

        let move = UIPanGestureRecognizer(target: self, action: #selector(moved(_:)))
        move.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped))
        twoFingerTap.numberOfTouchesRequired = 2
        for gesture in [move, scroll, tap, twoFingerTap] { pad.addGestureRecognizer(gesture) }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let buttonHeight = min(48, bounds.height * 0.2)
        pad.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - buttonHeight - 6)
        let half = (bounds.width - 6) / 2
        left.frame = CGRect(x: 0, y: pad.frame.maxY + 6, width: half, height: buttonHeight)
        right.frame = CGRect(x: half + 6, y: pad.frame.maxY + 6, width: half, height: buttonHeight)
    }

    private func restyle() {
        pad.backgroundColor = UIColor(white: 0.08, alpha: padOpacity * 0.8)
        for button in [left, right] {
            button.backgroundColor = UIColor(white: 0.08, alpha: padOpacity)
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor(white: 1, alpha: 0.18).cgColor
        }
    }

    func releaseButtons() {
        heldButtons.forEach { onButton?($0, false) }
        heldButtons.removeAll()
    }

    @objc private func moved(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let t = gesture.translation(in: pad)
        gesture.setTranslation(.zero, in: pad)
        // Pointer acceleration: slow moves stay precise, fast flicks cross
        // the whole Mac screen from a narrow pad.
        let gain = (1.5 + min(Double(hypot(t.x, t.y)) / 6, 3)) * AppSettings.shared.trackpadSpeed
        onMove?(Double(t.x) * gain, Double(t.y) * gain)
    }

    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let t = gesture.translation(in: pad)
        gesture.setTranslation(.zero, in: pad)
        let sign: Double = AppSettings.shared.naturalScrolling ? 1 : -1
        onScroll?(Double(t.x) * 2 * sign, Double(t.y) * 2 * sign)
    }

    @objc private func tapped() { onClick?("left") }
    @objc private func twoFingerTapped() { onClick?("right") }

    @objc private func buttonDown(_ button: UIButton) {
        let name = button.accessibilityIdentifier ?? "left"
        heldButtons.insert(name)
        onButton?(name, true)
    }

    @objc private func buttonUp(_ button: UIButton) {
        let name = button.accessibilityIdentifier ?? "left"
        guard heldButtons.remove(name) != nil else { return }
        onButton?(name, false)
    }
}
