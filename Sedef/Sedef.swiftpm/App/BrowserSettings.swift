import Foundation
import CoreGraphics

/// How the browser introduces itself to GeForce NOW.
enum BrowserIdentity: String, CaseIterable, Identifiable {
    case windowsChrome
    case macSafari
    case iPad

    /// Keep in sync with the Chrome version in `userAgent`; the injected script mirrors it
    /// in `navigator.userAgentData`.
    static let chromeMajor = "140"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windowsChrome: return "Windows PC · Chrome"
        case .macSafari: return "Mac · Safari"
        case .iPad: return "iPad · Safari (değiştirme)"
        }
    }

    var userAgent: String? {
        switch self {
        case .windowsChrome:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(Self.chromeMajor).0.0.0 Safari/537.36"
        case .macSafari:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        case .iPad:
            return nil
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
    static let reportWindows = "sedef.reportWindows"
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
    var reportWindows: Bool
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
        identity: .windowsChrome,
        reportWindows: true,
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
            reportWindows: bool(SettingsKey.reportWindows, d.reportWindows),
            lockDisplay: bool(SettingsKey.lockDisplay, d.lockDisplay),
            unlockWebKit: bool(SettingsKey.unlockWebKit, d.unlockWebKit),
            modernCodecs: bool(SettingsKey.modernCodecs, d.modernCodecs),
            showHUD: bool(SettingsKey.showHUD, d.showHUD),
            showMenuButton: bool(SettingsKey.showMenuButton, d.showMenuButton),
            menuCorner: store.string(forKey: SettingsKey.menuCorner).flatMap(MenuCorner.init(rawValue:)) ?? d.menuCorner,
            homeURL: store.string(forKey: SettingsKey.homeURL) ?? d.homeURL
        )
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
            || reportWindows != other.reportWindows
            || unlockWebKit != other.unlockWebKit
            || modernCodecs != other.modernCodecs
    }

    func scriptConfig(screenPixels: CGSize) -> [String: Any] {
        var config: [String: Any] = [
            "fps": fps,
            "identity": identity.rawValue,
            "reportWindows": reportWindows,
            "chromeMajor": BrowserIdentity.chromeMajor,
        ]
        if let size = StreamResolution.find(resolutionID).pixels(screenPixels: screenPixels) {
            config["width"] = size.width
            config["height"] = size.height
        }
        return config
    }
}
