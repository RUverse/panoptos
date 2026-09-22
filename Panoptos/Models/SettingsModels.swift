import Foundation

enum WindowSwitcherTitleMode: String, Codable, CaseIterable, Identifiable {
    case always
    case whenNeeded

    var id: Self { self }

    var title: String {
        switch self {
        case .always: "Always"
        case .whenNeeded: "Only when needed"
        }
    }

    func showsTitles(applicationWindowCount: Int) -> Bool {
        self == .always || applicationWindowCount > 1
    }
}

enum WindowSwitcherSize {
    static let minimumScale = 1.0
    static let maximumScale = 3.0
    static let scaleStep = 0.25
    static let defaultScale = 1.5
    /// Two points around the 19-point icon at 1×. The switcher button is the
    /// selection and hover highlight, so its inset is deliberately tight.
    static let baseButtonHeight: CGFloat = 23
    static let outerVerticalAllowance: CGFloat = 11

    static func normalized(_ scale: Double) -> Double {
        guard scale.isFinite else { return minimumScale }
        let clamped = min(maximumScale, max(minimumScale, scale))
        return (clamped / scaleStep).rounded() * scaleStep
    }

    static func barHeight(for scale: Double) -> CGFloat {
        (baseButtonHeight * CGFloat(normalized(scale)) + outerVerticalAllowance).rounded(.up)
    }
}

struct PanoptosSettings: Codable, Equatable {
    var windowDragShortcuts: WindowDragShortcuts
    var sectionBarsFillAvailableWidth: Bool
    var sectionBarsCentered: Bool
    var showWindowMenuBars: Bool
    var showUnattachedWindowIcons: Bool
    var windowSwitcherUIScale: Double
    var windowSwitcherTitleMode: WindowSwitcherTitleMode
    var limitWindowSwitcherTitleCharacters: Bool
    var invokeWithoutActivation: Bool
    var keepMacAwake: Bool
    var keepScreenOn: Bool
    /// Whether the welcome tour has been dismissed. It defaults to false for a
    /// settings file that predates the tour, so an existing installation sees
    /// it once after updating; Skip and Done both record it.
    var hasCompletedOnboarding: Bool

    static let defaults = PanoptosSettings(
        attachAllApplicationWindowsWithControlShift: true,
        sectionBarsFillAvailableWidth: false,
        sectionBarsCentered: true,
        // Menu bars are opt-in: the switcher is what every section needs, and
        // the menu strip costs window height. The Panoptos menu bar item and
        // the Appearance tab turn them on.
        showWindowMenuBars: false,
        showUnattachedWindowIcons: true,
        windowSwitcherUIScale: WindowSwitcherSize.defaultScale,
        windowSwitcherTitleMode: .whenNeeded,
        limitWindowSwitcherTitleCharacters: false,
        invokeWithoutActivation: false,
        keepMacAwake: false,
        keepScreenOn: false,
        hasCompletedOnboarding: false
    )

    // "showWindowManager" was removed: Panoptos is always active while running,
    // so an older settings file's value for it is simply ignored.
    private enum CodingKeys: String, CodingKey {
        case attachAllApplicationWindowsWithControlShift
        case windowDragShortcuts
        case sectionBarsFillAvailableWidth
        case sectionBarsCentered
        case showWindowMenuBars
        case showUnattachedWindowIcons
        case windowSwitcherUIScale
        case windowSwitcherTitleMode
        case limitWindowSwitcherTitleCharacters = "limitWindowSwitcherTitlesToSixCharacters"
        case invokeWithoutActivation
        case keepMacAwake
        case keepScreenOn
        case hasCompletedOnboarding
    }

    init(
        attachAllApplicationWindowsWithControlShift: Bool,
        sectionBarsFillAvailableWidth: Bool,
        sectionBarsCentered: Bool,
        showWindowMenuBars: Bool = false,
        showUnattachedWindowIcons: Bool = true,
        windowSwitcherUIScale: Double = WindowSwitcherSize.defaultScale,
        windowSwitcherTitleMode: WindowSwitcherTitleMode,
        limitWindowSwitcherTitleCharacters: Bool,
        invokeWithoutActivation: Bool,
        keepMacAwake: Bool = false,
        keepScreenOn: Bool = false,
        hasCompletedOnboarding: Bool = false,
        windowDragShortcuts: WindowDragShortcuts? = nil
    ) {
        self.windowDragShortcuts = windowDragShortcuts ?? WindowDragShortcuts(
            attachWindow: WindowDragShortcuts.defaults.attachWindow,
            attachApplicationWindows: attachAllApplicationWindowsWithControlShift
                ? WindowDragShortcuts.defaults.attachApplicationWindows
                : nil
        )
        self.sectionBarsFillAvailableWidth = sectionBarsFillAvailableWidth
        self.sectionBarsCentered = sectionBarsCentered
        self.showWindowMenuBars = showWindowMenuBars
        self.showUnattachedWindowIcons = showUnattachedWindowIcons
        self.windowSwitcherUIScale = WindowSwitcherSize.normalized(windowSwitcherUIScale)
        self.windowSwitcherTitleMode = windowSwitcherTitleMode
        self.limitWindowSwitcherTitleCharacters = limitWindowSwitcherTitleCharacters
        self.invokeWithoutActivation = invokeWithoutActivation
        self.keepMacAwake = keepMacAwake || keepScreenOn
        self.keepScreenOn = keepScreenOn
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        let legacyAttachAllApplicationWindows = try container.decodeIfPresent(
            Bool.self,
            forKey: .attachAllApplicationWindowsWithControlShift
        ) ?? defaults.attachAllApplicationWindowsWithControlShift
        windowDragShortcuts = try container.decodeIfPresent(
            WindowDragShortcuts.self,
            forKey: .windowDragShortcuts
        ) ?? WindowDragShortcuts(
            attachWindow: WindowDragShortcuts.defaults.attachWindow,
            attachApplicationWindows: legacyAttachAllApplicationWindows
                ? WindowDragShortcuts.defaults.attachApplicationWindows
                : nil
        )
        sectionBarsFillAvailableWidth = try container.decodeIfPresent(Bool.self, forKey: .sectionBarsFillAvailableWidth)
            ?? defaults.sectionBarsFillAvailableWidth
        sectionBarsCentered = try container.decodeIfPresent(Bool.self, forKey: .sectionBarsCentered)
            ?? defaults.sectionBarsCentered
        showWindowMenuBars = try container.decodeIfPresent(Bool.self, forKey: .showWindowMenuBars)
            ?? defaults.showWindowMenuBars
        showUnattachedWindowIcons = try container.decodeIfPresent(Bool.self, forKey: .showUnattachedWindowIcons)
            ?? defaults.showUnattachedWindowIcons
        windowSwitcherUIScale = WindowSwitcherSize.normalized(
            try container.decodeIfPresent(Double.self, forKey: .windowSwitcherUIScale)
                ?? defaults.windowSwitcherUIScale
        )
        windowSwitcherTitleMode = try container.decodeIfPresent(
            WindowSwitcherTitleMode.self,
            forKey: .windowSwitcherTitleMode
        ) ?? defaults.windowSwitcherTitleMode
        limitWindowSwitcherTitleCharacters = try container.decodeIfPresent(
            Bool.self,
            forKey: .limitWindowSwitcherTitleCharacters
        ) ?? defaults.limitWindowSwitcherTitleCharacters
        invokeWithoutActivation = try container.decodeIfPresent(Bool.self, forKey: .invokeWithoutActivation)
            ?? defaults.invokeWithoutActivation
        keepScreenOn = try container.decodeIfPresent(Bool.self, forKey: .keepScreenOn)
            ?? defaults.keepScreenOn
        let savedKeepMacAwake = try container.decodeIfPresent(Bool.self, forKey: .keepMacAwake)
            ?? defaults.keepMacAwake
        keepMacAwake = savedKeepMacAwake || keepScreenOn
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)
            ?? defaults.hasCompletedOnboarding
    }

    var attachAllApplicationWindowsWithControlShift: Bool {
        windowDragShortcuts.attachApplicationWindows != nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            attachAllApplicationWindowsWithControlShift,
            forKey: .attachAllApplicationWindowsWithControlShift
        )
        try container.encode(windowDragShortcuts, forKey: .windowDragShortcuts)
        try container.encode(sectionBarsFillAvailableWidth, forKey: .sectionBarsFillAvailableWidth)
        try container.encode(sectionBarsCentered, forKey: .sectionBarsCentered)
        try container.encode(showWindowMenuBars, forKey: .showWindowMenuBars)
        try container.encode(showUnattachedWindowIcons, forKey: .showUnattachedWindowIcons)
        try container.encode(windowSwitcherUIScale, forKey: .windowSwitcherUIScale)
        try container.encode(windowSwitcherTitleMode, forKey: .windowSwitcherTitleMode)
        try container.encode(limitWindowSwitcherTitleCharacters, forKey: .limitWindowSwitcherTitleCharacters)
        try container.encode(invokeWithoutActivation, forKey: .invokeWithoutActivation)
        try container.encode(keepMacAwake, forKey: .keepMacAwake)
        try container.encode(keepScreenOn, forKey: .keepScreenOn)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
    }
}

struct SettingsPersistence {
    let url: URL
    let fallbackURL: URL?

    init(url: URL, fallbackURL: URL? = nil) {
        self.url = url
        self.fallbackURL = fallbackURL
    }

    static var live: SettingsPersistence {
        SettingsPersistence(
            url: ApplicationSupportMigration.liveDirectory.appendingPathComponent("settings.json"),
            fallbackURL: ApplicationSupportMigration.legacyDirectory.appendingPathComponent("settings.json")
        )
    }

    func load() -> PanoptosSettings {
        for source in [url, fallbackURL].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: source),
                  let settings = try? JSONDecoder().decode(PanoptosSettings.self, from: data) else { continue }
            return settings
        }
        return .defaults
    }

    func save(_ settings: PanoptosSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(settings)
        try data.write(to: url, options: .atomic)
    }
}
