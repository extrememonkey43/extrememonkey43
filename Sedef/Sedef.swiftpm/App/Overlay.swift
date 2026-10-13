import UIKit

/// Numbers posted by the injected script once a second while a stream is playing.
struct StreamStats {
    var fps: Double?
    var presentedFps: Double?
    var width: Int?
    var height: Int?
    var codec: String?
    var mbps: Double?
    var rttMs: Double?
    var lost: Int?
    var droppedPerSec: Double?

    init?(_ payload: Any?) {
        guard let dict = payload as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? { (dict[key] as? NSNumber)?.doubleValue }
        fps = number("fps")
        presentedFps = number("presentedFps")
        width = number("width").map { Int($0) }
        height = number("height").map { Int($0) }
        codec = dict["codec"] as? String
        mbps = number("mbps")
        rttMs = number("rttMs")
        lost = number("lost").map { Int($0) }
        droppedPerSec = number("droppedPerSec")
    }
}

/// What the page asked GeForce NOW for, after our rewrite.
struct SessionRequest {
    var width: Int
    var height: Int
    var fps: Int
    var originalFps: Int?

    init?(_ payload: Any?) {
        guard let dict = payload as? [String: Any],
              let width = (dict["width"] as? NSNumber)?.intValue,
              let height = (dict["height"] as? NSNumber)?.intValue,
              let fps = (dict["fps"] as? NSNumber)?.intValue
        else { return nil }
        self.width = width
        self.height = height
        self.fps = fps
        originalFps = ((dict["before"] as? [String: Any])?["fps"] as? NSNumber)?.intValue
    }
}

enum HUDText {
    static func make(displayHz: Double?, displayLocked: Bool, stats: StreamStats?, request: SessionRequest?) -> String {
        var lines: [String] = []

        if let hz = displayHz {
            lines.append("Ekran \(Int(hz.rounded())) Hz")
        } else {
            lines.append(displayLocked ? "Ekran ölçülüyor…" : "Ekran kilidi kapalı")
        }

        if let stats {
            var parts: [String] = []
            if let fps = stats.fps {
                parts.append("Akış \(Int(fps.rounded())) fps")
            }
            if let shown = stats.presentedFps {
                parts.append("ekranda \(Int(shown.rounded()))")
            }
            if let w = stats.width, let h = stats.height, w > 0, h > 0 {
                parts.append("\(w)×\(h)")
            }
            if let codec = stats.codec {
                parts.append(codec)
            }
            if !parts.isEmpty {
                lines.append(parts.joined(separator: " · "))
            }

            var net: [String] = []
            if let mbps = stats.mbps {
                net.append(String(format: "%.1f Mbps", mbps))
            }
            if let rtt = stats.rttMs {
                net.append("ping \(Int(rtt.rounded())) ms")
            }
            if let dropped = stats.droppedPerSec, dropped >= 0.5 {
                net.append("düşen \(Int(dropped.rounded()))/sn")
            }
            if let lost = stats.lost, lost > 0 {
                net.append("kayıp paket \(lost)")
            }
            if !net.isEmpty {
                lines.append(net.joined(separator: " · "))
            }
        }

        if let request {
            lines.append("İstek \(request.width)×\(request.height) @ \(request.fps)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Small rounded label used for the HUD and toasts.
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 0
        textColor = .white
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        layer.cornerRadius = 10
        layer.masksToBounds = true
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let inner = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        return inner.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }
}
