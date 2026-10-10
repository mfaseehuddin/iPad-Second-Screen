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

    private let videoView = VideoContainerView()
    private let statusLabel = UILabel()
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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)
        videoView.layer.addSublayer(cursorLayer)

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
        inputOverlay.applySettings()
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

    /// Overlay: bottom band, settings-sized. Toggle arrow: bottom-right corner.
    private func layoutInputOverlay() {
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let height = (view.bounds.height * CGFloat(AppSettings.shared.overlayHeight)).rounded()
        inputOverlay.frame = CGRect(x: safe.minX, y: safe.maxY - height, width: safe.width, height: height)
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
        touch.view === view || touch.view === videoView
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
        inputOverlay.isHidden = !streaming || !overlayShown
        overlayToggle.isHidden = !streaming || overlayShown
        cursorLayer.isHidden = !streaming || !cursorVisible || cursorLayer.contents == nil
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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
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

    private func announcePanel() {
        let scale = UIScreen.main.scale
        let bounds = UIScreen.main.bounds
        receiver.devicePixelsWide = Int(bounds.width * scale)
        receiver.devicePixelsHigh = Int(bounds.height * scale)
        receiver.deviceScale = Double(scale)
        if !receiverStarted {
            receiverStarted = true
            receiver.start(port: 9000)
        }
    }
    private var receiverStarted = false

    // MARK: - Touch -> "touch" control messages

    private var forwardingInput: Bool {
        activeMode != nil && receivingVideo && controls.isHidden && AppSettings.shared.directTouch
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        forwardTouch(touches, phase: "began")
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        forwardTouch(touches, phase: "moved")
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        forwardTouch(touches, phase: "ended")
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        forwardTouch(touches, phase: "ended")
    }

    /// Maps a raw touch point into [0,1] video space, accounting for the
    /// letterboxing that `.resizeAspect` introduces when the decoded frame's
    /// aspect ratio doesn't exactly match the view's.
    private func forwardTouch(_ touches: Set<UITouch>, phase: String) {
        guard forwardingInput, let touch = touches.first else { return }
        sendNormalized(touch: touch, phase: phase)
    }

    private func sendNormalized(touch: UITouch, phase: String) {
        let point = touch.location(in: view)
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
        guard forwardingInput, gesture.state == .changed else { return }
        let translation = gesture.translation(in: view)
        gesture.setTranslation(.zero, in: view)
        receiver.sendScroll(dx: Double(translation.x), dy: Double(translation.y))
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
        updateCursorLayout()
    }

    func videoReceiver(_ receiver: VideoReceiver, cursorDidChange point: CGPoint, visible: Bool) {
        cursorNorm = point
        cursorVisible = visible
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
}
