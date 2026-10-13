import SwiftUI
import UIKit
import WebKit

/// Full-screen WKWebView tuned for GeForce NOW at 120 Hz, plus a small overlay
/// (menu button, stats HUD, toasts).
final class BrowserViewController: UIViewController {
    private var settings = BrowserSettings.load()
    private var webView: WKWebView?
    private var popupWebViews: [WKWebView] = []
    private var appliedWebKitFlags: [String] = []

    private let booster = DisplayRateBooster()
    private var measuredHz: Double?
    private var streamStats: StreamStats?
    private var sessionRequest: SessionRequest?

    private let hud = PaddedLabel()
    private let toast = PaddedLabel()
    private let menuButton = UIButton(type: .system)
    private var menuConstraints: [NSLayoutConstraint] = []
    private var fadeTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        booster.onMeasurement = { [weak self] hz in
            self?.measuredHz = hz
            self?.renderHUD()
        }

        setUpOverlay()
        installWebView(loading: settings.homePageURL)
        applyOverlaySettings()

        if !UserDefaults.standard.bool(forKey: SettingsKey.seenTip) {
            UserDefaults.standard.set(true, forKey: SettingsKey.seenTip)
            showToast("Menü: köşedeki düğme veya üç parmakla basılı tut.", seconds: 7)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateDisplayLock()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        booster.stop()
    }

    private var maximumFramesPerSecond: Int {
        view.window?.windowScene?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
    }

    private var screenPixels: CGSize {
        (view.window?.windowScene?.screen ?? UIScreen.main).nativeBounds.size
    }

    // MARK: - Web view

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.preferredContentMode = settings.identity == .iPad ? .recommended : .desktop

        let contentController = WKUserContentController()
        contentController.add(ScriptMessageProxy(self), name: "sedef")
        contentController.addUserScript(WKUserScript(
            source: GFNScript.source(config: settings.scriptConfig(screenPixels: screenPixels)),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        configuration.userContentController = contentController

        appliedWebKitFlags = WebKitTweaks.apply(settings, to: configuration.preferences)

        let webView = WKWebView(frame: view.bounds, configuration: configuration)
        configure(webView)
        return webView
    }

    private func configure(_ webView: WKWebView) {
        webView.customUserAgent = settings.identity.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        if #available(iOS 16.4, *) {
            // Lets you debug the page from Safari on a Mac (Develop menu).
            webView.isInspectable = true
        }
    }

    private func installWebView(loading url: URL) {
        if let old = webView {
            old.stopLoading()
            old.configuration.userContentController.removeAllScriptMessageHandlers()
            old.removeFromSuperview()
        }
        streamStats = nil
        sessionRequest = nil

        let webView = makeWebView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(webView, at: 0)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.webView = webView
        webView.load(URLRequest(url: url))
        renderHUD()
    }

    // MARK: - Overlay

    private func setUpOverlay() {
        hud.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        view.addSubview(hud)

        toast.font = .systemFont(ofSize: 15, weight: .semibold)
        toast.textAlignment = .center
        toast.alpha = 0
        view.addSubview(toast)

        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "slider.horizontal.3")
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
        menuButton.configuration = config
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.accessibilityLabel = "Sedef menüsü"
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = makeMenu()
        menuButton.addAction(UIAction { [weak self] _ in self?.wakeMenuButton() }, for: .menuActionTriggered)
        view.addSubview(menuButton)

        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            hud.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            hud.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -48),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])

        // Works even when the menu button is hidden; doesn't block touches meant for the game.
        let threeFingerHold = UILongPressGestureRecognizer(target: self, action: #selector(handleThreeFingerHold(_:)))
        threeFingerHold.numberOfTouchesRequired = 3
        threeFingerHold.minimumPressDuration = 0.8
        threeFingerHold.cancelsTouchesInView = false
        threeFingerHold.delaysTouchesBegan = false
        threeFingerHold.delegate = self
        view.addGestureRecognizer(threeFingerHold)
    }

    private func applyOverlaySettings() {
        menuButton.isHidden = !settings.showMenuButton
        hud.isHidden = !settings.showHUD

        NSLayoutConstraint.deactivate(menuConstraints)
        let guide = view.safeAreaLayoutGuide
        let inset: CGFloat = 12
        switch settings.menuCorner {
        case .topLeft:
            menuConstraints = [menuButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: inset),
                               menuButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: inset)]
        case .topRight:
            menuConstraints = [menuButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: inset),
                               menuButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -inset)]
        case .bottomLeft:
            menuConstraints = [menuButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -inset),
                               menuButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: inset)]
        case .bottomRight:
            menuConstraints = [menuButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -inset),
                               menuButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -inset)]
        }
        NSLayoutConstraint.activate(menuConstraints)
        wakeMenuButton()
        updateDisplayLock()
        renderHUD()
    }

    private func updateDisplayLock() {
        if settings.lockDisplay {
            booster.start(maximumFramesPerSecond: maximumFramesPerSecond)
        } else {
            booster.stop()
            measuredHz = nil
        }
        renderHUD()
    }

    private func renderHUD() {
        guard settings.showHUD else { return }
        hud.text = HUDText.make(displayHz: measuredHz, displayLocked: booster.isRunning, stats: streamStats, request: sessionRequest)
    }

    /// Full opacity for a few seconds, then fades so it doesn't sit on top of the game.
    private func wakeMenuButton() {
        menuButton.alpha = 1
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            UIView.animate(withDuration: 0.6) { self?.menuButton.alpha = 0.3 }
        }
    }

    private func showToast(_ text: String, seconds: Double = 4) {
        toast.text = text
        UIView.animate(withDuration: 0.25) { self.toast.alpha = 1 }
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            UIView.animate(withDuration: 0.4) { self?.toast.alpha = 0 }
        }
    }

    private func makeMenu() -> UIMenu {
        let dynamic = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else {
                completion([])
                return
            }
            var items: [UIMenuElement] = [
                UIAction(title: "Ayarlar", image: UIImage(systemName: "gearshape")) { [weak self] _ in self?.openSettings() },
                UIAction(title: "Yenile", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.reloadPage() },
            ]
            let back = UIAction(title: "Geri", image: UIImage(systemName: "chevron.backward")) { [weak self] _ in self?.webView?.goBack() }
            if self.webView?.canGoBack != true {
                back.attributes = .disabled
            }
            items.append(back)
            items.append(UIAction(title: "GeForce NOW ana sayfası", image: UIImage(systemName: "house")) { [weak self] _ in self?.goHome() })
            items.append(UIAction(
                title: self.settings.showHUD ? "İstatistikleri gizle" : "İstatistikleri göster",
                image: UIImage(systemName: "chart.bar.xaxis")
            ) { [weak self] _ in self?.toggleHUD() })
            items.append(UIAction(title: "Menü düğmesini gizle", image: UIImage(systemName: "eye.slash")) { [weak self] _ in
                self?.hideMenuButton()
            })
            completion(items)
        }
        return UIMenu(children: [dynamic])
    }

    // MARK: - Actions

    @objc private func handleThreeFingerHold(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began {
            openSettings()
        }
    }

    @objc private func openSettings() {
        guard presentedViewController == nil else { return }
        let status = SettingsView.Status(
            maximumHz: maximumFramesPerSecond,
            measuredHz: measuredHz,
            near60Removed: appliedWebKitFlags.contains(WebKitTweaks.near60FPSKey),
            codecsEnabled: appliedWebKitFlags.filter { WebKitTweaks.modernCodecKeys.contains($0) },
            lastRequest: sessionRequest.map { "\($0.width)×\($0.height) @ \($0.fps) FPS" }
        )
        let settingsView = SettingsView(
            status: status,
            onDone: { [weak self] in self?.dismiss(animated: true) { self?.settingsDidChange() } },
            onClearData: { [weak self] in self?.clearWebsiteData() }
        )
        let host = UIHostingController(rootView: settingsView)
        host.modalPresentationStyle = .formSheet
        host.presentationController?.delegate = self
        present(host, animated: true)
    }

    @objc private func reloadPage() {
        if webView?.url == nil {
            goHome()
        } else {
            webView?.reload()
        }
    }

    private func goHome() {
        webView?.load(URLRequest(url: settings.homePageURL))
    }

    @objc private func toggleHUD() {
        UserDefaults.standard.set(!settings.showHUD, forKey: SettingsKey.showHUD)
        settingsDidChange()
    }

    private func hideMenuButton() {
        UserDefaults.standard.set(false, forKey: SettingsKey.showMenuButton)
        settingsDidChange()
        showToast("Menüyü geri getirmek için üç parmakla basılı tut.", seconds: 5)
    }

    private func settingsDidChange() {
        let old = settings
        settings = BrowserSettings.load()
        if settings.needsNewWebView(comparedTo: old) {
            installWebView(loading: webView?.url ?? settings.homePageURL)
            showToast("Ayarlar uygulandı, sayfa yeniden yüklendi.")
        }
        applyOverlaySettings()
    }

    private func clearWebsiteData() {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            guard let self else { return }
            self.installWebView(loading: self.settings.homePageURL)
            self.showToast("Site verileri silindi.")
        }
    }

    // MARK: - Hardware keyboard

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(title: "Ayarlar", action: #selector(openSettings), input: ",", modifierFlags: .command),
            UIKeyCommand(title: "Yenile", action: #selector(reloadPage), input: "r", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "İstatistikler", action: #selector(toggleHUD), input: "i", modifierFlags: [.command, .shift]),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    // MARK: - Script messages

    fileprivate func handle(message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let payload = body["payload"]
        switch type {
        case "stats":
            streamStats = StreamStats(payload)
            renderHUD()
        case "session":
            guard let request = SessionRequest(payload) else { return }
            sessionRequest = request
            renderHUD()
            var text = "GFN'den \(request.width)×\(request.height) @ \(request.fps) FPS istendi"
            if let original = request.originalFps, original != request.fps {
                text += " (site \(original) istiyordu)"
            }
            showToast(text, seconds: 6)
        case "log":
            print("[Sedef]", payload ?? "")
        default:
            break
        }
    }

    // MARK: - Popups (sign-in windows)

    private func presentPopup(_ popup: WKWebView) {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        popup.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            popup.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
            popup.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
        ])
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self, weak popup] _ in
                guard let popup else { return }
                self?.closePopup(popup)
            }
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        topPresenter().present(navigation, animated: true)
    }

    private func closePopup(_ popup: WKWebView) {
        popupWebViews.removeAll { $0 === popup }
        var responder: UIResponder? = popup
        while let next = responder?.next {
            if let controller = next as? UIViewController {
                (controller.navigationController ?? controller).dismiss(animated: true)
                break
            }
            responder = next
        }
    }

    private func topPresenter() -> UIViewController {
        var top: UIViewController = self
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

// MARK: - WKNavigationDelegate

extension BrowserViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if ["http", "https", "about", "blob", "data", "javascript"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            // App Store links, mailto: and the like go to the system.
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        showToast("Sayfa açılamadı: \(nsError.localizedDescription)", seconds: 6)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showToast("Sayfa çöktü, yeniden yükleniyor…")
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension BrowserViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Must use the configuration WebKit hands us so window.opener keeps working.
        let popup = WKWebView(frame: .zero, configuration: configuration)
        configure(popup)
        popup.scrollView.bounces = true
        popupWebViews.append(popup)
        presentPopup(popup)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if popupWebViews.contains(where: { $0 === webView }) {
            closePopup(webView)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Tamam", style: .default) { _ in completionHandler() })
        topPresenter().present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Vazgeç", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "Tamam", style: .default) { _ in completionHandler(true) })
        topPresenter().present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Vazgeç", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "Tamam", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        topPresenter().present(alert, animated: true)
    }
}

// MARK: - Other delegates

extension BrowserViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

extension BrowserViewController: UIAdaptivePresentationControllerDelegate {
    /// Settings sheet swiped away instead of "Bitti".
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        settingsDidChange()
    }
}

/// WKUserContentController retains its handlers; this keeps it from retaining the view controller.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserViewController?

    init(_ owner: BrowserViewController) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.handle(message: message)
    }
}
