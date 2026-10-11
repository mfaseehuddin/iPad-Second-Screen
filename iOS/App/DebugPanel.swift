// DebugPanel.swift
//
// Stream diagnostics shown between the picture and the keyboard in the Game
// Boy layout (Settings → Debug panel). VideoReceiver fills StreamDebugInfo
// once a second; the Mac's side comes from its ping and per-frame timestamps.

import UIKit

/// One second of stream numbers. nil = not known (yet).
struct StreamDebugInfo {
    // Link
    var link: ReceiverLink?
    var remote = ""
    var connectedFor: TimeInterval?
    var mode: String?
    var quality = ""
    var panel = ""
    var rttMs: Double?
    var rttMinMs: Double?
    var rttMaxMs: Double?
    var clockOffsetMs: Double?

    // Video, measured on the iPad
    var videoSize: CGSize = .zero
    var profile = ""
    var fps: Double = 0
    var mbps: Double = 0
    var avgFrameKB: Double = 0
    var maxFrameKB: Double = 0
    var framesTotal = 0
    var megabytesTotal: Double = 0
    var keyframes = 0
    var lastKeyframeAgo: TimeInterval?
    var lastKeyframeKB: Double = 0
    var gapAvgMs: Double?
    var gapMaxMs: Double?
    var jitterMs: Double?
    var layerStatus = ""
    var layerFailures = 0
    var backlogKB: Double = 0
    var controlPerSec: Double = 0
    var awaitingKeyframe = false
    var backgrounded = false
    var framesSkippedInBackground = 0

    // Latency: capture → encoded on the Mac, encoded → received on the iPad
    var encodeMs: Double?
    var transitMs: Double?
    var transitMaxMs: Double?

    // Reported by the Mac every 2 s
    var macCaptureFps: Double?
    var macEncDropRate: Double?
    var macNetDropRate: Double?
    var macEncDrops: Int?
    var macNetDrops: Int?
    var macPendingSends: Int?
    var macInputP50: Double?
    var macInputP95: Double?
}

final class DebugPanel: PanelView {

    private static let lineCount = 9
    /// Three columns of single-line labels (one label per line, so a long
    /// value shrinks to fit instead of wrapping).
    private let columns = (0..<3).map { _ in (0..<DebugPanel.lineCount).map { _ in UILabel() } }
    private static let font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// Height for the panel's lines plus padding.
    static var preferredHeight: CGFloat { (font.lineHeight * CGFloat(lineCount)).rounded(.up) + 12 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.05, alpha: 0.9)
        layer.cornerRadius = 8
        clipsToBounds = true
        for (index, label) in columns.joined().enumerated() {
            label.font = Self.font
            // Each column's first line is its heading.
            label.textColor = index % Self.lineCount == 0 ? UIColor(red: 0.45, green: 0.75, blue: 1, alpha: 1)
                                                          : UIColor(white: 1, alpha: 0.88)
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            addSubview(label)
        }
        show(StreamDebugInfo(), keepAlive: "off")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.insetBy(dx: 10, dy: 6)
        let gap: CGFloat = 10
        let width = (area.width - gap * 2) / 3
        let lineHeight = Self.font.lineHeight
        for (column, labels) in columns.enumerated() {
            for (line, label) in labels.enumerated() {
                label.frame = CGRect(x: area.minX + CGFloat(column) * (width + gap),
                                     y: area.minY + CGFloat(line) * lineHeight, width: width, height: lineHeight)
            }
        }
    }

    /// keepAlive: what BackgroundKeeper is doing, e.g. "on", "playing", "off".
    func show(_ info: StreamDebugInfo, keepAlive: String) {
        let ms = { (value: Double?) in value.map { String(format: "%.0f", $0) } ?? "–" }
        let one = { (value: Double?) in value.map { String(format: "%.1f", $0) } ?? "–" }

        let linkName: String
        switch info.link {
        case .cable?: linkName = "Cable"
        case .wifi?: linkName = "Wi-Fi " + info.remote
        case nil: linkName = "not connected"
        }
        let size = info.videoSize == .zero ? "–" : "\(Int(info.videoSize.width))×\(Int(info.videoSize.height))"

        set(column: 0, [
            "LINK",
            linkName,
            "up \(Self.duration(info.connectedFor))  mode \(info.mode ?? "–")",
            "quality \(info.quality)",
            "panel \(info.panel)",
            "rtt \(ms(info.rttMs)) ms  (\(ms(info.rttMinMs))–\(ms(info.rttMaxMs)))",
            "clock offset \(ms(info.clockOffsetMs)) ms",
            "keep-alive \(keepAlive)" + (info.backgrounded ? "  [bg]" : ""),
            "skipped in bg \(info.framesSkippedInBackground)",
        ])

        set(column: 1, [
            "VIDEO (iPad)",
            "\(size)  \(info.profile.isEmpty ? "–" : info.profile)",
            String(format: "%.1f fps  %.2f Mbps", info.fps, info.mbps),
            String(format: "frame avg %.1f  max %.1f KB", info.avgFrameKB, info.maxFrameKB),
            "gap avg \(ms(info.gapAvgMs))  max \(ms(info.gapMaxMs)) ms",
            "jitter \(one(info.jitterMs)) ms",
            "IDR \(info.keyframes)  last \(Self.duration(info.lastKeyframeAgo)) ago  "
                + String(format: "%.0f KB", info.lastKeyframeKB),
            String(format: "frames %d  %.1f MB total", info.framesTotal, info.megabytesTotal),
            "layer \(info.layerStatus)  fails \(info.layerFailures)"
                + (info.awaitingKeyframe ? "  [wait IDR]" : ""),
        ])

        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "?"
        }
        let total = info.encodeMs.flatMap { encode in info.transitMs.map { encode + $0 } }
        set(column: 2, [
            "LATENCY / MAC",
            "encode \(one(info.encodeMs)) ms",
            "network \(ms(info.transitMs))  max \(ms(info.transitMaxMs)) ms",
            "capture→iPad \(ms(total)) ms",
            "Mac capture \(ms(info.macCaptureFps)) fps",
            "drops/s enc \(one(info.macEncDropRate))  net \(one(info.macNetDropRate))",
            "drops enc \(info.macEncDrops.map(String.init) ?? "–")  net \(info.macNetDrops.map(String.init) ?? "–")",
            "send queue \(info.macPendingSends.map(String.init) ?? "–")/3  rx \(String(format: "%.0f", info.backlogKB)) KB",
            "input p50 \(ms(info.macInputP50)) p95 \(ms(info.macInputP95))  \(thermal)",
        ])
    }

    private func set(column: Int, _ lines: [String]) {
        for (label, text) in zip(columns[column], lines) { label.text = text }
    }

    private static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds = seconds else { return "–" }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m\(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h\(String(format: "%02d", s / 60 % 60))m"
    }
}
