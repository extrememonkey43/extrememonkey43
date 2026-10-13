import WebKit

/// Flips WebKit's internal feature switches — the same ones Safari shows under
/// Settings ▸ Apps ▸ Safari ▸ Advanced ▸ Feature Flags. This is private API, looked up at
/// runtime so a WebKit build without it simply does nothing.
@MainActor
enum WebKitTweaks {
    /// Safari's "Prefer Page Rendering Updates near 60fps". On by default, which caps page
    /// rendering (requestAnimationFrame, gamepad polling loops) at 60 Hz.
    static let near60FPSKey = "PreferPageRenderingUpdatesNear60FPSEnabled"

    /// Extra WebRTC decoders. GeForce NOW only offers H.265/AV1 when the browser lists them.
    static let modernCodecKeys = ["WebRTCH265CodecEnabled", "WebRTCAV1CodecEnabled"]

    /// Must be applied to the configuration's preferences before the WKWebView is created.
    /// Returns the keys that were found and set.
    @discardableResult
    static func apply(_ settings: BrowserSettings, to preferences: WKPreferences) -> [String] {
        var changes: [String: Bool] = [:]
        if settings.unlockWebKit {
            changes[near60FPSKey] = false
        }
        if settings.modernCodecs {
            for key in modernCodecKeys {
                changes[key] = true
            }
        }
        return setFeatures(changes, on: preferences)
    }

    static func setFeatures(_ changes: [String: Bool], on preferences: WKPreferences) -> [String] {
        guard !changes.isEmpty else { return [] }
        let prefsClass = WKPreferences.self as AnyObject
        let keySelector = NSSelectorFromString("key")
        let collections = [
            ("_features", "_setEnabled:forFeature:"),
            ("_experimentalFeatures", "_setEnabled:forExperimentalFeature:"),
            ("_internalDebugFeatures", "_setEnabled:forInternalDebugFeature:"),
        ]
        var applied: [String] = []

        for (listName, setterName) in collections {
            let listSelector = NSSelectorFromString(listName)
            let setter = NSSelectorFromString(setterName)
            guard prefsClass.responds(to: listSelector), preferences.responds(to: setter),
                  let features = prefsClass.perform(listSelector)?.takeUnretainedValue() as? [NSObject]
            else { continue }

            // The setter takes a real BOOL, so call the IMP directly instead of perform(_:with:with:).
            typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
            let setEnabled = unsafeBitCast(preferences.method(for: setter), to: Setter.self)

            for feature in features where feature.responds(to: keySelector) {
                guard let key = feature.perform(keySelector)?.takeUnretainedValue() as? String,
                      let enabled = changes[key], !applied.contains(key)
                else { continue }
                setEnabled(preferences, setter, enabled, feature)
                applied.append(key)
            }
        }
        return applied
    }
}
