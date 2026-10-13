import UIKit
import UIKit.UIGestureRecognizerSubclass
import WebKit

/// Remembers when a finger (or mouse click) last touched the screen. Never recognizes, so it
/// doesn't take touches away from the web page.
final class TouchClockRecognizer: UIGestureRecognizer {
    private(set) static var lastTouch: CFTimeInterval = 0

    static func make() -> TouchClockRecognizer {
        let recognizer = TouchClockRecognizer(target: nil, action: nil)
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        return recognizer
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        Self.lastTouch = CACurrentMediaTime()
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

/// WebKit on iPad only raises the software keyboard when a text field gets focus *while* the
/// touch is being handled. Desktop-style pages (what GeForce NOW serves to the Windows identity)
/// often focus the field a moment later, from a timer or after an animation, so the keyboard
/// never appears. This treats a focus shortly after a real touch as user-initiated.
///
/// Implements the private `_WKInputDelegate` method, looked up at runtime.
@MainActor
final class KeyboardFocusPolicy: NSObject {
    /// How long after a touch a focus still counts as the user's.
    static let touchWindow: CFTimeInterval = 1.5

    /// Returns `_WKFocusStartsInputSessionPolicy`: 0 = Auto (WebKit decides), 1 = Allow.
    @objc(_webView:decidePolicyForFocusedElement:)
    func decidePolicy(webView: WKWebView, focusedElement: AnyObject) -> Int {
        CACurrentMediaTime() - TouchClockRecognizer.lastTouch < Self.touchWindow ? 1 : 0
    }

    /// WKWebView keeps the input delegate weakly; the caller must keep this object alive.
    func attach(to webView: WKWebView) {
        let setter = NSSelectorFromString("_setInputDelegate:")
        if webView.responds(to: setter) {
            _ = webView.perform(setter, with: self)
        }
    }
}
