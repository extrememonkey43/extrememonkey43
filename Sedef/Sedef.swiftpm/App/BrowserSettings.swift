import Foundation
import CoreGraphics

/// How the browser introduces itself to GeForce NOW.
///
/// GeForce NOW fingerprints the browser engine (worker `navigator.platform`, system voices,
/// `window.chrome`, …) and flags a Chrome/Windows disguise on WebKit as forged; it then drops the
/// browser version and refuses to stream. So Sedef stays a real WebKit browser and only changes
/// what GeForce NOW checks for its iPad and Mac Safari paths.
enum BrowserIdentity: String, CaseIterable, Identifiable {
    /// Real iPad Safari, presented as a Home Screen web app: GeForce NOW only streams on iPad
    /// from one (`navigator.standalone`).
    case iPad
    /// Mac Safari: no touch points, MacIntel platform, `window.safari`.
    case macSafari

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iPad: return "iPad · ana ekran uygulaması"
        case .macSafari: return "Mac · Safari (deneysel)"
        }
    }

    /// Pages the identity is shown to. Sign-in pages (NVIDIA, Google, Apple…) always see the
    /// plain iPad Safari.
    static func appliesTo(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "geforcenow.com" || host.hasSuffix(".geforcenow.com")
    }
}

/// What the session request tells GeForce NOW's servers about the device. The servers cap
/// iPad/Safari clients at 60 FPS, whatever the request asks for.
enum ServerProfile: String, CaseIterable, Identifiable {
    /// A Windows PC running Chrome: OS, device type, browser and version headers (default).
    case windowsChrome
    /// Only the OS header says Windows.
    case windowsOS
    /// Headers as GeForce NOW sent them (iPad).
    case iPad = "ipad"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windowsChrome: return "Windows PC · Chrome"
        case .windowsOS: return "Yalnızca işletim sistemi: Windows"
        case .iPad: return "iPad (değiştirme)"
        }
    }
}

/// Stream resolution written into the GeForce NOW session request.
struct StreamResolution: Identifiable, Hashable {
    let id: String
    let title: String
    let width: Int
    let height: Int

    static let automatic = StreamResolution(id: "auto", title: "Otomatik (GFN seçsin)", width: 0, height: 0)
    static let native = StreamResolution(id: "native", title: "Ekranın kendi çözünürlüğü (deneysel)", width: 0, height: 0)

    static let all: [StreamResolution] = [
        automatic,
        StreamResolution(id: "2560x1440", title: "2560 × 1440 (16:9)", width: 2560, height: 1440),
        StreamResolution(id: "2560x1600", title: "2560 × 1600 (16:10)", width: 2560, height: 1600),
        StreamResolution(id: "2048x1536", title: "2048 × 1536 (4:3, iPad oranı)", width: 2048, height: 1536),
        StreamResolution(id: "1920x1080", title: "1920 × 1080 (16:9)", width: 1920, height: 1080),
        StreamResolution(id: "1600x1200", title: "1600 × 1200 (4:3)", width: 1600, height: 1200),
        native,
    ]

    static func find(_ id: String) -> StreamResolution {
        all.first { $0.id == id } ?? automatic
    }

    /// Pixels to request, or nil to keep what GeForce NOW picked.
    /// `screenPixels` is the panel size in pixels (UIScreen.nativeBounds).
    func pixels(screenPixels: CGSize) -> (width: Int, height: Int)? {
        if id == StreamResolution.native.id {
            let long = Int(max(screenPixels.width, screenPixels.height))
            let short = Int(min(screenPixels.width, screenPixels.height))
            return long > 0 ? (long, short) : nil
        }
        return width > 0 ? (width, height) : nil
    }
}

enum MenuCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Sol üst"
        case .topRight: return "Sağ üst"
        case .bottomLeft: return "Sol alt"
        case .bottomRight: return "Sağ alt"
        }
    }
}

enum SettingsKey {
    static let fps = "sedef.fps"
    static let resolution = "sedef.resolution"
    static let identity = "sedef.identity"
    static let serverProfile = "sedef.serverProfile"
    /// Replaced by `serverProfile`; read once to carry an explicit "off" over.
    static let legacyReportWindows = "sedef.reportWindows"
    static let lockDisplay = "sedef.lockDisplay"
    static let unlockWebKit = "sedef.unlockWebKit"
    static let modernCodecs = "sedef.modernCodecs"
    static let showHUD = "sedef.showHUD"
    static let showMenuButton = "sedef.showMenuButton"
    static let menuCorner = "sedef.menuCorner"
    static let homeURL = "sedef.homeURL"
    static let seenTip = "sedef.seenTip"
}

/// Snapshot of the user's settings. SettingsView edits the same keys through @AppStorage.
struct BrowserSettings: Equatable {
    /// 0 means "leave GeForce NOW's choice alone".
    var fps: Int
    var resolutionID: String
    var identity: BrowserIdentity
    var serverProfile: ServerProfile
    var lockDisplay: Bool
    var unlockWebKit: Bool
    var modernCodecs: Bool
    var showHUD: Bool
    var showMenuButton: Bool
    var menuCorner: MenuCorner
    var homeURL: String

    static let defaultHomeURL = "https://play.geforcenow.com"

    static let defaults = BrowserSettings(
        fps: 120,
        resolutionID: StreamResolution.automatic.id,
        identity: .iPad,
        serverProfile: .windowsChrome,
        lockDisplay: true,
        unlockWebKit: true,
        modernCodecs: false,
        showHUD: true,
        showMenuButton: true,
        menuCorner: .topLeft,
        homeURL: defaultHomeURL
    )

    static func load(from store: UserDefaults = .standard) -> BrowserSettings {
        let d = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            store.object(forKey: key) == nil ? fallback : store.bool(forKey: key)
        }
        return BrowserSettings(
            fps: store.object(forKey: SettingsKey.fps) == nil ? d.fps : store.integer(forKey: SettingsKey.fps),
            resolutionID: store.string(forKey: SettingsKey.resolution) ?? d.resolutionID,
            identity: store.string(forKey: SettingsKey.identity).flatMap(BrowserIdentity.init(rawValue:)) ?? d.identity,
            serverProfile: loadServerProfile(from: store, fallback: d.serverProfile),
            lockDisplay: bool(SettingsKey.lockDisplay, d.lockDisplay),
            unlockWebKit: bool(SettingsKey.unlockWebKit, d.unlockWebKit),
            modernCodecs: bool(SettingsKey.modernCodecs, d.modernCodecs),
            showHUD: bool(SettingsKey.showHUD, d.showHUD),
            showMenuButton: bool(SettingsKey.showMenuButton, d.showMenuButton),
            menuCorner: store.string(forKey: SettingsKey.menuCorner).flatMap(MenuCorner.init(rawValue:)) ?? d.menuCorner,
            homeURL: store.string(forKey: SettingsKey.homeURL) ?? d.homeURL
        )
    }

    private static func loadServerProfile(from store: UserDefaults, fallback: ServerProfile) -> ServerProfile {
        if let raw = store.string(forKey: SettingsKey.serverProfile), let profile = ServerProfile(rawValue: raw) {
            return profile
        }
        if store.object(forKey: SettingsKey.legacyReportWindows) != nil, !store.bool(forKey: SettingsKey.legacyReportWindows) {
            return .iPad
        }
        return fallback
    }

    var homePageURL: URL {
        let trimmed = homeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            return url
        }
        return URL(string: Self.defaultHomeURL)!
    }

    /// Changing any of these needs a fresh WKWebView (scripts, user agent and WebKit flags are
    /// fixed when the web view is created).
    func needsNewWebView(comparedTo other: BrowserSettings) -> Bool {
        fps != other.fps
            || resolutionID != other.resolutionID
            || identity != other.identity
            || serverProfile != other.serverProfile
            || unlockWebKit != other.unlockWebKit
            || modernCodecs != other.modernCodecs
    }

    func scriptConfig(screenPixels: CGSize) -> [String: Any] {
        var config: [String: Any] = [
            "fps": fps,
            "identity": identity.rawValue,
            "serverProfile": serverProfile.rawValue,
        ]
        if let size = StreamResolution.find(resolutionID).pixels(screenPixels: screenPixels) {
            config["width"] = size.width
            config["height"] = size.height
        }
        return config
    }
}
