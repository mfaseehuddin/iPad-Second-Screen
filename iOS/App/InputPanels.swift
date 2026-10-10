// InputPanels.swift
//
// On-screen keyboard and trackpad for driving the Mac while streaming, and
// the floating toolbar that opens them. Sent as "key" / "text" / "mouse"
// control messages, which the patched OpenDisplay Mac app injects
// (patches/02-keyboard-trackpad.patch). Plain UIKit for iOS 12.

import UIKit

/// macOS virtual key codes (US ANSI positions) for characters typed while a
/// modifier is held, so shortcuts like Cmd+C go out as real key presses.
enum MacKeyCode {
    static let returnKey = 36, tab = 48, space = 49, delete = 51, escape = 53
    static let left = 123, right = 124, down = 125, up = 126

    private static let unshifted: [Character: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50, " ": 49,
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
        "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// Key code and whether Shift is implied (uppercase letter or shifted symbol).
    static func lookup(_ character: Character) -> (code: Int, shift: Bool)? {
        let lower = Character(String(character).lowercased())
        if let code = unshifted[lower] { return (code, lower != character) }
        if let base = shifted[character], let code = unshifted[base] { return (code, true) }
        return nil
    }
}

/// A view that swallows stray touches, so taps on a panel's background never
/// reach the view controller as clicks on the Mac.
class PanelView: UIView {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

    /// Drag the panel around by `handle`, kept inside the superview.
    func makeDraggable(by handle: UIView) {
        handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let container = superview else { return }
        let translation = gesture.translation(in: container)
        gesture.setTranslation(.zero, in: container)
        let half = CGSize(width: bounds.width / 2, height: bounds.height / 2)
        let area = container.bounds
        center = CGPoint(x: min(max(center.x + translation.x, half.width), area.width - half.width),
                         y: min(max(center.y + translation.y, half.height), area.height - half.height))
    }
}

private func panelButton(_ title: String, size: CGFloat = 16) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.tintColor = .white
    button.titleLabel?.font = .systemFont(ofSize: size, weight: .semibold)
    button.backgroundColor = UIColor(white: 1, alpha: 0.12)
    button.layer.cornerRadius = 8
    return button
}

// MARK: - Keyboard

/// Invisible first responder that brings up the iPad keyboard (or takes a
/// hardware keyboard's typing) and forwards it to the Mac.
final class KeyboardInputView: UIView, UIKeyInput {

    var onText: ((String) -> Void)?
    var onKey: ((Int, [String]) -> Void)?

    private let bar = KeyboardAccessoryBar()

    // Send exactly what was typed: no autocorrect, capitals or smart punctuation.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    override init(frame: CGRect) {
        super.init(frame: frame)
        bar.onKey = { [weak self] code in self?.sendKey(code) }
        bar.onHide = { [weak self] in _ = self?.resignFirstResponder() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { bar }

    // Always true, so Delete reaches deleteBackward() even with nothing typed.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        let modifiers = bar.consumeModifiers()
        var plain = ""
        func flush() {
            if !plain.isEmpty { onText?(plain); plain = "" }
        }
        for character in text {
            if character == "\n" {
                flush(); onKey?(MacKeyCode.returnKey, modifiers)
            } else if character == "\t" {
                flush(); onKey?(MacKeyCode.tab, modifiers)
            } else if !modifiers.isEmpty, let key = MacKeyCode.lookup(character) {
                flush()
                onKey?(key.code, key.shift && !modifiers.contains("shift") ? modifiers + ["shift"] : modifiers)
            } else {
                plain.append(character)
            }
        }
        flush()
    }

    func deleteBackward() {
        sendKey(MacKeyCode.delete)
    }

    private func sendKey(_ code: Int) {
        onKey?(code, bar.consumeModifiers())
    }

    // Hardware keyboard keys that never reach insertText.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand.inputEscape, UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
         UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow].map {
            UIKeyCommand(input: $0, modifierFlags: [], action: #selector(hardwareKey(_:)))
        }
    }

    @objc private func hardwareKey(_ command: UIKeyCommand) {
        let codes: [String: Int] = [
            UIKeyCommand.inputEscape: MacKeyCode.escape, UIKeyCommand.inputUpArrow: MacKeyCode.up,
            UIKeyCommand.inputDownArrow: MacKeyCode.down, UIKeyCommand.inputLeftArrow: MacKeyCode.left,
            UIKeyCommand.inputRightArrow: MacKeyCode.right,
        ]
        if let input = command.input, let code = codes[input] { sendKey(code) }
    }
}

/// Strip above the keyboard: one-shot modifiers (held for the next key) and
/// keys the iPad keyboard lacks.
final class KeyboardAccessoryBar: UIView {

    var onKey: ((Int) -> Void)?
    var onHide: (() -> Void)?

    private let modifierNames = ["cmd", "opt", "ctrl", "shift"]
    private var modifierButtons: [UIButton] = []
    private var active = Set<String>()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 52))
        autoresizingMask = .flexibleWidth
        backgroundColor = UIColor(white: 0.12, alpha: 1)

        modifierButtons = zip(["⌘", "⌥", "⌃", "⇧"], modifierNames.indices).map { title, index in
            let button = panelButton(title, size: 20)
            button.tag = index
            button.addTarget(self, action: #selector(toggleModifier(_:)), for: .touchUpInside)
            return button
        }
        let keys: [(String, Int)] = [
            ("esc", MacKeyCode.escape), ("tab", MacKeyCode.tab), ("←", MacKeyCode.left),
            ("↓", MacKeyCode.down), ("↑", MacKeyCode.up), ("→", MacKeyCode.right),
        ]
        let keyButtons = keys.map { title, code -> UIButton in
            let button = panelButton(title)
            button.tag = code
            button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
            return button
        }
        let hide = panelButton("Hide")
        hide.addTarget(self, action: #selector(hideTapped), for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: modifierButtons + keyButtons + [hide])
        row.spacing = 6
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Modifiers for the key being sent; they release after one use.
    func consumeModifiers() -> [String] {
        let modifiers = modifierNames.filter { active.contains($0) }
        active.removeAll()
        updateModifierButtons()
        return modifiers
    }

    @objc private func toggleModifier(_ button: UIButton) {
        let name = modifierNames[button.tag]
        if active.contains(name) { active.remove(name) } else { active.insert(name) }
        updateModifierButtons()
    }

    @objc private func keyTapped(_ button: UIButton) {
        onKey?(button.tag)
    }

    @objc private func hideTapped() {
        onHide?()
    }

    private func updateModifierButtons() {
        for button in modifierButtons {
            let on = active.contains(modifierNames[button.tag])
            button.backgroundColor = on ? UIColor(red: 0.04, green: 0.52, blue: 1, alpha: 1)
                                        : UIColor(white: 1, alpha: 0.12)
        }
    }
}

// MARK: - Trackpad

/// Floating trackpad: one finger moves the cursor, tap clicks, two-finger
/// tap right-clicks, two-finger drag scrolls. Hold L or R and move with
/// another finger to drag.
final class TrackpadPanel: PanelView {

    /// dx/dy in Mac points.
    var onMove: ((Double, Double) -> Void)?
    var onClick: ((String) -> Void)?
    var onButton: ((String, Bool) -> Void)?
    /// dx/dy with the stream's scroll sign (content follows the fingers).
    var onScroll: ((Double, Double) -> Void)?
    var onClose: (() -> Void)?

    private let pad = UIView()

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 340, height: 270))
        backgroundColor = UIColor(white: 0.1, alpha: 0.92)
        layer.cornerRadius = 18
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor

        let header = UIView()
        let grip = UIView()
        grip.backgroundColor = UIColor(white: 1, alpha: 0.35)
        grip.layer.cornerRadius = 2.5
        let close = UIButton(type: .system)
        close.setTitle("✕", for: .normal)
        close.tintColor = .white
        close.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        pad.backgroundColor = UIColor(white: 1, alpha: 0.07)
        pad.layer.cornerRadius = 12

        let left = panelButton("L")
        let right = panelButton("R")
        for (button, name) in [(left, "left"), (right, "right")] {
            button.accessibilityIdentifier = name
            button.addTarget(self, action: #selector(buttonDown(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(buttonUp(_:)),
                             for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        let buttons = UIStackView(arrangedSubviews: [left, right])
        buttons.spacing = 8
        buttons.distribution = .fillEqually

        for view in [header, grip, close, pad, buttons] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(header)
        header.addSubview(grip)
        header.addSubview(close)
        addSubview(pad)
        addSubview(buttons)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            grip.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            grip.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: 44),
            grip.heightAnchor.constraint(equalToConstant: 5),
            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pad.topAnchor.constraint(equalTo: header.bottomAnchor),
            pad.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            pad.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: pad.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: pad.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: pad.trailingAnchor),
            buttons.heightAnchor.constraint(equalToConstant: 44),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        makeDraggable(by: header)

        let move = UIPanGestureRecognizer(target: self, action: #selector(moved(_:)))
        move.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped))
        twoFingerTap.numberOfTouchesRequired = 2
        for gesture in [move, scroll, tap, twoFingerTap] { pad.addGestureRecognizer(gesture) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func moved(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let t = gesture.translation(in: pad)
        gesture.setTranslation(.zero, in: pad)
        // Pointer acceleration: slow moves stay precise, fast flicks cross
        // the whole Mac screen from a small pad.
        let gain = 1.5 + min(Double(hypot(t.x, t.y)) / 6, 3)
        onMove?(Double(t.x) * gain, Double(t.y) * gain)
    }

    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let t = gesture.translation(in: pad)
        gesture.setTranslation(.zero, in: pad)
        onScroll?(Double(t.x) * 2, Double(t.y) * 2)
    }

    @objc private func tapped() { onClick?("left") }
    @objc private func twoFingerTapped() { onClick?("right") }
    @objc private func closeTapped() { onClose?() }

    @objc private func buttonDown(_ button: UIButton) {
        onButton?(button.accessibilityIdentifier ?? "left", true)
    }

    @objc private func buttonUp(_ button: UIButton) {
        onButton?(button.accessibilityIdentifier ?? "left", false)
    }
}

// MARK: - Toolbar

/// Small draggable pill shown while streaming: opens the keyboard or trackpad.
final class InputToolbar: PanelView {

    var onKeyboard: (() -> Void)?
    var onTrackpad: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 224, height: 52))
        backgroundColor = UIColor(white: 0.1, alpha: 0.85)
        layer.cornerRadius = 26
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor

        let grip = UIView()
        grip.backgroundColor = UIColor(white: 1, alpha: 0.35)
        grip.layer.cornerRadius = 2
        let keyboard = panelButton("Keyboard", size: 14)
        keyboard.addTarget(self, action: #selector(keyboardTapped), for: .touchUpInside)
        let trackpad = panelButton("Trackpad", size: 14)
        trackpad.addTarget(self, action: #selector(trackpadTapped), for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [keyboard, trackpad])
        row.spacing = 6
        row.distribution = .fillEqually
        for view in [grip, row] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            grip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            grip.centerYAnchor.constraint(equalTo: centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: 4),
            grip.heightAnchor.constraint(equalToConstant: 22),
            row.leadingAnchor.constraint(equalTo: grip.trailingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        // The pill's own background (around the buttons) is the drag handle.
        makeDraggable(by: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func keyboardTapped() { onKeyboard?() }
    @objc private func trackpadTapped() { onTrackpad?() }
}
