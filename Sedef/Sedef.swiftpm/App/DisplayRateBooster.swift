import UIKit

/// Keeps a CADisplayLink asking for the panel's top refresh rate, so ProMotion stays at 120 Hz
/// instead of dropping when the page itself is idle. The video frames are composited on the
/// next display refresh, so the panel rate is the ceiling for what you see.
/// Also measures the real rate for the HUD (Low Power Mode, for example, caps it to 60 Hz).
final class DisplayRateBooster {
    var onMeasurement: ((Double) -> Void)?
    private var link: CADisplayLink?
    private var frames = 0
    private var windowStart: CFTimeInterval = 0

    var isRunning: Bool { link != nil }

    func start(maximumFramesPerSecond: Int) {
        guard link == nil else { return }
        let rate = Float(max(maximumFramesPerSecond, 60))
        let link = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
        frames = 0
        windowStart = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard windowStart > 0 else {
            windowStart = link.timestamp
            frames = 0
            return
        }
        frames += 1
        let elapsed = link.timestamp - windowStart
        if elapsed >= 1 {
            onMeasurement?(Double(frames) / elapsed)
            frames = 0
            windowStart = link.timestamp
        }
    }

    deinit {
        link?.invalidate()
    }

    /// CADisplayLink retains its target; the proxy keeps that from retaining the booster.
    private final class Proxy: NSObject {
        weak var owner: DisplayRateBooster?

        init(_ owner: DisplayRateBooster) {
            self.owner = owner
        }

        @objc func tick(_ link: CADisplayLink) {
            owner?.tick(link)
        }
    }
}
