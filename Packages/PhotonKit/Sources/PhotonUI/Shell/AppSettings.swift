import Foundation
import Observation

/// What the Settings window changes. Kept in user defaults, which live on the internal disk.
///
/// A launch that sets any `PHOTON_` variable is a test or a measurement, so it reads and writes a domain
/// of its own and never changes the user's settings. `PHOTON_RESET_SETTINGS` starts that domain empty.
@MainActor
@Observable
public final class AppSettings {
    /// Thumbnail cache limits the Settings window offers, in gigabytes.
    public static let cacheLimitChoices = [5, 10, 20, 50, 100]
    public static let defaultCacheLimit = 20

    /// A video plays in its tile when the pointer rests on it. Reduce Motion turns previews off whatever
    /// this says.
    public var playsVideoPreviews: Bool {
        didSet { defaults?.set(playsVideoPreviews, forKey: Key.videoPreviews) }
    }
    /// Tiles keep each photo's shape rather than cropping it square. The View menu's Keep Aspect Ratio
    /// changes this too, so the choice lasts from one launch to the next.
    public var keepsAspectRatio: Bool {
        didSet { defaults?.set(keepsAspectRatio, forKey: Key.aspectRatio) }
    }
    /// How a folder, album or tag opens the first time. After that its own session decides.
    public var newSourceViewMode: BrowserViewMode {
        didSet { defaults?.set(newSourceViewMode.rawValue, forKey: Key.viewMode) }
    }
    /// Launch reopens the viewer if the last run ended in it.
    public var reopensViewer: Bool {
        didSet { defaults?.set(reopensViewer, forKey: Key.reopensViewer) }
    }
    /// The most the thumbnail cache keeps, in gigabytes. Small thumbnails are kept whatever this says.
    public var thumbnailCacheLimit: Int {
        didSet { defaults?.set(thumbnailCacheLimit, forKey: Key.cacheLimit) }
    }

    public var thumbnailCacheByteLimit: Int64 { Int64(thumbnailCacheLimit) << 30 }

    /// The browser in the app's window, once its library has opened, for the settings that act on it.
    public internal(set) var browser: BrowserModel?

    @ObservationIgnored private let defaults: UserDefaults?

    private enum Key {
        static let videoPreviews = "PlaysVideoPreviews"
        static let aspectRatio = "KeepsAspectRatio"
        static let viewMode = "NewSourceViewMode"
        static let reopensViewer = "ReopensViewer"
        static let cacheLimit = "ThumbnailCacheLimitGB"
    }

    /// - Parameter defaults: Nil keeps everything in memory, as tests do.
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        playsVideoPreviews = defaults?.object(forKey: Key.videoPreviews) as? Bool ?? true
        keepsAspectRatio = defaults?.object(forKey: Key.aspectRatio) as? Bool ?? false
        newSourceViewMode = (defaults?.object(forKey: Key.viewMode) as? Int).flatMap(BrowserViewMode.init) ?? .tiles
        reopensViewer = defaults?.object(forKey: Key.reopensViewer) as? Bool ?? true
        let limit = defaults?.object(forKey: Key.cacheLimit) as? Int ?? Self.defaultCacheLimit
        thumbnailCacheLimit = Self.cacheLimitChoices.contains(limit) ? limit : Self.defaultCacheLimit
    }

    /// The app's settings, from the domain this launch should use. Anything but the app itself, such as
    /// the package's tests, keeps them in memory, so that one test's choice can't reach the next.
    public static let shared = AppSettings(
        defaults: Bundle.main.bundleIdentifier == appIdentifier ? launchDefaults() : nil)

    static let appIdentifier = "app.photon.Photon"

    /// The suite a test or measurement uses instead of the user's own settings.
    static let developmentSuite = "app.photon.Photon.development"

    static func launchDefaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> UserDefaults {
        guard environment.keys.contains(where: { $0.hasPrefix("PHOTON_") || $0.hasPrefix("XCTest") }),
            let suite = UserDefaults(suiteName: developmentSuite)
        else { return .standard }
        if environment["PHOTON_RESET_SETTINGS"] != nil {
            suite.removePersistentDomain(forName: developmentSuite)
        }
        return suite
    }
}
