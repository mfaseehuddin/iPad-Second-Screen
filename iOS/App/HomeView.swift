// HomeView.swift
//
// What the device shows while nothing is streaming (connection status and
// the Extend / Mirror choice), plus the overlay summoned mid-stream. Plain
// UIKit for iOS 12: no SF Symbols or system materials, so the mode glyphs
// are drawn with CAShapeLayer.

import UIKit

private enum Palette {
    static let background = UIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
    static let tile = UIColor(white: 1, alpha: 0.06)
    static let tileBorder = UIColor(white: 1, alpha: 0.12)
    static let accent = UIColor(red: 0.04, green: 0.52, blue: 1, alpha: 1)
    static let secondaryText = UIColor(white: 1, alpha: 0.55)
    static let connected = UIColor(red: 0.2, green: 0.82, blue: 0.4, alpha: 1)
    static let waiting = UIColor(white: 1, alpha: 0.35)
}

// MARK: - Home screen

final class HomeView: UIView {

    var onChoose: ((DisplayMode) -> Void)?
    var onSettings: (() -> Void)?

    /// nil = no Mac connected yet.
    var link: ReceiverLink? { didSet { updateStatus() } }
    /// Mode tapped but not streaming yet (Mac not connected, or starting up).
    var pendingMode: DisplayMode? { didSet { updateStatus() } }
    /// Listener diagnostics ("Listening on :9000", errors).
    var detail: String? { didSet { detailLabel.text = detail } }

    private let titleLabel = UILabel()
    private let deviceLabel = UILabel()
    private let statusDot = UIView()
    private let statusLabel = UILabel()
    private let extendTile = ModeTile(mode: .extend)
    private let mirrorTile = ModeTile(mode: .mirror)
    private let hintLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.background

        titleLabel.text = "Second Screen"
        titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
        titleLabel.textColor = .white

        deviceLabel.text = UIDevice.current.name
        deviceLabel.font = .systemFont(ofSize: 17)
        deviceLabel.textColor = Palette.secondaryText

        statusDot.layer.cornerRadius = 5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textColor = .white
        let statusRow = UIStackView(arrangedSubviews: [statusDot, statusLabel])
        statusRow.spacing = 8
        statusRow.alignment = .center
        let pill = UIView()
        pill.backgroundColor = Palette.tile
        pill.layer.cornerRadius = 18
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(statusRow)
        NSLayoutConstraint.activate([
            statusRow.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            statusRow.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            statusRow.topAnchor.constraint(equalTo: pill.topAnchor, constant: 9),
            statusRow.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -9),
        ])

        extendTile.addTarget(self, action: #selector(tileTapped(_:)), for: .touchUpInside)
        mirrorTile.addTarget(self, action: #selector(tileTapped(_:)), for: .touchUpInside)
        let tiles = UIStackView(arrangedSubviews: [extendTile, mirrorTile])
        tiles.spacing = 20
        tiles.distribution = .fillEqually

        hintLabel.font = .systemFont(ofSize: 15)
        hintLabel.textColor = Palette.secondaryText
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, deviceLabel, pill, tiles, hintLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(24, after: deviceLabel)
        stack.setCustomSpacing(36, after: pill)
        stack.setCustomSpacing(28, after: tiles)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let settings = UIButton(type: .system)
        settings.setTitle("Settings", for: .normal)
        settings.tintColor = Palette.secondaryText
        settings.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        settings.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
        settings.translatesAutoresizingMaskIntoConstraints = false
        addSubview(settings)
        NSLayoutConstraint.activate([
            settings.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            settings.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
        ])

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = Palette.waiting
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        let tileWidth = extendTile.widthAnchor.constraint(equalToConstant: 260)
        tileWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: layoutMarginsGuide.leadingAnchor),
            tileWidth,
            extendTile.heightAnchor.constraint(equalTo: extendTile.widthAnchor, multiplier: 0.8),
            hintLabel.widthAnchor.constraint(lessThanOrEqualTo: tiles.widthAnchor),
            detailLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func tileTapped(_ tile: ModeTile) {
        onChoose?(tile.mode)
    }

    @objc private func settingsTapped() {
        onSettings?()
    }

    private func updateStatus() {
        statusDot.layer.removeAllAnimations()
        switch link {
        case .cable?:
            statusDot.backgroundColor = Palette.connected
            statusLabel.text = "Mac connected · Cable"
        case .wifi?:
            statusDot.backgroundColor = Palette.connected
            statusLabel.text = "Mac connected · Wi-Fi"
        case nil:
            statusDot.backgroundColor = Palette.waiting
            statusLabel.text = "Waiting for your Mac"
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            statusDot.layer.add(pulse, forKey: "pulse")
        }

        extendTile.isPending = pendingMode == .extend
        mirrorTile.isPending = pendingMode == .mirror

        if let pending = pendingMode {
            let name = pending == .extend ? "Extend" : "Mirror"
            hintLabel.text = link == nil
                ? "\(name) starts as soon as your Mac connects. Tap it again to cancel."
                : "Starting \(name)…"
        } else if link == nil {
            hintLabel.text = "Plug in the cable, or keep OpenDisplay open on a Mac on the same Wi-Fi."
        } else {
            hintLabel.text = "While streaming, the arrow at the bottom right opens the keyboard and trackpad. Tap with three fingers for controls."
        }
    }
}

// MARK: - Mode tile

final class ModeTile: UIControl {

    let mode: DisplayMode
    var isPending = false { didSet { updateAppearance() } }

    private let glyph = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .white)

    init(mode: DisplayMode) {
        self.mode = mode
        super.init(frame: .zero)
        backgroundColor = Palette.tile
        layer.cornerRadius = 22
        layer.borderWidth = 1.5
        layer.borderColor = Palette.tileBorder.cgColor

        titleLabel.text = mode == .extend ? "Extend" : "Mirror"
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .white
        subtitleLabel.text = mode == .extend ? "Use as a second display" : "Show your Mac's screen"
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = Palette.secondaryText
        subtitleLabel.adjustsFontSizeToFitWidth = true

        let stack = UIStackView(arrangedSubviews: [glyph, titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.setCustomSpacing(18, after: glyph)
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            glyph.widthAnchor.constraint(equalToConstant: 120),
            glyph.heightAnchor.constraint(equalToConstant: 56),
            spinner.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        drawGlyph()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
                self.alpha = self.isHighlighted ? 0.85 : 1
            }
        }
    }

    private func updateAppearance() {
        layer.borderColor = (isPending ? Palette.accent : Palette.tileBorder).cgColor
        if isPending { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    /// Two screens, Mac on the left and this device on the right. Extend: one
    /// window straddling both. Mirror: the same window on each.
    private func drawGlyph() {
        let screens = [CGRect(x: 0, y: 4, width: 62, height: 44), CGRect(x: 72, y: 8, width: 48, height: 36)]
        for frame in screens {
            let screen = CAShapeLayer()
            screen.path = UIBezierPath(roundedRect: frame, cornerRadius: 5).cgPath
            screen.fillColor = UIColor.clear.cgColor
            screen.strokeColor = UIColor(white: 1, alpha: 0.8).cgColor
            screen.lineWidth = 2
            glyph.layer.addSublayer(screen)
        }
        let windows: [CGRect] = mode == .extend
            ? [CGRect(x: 40, y: 16, width: 52, height: 20)]
            : [CGRect(x: 14, y: 14, width: 34, height: 24), CGRect(x: 82, y: 16, width: 28, height: 20)]
        for frame in windows {
            let window = CAShapeLayer()
            window.path = UIBezierPath(roundedRect: frame, cornerRadius: 3).cgPath
            window.fillColor = Palette.accent.cgColor
            glyph.layer.addSublayer(window)
        }
    }
}

// MARK: - In-stream controls

/// Summoned with a three-finger tap while streaming: switch mode, stop, or
/// dismiss. Tapping outside the bar dismisses it too.
final class ControlsOverlay: UIView, UIGestureRecognizerDelegate {

    var onChoose: ((DisplayMode) -> Void)?
    var onStop: (() -> Void)?
    var onSettings: (() -> Void)?

    var mode: DisplayMode = .extend {
        didSet { modePicker.selectedSegmentIndex = mode == .extend ? 0 : 1 }
    }

    private let modePicker = UISegmentedControl(items: ["Extend", "Mirror"])

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0, alpha: 0.35)

        let bar = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        bar.layer.cornerRadius = 18
        bar.clipsToBounds = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        modePicker.tintColor = .white
        modePicker.selectedSegmentIndex = 0
        modePicker.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        let stop = UIButton(type: .system)
        stop.setTitle("Stop", for: .normal)
        stop.setTitleColor(UIColor(red: 1, green: 0.35, blue: 0.33, alpha: 1), for: .normal)
        stop.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        stop.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)

        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.tintColor = .white
        done.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        done.addTarget(self, action: #selector(dismiss), for: .touchUpInside)

        let settings = UIButton(type: .system)
        settings.setTitle("Settings", for: .normal)
        settings.tintColor = .white
        settings.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        settings.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [modePicker, settings, stop, done])
        row.spacing = 24
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 20),
            row.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: bar.contentView.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor, constant: -14),
            modePicker.widthAnchor.constraint(equalToConstant: 220),
        ])

        let outsideTap = UITapGestureRecognizer(target: self, action: #selector(dismiss))
        outsideTap.delegate = self
        addGestureRecognizer(outsideTap)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        isHidden = false
        alpha = 0
        UIView.animate(withDuration: 0.2) { self.alpha = 1 }
    }

    @objc func dismiss() {
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }) { _ in self.isHidden = true }
    }

    @objc private func modeChanged() {
        let chosen: DisplayMode = modePicker.selectedSegmentIndex == 0 ? .extend : .mirror
        guard chosen != mode else { return }
        mode = chosen
        onChoose?(chosen)
        dismiss()
    }

    @objc private func settingsTapped() {
        dismiss()
        onSettings?()
    }

    @objc private func stopTapped() {
        onStop?()
        dismiss()
    }
}
