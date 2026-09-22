import AppKit
import Carbon.HIToolbox
import Foundation

enum ShortcutCommand: String, Codable, CaseIterable, Identifiable {
    case cycleNextWindow
    case cyclePreviousWindow
    case focusPreviousSection
    case focusNextSection
    case cycleWindowLeft
    case cycleWindowRight
    case moveApplicationEarlier
    case moveApplicationLater
    case spanWindowLeft
    case spanWindowRight
    case toggleSectionFocus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cycleNextWindow: "Cycle next window"
        case .cyclePreviousWindow: "Cycle previous window"
        case .focusPreviousSection: "Focus window in previous section"
        case .focusNextSection: "Focus window in next section"
        case .cycleWindowLeft: "Cycle window left"
        case .cycleWindowRight: "Cycle window right"
        case .moveApplicationEarlier: "Move application earlier in switcher"
        case .moveApplicationLater: "Move application later in switcher"
        case .spanWindowLeft: "Span window left"
        case .spanWindowRight: "Span window right"
        case .toggleSectionFocus: "Toggle section focus"
        }
    }

    var group: ShortcutGroup {
        switch self {
        case .cycleNextWindow, .cyclePreviousWindow, .focusPreviousSection, .focusNextSection: .windowSwitching
        case .cycleWindowLeft, .cycleWindowRight, .moveApplicationEarlier, .moveApplicationLater,
             .spanWindowLeft, .spanWindowRight: .windowMovement
        case .toggleSectionFocus: .sectionFocus
        }
    }

    var defaultShortcut: GlobalShortcut? {
        let windowCycleModifiers: ShortcutModifiers = [.control, .option]
        let windowMovementModifiers: ShortcutModifiers = [.control, .option, .shift]
        let windowSpanModifiers: ShortcutModifiers = [.control, .option, .command]
        let sectionFocusModifiers: ShortcutModifiers = [.control, .option]
        switch self {
        case .cycleNextWindow:
            return GlobalShortcut(keyCode: UInt32(kVK_DownArrow), keyLabel: "↓", modifiers: windowCycleModifiers)
        case .cyclePreviousWindow:
            return GlobalShortcut(keyCode: UInt32(kVK_UpArrow), keyLabel: "↑", modifiers: windowCycleModifiers)
        case .focusPreviousSection:
            return GlobalShortcut(keyCode: UInt32(kVK_LeftArrow), keyLabel: "←", modifiers: sectionFocusModifiers)
        case .focusNextSection:
            return GlobalShortcut(keyCode: UInt32(kVK_RightArrow), keyLabel: "→", modifiers: sectionFocusModifiers)
        case .cycleWindowLeft:
            return GlobalShortcut(keyCode: UInt32(kVK_LeftArrow), keyLabel: "←", modifiers: windowMovementModifiers)
        case .cycleWindowRight:
            return GlobalShortcut(keyCode: UInt32(kVK_RightArrow), keyLabel: "→", modifiers: windowMovementModifiers)
        case .moveApplicationEarlier:
            return GlobalShortcut(keyCode: UInt32(kVK_UpArrow), keyLabel: "↑", modifiers: windowMovementModifiers)
        case .moveApplicationLater:
            return GlobalShortcut(keyCode: UInt32(kVK_DownArrow), keyLabel: "↓", modifiers: windowMovementModifiers)
        case .spanWindowLeft:
            return GlobalShortcut(keyCode: UInt32(kVK_LeftArrow), keyLabel: "←", modifiers: windowSpanModifiers)
        case .spanWindowRight:
            return GlobalShortcut(keyCode: UInt32(kVK_RightArrow), keyLabel: "→", modifiers: windowSpanModifiers)
        case .toggleSectionFocus:
            return GlobalShortcut(keyCode: UInt32(kVK_ANSI_F), keyLabel: "F", modifiers: sectionFocusModifiers)
        }
    }
}

/// The user's shortcut bindings plus the commands they explicitly disabled.
/// A disabled command has no entry in `bindings`, which is also what a command
/// that never had a binding looks like; `disabledCommands` is what lets a
/// later migration install a new default for the latter and not the former.
struct ShortcutState: Equatable {
    var bindings: [ShortcutCommand: GlobalShortcut]
    var disabledCommands: Set<ShortcutCommand>

    static var defaults: ShortcutState {
        ShortcutState(bindings: ShortcutPersistence.defaults, disabledCommands: [])
    }
}

enum ShortcutGroup: String, CaseIterable, Identifiable {
    case windowSwitching
    case windowMovement
    case sectionFocus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windowSwitching: "Window switching"
        case .windowMovement: "Window movement"
        case .sectionFocus: "Section focus"
        }
    }

    var description: String {
        switch self {
        case .windowSwitching: "Focus windows within the same section or across neighboring sections."
        case .windowMovement: "Move or extend the focused window across sections, or reorder its application in the switcher."
        case .sectionFocus: "Give the focused window's section the screen to itself by hiding the other sections."
        }
    }

    var commands: [ShortcutCommand] {
        ShortcutCommand.allCases.filter { $0.group == self }
    }
}

struct ShortcutModifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt32

    static let control = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let shift = ShortcutModifiers(rawValue: 1 << 2)
    static let command = ShortcutModifiers(rawValue: 1 << 3)

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var value: ShortcutModifiers = []
        let flags = eventFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.command) { value.insert(.command) }
        self = value
    }

    var displayText: String {
        var value = ""
        if contains(.control) { value += "⌃" }
        if contains(.option) { value += "⌥" }
        if contains(.shift) { value += "⇧" }
        if contains(.command) { value += "⌘" }
        return value
    }

    var carbonFlags: UInt32 {
        var value: UInt32 = 0
        if contains(.control) { value |= UInt32(controlKey) }
        if contains(.option) { value |= UInt32(optionKey) }
        if contains(.shift) { value |= UInt32(shiftKey) }
        if contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    var hasNonShiftModifier: Bool {
        !intersection([.control, .option, .command]).isEmpty
    }
}

enum WindowDragShortcutAction: String, CaseIterable, Identifiable {
    case attachWindow
    case attachApplicationWindows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attachWindow: "Attach dragged window"
        case .attachApplicationWindows: "Attach all application windows"
        }
    }

    var description: String {
        switch self {
        case .attachWindow: "Hold these keys when finishing a window drag."
        case .attachApplicationWindows: "Hold these keys to attach every eligible window from the dragged app."
        }
    }
}

struct WindowDragShortcuts: Codable, Equatable {
    var attachWindow: ShortcutModifiers?
    var attachApplicationWindows: ShortcutModifiers?

    static let defaults = WindowDragShortcuts(
        attachWindow: [.shift],
        attachApplicationWindows: [.control, .shift]
    )

    subscript(action: WindowDragShortcutAction) -> ShortcutModifiers? {
        get {
            switch action {
            case .attachWindow: attachWindow
            case .attachApplicationWindows: attachApplicationWindows
            }
        }
        set {
            switch action {
            case .attachWindow: attachWindow = newValue
            case .attachApplicationWindows: attachApplicationWindows = newValue
            }
        }
    }

    func action(for modifiers: ShortcutModifiers) -> WindowDragShortcutAction? {
        if let attachApplicationWindows,
           !attachApplicationWindows.isEmpty,
           modifiers == attachApplicationWindows {
            return .attachApplicationWindows
        }
        if let attachWindow, !attachWindow.isEmpty, modifiers == attachWindow {
            return .attachWindow
        }
        return nil
    }
}

struct GlobalShortcut: Codable, Hashable {
    let keyCode: UInt32
    let keyLabel: String
    let modifiers: ShortcutModifiers

    var displayText: String { modifiers.displayText + keyLabel }

    func conflicts(with other: GlobalShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    init(keyCode: UInt32, keyLabel: String, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        keyLabel = Self.label(for: event)
        modifiers = ShortcutModifiers(eventFlags: event.modifierFlags)
    }

    private static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Space: "Space"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_Escape: "⎋"
        case kVK_Home: "↖"
        case kVK_End: "↘"
        case kVK_PageUp: "⇞"
        case kVK_PageDown: "⇟"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        default:
            if let characters = event.charactersIgnoringModifiers?.uppercased(), !characters.isEmpty {
                characters
            } else {
                "Key " + String(event.keyCode)
            }
        }
    }
}

struct ShortcutPersistence {
    let url: URL
    let fallbackURL: URL?

    init(url: URL, fallbackURL: URL? = nil) {
        self.url = url
        self.fallbackURL = fallbackURL
    }

    private struct StoredShortcuts: Codable {
        let version: Int
        let shortcuts: [ShortcutCommand: GlobalShortcut]
        /// Absent in files written before version 8, which decode as "nothing
        /// explicitly disabled". Unknown command names from a newer app are
        /// dropped rather than failing the whole file.
        let disabledCommands: Set<ShortcutCommand>

        private enum CodingKeys: String, CodingKey {
            case version
            case shortcuts
            case disabledCommands
        }

        init(
            version: Int,
            shortcuts: [ShortcutCommand: GlobalShortcut],
            disabledCommands: Set<ShortcutCommand> = []
        ) {
            self.version = version
            self.shortcuts = shortcuts
            self.disabledCommands = disabledCommands
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            shortcuts = try container.decode(ShortcutBindings.self, forKey: .shortcuts).values
            let rawDisabled = try container.decodeIfPresent([String].self, forKey: .disabledCommands) ?? []
            disabledCommands = Set(rawDisabled.compactMap(ShortcutCommand.init(rawValue:)))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(ShortcutBindings(values: shortcuts), forKey: .shortcuts)
            try container.encode(
                ShortcutCommand.allCases.filter(disabledCommands.contains).map(\.rawValue),
                forKey: .disabledCommands
            )
        }
    }

    /// Swift encodes dictionaries with enum keys as alternating key/value arrays.
    /// Decode that representation explicitly so commands added by a newer app are
    /// ignored instead of making every recognized binding undecodable.
    private struct ShortcutBindings: Codable {
        let values: [ShortcutCommand: GlobalShortcut]

        init(values: [ShortcutCommand: GlobalShortcut]) {
            self.values = values
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var decoded: [ShortcutCommand: GlobalShortcut] = [:]
            while !container.isAtEnd {
                let rawCommand = try container.decode(String.self)
                let shortcut = try container.decode(GlobalShortcut.self)
                if let command = ShortcutCommand(rawValue: rawCommand) {
                    decoded[command] = shortcut
                }
            }
            values = decoded
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            for command in ShortcutCommand.allCases {
                guard let shortcut = values[command] else { continue }
                try container.encode(command.rawValue)
                try container.encode(shortcut)
            }
        }
    }

    /// Version 8 gave the span commands their ⌃⌥⌘←/→ defaults and started
    /// recording explicitly disabled commands.
    private static let currentVersion = 8

    static var live: ShortcutPersistence {
        ShortcutPersistence(
            url: ApplicationSupportMigration.liveDirectory.appendingPathComponent("shortcuts.json"),
            fallbackURL: ApplicationSupportMigration.legacyDirectory.appendingPathComponent("shortcuts.json")
        )
    }

    func load() -> [ShortcutCommand: GlobalShortcut] {
        loadState().bindings
    }

    func loadState() -> ShortcutState {
        guard let data = [url, fallbackURL]
            .compactMap({ $0 })
            .compactMap({ try? Data(contentsOf: $0) })
            .first(where: { data in
                (try? JSONDecoder().decode(StoredShortcuts.self, from: data)) != nil
                    || (try? JSONDecoder().decode([ShortcutCommand: GlobalShortcut].self, from: data)) != nil
            }) else { return .defaults }
        if let stored = try? JSONDecoder().decode(StoredShortcuts.self, from: data) {
            guard stored.version < Self.currentVersion else {
                return ShortcutState(bindings: stored.shortcuts, disabledCommands: stored.disabledCommands)
            }
            let migrated = ShortcutState(
                bindings: Self.migratePreviousVersion(
                    stored.shortcuts,
                    disabledCommands: stored.disabledCommands
                ),
                disabledCommands: stored.disabledCommands
            )
            try? save(migrated)
            return migrated
        }
        guard let loaded = try? JSONDecoder().decode([ShortcutCommand: GlobalShortcut].self, from: data) else {
            return .defaults
        }
        let migrated = ShortcutState(bindings: Self.migrateUnversioned(loaded), disabledCommands: [])
        try? save(migrated)
        return migrated
    }

    func save(_ shortcuts: [ShortcutCommand: GlobalShortcut]) throws {
        try save(ShortcutState(bindings: shortcuts, disabledCommands: []))
    }

    func save(_ state: ShortcutState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(StoredShortcuts(
            version: Self.currentVersion,
            shortcuts: state.bindings,
            disabledCommands: state.disabledCommands
        ))
        try data.write(to: url, options: .atomic)
    }

    static var defaults: [ShortcutCommand: GlobalShortcut] {
        Dictionary(uniqueKeysWithValues: ShortcutCommand.allCases.compactMap { command in
            command.defaultShortcut.map { (command, $0) }
        })
    }

    private static func migrateUnversioned(
        _ shortcuts: [ShortcutCommand: GlobalShortcut]
    ) -> [ShortcutCommand: GlobalShortcut] {
        var migrated = migratePreviousVersion(shortcuts)

        for command in [ShortcutCommand.focusPreviousSection, .focusNextSection] {
            guard let defaultShortcut = command.defaultShortcut,
                  !migrated.values.contains(where: { $0.conflicts(with: defaultShortcut) }) else { continue }
            migrated[command] = defaultShortcut
        }
        return migrated
    }

    private static func migratePreviousVersion(
        _ shortcuts: [ShortcutCommand: GlobalShortcut],
        disabledCommands: Set<ShortcutCommand> = []
    ) -> [ShortcutCommand: GlobalShortcut] {
        var migrated = shortcuts

        for command in [ShortcutCommand.spanWindowLeft, .spanWindowRight] {
            if migrated[command].map(isHistoricalSpanDefault) == true {
                migrated.removeValue(forKey: command)
            }
        }
        for command in [ShortcutCommand.cycleNextWindow, .cyclePreviousWindow] {
            migrate(
                command,
                from: versionThreeDefault(for: command),
                to: command.defaultShortcut,
                in: &migrated
            )
        }
        migratePreviousWindowCycleDefaults(in: &migrated)
        for command in [ShortcutCommand.cycleWindowLeft, .cycleWindowRight] {
            migrate(
                command,
                from: previousMovementDefault(for: command),
                to: command.defaultShortcut,
                in: &migrated
            )
        }
        // A command that did not exist when the file was written has no
        // binding to preserve, so it starts on its default — unless the user
        // already gave those keys to something else, or explicitly disabled
        // the command in a file that records that.
        //
        // The span commands had no default before version 8, so an absent
        // entry in an older file almost always means "never bound". A user
        // who bound and later cleared one receives the new default once;
        // files from version 8 on record the disable and are left alone.
        for command in [
            ShortcutCommand.toggleSectionFocus,
            .moveApplicationEarlier,
            .moveApplicationLater,
            .spanWindowLeft,
            .spanWindowRight
        ] {
            guard migrated[command] == nil,
                  !disabledCommands.contains(command),
                  let defaultShortcut = command.defaultShortcut,
                  !migrated.values.contains(where: { $0.conflicts(with: defaultShortcut) }) else { continue }
            migrated[command] = defaultShortcut
        }
        return migrated
    }

    private static func migrate(
        _ command: ShortcutCommand,
        from historicalShortcut: GlobalShortcut?,
        to newShortcut: GlobalShortcut?,
        in shortcuts: inout [ShortcutCommand: GlobalShortcut]
    ) {
        guard let historicalShortcut,
              shortcuts[command] == historicalShortcut,
              let newShortcut else { return }
        let conflictsWithUserBinding = shortcuts.contains { otherCommand, shortcut in
            otherCommand != command && shortcut.conflicts(with: newShortcut)
        }
        guard !conflictsWithUserBinding else { return }
        shortcuts[command] = newShortcut
    }

    private static func migratePreviousWindowCycleDefaults(
        in shortcuts: inout [ShortcutCommand: GlobalShortcut]
    ) {
        let previousNext = GlobalShortcut(
            keyCode: UInt32(kVK_UpArrow),
            keyLabel: "↑",
            modifiers: [.control, .option]
        )
        let previousPrevious = GlobalShortcut(
            keyCode: UInt32(kVK_DownArrow),
            keyLabel: "↓",
            modifiers: [.control, .option]
        )
        let nextUsedPreviousDefault = shortcuts[.cycleNextWindow] == previousNext
        let previousUsedPreviousDefault = shortcuts[.cyclePreviousWindow] == previousPrevious

        if nextUsedPreviousDefault && previousUsedPreviousDefault {
            shortcuts[.cycleNextWindow] = ShortcutCommand.cycleNextWindow.defaultShortcut
            shortcuts[.cyclePreviousWindow] = ShortcutCommand.cyclePreviousWindow.defaultShortcut
            return
        }
        if nextUsedPreviousDefault {
            migrate(
                .cycleNextWindow,
                from: previousNext,
                to: ShortcutCommand.cycleNextWindow.defaultShortcut,
                in: &shortcuts
            )
        }
        if previousUsedPreviousDefault {
            migrate(
                .cyclePreviousWindow,
                from: previousPrevious,
                to: ShortcutCommand.cyclePreviousWindow.defaultShortcut,
                in: &shortcuts
            )
        }
    }

    private static func isHistoricalSpanDefault(_ shortcut: GlobalShortcut) -> Bool {
        let spanModifiers: [ShortcutModifiers] = [
            [.control, .option, .shift],
            [.control, .option, .shift, .command]
        ]
        return spanModifiers.contains(shortcut.modifiers)
            && [UInt32(kVK_LeftArrow), UInt32(kVK_RightArrow)].contains(shortcut.keyCode)
    }

    private static func versionThreeDefault(for command: ShortcutCommand) -> GlobalShortcut? {
        let modifiers: ShortcutModifiers = [.control, .option, .shift]
        switch command {
        case .cycleNextWindow:
            return GlobalShortcut(keyCode: UInt32(kVK_UpArrow), keyLabel: "↑", modifiers: modifiers)
        case .cyclePreviousWindow:
            return GlobalShortcut(keyCode: UInt32(kVK_DownArrow), keyLabel: "↓", modifiers: modifiers)
        case .focusPreviousSection, .focusNextSection, .cycleWindowLeft, .cycleWindowRight,
             .moveApplicationEarlier, .moveApplicationLater, .spanWindowLeft, .spanWindowRight,
             .toggleSectionFocus:
            return nil
        }
    }

    private static func previousMovementDefault(for command: ShortcutCommand) -> GlobalShortcut? {
        let cycleModifiers: ShortcutModifiers = [.control, .option]
        switch command {
        case .cycleWindowLeft:
            return GlobalShortcut(keyCode: UInt32(kVK_LeftArrow), keyLabel: "←", modifiers: cycleModifiers)
        case .cycleWindowRight:
            return GlobalShortcut(keyCode: UInt32(kVK_RightArrow), keyLabel: "→", modifiers: cycleModifiers)
        case .cycleNextWindow, .cyclePreviousWindow, .focusPreviousSection, .focusNextSection,
             .moveApplicationEarlier, .moveApplicationLater, .spanWindowLeft, .spanWindowRight,
             .toggleSectionFocus:
            return nil
        }
    }

}

protocol ShortcutRegistering: AnyObject {
    var handler: ((ShortcutCommand) -> Void)? { get set }
    func update(_ shortcuts: [ShortcutCommand: GlobalShortcut]) -> [ShortcutCommand: OSStatus]
}

final class GlobalShortcutRegistrar: ShortcutRegistering {
    var handler: ((ShortcutCommand) -> Void)?

    private let signature: OSType = 0x50414E4F // PANO
    private var eventHandler: EventHandlerRef?
    private var registered: [ShortcutCommand: EventHotKeyRef] = [:]
    private var commandsByID: [UInt32: ShortcutCommand] = [:]

    func update(_ shortcuts: [ShortcutCommand: GlobalShortcut]) -> [ShortcutCommand: OSStatus] {
        unregisterAll()
        let installationStatus = installEventHandlerIfNeeded()
        guard installationStatus == noErr else {
            return Dictionary(uniqueKeysWithValues: shortcuts.keys.map { ($0, installationStatus) })
        }

        var failures: [ShortcutCommand: OSStatus] = [:]
        for (index, command) in ShortcutCommand.allCases.enumerated() {
            guard let shortcut = shortcuts[command] else { continue }
            let numericID = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers.carbonFlags,
                EventHotKeyID(signature: signature, id: numericID),
                GetEventDispatcherTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                registered[command] = reference
                commandsByID[numericID] = command
            } else {
                failures[command] = status
            }
        }
        return failures
    }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func installEventHandlerIfNeeded() -> OSStatus {
        guard eventHandler == nil else { return noErr }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Hot-key events are delivered to the dispatcher target; handlers on the
        // application target only fire while this app is active.
        return InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let registrar = Unmanaged<GlobalShortcutRegistrar>.fromOpaque(userData).takeUnretainedValue()
                guard hotKeyID.signature == registrar.signature,
                      let command = registrar.commandsByID[hotKeyID.id] else {
                    return OSStatus(eventNotHandledErr)
                }
                registrar.handler?(command)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func unregisterAll() {
        for reference in registered.values { UnregisterEventHotKey(reference) }
        registered.removeAll()
        commandsByID.removeAll()
    }
}

enum HorizontalDirection {
    case left
    case right
}

/// Horizontal navigation between sections. Frames are ordered by their left
/// edge, then their right edge, so a spanned section — which shares its edges
/// with the sections it covers — is one stop in the sweep: a section, the
/// span that starts there, the next section that span covers, and so on. That
/// is what keeps every layer reachable from the keyboard.
enum SectionNavigator {
    static func adjacentSection(
        to sourceID: UUID,
        direction: HorizontalDirection,
        frames: [UUID: CGRect],
        excluding excluded: Set<UUID> = []
    ) -> UUID? {
        guard let source = frames[sourceID] else { return nil }
        let candidates = frames.filter { id, frame in
            id != sourceID
                && !excluded.contains(id)
                && verticalOverlap(source, frame) > 0
                && (direction == .left ? precedes(frame, source) : precedes(source, frame))
        }
        return candidates.min { lhs, rhs in
            let leftDistance = horizontalDistance(source, lhs.value, direction: direction)
            let rightDistance = horizontalDistance(source, rhs.value, direction: direction)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            let leftVertical = abs(lhs.value.midY - source.midY)
            let rightVertical = abs(rhs.value.midY - source.midY)
            if leftVertical != rightVertical { return leftVertical < rightVertical }
            // The nearest stop in the sweep: overlapping frames tie on
            // distance, and the one closest to the source in sweep order wins.
            if lhs.value != rhs.value {
                return direction == .left
                    ? precedes(rhs.value, lhs.value)
                    : precedes(lhs.value, rhs.value)
            }
            return lhs.key.uuidString < rhs.key.uuidString
        }?.key
    }

    static func cyclingSection(
        from sourceID: UUID,
        direction: HorizontalDirection,
        frames: [UUID: CGRect]
    ) -> UUID? {
        if let adjacent = adjacentSection(to: sourceID, direction: direction, frames: frames) {
            return adjacent
        }
        guard let source = frames[sourceID] else { return nil }
        let row = frames.filter { id, frame in id != sourceID && verticalOverlap(source, frame) > 0 }
        let ordered = row.sorted { lhs, rhs in
            if lhs.value != rhs.value { return precedes(lhs.value, rhs.value) }
            return lhs.key.uuidString < rhs.key.uuidString
        }
        switch direction {
        case .left:
            return ordered.last?.key
        case .right:
            return ordered.first?.key
        }
    }

    /// Sweep order: left edge first, then right edge.
    private static func precedes(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
        return lhs.maxX < rhs.maxX
    }

    private static func verticalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    }

    private static func horizontalDistance(_ source: CGRect, _ candidate: CGRect, direction: HorizontalDirection) -> CGFloat {
        switch direction {
        case .left: max(0, source.minX - candidate.maxX)
        case .right: max(0, candidate.minX - source.maxX)
        }
    }
}
