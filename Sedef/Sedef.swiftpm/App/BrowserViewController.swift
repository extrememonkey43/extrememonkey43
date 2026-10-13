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
    private let keyboardPolicy = KeyboardFocusPolicy()
    private var measuredHz: Double?
    private var streamStats: StreamStats?
    private var sessionRequest: SessionRequest?

    private let hud = PaddedLabel()
    private let toast = PaddedLabel()
    private let menuButton = UIButton(type: .system)
    private let typeButton = UIButton(type: .system)
    private var editField: EditField?
    private var lastEditField: EditField?
    private weak var editWebView: WKWebView?
    private var keyboardVisible = false
    private var typeButtonTask: Task<Void, Never>?
    private var menuConstraints: [NSLayoutConstraint] = []
    private var fadeTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    /// iPadOS 26 ships Safari 26, so the OS major version is the Safari version.
    private let safariVersion: String = {
        let major = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "26"
        return major + ".0"
    }()

    /// WebKit lets each page load have its own user agent (Safari uses this for "Request Desktop
    /// Website"). Private API; without it the identity falls back to the whole web view.
    private static let perPageIdentity = WKWebpagePreferences().responds(to: NSSelectorFromString("_setCustomUserAgent:"))

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
        configuration.defaultWebpagePreferences.preferredContentMode = .recommended
        // A plain WKWebView leaves "Version/… Safari/…" out of its user agent; sign-in pages
        // (Google in particular) treat that as an embedded browser. Match real Safari.
        configuration.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"

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
        webView.customUserAgent = Self.perPageIdentity ? nil : settings.identity.userAgent(safariVersion: safariVersion)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        keyboardPolicy.attach(to: webView)
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

    /// GeForce NOW pages get the chosen identity; everything else (sign-in pages) the real iPad.
    private func applyIdentity(to preferences: WKWebpagePreferences, for url: URL) {
        let onGeForceNow = BrowserIdentity.appliesTo(url)
        let userAgent = onGeForceNow ? settings.identity.userAgent(safariVersion: safariVersion) : nil
        preferences.preferredContentMode = userAgent == nil ? .recommended : .desktop
        guard Self.perPageIdentity, let userAgent else { return }
        _ = preferences.perform(NSSelectorFromString("_setCustomUserAgent:"), with: userAgent)
        let platformSetter = NSSelectorFromString("_setCustomNavigatorPlatform:")
        if let platform = settings.identity.navigatorPlatform, preferences.responds(to: platformSetter) {
            _ = preferences.perform(platformSetter, with: platform)
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
            toast.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -100),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])

        // Fallback for when the iPad keyboard doesn't come up for a web text field.
        var typeConfig = UIButton.Configuration.filled()
        typeConfig.title = "Yaz"
        typeConfig.image = UIImage(systemName: "keyboard")
        typeConfig.imagePadding = 8
        typeConfig.baseBackgroundColor = UIColor(red: 0.46, green: 0.73, blue: 0.0, alpha: 1)
        typeConfig.baseForegroundColor = .black
        typeConfig.cornerStyle = .capsule
        typeConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
        typeButton.configuration = typeConfig
        typeButton.translatesAutoresizingMaskIntoConstraints = false
        typeButton.isHidden = true
        typeButton.alpha = 0
        typeButton.addAction(UIAction { [weak self] _ in self?.presentTextPrompt() }, for: .primaryActionTriggered)
        view.addSubview(typeButton)
        NSLayoutConstraint.activate([
            typeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            typeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)

        // Works even when the menu button is hidden; doesn't block touches meant for the game.
        let threeFingerHold = UILongPressGestureRecognizer(target: self, action: #selector(handleThreeFingerHold(_:)))
        threeFingerHold.numberOfTouchesRequired = 3
        threeFingerHold.minimumPressDuration = 0.8
        threeFingerHold.cancelsTouchesInView = false
        threeFingerHold.delaysTouchesBegan = false
        threeFingerHold.delaysTouchesEnded = false
        threeFingerHold.delegate = self
        view.addGestureRecognizer(threeFingerHold)

        // Lets text fields open the keyboard even when the page focuses them a moment late.
        view.addGestureRecognizer(TouchClockRecognizer.make())
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
            if self.lastEditField != nil {
                items.append(UIAction(title: "Metin kutusuna yaz", image: UIImage(systemName: "keyboard")) { [weak self] _ in
                    self?.presentTextPrompt()
                })
            }
            items.append(UIAction(
                title: self.settings.showHUD ? "İstatistikleri gizle" : "İstatistikleri göster",
                image: UIImage(systemName: "chart.bar.xaxis")
            ) { [weak self] _ in self?.toggleHUD() })
            items.append(UIAction(title: "Sayfa bilgisi", image: UIImage(systemName: "info.circle")) { [weak self] _ in
                self?.showPageInfo()
            })
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

    /// Where the page is stuck, in a form that's easy to copy and send.
    private func showPageInfo() {
        guard let webView, topPresenter() === self else { return }
        let url = webView.url?.absoluteString ?? "—"
        let shownURL = url.count > 160 ? String(url.prefix(160)) + "…" : url
        let identity: String
        if let pageURL = webView.url, BrowserIdentity.appliesTo(pageURL) {
            identity = settings.identity.title
        } else {
            identity = "iPad Safari (giriş sayfaları için)"
        }
        let message = [
            "Başlık: \(webView.title ?? "—")",
            "Adres: \(shownURL)",
            "Kimlik: \(identity)",
            "iPadOS \(UIDevice.current.systemVersion)",
        ].joined(separator: "\n\n")
        let alert = UIAlertController(title: "Sayfa bilgisi", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Adresi kopyala", style: .default) { _ in
            UIPasteboard.general.string = url
        })
        alert.addAction(UIAlertAction(title: "Kapat", style: .cancel))
        present(alert, animated: true)
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

    private func handle(message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let payload = body["payload"]
        switch type {
        case "stats":
            streamStats = StreamStats(payload)
            renderHUD()
            if streamStats != nil {
                setTypeButtonVisible(false)
            }
        case "editFocus":
            guard let field = EditField(payload) else { return }
            editField = field
            lastEditField = field
            editWebView = message.webView
            scheduleTypeButtonCheck(after: 0.8)
        case "editBlur":
            editField = nil
            scheduleTypeButtonCheck(after: 0.3)
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

    // MARK: - Text entry fallback

    @objc private func keyboardWillShow(_ notification: Notification) {
        keyboardVisible = true
        setTypeButtonVisible(false)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboardVisible = false
        scheduleTypeButtonCheck(after: 0.5)
    }

    /// Shows the "Yaz" button while a web text field is focused but no keyboard is on screen.
    private func scheduleTypeButtonCheck(after seconds: Double) {
        typeButtonTask?.cancel()
        typeButtonTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.setTypeButtonVisible(self.editField != nil && !self.keyboardVisible && self.streamStats == nil)
        }
    }

    private func setTypeButtonVisible(_ visible: Bool) {
        if visible {
            guard typeButton.isHidden || typeButton.alpha < 1 else { return }
            typeButton.isHidden = false
            UIView.animate(withDuration: 0.2) { self.typeButton.alpha = 1 }
        } else {
            guard !typeButton.isHidden else { return }
            UIView.animate(withDuration: 0.2, animations: { self.typeButton.alpha = 0 }, completion: { _ in
                if self.typeButton.alpha == 0 {
                    self.typeButton.isHidden = true
                }
            })
        }
    }

    /// The app's own text box; whatever is typed goes into the focused web field.
    private func presentTextPrompt() {
        guard let field = editField ?? lastEditField, topPresenter() === self else { return }
        setTypeButtonVisible(false)

        let alert = UIAlertController(title: field.isPassword ? "Parolayı yaz" : "Metni yaz", message: field.label.isEmpty ? nil : field.label, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = field.value
            textField.isSecureTextEntry = field.isPassword
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.spellCheckingType = .no
            textField.clearButtonMode = .whileEditing
            switch field.type {
            case "email":
                textField.keyboardType = .emailAddress
                textField.textContentType = .emailAddress
            case "password":
                textField.textContentType = .password
            case "url":
                textField.keyboardType = .URL
            case "number", "tel":
                textField.keyboardType = .numbersAndPunctuation
            default:
                break
            }
        }
        alert.addAction(UIAlertAction(title: "Vazgeç", style: .cancel))
        let done = UIAlertAction(title: "Tamam", style: .default) { [weak self, weak alert] _ in
            self?.insertIntoWebField(alert?.textFields?.first?.text ?? "")
        }
        alert.addAction(done)
        alert.preferredAction = done
        present(alert, animated: true)
    }

    private func insertIntoWebField(_ text: String) {
        guard let target = editWebView ?? webView,
              let data = try? JSONEncoder().encode(text),
              let literal = String(data: data, encoding: .utf8)
        else { return }
        target.evaluateJavaScript("window.__sedefInsertText ? window.__sedefInsertText(\(literal)) : false") { [weak self] result, _ in
            if (result as? Bool) != true {
                self?.showToast("Metin kutusu bulunamadı. Kutuya tekrar dokun.")
            }
        }
    }

    // MARK: - Popups (sign-in windows)

    private func presentPopup(_ popup: WKWebView) {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        controller.view.addGestureRecognizer(TouchClockRecognizer.make())
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
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow, preferences)
            return
        }
        guard ["http", "https", "about", "blob", "data", "javascript"].contains(scheme) else {
            // App Store links, mailto: and the like go to the system.
            UIApplication.shared.open(url)
            decisionHandler(.cancel, preferences)
            return
        }
        if navigationAction.targetFrame?.isMainFrame != false {
            applyIdentity(to: preferences, for: url)
        }
        decisionHandler(.allow, preferences)
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

// MARK: - WKScriptMessageHandler

extension BrowserViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        handle(message: message)
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
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
