// ReceiverViewController.swift
//
// Home screen (pick Extend / Mirror) over a fullscreen video surface with
// touch/scroll input forwarding. Deliberately plain UIKit (no SwiftUI) so it
// compiles for iOS 12.

import UIKit
import AVFoundation

final class VideoContainerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

final class ReceiverViewController: UIViewController, VideoReceiverDelegate, UIGestureRecognizerDelegate {

    // The video sits in a clipping container so pinch-zoom can scale it
    // without spilling over the docked overlay.
    private let videoClip = UIView()
    private let videoView = VideoContainerView()
    private let statusLabel = UILabel()
    private let statusBar = UILabel()
    private let homeView = HomeView()
    private let controls = ControlsOverlay()
    private let inputOverlay = InputOverlay()
    private let overlayToggle = OverlayToggleButton()
    private var overlayShown = false
    private var receiver: VideoReceiver!
    private var lastVideoSize: CGSize = .zero

    // nil = home screen. Set when the user picks a mode; the home screen
    // stays up until the first frame of that mode arrives.
    private var activeMode: DisplayMode?
    private var receivingVideo = false

    // Local zoom (iPad only): scale, and the point of the picture kept at
    // the center of the screen, normalized to videoView's bounds.
    private var zoomScale: CGFloat = 1
    private var zoomFocus = CGPoint(x: 0.5, y: 0.5)
    private var pinchStartScale: CGFloat = 1

    // Clipboard sync: the iPad side polls its pasteboard while streaming.
    private var clipboardTimer: Timer?
    private var lastPasteboardCount = UIPasteboard.general.changeCount
    private var lastClipboardFromMac: String?

    // Status bar contents.
    private var macBattery: Int?
    private var macCharging = false
    private var macOnAC = true
    private var statsText = ""

    // Picture-as-trackpad gestures, active only in that touch mode.
    private var pictureTrackpadGestures: [UIGestureRecognizer] = []
    private var lastPictureTapAt = Date.distantPast
    private var pictureTapDragging = false
    private let pictureMomentum = MomentumScroller()

    // Edge swipes, and a touch that started on an edge (never a click).
    private let leftEdgeSwipe = UIScreenEdgePanGestureRecognizer()
    private let topEdgeSwipe = UIScreenEdgePanGestureRecognizer()
    private var edgeTouch = false

    // Lock screen.
    private let lockPanel = LockPanel()
    private var macLocked = false

    // Settings that need more than a relayout when they change.
    private var appliedQuality = AppSettings.shared.quality
    private var appliedDisplaySize = AppSettings.shared.displaySize
    private var link: ReceiverLink?

    // Cursor sprite: positioned/sized in normalized [0,1] Mac-display space,
    // updated at control-message rate (fast) independent of the ~30ms video path.
    private let cursorLayer: CALayer = {
        let layer = CALayer()
        layer.isHidden = true
        layer.zPosition = 10
        layer.actions = ["position": NSNull(), "contents": NSNull(),
                         "bounds": NSNull(), "hidden": NSNull()]
        return layer
    }()
    private var cursorNormSize: CGSize = .zero
    private var cursorNorm = CGPoint(x: 0.5, y: 0.5)
    private var cursorVisible = false

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        AppSettings.shared.portraitLayout == .landscape ? .landscape : .all
    }

    private var isPortrait: Bool { view.bounds.height > view.bounds.width }

    /// Game Boy layout: upright iPad, picture at the top, overlay docked below.
    private var docked: Bool {
        isPortrait && AppSettings.shared.portraitLayout == .gameBoy && activeMode != nil && receivingVideo
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoClip.clipsToBounds = true
        videoClip.frame = view.bounds
        view.addSubview(videoClip)
        videoView.frame = videoClip.bounds
        videoClip.addSubview(videoView)
        videoView.layer.addSublayer(cursorLayer)

        statusBar.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusBar.textColor = UIColor(white: 1, alpha: 0.85)
        statusBar.backgroundColor = UIColor(white: 0, alpha: 0.45)
        statusBar.textAlignment = .center
        statusBar.layer.cornerRadius = 8
        statusBar.clipsToBounds = true
        statusBar.isHidden = true
        view.addSubview(statusBar)

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        setUpInputPanels()

        homeView.frame = view.bounds
        homeView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        homeView.onChoose = { [weak self] mode in self?.choose(mode) }
        homeView.onSettings = { [weak self] in self?.showSettings() }
        view.addSubview(homeView)

        controls.frame = view.bounds
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controls.isHidden = true
        controls.onChoose = { [weak self] mode in self?.choose(mode) }
        controls.onStop = { [weak self] in self?.stopStreaming() }
        controls.onSettings = { [weak self] in self?.showSettings() }
        view.addSubview(controls)

        receiver = VideoReceiver(displayLayer: videoView.displayLayer)
        receiver.delegate = self
        let settings = AppSettings.shared
        receiver.setQuality(settings.quality.rawValue)
        receiver.subscribe(clipboard: settings.syncClipboard, status: true)
        if settings.autoStart, let mode = settings.lastMode { choose(mode) }

        // Pinch the picture to zoom (iPad only); two-finger double-tap resets.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
        let resetZoom = UITapGestureRecognizer(target: self, action: #selector(resetZoomTapped))
        resetZoom.numberOfTouchesRequired = 2
        resetZoom.numberOfTapsRequired = 2
        resetZoom.delegate = self
        view.addGestureRecognizer(resetZoom)

        // Picture as a trackpad (Settings → Touch → Picture).
        let pictureMove = UIPanGestureRecognizer(target: self, action: #selector(pictureMoved(_:)))
        pictureMove.maximumNumberOfTouches = 1
        let pictureTap = UITapGestureRecognizer(target: self, action: #selector(pictureTapped))
        let pictureRightTap = UITapGestureRecognizer(target: self, action: #selector(pictureRightTapped(_:)))
        pictureRightTap.numberOfTouchesRequired = 2
        pictureRightTap.require(toFail: resetZoom)
        let pictureSwipe = UIPanGestureRecognizer(target: self, action: #selector(pictureSwiped(_:)))
        pictureSwipe.minimumNumberOfTouches = 3
        pictureTrackpadGestures = [pictureMove, pictureTap, pictureRightTap, pictureSwipe]
        for gesture in pictureTrackpadGestures {
            gesture.delegate = self
            view.addGestureRecognizer(gesture)
        }

        pictureMomentum.onScroll = { [weak self] dx, dy in self?.receiver.sendScroll(dx: dx, dy: dy) }

        leftEdgeSwipe.edges = .left
        leftEdgeSwipe.addTarget(self, action: #selector(leftEdgeSwiped(_:)))
        topEdgeSwipe.edges = .top
        topEdgeSwipe.addTarget(self, action: #selector(topEdgeSwiped(_:)))
        for gesture in [leftEdgeSwipe, topEdgeSwipe] {
            gesture.delegate = self
            view.addGestureRecognizer(gesture)
        }

        lockPanel.frame = view.bounds
        lockPanel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        lockPanel.isHidden = true
        lockPanel.onUnlock = { [weak self] password in self?.typePassword(password) }
        lockPanel.onWake = { [weak self] in self?.wakeMac() }
        view.insertSubview(lockPanel, belowSubview: controls)

        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(batteryChanged), name: name, object: nil)
        }

        UIApplication.shared.isIdleTimerDisabled = true

        // Two-finger pan = scroll (like a trackpad).
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        scrollPan.delegate = self
        view.addGestureRecognizer(scrollPan)

        // Three-finger tap while streaming = controls (switch mode / stop).
        let controlsTap = UITapGestureRecognizer(target: self, action: #selector(showControls))
        controlsTap.numberOfTouchesRequired = 3
        controlsTap.delegate = self
        view.addGestureRecognizer(controlsTap)

        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
                                                name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // MARK: - Keyboard / trackpad

    private func setUpInputPanels() {
        inputOverlay.isHidden = true
        inputOverlay.onKey = { [weak self] code, modifiers in self?.receiver.sendKey(code: code, modifiers: modifiers) }
        inputOverlay.onMove = { [weak self] dx, dy in self?.receiver.sendMouse(action: "move", dx: dx, dy: dy) }
        inputOverlay.onClick = { [weak self] button in self?.receiver.sendMouse(action: "click", button: button) }
        inputOverlay.onButton = { [weak self] button, down in
            self?.receiver.sendMouse(action: down ? "down" : "up", button: button)
        }
        inputOverlay.onScroll = { [weak self] dx, dy in self?.receiver.sendScroll(dx: dx, dy: dy) }
        inputOverlay.onSettings = { [weak self] in self?.showSettings() }
        inputOverlay.onHide = { [weak self] in self?.setOverlay(shown: false) }
        inputOverlay.onLayoutChange = { [weak self] in
            self?.view.setNeedsLayout()
            self?.updateScreen()
        }
        view.addSubview(inputOverlay)

        overlayToggle.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)
        view.addSubview(overlayToggle)

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: AppSettings.didChange, object: nil)
    }

    @objc private func toggleTapped() {
        setOverlay(shown: true)
    }

    @objc private func settingsChanged() {
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        let settings = AppSettings.shared
        if settings.quality != appliedQuality {
            appliedQuality = settings.quality
            receiver.setQuality(settings.quality.rawValue)
            receiver.restartStream()
        }
        if settings.displaySize != appliedDisplaySize {
            appliedDisplaySize = settings.displaySize
            announcePanel()
        }
        receiver.subscribe(clipboard: settings.syncClipboard, status: true)
        if !settings.pinchToZoom { setZoom(1, animated: false) }
        inputOverlay.applySettings()
        UIViewController.attemptRotationToDeviceOrientation()
        announcePanel()
        updateScreen()
        view.setNeedsLayout()
    }

    private func setOverlay(shown: Bool) {
        overlayShown = shown
        if !shown { inputOverlay.releaseAll() }
        layoutInputOverlay()
        let offscreen = inputOverlay.frame.offsetBy(dx: 0, dy: inputOverlay.frame.height)
        let onscreen = inputOverlay.frame
        if shown {
            inputOverlay.isHidden = false
            inputOverlay.frame = offscreen
        }
        overlayToggle.isHidden = true
        UIView.animate(withDuration: 0.22, animations: {
            self.inputOverlay.frame = shown ? onscreen : offscreen
        }, completion: { _ in
            self.inputOverlay.frame = onscreen
            self.updateScreen()
        })
    }

    /// Video: full screen, or a landscape band at the top when docked.
    /// Overlay: bottom band (settings-sized), or everything under the video
    /// when docked. Toggle arrow: bottom-right corner.
    private func layoutInputOverlay() {
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        if docked {
            let aspect = lastVideoSize.width > 0 ? lastVideoSize.height / lastVideoSize.width
                                                 : safe.width / safe.height
            setVideoFrame(CGRect(x: 0, y: safe.minY, width: view.bounds.width,
                                 height: (view.bounds.width * aspect).rounded()))
            let top = videoClip.frame.maxY + 6
            let height = inputOverlay.preferredHeight(full: safe.maxY - top)
            inputOverlay.frame = CGRect(x: safe.minX, y: top, width: safe.width, height: height)
        } else {
            setVideoFrame(view.bounds)
            let full = (view.bounds.height * CGFloat(AppSettings.shared.overlayHeight)).rounded()
            let height = inputOverlay.preferredHeight(full: full)
            inputOverlay.frame = CGRect(x: safe.minX, y: safe.maxY - height, width: safe.width, height: height)
        }
        overlayToggle.center = CGPoint(x: safe.maxX - overlayToggle.bounds.width / 2 - 10,
                                       y: safe.maxY - overlayToggle.bounds.height / 2 - 10)
    }

    private func showSettings() {
        let settings = UINavigationController(rootViewController: SettingsViewController())
        settings.modalPresentationStyle = .formSheet
        present(settings, animated: true)
    }

    // Stream-wide gestures (scroll, three-finger tap) only for touches on
    // the video itself, not on the panels floating over it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === view || touch.view === videoView || touch.view === videoClip
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        // Our top-edge swipe first; a second swipe still opens iOS's own.
        AppSettings.shared.edgeSwipes ? .top : []
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let edges = AppSettings.shared.edgeSwipes && pictureInputAllowed && lockPanel.isHidden
        if gestureRecognizer === leftEdgeSwipe { return edges && !docked && !overlayShown }
        if gestureRecognizer === topEdgeSwipe { return edges }
        if pictureTrackpadGestures.contains(gestureRecognizer) {
            return pictureInputAllowed && pictureMode == .trackpad
        }
        if gestureRecognizer is UIPinchGestureRecognizer {
            return AppSettings.shared.pinchToZoom && activeMode != nil && receivingVideo
        }
        return true
    }

    // MARK: - Picture touch modes

    /// Streaming, with no controls sheet in the way.
    private var pictureInputAllowed: Bool {
        activeMode != nil && receivingVideo && controls.isHidden
    }

    /// What a touch on the picture does right now.
    private var pictureMode: PictureTouch {
        let setting = AppSettings.shared.pictureTouch
        guard setting == .automatic else { return setting }
        let overlayOpen = !inputOverlay.isHidden
        return overlayOpen && !inputOverlay.showsTrackpad ? .trackpad : .direct
    }

    @objc private func pictureMoved(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            pictureMomentum.stop()
            // Tap, then touch again and move: drag.
            if AppSettings.shared.tapToDrag, Date().timeIntervalSince(lastPictureTapAt) < 0.5 {
                pictureTapDragging = true
                receiver.sendMouse(action: "down", button: "left")
            }
        case .changed:
            let t = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            let (dx, dy) = pointerDelta(t)
            receiver.sendMouse(action: "move", dx: dx, dy: dy)
        default:
            if pictureTapDragging {
                pictureTapDragging = false
                receiver.sendMouse(action: "up", button: "left")
            }
        }
    }

    @objc private func pictureTapped() {
        pictureMomentum.stop()
        lastPictureTapAt = Date()
        receiver.sendMouse(action: "click", button: "left")
    }

    // MARK: - Edge swipes

    @objc private func leftEdgeSwiped(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended, gesture.translation(in: view).x > 40 else { return }
        setOverlay(shown: true)
    }

    @objc private func topEdgeSwiped(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended, gesture.translation(in: view).y > 40 else { return }
        showControls()
    }

    /// Touches starting within this distance of the left or top edge are
    /// kept for edge swipes and never click on the Mac.
    private func startsOnEdge(_ touches: Set<UITouch>) -> Bool {
        guard AppSettings.shared.edgeSwipes, let point = touches.first?.location(in: view) else { return false }
        return point.x < 20 || point.y < 20
    }

    // MARK: - Lock screen

    /// Nudges the pointer, which wakes a sleeping display and the login field.
    private func wakeMac() {
        receiver.sendMouse(action: "move", dx: 1, dy: 0)
        receiver.sendMouse(action: "move", dx: -1, dy: 0)
    }

    /// Wakes the lock screen, then types the password as US-layout key
    /// presses (characters off that layout as text) and presses return.
    /// The password is not stored.
    private func typePassword(_ password: String) {
        wakeMac()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            for character in password {
                if let key = MacKeyCode.keystroke(for: character) {
                    self.receiver.sendKey(code: key.code, modifiers: key.shift ? ["shift"] : [])
                } else {
                    self.receiver.sendText(String(character))
                }
            }
            self.receiver.sendKey(code: MacKeyCode.returnKey, modifiers: [])
        }
    }

    @objc private func pictureRightTapped(_ gesture: UITapGestureRecognizer) {
        receiver.sendMouse(action: "click", button: clickButton(forTwoFingerTap: gesture))
    }

    /// Three-finger swipe: desktops, Mission Control, app windows (like the trackpad).
    @objc private func pictureSwiped(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let t = gesture.translation(in: view)
        guard max(abs(t.x), abs(t.y)) > 30 else { return }
        let code = abs(t.x) > abs(t.y) ? (t.x < 0 ? MacKeyCode.right : MacKeyCode.left)
                                       : (t.y < 0 ? MacKeyCode.up : MacKeyCode.down)
        receiver.sendKey(code: code, modifiers: ["ctrl"])
    }

    // MARK: - Zoom (iPad only)

    private func setVideoFrame(_ frame: CGRect) {
        videoClip.frame = frame
        videoView.transform = .identity
        videoView.frame = videoClip.bounds
        applyZoom()
        layoutStatusBar()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartScale = zoomScale
            // location(in:) undoes the current zoom transform.
            let point = gesture.location(in: videoView)
            let size = videoView.bounds.size
            if zoomScale <= 1, size.width > 0, size.height > 0 {
                zoomFocus = CGPoint(x: point.x / size.width, y: point.y / size.height)
            }
        case .changed:
            zoomScale = min(max(pinchStartScale * gesture.scale, 1), 4)
            applyZoom()
        default:
            break
        }
    }

    @objc private func resetZoomTapped() {
        setZoom(1, animated: true)
    }

    private func setZoom(_ scale: CGFloat, animated: Bool) {
        zoomScale = scale
        if scale <= 1 { zoomFocus = CGPoint(x: 0.5, y: 0.5) }
        UIView.animate(withDuration: animated ? 0.2 : 0) { self.applyZoom() }
    }

    /// Scales the picture around zoomFocus, kept inside the screen.
    private func applyZoom() {
        let size = videoView.bounds.size
        guard zoomScale > 1.01, size.width > 0 else {
            zoomScale = 1
            videoView.transform = .identity
            return
        }
        let s = zoomScale
        let limitX = (s - 1) * size.width / 2, limitY = (s - 1) * size.height / 2
        let tx = min(max(-s * (zoomFocus.x - 0.5) * size.width, -limitX), limitX)
        let ty = min(max(-s * (zoomFocus.y - 0.5) * size.height, -limitY), limitY)
        // Store the clamped focus back so following the pointer starts from
        // what's actually on screen.
        zoomFocus = CGPoint(x: 0.5 - tx / (s * size.width), y: 0.5 - ty / (s * size.height))
        videoView.transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: s, y: s)
    }

    /// While zoomed, pans just enough to keep the Mac pointer on screen.
    private func followPointer() {
        guard zoomScale > 1, AppSettings.shared.zoomFollowsPointer else { return }
        let rect = letterboxedContentRect()
        let size = videoView.bounds.size
        guard rect.width > 0, size.width > 0 else { return }
        let pointer = CGPoint(x: (rect.minX + cursorNorm.x * rect.width) / size.width,
                              y: (rect.minY + cursorNorm.y * rect.height) / size.height)
        let innerHalf = 0.35 / zoomScale   // pointer stays in the middle 70%
        var focus = zoomFocus
        if pointer.x > focus.x + innerHalf { focus.x = pointer.x - innerHalf }
        if pointer.x < focus.x - innerHalf { focus.x = pointer.x + innerHalf }
        if pointer.y > focus.y + innerHalf { focus.y = pointer.y - innerHalf }
        if pointer.y < focus.y - innerHalf { focus.y = pointer.y + innerHalf }
        guard focus != zoomFocus else { return }
        zoomFocus = focus
        applyZoom()
    }

    // MARK: - Status bar and clipboard

    private func layoutStatusBar() {
        let size = statusBar.intrinsicContentSize
        let width = size.width + 20, height = size.height + 8
        statusBar.frame = CGRect(x: videoClip.frame.maxX - width - 10, y: videoClip.frame.minY + 10,
                                 width: width, height: height)
    }

    @objc private func batteryChanged() {
        updateStatusBar()
        updateScreen()
    }

    /// iPad battery percent, nil when unknown (e.g. the simulator).
    private var iPadBattery: Int? {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Int((level * 100).rounded())
    }

    private var iPadCharging: Bool {
        [.charging, .full].contains(UIDevice.current.batteryState)
    }

    /// A battery at 15% or less that isn't charging.
    private var lowBattery: Bool {
        guard AppSettings.shared.lowBatteryWarning else { return false }
        let macLow = macBattery.map { $0 <= 15 && !macCharging && !macOnAC } ?? false
        let iPadLow = iPadBattery.map { $0 <= 15 && !iPadCharging } ?? false
        return macLow || iPadLow
    }

    private func updateStatusBar() {
        var parts: [String] = []
        if let battery = macBattery { parts.append("Mac \(battery)%" + (macCharging ? " ⚡︎" : "")) }
        if let battery = iPadBattery { parts.append("iPad \(battery)%" + (iPadCharging ? " ⚡︎" : "")) }
        if !statsText.isEmpty { parts.append(statsText) }
        statusBar.text = (lowBattery ? "⚠︎ Low battery  ·  " : "") + parts.joined(separator: "  ·  ")
        statusBar.backgroundColor = lowBattery ? UIColor(red: 0.75, green: 0.1, blue: 0.1, alpha: 0.85)
                                               : UIColor(white: 0, alpha: 0.45)
        layoutStatusBar()
    }

    private func updateClipboardTimer(streaming: Bool) {
        let wanted = streaming && AppSettings.shared.syncClipboard
        if wanted, clipboardTimer == nil {
            // Only copies made from now on are sent.
            lastPasteboardCount = UIPasteboard.general.changeCount
            clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.pollPasteboard()
            }
        } else if !wanted {
            clipboardTimer?.invalidate()
            clipboardTimer = nil
        }
    }

    private func pollPasteboard() {
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != lastPasteboardCount else { return }
        lastPasteboardCount = pasteboard.changeCount
        if let text = pasteboard.string, text != lastClipboardFromMac {
            receiver.sendClipboard(text)
        }
    }

    // MARK: - Mode selection

    private func choose(_ mode: DisplayMode) {
        // Tapping the pending tile again before the Mac connects cancels it.
        if activeMode == mode, !receivingVideo {
            stopStreaming()
            return
        }
        if activeMode != mode { receivingVideo = false }
        activeMode = mode
        AppSettings.shared.lastMode = mode
        controls.mode = mode
        receiver.request(mode: mode)
        updateScreen()
    }

    private func stopStreaming() {
        activeMode = nil
        receivingVideo = false
        receiver.stop()
        updateScreen()
    }

    @objc private func showControls() {
        guard activeMode != nil, receivingVideo else { return }
        controls.show()
    }

    private func updateScreen() {
        let streaming = activeMode != nil && receivingVideo
        homeView.isHidden = streaming
        homeView.link = link
        homeView.pendingMode = streaming ? nil : activeMode
        if !streaming {
            controls.isHidden = true
            if overlayShown {
                overlayShown = false
                inputOverlay.releaseAll()
            }
        }
        inputOverlay.isHidden = !streaming || !(overlayShown || docked)
        inputOverlay.showsHideButton = !docked
        overlayToggle.isHidden = !streaming || overlayShown || docked
        cursorLayer.isHidden = !streaming || !cursorVisible || cursorLayer.contents == nil
        // Also before the first frame: a Mac locked at connect never sends one.
        let showLock = activeMode != nil && link != nil && macLocked
        if lockPanel.isHidden == showLock {
            lockPanel.isHidden = !showLock
            if !showLock { lockPanel.dismissKeyboard() }
        }
        // The low-battery warning shows even with the status bar turned off.
        statusBar.isHidden = !streaming || !(AppSettings.shared.showStatusBar || lowBattery)
            || statusBar.text?.isEmpty != false
        updateClipboardTimer(streaming: streaming)
        if !streaming, zoomScale > 1 { setZoom(1, animated: false) }
        // Mid-stream drop (app switch, cable pulled): keep the last frame
        // up and say so, rather than flashing back to the home screen.
        statusLabel.isHidden = !streaming || link != nil
        statusLabel.text = "Reconnecting…"
    }

    // Backgrounding suspends our networking queue; the listener/connection
    // can die silently without ever telling us, leaving the screen stuck on
    // the last decoded frame. Force a clean reconnect on every return.
    @objc private func appWillEnterForeground() {
        receiver.ensureListening()
        let settings = AppSettings.shared
        if activeMode == nil, settings.autoStart, let mode = settings.lastMode { choose(mode) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateScreen()
        layoutInputOverlay()
        announcePanel()
        updateCursorLayout()
    }

    /// Positions/sizes the cursor sprite inside the letterboxed video rect.
    /// `cursorNorm`/`cursorNormSize` are normalized [0,1] against the Mac's
    /// captured display (see VideoReceiver's "cursor"/"cursorImg" handling).
    private func updateCursorLayout() {
        let rect = letterboxedContentRect()
        guard cursorNormSize.width > 0, cursorNormSize.height > 0,
              rect.width > 0, rect.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.bounds = CGRect(x: 0, y: 0,
                                     width: cursorNormSize.width * rect.width,
                                     height: cursorNormSize.height * rect.height)
        cursorLayer.position = CGPoint(x: rect.minX + cursorNorm.x * rect.width,
                                        y: rect.minY + cursorNorm.y * rect.height)
        CATransaction.commit()
    }

    /// Tells the Mac the panel size to build the display at: upright only in
    /// "Turn the Mac display upright", landscape otherwise.
    private func announcePanel() {
        let scale = UIScreen.main.scale
        let bounds = UIScreen.main.bounds
        // Display size: a smaller announced panel makes everything on the
        // Mac bigger, a larger one gives more room (the picture is scaled to fit).
        let size = AppSettings.shared.displaySize.panelScale
        var wide = Int(Double(bounds.width * scale) * size) & ~1
        var high = Int(Double(bounds.height * scale) * size) & ~1
        if high > wide, AppSettings.shared.portraitLayout != .rotate { swap(&wide, &high) }
        receiver.updatePanel(pixelsWide: wide, pixelsHigh: high, scale: Double(scale))
        if !receiverStarted {
            receiverStarted = true
            receiver.start(port: 9000)
        }
    }
    private var receiverStarted = false

    // MARK: - Touch -> "touch" control messages

    private var forwardingInput: Bool {
        pictureInputAllowed && pictureMode == .direct
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        pictureMomentum.stop()
        if startsOnEdge(touches) {
            edgeTouch = true
            return
        }
        forwardTouch(touches, phase: "began")
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A second finger means a pinch or scroll, not a drag on the Mac.
        guard !edgeTouch, (event?.allTouches?.count ?? 1) < 2 else { return }
        forwardTouch(touches, phase: "moved")
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if edgeTouch {
            edgeTouch = false
            return
        }
        forwardTouch(touches, phase: "ended")
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    /// Maps a raw touch point into [0,1] video space, accounting for the
    /// letterboxing that `.resizeAspect` introduces when the decoded frame's
    /// aspect ratio doesn't exactly match the view's.
    private func forwardTouch(_ touches: Set<UITouch>, phase: String) {
        guard forwardingInput, let touch = touches.first else { return }
        sendNormalized(touch: touch, phase: phase)
    }

    private func sendNormalized(touch: UITouch, phase: String) {
        let point = touch.location(in: videoView)
        let contentRect = letterboxedContentRect()
        guard contentRect.width > 0, contentRect.height > 0 else { return }
        let clampedX = min(max(point.x, contentRect.minX), contentRect.maxX)
        let clampedY = min(max(point.y, contentRect.minY), contentRect.maxY)
        let nx = (clampedX - contentRect.minX) / contentRect.width
        let ny = (clampedY - contentRect.minY) / contentRect.height
        receiver.sendTouch(phase: phase, x: Double(nx), y: Double(ny))
    }

    /// The actual rect the decoded video occupies inside `videoView` under
    /// AVLayerVideoGravity.resizeAspect.
    private func letterboxedContentRect() -> CGRect {
        let bounds = videoView.bounds
        guard lastVideoSize.width > 0, lastVideoSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let videoAspect = lastVideoSize.width / lastVideoSize.height
        let boundsAspect = bounds.width / bounds.height
        if videoAspect > boundsAspect {
            let height = bounds.width / videoAspect
            let y = (bounds.height - height) / 2
            return CGRect(x: 0, y: y, width: bounds.width, height: height)
        } else {
            let width = bounds.height * videoAspect
            let x = (bounds.width - width) / 2
            return CGRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    // MARK: - Two-finger scroll -> "scroll" control messages

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        // Two-finger scroll works in every picture touch mode.
        guard pictureInputAllowed else { return }
        let sign: CGFloat = AppSettings.shared.naturalScrolling ? 1 : -1
        switch gesture.state {
        case .began:
            pictureMomentum.stop()
        case .changed:
            let translation = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            receiver.sendScroll(dx: Double(translation.x * sign), dy: Double(translation.y * sign))
        case .ended:
            let v = gesture.velocity(in: view)
            pictureMomentum.start(velocity: CGPoint(x: v.x * sign, y: v.y * sign))
        default:
            break
        }
    }

    // MARK: - VideoReceiverDelegate

    func videoReceiver(_ receiver: VideoReceiver, statusDidChange status: String) {
        homeView.detail = status
    }

    func videoReceiver(_ receiver: VideoReceiver, linkDidChange link: ReceiverLink?) {
        self.link = link
        updateScreen()
    }

    func videoReceiver(_ receiver: VideoReceiver, videoSizeDidChange size: CGSize) {
        lastVideoSize = size
        // Frames left over from a stopped stream can still trickle in.
        if activeMode != nil, link != nil { receivingVideo = true }
        updateScreen()
        view.setNeedsLayout()
        updateCursorLayout()
    }

    func videoReceiver(_ receiver: VideoReceiver, cursorDidChange point: CGPoint, visible: Bool) {
        cursorNorm = point
        cursorVisible = visible
        followPointer()
        cursorLayer.isHidden = homeView.isHidden == false || !visible || cursorLayer.contents == nil
        updateCursorLayout()
    }

    func videoReceiver(_ receiver: VideoReceiver, cursorImageDidChange image: UIImage, anchor: CGPoint, normSize: CGSize) {
        cursorLayer.contents = image.cgImage
        cursorLayer.anchorPoint = anchor
        cursorNormSize = normSize
        cursorLayer.isHidden = homeView.isHidden == false || !cursorVisible
        updateCursorLayout()
    }

    func videoReceiver(_ receiver: VideoReceiver, statsDidChange rttMs: Double?, fps: Int?) {
        statsText = (rttMs.map { "\(Int($0.rounded())) ms  ·  " } ?? "") + (fps.map { "\($0) fps" } ?? "idle")
        updateStatusBar()
        updateScreen()
    }

    func videoReceiver(_ receiver: VideoReceiver, macStatusDidChange battery: Int?, charging: Bool, onAC: Bool) {
        macBattery = battery
        macCharging = charging
        macOnAC = onAC
        updateStatusBar()
    }

    func videoReceiver(_ receiver: VideoReceiver, macLockDidChange locked: Bool) {
        guard locked != macLocked else { return }
        macLocked = locked
        updateScreen()
    }

    func videoReceiver(_ receiver: VideoReceiver, clipboardDidArrive text: String) {
        lastClipboardFromMac = text
        UIPasteboard.general.string = text
        lastPasteboardCount = UIPasteboard.general.changeCount
    }
}
