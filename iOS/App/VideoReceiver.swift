// VideoReceiver.swift
//
// A minimal iOS-12-compatible receiver for the "OpenDisplay"-style wire
// protocol (see https://github.com/peetzweg/opendisplay). It does NOT
// contain any code copied from that project -- it is a clean-room
// implementation of the same *publicly documented* framing/JSON contract,
// written so it can talk to an unmodified OpenDisplay Mac app.
//
// Wire format observed from the Mac sender:
//   [4-byte big-endian length][payload]
// `payload` is either:
//   - a JSON control message (< 32KB, first byte '{', contains no 0x00 byte)
//   - a raw H.264 Annex-B chunk (may be prefixed by a small JSON "telemetry"
//     blob before the first 00 00 00 01 start code -- we simply skip
//     everything before the first start code)
//
// The PHONE listens (NWListener) on a TCP port; the MAC connects to it.
// That direction is required so the exact same code path works whether the
// connection arrives over Wi-Fi or is tunneled in over the Lightning/USB-C
// cable via macOS's usbmuxd -- from the phone's point of view both look
// like an incoming TCP connection.
//
// Deliberately avoids Combine (@Published/ObservableObject need iOS 13) and
// SwiftUI (iOS 13) so it builds and runs on iOS 12.

import Foundation
import Network
import AVFoundation
import CoreMedia
import VideoToolbox
import UIKit

/// How the Mac reached us. usbmuxd tunnels the cable connection in from
/// loopback; anything else came over the network.
enum ReceiverLink {
    case cable, wifi
}

/// What the Mac should do with this device. Sent as `mode` in hello; the
/// patched OpenDisplay Mac app honors it over its own Mode picker.
enum DisplayMode: String {
    case extend, mirror
}

protocol VideoReceiverDelegate: AnyObject {
    func videoReceiver(_ receiver: VideoReceiver, statusDidChange status: String)
    /// nil = no Mac connected.
    func videoReceiver(_ receiver: VideoReceiver, linkDidChange link: ReceiverLink?)
    func videoReceiver(_ receiver: VideoReceiver, videoSizeDidChange size: CGSize)
    /// x/y normalized [0,1] against the Mac's captured display.
    func videoReceiver(_ receiver: VideoReceiver, cursorDidChange point: CGPoint, visible: Bool)
    /// anchor/normSize normalized against the Mac's captured display (see MacSender.pollCursorImage).
    func videoReceiver(_ receiver: VideoReceiver, cursorImageDidChange image: UIImage, anchor: CGPoint, normSize: CGSize)
    /// Round trip to the Mac in ms (nil until measured) and frames per second
    /// over the last few seconds; fps is nil while the Mac screen is still
    /// (the Mac only sends a frame when something changes).
    func videoReceiver(_ receiver: VideoReceiver, statsDidChange rttMs: Double?, fps: Int?)
    /// Everything the debug panel shows, once a second while it's on.
    func videoReceiver(_ receiver: VideoReceiver, debugDidUpdate info: StreamDebugInfo)
    /// Mac battery percent (nil without a battery), charging, and on mains power.
    func videoReceiver(_ receiver: VideoReceiver, macStatusDidChange battery: Int?, charging: Bool, onAC: Bool)
    /// Text copied on the Mac.
    func videoReceiver(_ receiver: VideoReceiver, clipboardDidArrive text: String)
    /// The Mac's screen locked or unlocked (capture pauses while locked).
    func videoReceiver(_ receiver: VideoReceiver, macLockDidChange locked: Bool)
}

final class VideoReceiver {

    weak var delegate: VideoReceiverDelegate?
    let displayLayer: AVSampleBufferDisplayLayer

    private(set) var videoSize: CGSize = .zero
    private(set) var isConnected = false

    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "videoreceiver.queue")
    private var buffer = Data()

    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    private var port: UInt16 = 9000
    private var lastDataReceived = Date()
    private var watchdogStarted = false
    private var advertisement: NetService?

    // Hello is held back until the user picks a mode, so a Mac that dials
    // in (cable plugged in, or WiFi) waits without creating a display.
    // Both are queue-confined.
    private var requestedMode: DisplayMode?
    private var helloSent = false

    // Also queue-confined. Quality rides in hello; subscriptions go out in a
    // "subscribe" message after it (patches/03-quality-clipboard-status.patch).
    private var requestedQuality: String?
    private var wantsClipboard = false
    private var wantsStatus = false
    private var framesSinceStats = 0
    private var lastStatsAt = Date()
    private var recentSamples: [(frames: Int, seconds: Double)] = []
    private var rttMs: Double?

    // Background (queue-confined). Frames aren't drawn while the app is in
    // the background; afterwards the picture waits for a fresh keyframe,
    // since the skipped frames were references for the ones that follow.
    private var backgrounded = false
    private var awaitingKeyframe = false
    private var framesSkippedInBackground = 0

    // Debug panel numbers (queue-confined). The win* values cover the
    // current one-second window.
    private var debugEnabled = false
    private var connectedAt: Date?
    private var winFrames = 0
    private var winBytes = 0
    private var winMaxFrame = 0
    private var winGapsMs: [Double] = []
    private var winEncodeMs: [Double] = []
    private var winTransitMs: [Double] = []
    private var winControl = 0
    private var lastWindowAt = Date()
    private var lastFrameAt: Date?
    private var framesTotal = 0
    private var bytesTotal = 0
    private var keyframesTotal = 0
    private var lastKeyframeAt: Date?
    private var lastKeyframeBytes = 0
    private var recentRtts: [Double] = []
    // Mac clock minus iPad clock, from the ping with the lowest recent round
    // trip, so frame timestamps from the Mac can be read on the iPad's clock.
    private var clockSamples: [(rtt: Double, offset: Double)] = []
    private var clockOffsetMs: Double?
    private var layerFailures = 0
    private var profile = ""
    private var macPing: [String: Double] = [:]
    private var macPingAt: Date?
    private var macEncDropRate: Double?
    private var macNetDropRate: Double?

    // Panel size announced to the Mac in "hello" so it can size the virtual
    // display to match. Queue-confined; set through updatePanel().
    private var devicePixelsWide: Int = 0
    private var devicePixelsHigh: Int = 0
    private var deviceScale: Double = 2

    // Stable per-install id (helps the Mac recognize "same device, other
    // transport"); persisted so it survives relaunches.
    static let installID: String = {
        let key = "LegacyPadDisplay.installID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
    }

    // MARK: - Lifecycle

    func start(port: UInt16 = 9000) {
        self.port = port
        queue.async { self.startListener() }
        advertise()
        if !watchdogStarted {
            watchdogStarted = true
            scheduleWatchdog()
            scheduleDebugTick()
        }
    }

    /// Tears down and recreates the listener and connection. When iOS has
    /// suspended our queue in the background, they can die silently without
    /// ever reaching the `.failed` state that would otherwise trigger
    /// startListener()'s own retry -- leaving the screen stuck on the last
    /// decoded frame forever. Costs a brief reconnect flicker.
    private func reconnect() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        resetStreamState()
        startListener()
        advertise()
    }

    /// The app went to the background (true) or came back (false). In the
    /// background the connection stays up only if something keeps the app
    /// running (BackgroundKeeper); otherwise iOS suspends us.
    func setBackgrounded(_ isBackground: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if isBackground {
                self.backgrounded = true
                self.framesSkippedInBackground = 0
                return
            }
            self.backgrounded = false
            // Still connected and hearing from the Mac: keep the session and
            // just resync the picture. Otherwise reconnect from scratch.
            if let conn = self.connection, conn.state == .ready,
               Date().timeIntervalSince(self.lastDataReceived) < 3 {
                self.displayLayer.flush()
                self.awaitingKeyframe = true
                if self.helloSent { self.sendControl(["type": "kf"], on: conn) }
            } else {
                self.reconnect()
            }
        }
    }

    /// Debug panel numbers on (once a second, see debugDidUpdate) or off.
    func setDebugEnabled(_ enabled: Bool) {
        queue.async { [weak self] in self?.debugEnabled = enabled }
    }

    /// The panel size to announce in hello. If it changes mid-session (the
    /// iPad rotated and the display should follow), hello is sent again and
    /// the Mac rebuilds the virtual display at the new size.
    func updatePanel(pixelsWide: Int, pixelsHigh: Int, scale: Double) {
        queue.async { [weak self] in
            guard let self = self,
                  pixelsWide != self.devicePixelsWide || pixelsHigh != self.devicePixelsHigh else { return }
            self.devicePixelsWide = pixelsWide
            self.devicePixelsHigh = pixelsHigh
            self.deviceScale = scale
            if self.helloSent, let conn = self.connection, conn.state == .ready {
                self.sendHello(on: conn)
            }
        }
    }

    /// Ask the Mac to start (or switch to) `mode`. Takes effect as soon as a
    /// Mac is connected; switching mode goes through standby, and the Mac's
    /// redial gets a hello carrying the new mode.
    func request(mode: DisplayMode) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let previous = self.requestedMode
            self.requestedMode = mode
            guard let conn = self.connection, conn.state == .ready else { return }
            if !self.helloSent {
                self.sendHello(on: conn)
            } else if previous != mode {
                self.sendControl(["type": "standby"], on: conn)
            }
        }
    }

    /// Stream quality to ask for ("best", "balanced", "fast"). Takes effect
    /// on the next hello; call restartStream() to apply it now.
    func setQuality(_ quality: String) {
        queue.async { [weak self] in self?.requestedQuality = quality }
    }

    /// Rebuild the stream with the current settings: standby, then the Mac
    /// redials and gets a fresh hello.
    func restartStream() {
        queue.async { [weak self] in
            guard let self = self, self.helloSent else { return }
            self.sendControl(["type": "standby"])
        }
    }

    /// Opt in to clipboard sync and/or the Mac's battery status.
    func subscribe(clipboard: Bool, status: Bool) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.wantsClipboard = clipboard
            self.wantsStatus = status
            if self.helloSent { self.sendSubscription() }
        }
    }

    /// Text copied on the iPad, for the Mac's clipboard.
    func sendClipboard(_ text: String) {
        queue.async { [weak self] in
            guard let self = self, self.wantsClipboard, text.utf8.count <= 16_000 else { return }
            self.sendControl(["type": "clipboard", "text": text])
        }
    }

    private func sendSubscription() {
        sendControl(["type": "subscribe", "clipboard": wantsClipboard, "status": wantsStatus])
    }

    /// Ask the Mac to take the display down. The Mac redials and waits for
    /// the next request().
    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.requestedMode = nil
            if self.helloSent { self.sendControl(["type": "standby"]) }
            self.helloSent = false
            self.displayLayer.flush()
        }
    }

    private func startListener() {
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true // touch events are tiny packets; don't let Nagle batch them
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                setStatus("Invalid port \(port)")
                return
            }
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            setStatus("Listener failed: \(error.localizedDescription)")
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            self.connection?.cancel()
            self.connection = conn
            self.helloSent = false
            self.resetStreamState()
            conn.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.lastDataReceived = Date()
                    self.connectedAt = Date()
                    self.setLink(Self.link(of: conn))
                    if self.requestedMode != nil { self.sendHello(on: conn) }
                case .failed, .cancelled:
                    // A replaced connection's late cancel must not mark the
                    // new one as gone.
                    if self.connection === conn || self.connection == nil { self.setLink(nil) }
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
            self.receive(on: conn)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.setStatus("Listening on :\(self.port)")
            case .failed(let error):
                self.setStatus("Listener failed (\(error)) -- restarting")
                self.queue.asyncAfter(deadline: .now() + 1) {
                    self.listener?.cancel()
                    self.listener = nil
                    self.startListener()
                }
            default:
                break
            }
        }
        listener?.start(queue: queue)
    }

    /// Bonjour advertisement (WiFi discovery only; usbmuxd connects straight
    /// to the port and never looks at this). NetService rather than
    /// NWListener.service because NWTXTRecord needs iOS 13. TXT: `id` lets
    /// the Mac match this device across USB and WiFi; `gate=1` tells the
    /// patched Mac app it may dial us any time, since we send hello only
    /// once the user picks a mode.
    private func advertise() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.advertisement?.stop()
            let service = NetService(domain: "", type: "_opensidecar._tcp.",
                                     name: UIDevice.current.name, port: Int32(self.port))
            service.setTXTRecord(NetService.data(fromTXTRecord: [
                "id": Data(Self.installID.utf8),
                "gate": Data("1".utf8),
            ]))
            service.publish()
            self.advertisement = service
        }
    }

    private static func link(of conn: NWConnection) -> ReceiverLink {
        if case .hostPort(let host, _) = conn.endpoint {
            switch host {
            case .ipv4(let address) where address.isLoopback: return .cable
            case .ipv6(let address) where address.isLoopback: return .cable
            default: break
            }
        }
        return .wifi
    }

    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            if let conn = self.connection, conn.state == .ready,
               Date().timeIntervalSince(self.lastDataReceived) > 6 {
                conn.cancel()
                self.connection = nil
                self.setLink(nil)
            }
            self.reportStats()
            self.scheduleWatchdog()
        }
    }

    /// Every watchdog tick: frames per second since the last tick, and a ping
    /// whose pong gives the round trip.
    private func reportStats() {
        // Average over the last two ticks (~4 s) so the number doesn't jump,
        // and call it idle when nothing arrived in the latest tick.
        recentSamples.append((framesSinceStats, Date().timeIntervalSince(lastStatsAt)))
        if recentSamples.count > 2 { recentSamples.removeFirst() }
        let frames = recentSamples.reduce(0) { $0 + $1.frames }
        let seconds = recentSamples.reduce(0) { $0 + $1.seconds }
        let fps: Int? = framesSinceStats == 0 || seconds <= 0 ? nil : Int((Double(frames) / seconds).rounded())
        framesSinceStats = 0
        lastStatsAt = Date()
        if helloSent, connection?.state == .ready {
            sendControl(["type": "ping", "t": Date().timeIntervalSince1970 * 1000])
        } else {
            rttMs = nil
        }
        let rtt = rttMs
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.videoReceiver(self, statsDidChange: rtt, fps: fps)
        }
    }

    private func reportLock(_ locked: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.videoReceiver(self, macLockDidChange: locked)
        }
    }

    private func resetStreamState() {
        buffer.removeAll(keepingCapacity: true)
        formatDesc = nil
        sps = nil
        pps = nil
        awaitingKeyframe = false
        connectedAt = nil
        lastFrameAt = nil
        clockSamples.removeAll()
        clockOffsetMs = nil
        macPing.removeAll()
        macPingAt = nil
        macEncDropRate = nil
        macNetDropRate = nil
        displayLayer.flush()
    }

    // MARK: - Outgoing control messages (phone -> Mac)

    private func sendHello(on conn: NWConnection) {
        guard let mode = requestedMode else { return }
        helloSent = true
        sendControl([
            "type": "hello",
            "pixelsWide": devicePixelsWide,
            "pixelsHigh": devicePixelsHigh,
            "scale": deviceScale,
            "device": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            "id": Self.installID,
            "mode": mode.rawValue,
            "quality": requestedQuality ?? "best",
            // No "pv" field on purpose: an absent protocol version is
            // defined by the Mac app as protocol 1, which every released
            // OpenDisplay Mac build supports (minSupportedPeer stays at 1).
        ], on: conn)
        sendSubscription()
    }

    /// x/y normalized [0,1] in *decoded video* space, origin top-left.
    func sendTouch(phase: String, x: Double, y: Double) {
        sendControl(["type": "touch", "phase": phase, "x": x, "y": y])
    }

    /// dx/dy in video pixels (natural-scrolling sign, i.e. content follows the fingers).
    func sendScroll(dx: Double, dy: Double) {
        sendControl(["type": "scroll", "dx": dx, "dy": dy])
    }

    /// One key press: a macOS virtual key code plus "cmd"/"opt"/"ctrl"/"shift".
    func sendKey(code: Int, modifiers: [String]) {
        sendControl(["type": "key", "code": code, "mods": modifiers])
    }

    /// Typed characters, inserted on the Mac as-is.
    func sendText(_ text: String) {
        sendControl(["type": "text", "text": text])
    }

    /// Trackpad: action "move" (dx/dy in Mac points), or "down"/"up"/"click".
    func sendMouse(action: String, button: String = "left", dx: Double = 0, dy: Double = 0) {
        sendControl(["type": "mouse", "action": action, "button": button, "dx": dx, "dy": dy])
    }

    private func sendControl(_ message: [String: Any], on conn: NWConnection? = nil) {
        guard let conn = conn ?? connection,
              let payload = try? JSONSerialization.data(withJSONObject: message) else { return }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: - Incoming: read + length-prefixed deframing

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.lastDataReceived = Date()
                self.buffer.append(data)
                self.drainFrames()
            }
            if error != nil { return }
            if isComplete {
                if self.connection === conn { self.setLink(nil) }
                return
            }
            self.receive(on: conn)
        }
    }

    private func drainFrames() {
        var cursor = buffer.startIndex
        while buffer.distance(from: cursor, to: buffer.endIndex) >= 4 {
            let lenRange = cursor..<buffer.index(cursor, offsetBy: 4)
            let len = buffer[lenRange].withUnsafeBytes { raw -> Int in
                let b = raw.bindMemory(to: UInt8.self)
                let v = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
                return Int(v)
            }
            guard buffer.distance(from: cursor, to: buffer.endIndex) >= 4 + len else { break }
            let start = buffer.index(cursor, offsetBy: 4)
            let end = buffer.index(start, offsetBy: len)
            handlePayload(Data(buffer[start..<end]))
            cursor = end
        }
        buffer.removeSubrange(buffer.startIndex..<cursor)
    }

    // MARK: - Payload routing: JSON control vs. H.264 Annex-B

    private func handlePayload(_ data: Data) {
        if data.count < 32_768, data.first == UInt8(ascii: "{"), !data.contains(0) {
            handleControlJSON(data)
            return
        }
        handleAnnexB(data)
    }

    private func handleControlJSON(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        winControl += 1
        switch type {
        case "ping":
            // Reply so the Mac's liveness check on this connection is happy.
            sendControl(["type": "pong", "t": obj["t"] ?? 0, "mt": Date().timeIntervalSince1970 * 1000])
            recordMacPing(obj)
        case "pong":
            // Reply to our own ping (see reportStats).
            if let sent = obj["t"] as? Double {
                let now = Date().timeIntervalSince1970 * 1000
                let rtt = now - sent
                rttMs = rtt
                recentRtts.append(rtt)
                if recentRtts.count > 30 { recentRtts.removeFirst() }
                if let macTime = obj["mt"] as? Double {
                    clockSamples.append((rtt, macTime - (sent + now) / 2))
                    if clockSamples.count > 10 { clockSamples.removeFirst() }
                    clockOffsetMs = clockSamples.min { $0.rtt < $1.rtt }?.offset
                }
            }
        case "macLock":
            guard let locked = obj["locked"] as? Bool else { return }
            reportLock(locked)
        case "macStatus":
            if let locked = obj["locked"] as? Bool { reportLock(locked) }
            let battery = obj["battery"] as? Int
            let charging = obj["charging"] as? Bool ?? false
            let onAC = obj["onAC"] as? Bool ?? (battery == nil)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.videoReceiver(self, macStatusDidChange: battery, charging: charging, onAC: onAC)
            }
        case "clipboard":
            guard wantsClipboard, let text = obj["text"] as? String else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.videoReceiver(self, clipboardDidArrive: text)
            }
        case "cursor":
            let visible = (obj["v"] as? Int ?? 0) == 1
            let point = CGPoint(x: obj["x"] as? Double ?? 0, y: obj["y"] as? Double ?? 0)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.videoReceiver(self, cursorDidChange: point, visible: visible)
            }
        case "cursorImg":
            guard let b64 = obj["png"] as? String,
                  let png = Data(base64Encoded: b64),
                  let image = UIImage(data: png),
                  let nw = obj["nw"] as? Double, let nh = obj["nh"] as? Double else { return }
            let anchor = CGPoint(x: obj["ax"] as? Double ?? 0, y: obj["ay"] as? Double ?? 0)
            let normSize = CGSize(width: nw, height: nh)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.videoReceiver(self, cursorImageDidChange: image, anchor: anchor, normSize: normSize)
            }
        default:
            break // welcome / stats-only messages: nothing to do in this minimal client
        }
    }

    private func handleAnnexB(_ data: Data) {
        // Split on 4-byte start codes (00 00 00 01). Anything before the
        // first start code is telemetry JSON prefix the Mac may prepend --
        // only the debug panel reads it (recordTelemetry).
        var nalus: [Data] = []
        var firstStartCode: Int?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var naluStart: Int? = nil
            var i = 0
            while i + 4 <= bytes.count {
                if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    if firstStartCode == nil { firstStartCode = i }
                    if let s = naluStart, s < i { nalus.append(Data(bytes[s..<i])) }
                    naluStart = i + 4
                    i += 4
                } else {
                    i += 1
                }
            }
            if let s = naluStart, s < bytes.count { nalus.append(Data(bytes[s...])) }
        }

        if let start = firstStartCode, start > 0 { recordTelemetry(data.prefix(start)) }

        var vclNALUs: [Data] = []
        var isKeyframe = false
        for nalu in nalus {
            guard let first = nalu.first else { continue }
            switch first & 0x1F {
            case 7: // SPS
                if sps != nalu { sps = nalu; formatDesc = nil; profile = Self.describeProfile(sps: nalu) }
            case 8: // PPS
                if pps != nalu { pps = nalu; formatDesc = nil }
            case 6:
                break // SEI, ignore
            case 5: // IDR slice
                isKeyframe = true
                vclNALUs.append(nalu)
            default:
                vclNALUs.append(nalu) // slice data
            }
        }
        if formatDesc == nil, let sps = sps, let pps = pps {
            displayLayer.flush()
            buildFormatDescription(sps: sps, pps: pps)
        }
        guard !vclNALUs.isEmpty else { return }
        recordFrame(bytes: data.count, keyframe: isKeyframe)
        if backgrounded {
            framesSkippedInBackground += 1
            return
        }
        if awaitingKeyframe {
            guard isKeyframe else { return }
            awaitingKeyframe = false
        }
        enqueueFrame(vclNALUs)
    }

    private func buildFormatDescription(sps: Data, pps: Data) {
        sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                let ptrs: [UnsafePointer<UInt8>] = [
                    spsBuf.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBuf.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                var desc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrs,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc)
                if status == noErr, let desc = desc {
                    formatDesc = desc
                    let dims = CMVideoFormatDescriptionGetDimensions(desc)
                    let size = CGSize(width: Int(dims.width), height: Int(dims.height))
                    videoSize = size
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.delegate?.videoReceiver(self, videoSizeDidChange: size)
                    }
                    setStatus("Receiving \(dims.width)x\(dims.height)")
                }
            }
        }
    }

    private func enqueueFrame(_ nalus: [Data]) {
        guard let formatDesc = formatDesc else { return }

        var avcc = Data(capacity: nalus.reduce(0) { $0 + $1.count + 4 })
        for nalu in nalus {
            var len = UInt32(nalu.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nalu)
        }

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &blockBuffer)
        guard createStatus == noErr, let blockBuffer = blockBuffer else { return }
        let copyStatus = avcc.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                           offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copyStatus == noErr else { return }

        var sample: CMSampleBuffer?
        var sizeArr = [avcc.count]
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDesc, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr,
            sampleBufferOut: &sample)
        guard let sample = sample else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if displayLayer.status == .failed {
            layerFailures += 1
            displayLayer.flush()
        }
        displayLayer.enqueue(sample)
        framesSinceStats += 1
    }

    // MARK: - Debug statistics

    private func recordFrame(bytes: Int, keyframe: Bool) {
        let now = Date()
        if let last = lastFrameAt { winGapsMs.append(now.timeIntervalSince(last) * 1000) }
        lastFrameAt = now
        winFrames += 1
        winBytes += bytes
        winMaxFrame = max(winMaxFrame, bytes)
        framesTotal += 1
        bytesTotal += bytes
        if keyframe {
            keyframesTotal += 1
            lastKeyframeAt = now
            lastKeyframeBytes = bytes
        }
    }

    /// The Mac prefixes each frame with {"cap":ms,"snd":ms}: when the screen
    /// was captured and when the encoded frame was handed to the network,
    /// both on the Mac's clock.
    private func recordTelemetry(_ prefix: Data) {
        guard prefix.first == UInt8(ascii: "{"),
              let obj = try? JSONSerialization.jsonObject(with: prefix) as? [String: Any],
              let cap = obj["cap"] as? Double, let snd = obj["snd"] as? Double else { return }
        winEncodeMs.append(snd - cap)
        if let offset = clockOffsetMs {
            winTransitMs.append(Date().timeIntervalSince1970 * 1000 - (snd - offset))
        }
    }

    /// The Mac's ping carries running totals of its frame drops, its send
    /// queue, capture rate and input latency.
    private func recordMacPing(_ obj: [String: Any]) {
        var values: [String: Double] = [:]
        for (key, value) in obj { if let number = value as? Double { values[key] = number } }
        let now = Date()
        if let at = macPingAt {
            let seconds = now.timeIntervalSince(at)
            if seconds > 0 {
                if let enc = values["encDrops"], let before = macPing["encDrops"] {
                    macEncDropRate = max(0, enc - before) / seconds
                }
                if let net = values["netDrops"], let before = macPing["netDrops"] {
                    macNetDropRate = max(0, net - before) / seconds
                }
            }
        }
        macPing = values
        macPingAt = now
    }

    private static func describeProfile(sps: Data) -> String {
        guard sps.count >= 4 else { return "" }
        let names: [UInt8: String] = [66: "Baseline", 77: "Main", 88: "Extended", 100: "High"]
        let level = Double(sps[sps.startIndex + 3]) / 10
        return "\(names[sps[sps.startIndex + 1]] ?? "profile \(sps[sps.startIndex + 1])") \(level)"
    }

    private func scheduleDebugTick() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            self.reportDebug()
            self.scheduleDebugTick()
        }
    }

    private func reportDebug() {
        let now = Date()
        let seconds = max(now.timeIntervalSince(lastWindowAt), 0.001)
        defer {
            lastWindowAt = now
            winFrames = 0
            winBytes = 0
            winMaxFrame = 0
            winGapsMs.removeAll(keepingCapacity: true)
            winEncodeMs.removeAll(keepingCapacity: true)
            winTransitMs.removeAll(keepingCapacity: true)
            winControl = 0
        }
        guard debugEnabled else { return }

        func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        var info = StreamDebugInfo()
        info.link = isConnected ? connection.map(Self.link(of:)) : nil
        if let conn = connection, case .hostPort(let host, _) = conn.endpoint { info.remote = "\(host)" }
        info.connectedFor = connectedAt.map { now.timeIntervalSince($0) }
        info.mode = requestedMode?.rawValue
        info.quality = requestedQuality ?? "best"
        info.panel = "\(devicePixelsWide)×\(devicePixelsHigh) @\(Int(deviceScale))x"
        info.videoSize = videoSize
        info.profile = profile
        info.fps = Double(winFrames) / seconds
        info.mbps = Double(winBytes) * 8 / seconds / 1_000_000
        info.avgFrameKB = winFrames > 0 ? Double(winBytes) / Double(winFrames) / 1024 : 0
        info.maxFrameKB = Double(winMaxFrame) / 1024
        info.framesTotal = framesTotal
        info.megabytesTotal = Double(bytesTotal) / 1_048_576
        info.keyframes = keyframesTotal
        info.lastKeyframeAgo = lastKeyframeAt.map { now.timeIntervalSince($0) }
        info.lastKeyframeKB = Double(lastKeyframeBytes) / 1024
        if let gapMean = mean(winGapsMs) {
            info.gapAvgMs = gapMean
            info.gapMaxMs = winGapsMs.max()
            info.jitterMs = (winGapsMs.map { ($0 - gapMean) * ($0 - gapMean) }.reduce(0, +)
                             / Double(winGapsMs.count)).squareRoot()
        }
        info.rttMs = rttMs
        info.rttMinMs = recentRtts.min()
        info.rttMaxMs = recentRtts.max()
        info.clockOffsetMs = clockOffsetMs
        info.encodeMs = mean(winEncodeMs)
        info.transitMs = mean(winTransitMs)
        info.transitMaxMs = winTransitMs.max()
        switch displayLayer.status {
        case .rendering: info.layerStatus = "rendering"
        case .failed: info.layerStatus = "failed"
        default: info.layerStatus = "idle"
        }
        info.layerFailures = layerFailures
        info.backlogKB = Double(buffer.count) / 1024
        info.controlPerSec = Double(winControl) / seconds
        info.awaitingKeyframe = awaitingKeyframe
        info.backgrounded = backgrounded
        info.framesSkippedInBackground = framesSkippedInBackground
        info.macCaptureFps = macPing["capFps"]
        info.macEncDropRate = macEncDropRate
        info.macNetDropRate = macNetDropRate
        info.macEncDrops = macPing["encDrops"].map(Int.init)
        info.macNetDrops = macPing["netDrops"].map(Int.init)
        info.macPendingSends = macPing["pending"].map(Int.init)
        info.macInputP50 = macPing["inp50"]
        info.macInputP95 = macPing["inp95"]
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.videoReceiver(self, debugDidUpdate: info)
        }
    }

    // MARK: - Helpers

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.videoReceiver(self, statusDidChange: text)
        }
    }

    private func setLink(_ link: ReceiverLink?) {
        isConnected = link != nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.videoReceiver(self, linkDidChange: link)
        }
        setStatus(link == nil ? "Listening on :\(port)" : "Connected")
    }
}
