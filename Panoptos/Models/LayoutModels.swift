import AppKit
import ColorSync
import Foundation
import OSLog

enum ApplicationSupportMigration {
    private static let logger = Logger(subsystem: "ai.ruverse.Panoptos", category: "PersistenceMigration")
    static let durableFileNames = [
        "layouts.json",
        "window-assignments.json",
        "settings.json",
        "shortcuts.json"
    ]

    static let liveDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent("Panoptos", isDirectory: true)
        do {
            try migrateLegacyData(in: base)
        } catch {
            logger.error("Could not prepare Panoptos persistence migration: \(error.localizedDescription, privacy: .public)")
        }
        return current
    }()

    static let legacyDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Panoptes", isDirectory: true)
    }()

    /// The product rename changed the Application Support directory. Copy
    /// durable files once, without replacing any state already written by the
    /// renamed app.
    static func migrateLegacyData(
        in base: URL,
        fileManager: FileManager = .default,
        copyItem: ((URL, URL) throws -> Void)? = nil
    ) throws {
        let legacy = base.appendingPathComponent("Panoptes", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        let current = base.appendingPathComponent("Panoptos", isDirectory: true)
        try fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        let copyItem = copyItem ?? { try fileManager.copyItem(at: $0, to: $1) }
        for fileName in durableFileNames {
            let source = legacy.appendingPathComponent(fileName)
            let destination = current.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                try copyItem(source, destination)
            } catch {
                // Continue so one unreadable file cannot prevent every other
                // durable preference from migrating. Live stores also retain
                // the legacy file as a read fallback until copying succeeds.
                logger.error(
                    "Could not migrate \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}

enum SplitAxis: String, Codable, CaseIterable {
    case horizontal
    case vertical

    var systemImage: String { self == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2" }
}

/// Two adjacent application groups that share one layout section. Bundle
/// identifiers are stable across relaunches, unlike pids and AX elements.
struct ApplicationSplitPair: Hashable {
    let firstBundleIdentifier: String
    let secondBundleIdentifier: String

    var bundleIdentifiers: [String] {
        [firstBundleIdentifier, secondBundleIdentifier]
    }

    func contains(_ bundleIdentifier: String) -> Bool {
        firstBundleIdentifier == bundleIdentifier || secondBundleIdentifier == bundleIdentifier
    }

    func partner(of bundleIdentifier: String) -> String? {
        if firstBundleIdentifier == bundleIdentifier { return secondBundleIdentifier }
        if secondBundleIdentifier == bundleIdentifier { return firstBundleIdentifier }
        return nil
    }
}

/// The order rendered by the switcher: applications keep the position of
/// their first window, and every later window from that application joins the
/// first one's group without disturbing the application's internal order.
enum SwitcherOrder {
    static func groups<Element>(
        _ elements: [Element],
        bundleIdentifier: (Element) -> String
    ) -> [(bundleIdentifier: String, elements: [Element])] {
        var bundleOrder: [String] = []
        var elementsByBundle: [String: [Element]] = [:]
        for element in elements {
            let identifier = bundleIdentifier(element)
            if elementsByBundle[identifier] == nil {
                bundleOrder.append(identifier)
            }
            elementsByBundle[identifier, default: []].append(element)
        }
        return bundleOrder.map { identifier in
            (identifier, elementsByBundle[identifier, default: []])
        }
    }

    static func grouped<Element>(
        _ elements: [Element],
        bundleIdentifier: (Element) -> String
    ) -> [Element] {
        groups(elements, bundleIdentifier: bundleIdentifier).flatMap(\.elements)
    }

    /// Completes an order the switcher produced from the windows it rendered.
    /// Windows it did not render — those off screen at the time — are placed
    /// directly after the last rendered window of their application, and an
    /// application with nothing rendered keeps its windows at the end in their
    /// existing order. The result lists every element exactly once, which the
    /// model requires before it accepts a reorder.
    static func completing<Element: Identifiable>(
        _ renderedOrder: [Element.ID],
        with elements: [Element],
        bundleIdentifier: (Element) -> String
    ) -> [Element.ID] {
        let rendered = Set(renderedOrder)
        var result = renderedOrder
        var lastRenderedIndexByBundle: [String: Int] = [:]
        let elementsByID = Dictionary(elements.map { ($0.id, $0) }) { first, _ in first }
        for (index, id) in renderedOrder.enumerated() {
            guard let element = elementsByID[id] else { continue }
            lastRenderedIndexByBundle[bundleIdentifier(element)] = index
        }
        var trailing: [Element.ID] = []
        for element in elements.reversed() where !rendered.contains(element.id) {
            guard let anchor = lastRenderedIndexByBundle[bundleIdentifier(element)] else {
                trailing.insert(element.id, at: 0)
                continue
            }
            result.insert(element.id, at: anchor + 1)
        }
        return result + trailing
    }
}

enum SwitcherApplicationUnit: Hashable {
    case application(String)
    case pair(ApplicationSplitPair)

    var bundleIdentifiers: [String] {
        switch self {
        case .application(let bundleIdentifier): [bundleIdentifier]
        case .pair(let pair): pair.bundleIdentifiers
        }
    }

    func contains(_ bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains(bundleIdentifier)
    }

    static func make(
        bundleOrder: [String],
        pairs: [ApplicationSplitPair]
    ) -> [SwitcherApplicationUnit] {
        var units: [SwitcherApplicationUnit] = []
        var index = 0
        while index < bundleOrder.count {
            let bundleIdentifier = bundleOrder[index]
            if index + 1 < bundleOrder.count,
               let pair = pairs.first(where: {
                   $0.firstBundleIdentifier == bundleIdentifier
                       && $0.secondBundleIdentifier == bundleOrder[index + 1]
               }) {
                units.append(.pair(pair))
                index += 2
            } else {
                units.append(.application(bundleIdentifier))
                index += 1
            }
        }
        return units
    }
}

struct ApplicationSplitFrames: Equatable {
    let axis: SplitAxis
    let first: CGRect
    let second: CGRect
}

enum ApplicationSplitGeometry {
    /// Tall sections stack their applications; square and wide sections put
    /// them side by side. The first application is top/left, matching switcher
    /// order and the layout editor's split semantics.
    static func frames(in bounds: CGRect, gutter: CGFloat) -> ApplicationSplitFrames {
        frames(in: bounds, gutter: gutter, axis: axis(for: bounds))
    }

    static func axis(for sectionBounds: CGRect) -> SplitAxis {
        sectionBounds.height > sectionBounds.width ? .vertical : .horizontal
    }

    static func frames(
        in bounds: CGRect,
        gutter: CGFloat,
        axis: SplitAxis
    ) -> ApplicationSplitFrames {
        let divider = max(0, gutter)
        let available = max(0, (axis == .horizontal ? bounds.width : bounds.height) - divider)
        let firstLength = (available / 2).rounded()
        if axis == .horizontal {
            let first = CGRect(x: bounds.minX, y: bounds.minY, width: firstLength, height: bounds.height)
            let second = CGRect(
                x: first.maxX + divider,
                y: bounds.minY,
                width: max(0, available - firstLength),
                height: bounds.height
            )
            return ApplicationSplitFrames(axis: axis, first: first, second: second)
        }
        let first = CGRect(
            x: bounds.minX,
            y: bounds.maxY - firstLength,
            width: bounds.width,
            height: firstLength
        )
        let second = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: max(0, available - firstLength)
        )
        return ApplicationSplitFrames(axis: axis, first: first, second: second)
    }
}

indirect enum LayoutNode: Codable, Equatable, Identifiable {
    case leaf(id: UUID)
    case split(id: UUID, axis: SplitAxis, ratio: CGFloat, first: LayoutNode, second: LayoutNode)

    var id: UUID {
        switch self {
        case .leaf(let id), .split(let id, _, _, _, _): id
        }
    }

    var leafIDs: [UUID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, _, _, let first, let second): first.leafIDs + second.leafIDs
        }
    }

    func frames(in bounds: CGRect, dividerWidth: CGFloat = 6) -> [UUID: CGRect] {
        switch self {
        case .leaf(let id):
            return [id: bounds]
        case .split(_, let axis, let rawRatio, let first, let second):
            let ratio = min(max(rawRatio, 0.05), 0.95)
            let available = max(0, (axis == .horizontal ? bounds.width : bounds.height) - dividerWidth)
            let firstLength = (available * ratio).rounded()
            let firstFrame: CGRect
            let secondFrame: CGRect
            if axis == .horizontal {
                firstFrame = CGRect(x: bounds.minX, y: bounds.minY, width: firstLength, height: bounds.height)
                secondFrame = CGRect(
                    x: firstFrame.maxX + dividerWidth,
                    y: bounds.minY,
                    width: max(0, available - firstLength),
                    height: bounds.height
                )
            } else {
                firstFrame = CGRect(
                    x: bounds.minX,
                    y: bounds.maxY - firstLength,
                    width: bounds.width,
                    height: firstLength
                )
                secondFrame = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: max(0, available - firstLength)
                )
            }
            return first.frames(in: firstFrame, dividerWidth: dividerWidth)
                .merging(second.frames(in: secondFrame, dividerWidth: dividerWidth)) { _, rhs in rhs }
        }
    }

    func splitting(leafID: UUID, axis: SplitAxis) -> LayoutNode {
        switch self {
        case .leaf(let id) where id == leafID:
            return .split(id: UUID(), axis: axis, ratio: 0.5, first: .leaf(id: id), second: .leaf(id: UUID()))
        case .leaf:
            return self
        case .split(let id, let existingAxis, let ratio, let first, let second):
            return .split(
                id: id,
                axis: existingAxis,
                ratio: ratio,
                first: first.splitting(leafID: leafID, axis: axis),
                second: second.splitting(leafID: leafID, axis: axis)
            )
        }
    }

    func replacingSplit(id targetID: UUID, ratio newRatio: CGFloat) -> LayoutNode {
        switch self {
        case .leaf:
            return self
        case .split(let id, let axis, let ratio, let first, let second):
            if id == targetID {
                return .split(id: id, axis: axis, ratio: min(max(newRatio, 0.1), 0.9), first: first, second: second)
            }
            return .split(
                id: id,
                axis: axis,
                ratio: ratio,
                first: first.replacingSplit(id: targetID, ratio: newRatio),
                second: second.replacingSplit(id: targetID, ratio: newRatio)
            )
        }
    }

    /// Removes a leaf and returns the leaf that should receive its windows.
    func removing(leafID: UUID) -> (node: LayoutNode, survivor: UUID)? {
        switch self {
        case .leaf:
            return nil
        case .split(_, _, _, let first, let second):
            if case .leaf(let id) = first, id == leafID {
                return (second, second.leafIDs[0])
            }
            if case .leaf(let id) = second, id == leafID {
                return (first, first.leafIDs[0])
            }
        }

        if case .split(let id, let axis, let ratio, let first, let second) = self {
            if let removal = first.removing(leafID: leafID) {
                return (.split(id: id, axis: axis, ratio: ratio, first: removal.node, second: second), removal.survivor)
            }
            if let removal = second.removing(leafID: leafID) {
                return (.split(id: id, axis: axis, ratio: ratio, first: first, second: removal.node), removal.survivor)
            }
        }
        return nil
    }
}

/// Pure helpers shared by the compact layout previews and the layout editor so
/// both describe sections with the same ordering and units.
enum LayoutGeometry {
    /// Screen-space tolerance for treating two edges as the same edge.
    static let edgeTolerance: CGFloat = 0.5

    /// Top-to-bottom, then leading-to-trailing. Frames use AppKit coordinates,
    /// so a larger `maxY` is higher on screen.
    static func readingOrder(leafIDs: [UUID], frames: [UUID: CGRect]) -> [UUID] {
        leafIDs
            .filter { frames[$0] != nil }
            .sorted { lhs, rhs in
                guard let left = frames[lhs], let right = frames[rhs] else { return false }
                if abs(left.maxY - right.maxY) > edgeTolerance { return left.maxY > right.maxY }
                if abs(left.minX - right.minX) > edgeTolerance { return left.minX < right.minX }
                return lhs.uuidString < rhs.uuidString
            }
    }

    static func sizeLabel(_ frame: CGRect) -> String {
        "\(Int(frame.width.rounded())) × \(Int(frame.height.rounded()))"
    }
}

struct DisplayFingerprint: Codable, Hashable, Identifiable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let name: String
    /// A public Core Graphics identity that remains stable when macOS changes
    /// the display's localized connection name.
    let stableIdentifier: String?

    var id: String { identityKey }

    init(
        vendor: UInt32,
        model: UInt32,
        serial: UInt32,
        name: String,
        stableIdentifier: String? = nil
    ) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.name = name
        self.stableIdentifier = stableIdentifier?.lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case vendor
        case model
        case serial
        case name
        case stableIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            vendor: try container.decode(UInt32.self, forKey: .vendor),
            model: try container.decode(UInt32.self, forKey: .model),
            serial: try container.decode(UInt32.self, forKey: .serial),
            name: try container.decode(String.self, forKey: .name),
            stableIdentifier: try container.decodeIfPresent(String.self, forKey: .stableIdentifier)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vendor, forKey: .vendor)
        try container.encode(model, forKey: .model)
        try container.encode(serial, forKey: .serial)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(stableIdentifier, forKey: .stableIdentifier)
    }

    static func == (lhs: DisplayFingerprint, rhs: DisplayFingerprint) -> Bool {
        lhs.identityKey == rhs.identityKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identityKey)
    }

    /// Includes presentation fields and is therefore suitable for detecting
    /// whether a migration needs to rewrite the persisted representation.
    var storageKey: String {
        "\(stableIdentifier ?? "-")|\(vendor)|\(model)|\(serial)|\(name)"
    }

    var hasNonzeroHardwareIdentity: Bool {
        vendor != 0 && model != 0 && serial != 0
    }

    func representsSamePhysicalDisplay(as other: DisplayFingerprint) -> Bool {
        if let stableIdentifier, let otherIdentifier = other.stableIdentifier {
            return stableIdentifier == otherIdentifier
        }
        if hasNonzeroHardwareIdentity, other.hasNonzeroHardwareIdentity {
            return vendor == other.vendor && model == other.model && serial == other.serial
        }
        return vendor == other.vendor
            && model == other.model
            && serial == other.serial
            && name == other.name
    }

    func canonicalized(using current: [DisplayFingerprint]) -> DisplayFingerprint {
        if let stableIdentifier,
           let match = current.first(where: { $0.stableIdentifier == stableIdentifier }) {
            return match
        }
        if stableIdentifier == nil, hasNonzeroHardwareIdentity {
            let matches = current.filter {
                $0.vendor == vendor && $0.model == model && $0.serial == serial
            }
            if matches.count == 1 { return matches[0] }
        }
        if stableIdentifier == nil,
           let exactLegacy = current.first(where: {
               $0.vendor == vendor && $0.model == model && $0.serial == serial && $0.name == name
           }) {
            return exactLegacy
        }
        return self
    }

    private var identityKey: String {
        if let stableIdentifier { return "uuid-\(stableIdentifier)" }
        if hasNonzeroHardwareIdentity { return "hardware-\(vendor)-\(model)-\(serial)" }
        return "legacy-\(vendor)-\(model)-\(serial)-\(name)"
    }

    static func current(for screen: NSScreen) -> DisplayFingerprint {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return DisplayFingerprint(vendor: 0, model: 0, serial: 0, name: screen.localizedName)
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let stableIdentifier = CGDisplayCreateUUIDFromDisplayID(displayID).map {
            CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
        }
        return DisplayFingerprint(
            vendor: CGDisplayVendorNumber(displayID),
            model: CGDisplayModelNumber(displayID),
            serial: CGDisplaySerialNumber(displayID),
            name: screen.localizedName,
            stableIdentifier: stableIdentifier
        )
    }
}

struct DisplayLayout: Codable, Equatable, Identifiable {
    static let defaultGutter: CGFloat = 10
    static let gutterRange: ClosedRange<CGFloat> = 0...32

    var fingerprint: DisplayFingerprint
    var root: LayoutNode
    var gutter: CGFloat

    var id: String { fingerprint.id }
    var normalizedGutter: CGFloat {
        min(max(gutter, Self.gutterRange.lowerBound), Self.gutterRange.upperBound)
    }

    init(fingerprint: DisplayFingerprint, root: LayoutNode, gutter: CGFloat = defaultGutter) {
        self.fingerprint = fingerprint
        self.root = root
        self.gutter = gutter
    }

    func frames(in bounds: CGRect) -> [UUID: CGRect] {
        let gutter = normalizedGutter
        let insetBounds = bounds.insetBy(dx: gutter, dy: gutter)
        return root.frames(in: insetBounds, dividerWidth: gutter)
    }

    private enum CodingKeys: String, CodingKey {
        case fingerprint
        case root
        case gutter
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try container.decode(DisplayFingerprint.self, forKey: .fingerprint)
        root = try container.decode(LayoutNode.self, forKey: .root)
        gutter = try container.decodeIfPresent(CGFloat.self, forKey: .gutter) ?? Self.defaultGutter
    }
}

struct CurrentDisplay: Identifiable, Equatable {
    let fingerprint: DisplayFingerprint
    let frame: CGRect
    let visibleFrame: CGRect
    let scale: CGFloat

    var id: String { fingerprint.id }
    var name: String { fingerprint.name }
}

struct LayoutPersistence {
    let url: URL
    let fallbackURL: URL?

    init(url: URL, fallbackURL: URL? = nil) {
        self.url = url
        self.fallbackURL = fallbackURL
    }

    static var live: LayoutPersistence {
        LayoutPersistence(
            url: ApplicationSupportMigration.liveDirectory.appendingPathComponent("layouts.json"),
            fallbackURL: ApplicationSupportMigration.legacyDirectory.appendingPathComponent("layouts.json")
        )
    }

    func load() -> [DisplayLayout] {
        for source in [url, fallbackURL].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: source),
                  let layouts = try? JSONDecoder().decode([DisplayLayout].self, from: data) else { continue }
            return layouts
        }
        return []
    }

    func save(_ layouts: [DisplayLayout]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(layouts)
        try data.write(to: url, options: .atomic)
    }
}

struct PersistedWindowAssignment: Codable, Equatable {
    let id: UUID
    var sectionID: UUID
    var additionalSectionIDs: Set<UUID>
    let bundleIdentifier: String
    let processIdentifier: Int32
    let accessibilityIdentifier: String?
    let title: String
    let windowOrdinal: Int
    var order: Int
    var isActive: Bool
    /// The other application sharing this assignment's section, when the two
    /// application groups are paired in the switcher. Optional so files from
    /// before application splits continue to decode as unpaired.
    var splitPartnerBundleIdentifier: String? = nil
    /// Set when the assignment is filed but its window is not currently
    /// attached, either because a heuristic dropped it or because restoration
    /// could not match it yet. Absent in files written before orphan tracking,
    /// and absent for every attached window.
    var orphanedAt: Date? = nil
    /// Set when the user closed an attached window without quitting its
    /// application. The next window-created notification from that same
    /// process may reclaim this assignment. Optional so older files decode
    /// with the previous detach-on-close behavior represented as no pending
    /// reopen.
    var awaitsWindowReopen: Bool? = nil
    /// Set when the owning application quit while this window was attached.
    /// The next instance may have a different pid and publish a changed title
    /// before its stable Accessibility identity is available, so this permits
    /// the persisted ordinal as a final relaunch-only match. Optional for
    /// backward-compatible decoding of assignment files written before this
    /// state existed.
    var awaitsApplicationRelaunch: Bool? = nil
    /// The physical display set for which this location applies. Older files
    /// have no value; those records remain a preferred legacy location until
    /// Panoptos has written topology-specific profiles.
    var displayTopology: [DisplayFingerprint]? = nil

    /// Every layout section the window spans, or empty when it occupies
    /// `sectionID` alone. `sectionID` always names a layout section, so
    /// older files decode unchanged and display migration keeps working.
    var coveredSectionIDs: Set<UUID> {
        additionalSectionIDs.isEmpty ? [] : additionalSectionIDs.union([sectionID])
    }

    /// The section the window lives in at runtime: its layout section, or the
    /// spanned section derived from everything it covers.
    var liveSectionID: UUID {
        additionalSectionIDs.isEmpty ? sectionID : SpannedSectionIdentity.id(covering: coveredSectionIDs)
    }

    /// Display profiles own placement and ordering. A window's current public
    /// descriptors and close/relaunch state belong to the window itself, even
    /// when its monitor is disconnected.
    func updatingWindowState(from current: PersistedWindowAssignment) -> PersistedWindowAssignment {
        guard id == current.id, bundleIdentifier == current.bundleIdentifier else { return self }
        var updated = current
        updated.sectionID = sectionID
        updated.additionalSectionIDs = additionalSectionIDs
        updated.order = order
        updated.isActive = isActive
        updated.splitPartnerBundleIdentifier = splitPartnerBundleIdentifier
        updated.displayTopology = displayTopology
        return updated
    }
}

enum DisplayPersistenceMigration {
    struct LayoutResult {
        let layouts: [DisplayLayout]
        let changed: Bool
    }

    private struct LayoutCandidate {
        let layout: DisplayLayout
        let canonicalFingerprint: DisplayFingerprint
        let storedIndex: Int
        let currentNameMatches: Bool
    }

    private struct ProfileVariant {
        let topology: [DisplayFingerprint]
        let canonicalTopology: [DisplayFingerprint]
        let firstStoredIndex: Int
        let currentNameMatches: Int
        var records: [PersistedWindowAssignment]

        var durableWindowCount: Int { Set(records.map(\.id)).count }
    }

    private struct MigratedProfile {
        let firstStoredIndex: Int
        let records: [PersistedWindowAssignment]
    }

    static func layouts(
        _ stored: [DisplayLayout],
        current: [DisplayFingerprint]
    ) -> LayoutResult {
        var groupOrder: [String] = []
        var groups: [String: [LayoutCandidate]] = [:]
        for (index, layout) in stored.enumerated() {
            let canonical = layout.fingerprint.canonicalized(using: current)
            let candidate = LayoutCandidate(
                layout: layout,
                canonicalFingerprint: canonical,
                storedIndex: index,
                currentNameMatches: current.contains {
                    layout.fingerprint.representsSamePhysicalDisplay(as: $0)
                        && layout.fingerprint.name == $0.name
                }
            )
            if groups[canonical.id] == nil { groupOrder.append(canonical.id) }
            groups[canonical.id, default: []].append(candidate)
        }

        let migrated = groupOrder.compactMap { key -> (Int, DisplayLayout)? in
            guard let candidates = groups[key],
                  let winner = candidates.sorted(by: preferredLayoutCandidate).first else { return nil }
            return (
                candidates.map(\.storedIndex).min() ?? winner.storedIndex,
                DisplayLayout(
                    fingerprint: winner.canonicalFingerprint,
                    root: winner.layout.root,
                    gutter: winner.layout.gutter
                )
            )
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)

        return LayoutResult(
            layouts: migrated,
            changed: !layoutsAreStorageEquivalent(stored, migrated)
        )
    }

    static func assignments(
        _ stored: [PersistedWindowAssignment],
        current: [DisplayFingerprint]
    ) -> [PersistedWindowAssignment] {
        var legacyRecords: [(Int, PersistedWindowAssignment)] = []
        var variantOrder: [String] = []
        var variantsByStorageKey: [String: ProfileVariant] = [:]

        for (index, assignment) in stored.enumerated() {
            guard let topology = assignment.displayTopology else {
                legacyRecords.append((index, assignment))
                continue
            }
            let storageKey = topology.map(\.storageKey).sorted().joined(separator: ";")
            if variantsByStorageKey[storageKey] == nil {
                let canonical = canonicalTopology(topology, current: current)
                variantsByStorageKey[storageKey] = ProfileVariant(
                    topology: topology,
                    canonicalTopology: canonical,
                    firstStoredIndex: index,
                    currentNameMatches: topology.filter { fingerprint in
                        current.contains {
                            fingerprint.representsSamePhysicalDisplay(as: $0)
                                && fingerprint.name == $0.name
                        }
                    }.count,
                    records: []
                )
                variantOrder.append(storageKey)
            }
            variantsByStorageKey[storageKey]?.records.append(assignment)
        }

        var profileGroupOrder: [String] = []
        var profileGroups: [String: [ProfileVariant]] = [:]
        for storageKey in variantOrder {
            guard let variant = variantsByStorageKey[storageKey] else { continue }
            let profileKey = variant.canonicalTopology.map(\.id).joined(separator: ";")
            if profileGroups[profileKey] == nil { profileGroupOrder.append(profileKey) }
            profileGroups[profileKey, default: []].append(variant)
        }

        var migratedProfiles = profileGroupOrder.compactMap { key -> MigratedProfile? in
            guard let variants = profileGroups[key],
                  let winner = variants.sorted(by: preferredProfileVariant).first else { return nil }
            let targetTopology = winner.canonicalTopology
            var merged = winner.records.map { assignment in
                var assignment = assignment
                assignment.displayTopology = targetTopology
                return assignment
            }
            let canonicalActiveSections = Set(
                merged.filter(\.isActive).map(\.sectionID)
            )
            var seenWindowIDs = Set(merged.map(\.id))
            for variant in variants.sorted(by: { $0.firstStoredIndex < $1.firstStoredIndex })
            where variant.firstStoredIndex != winner.firstStoredIndex {
                for original in variant.records where seenWindowIDs.insert(original.id).inserted {
                    var assignment = original
                    assignment.displayTopology = targetTopology
                    // A retired alias contributes only records absent from the
                    // canonical profile. Its numeric slots belong to that
                    // retired profile and must not displace canonical records.
                    assignment.order = merged.count
                    if canonicalActiveSections.contains(assignment.sectionID) {
                        assignment.isActive = false
                    }
                    merged.append(assignment)
                }
            }
            return MigratedProfile(
                firstStoredIndex: variants.map(\.firstStoredIndex).min() ?? winner.firstStoredIndex,
                records: canonicalizedSectionOrder(merged)
            )
        }

        if !legacyRecords.isEmpty {
            migratedProfiles.append(MigratedProfile(
                firstStoredIndex: legacyRecords.map(\.0).min() ?? 0,
                records: canonicalizedSectionOrder(legacyRecords.map(\.1))
            ))
        }
        return migratedProfiles
            .sorted { $0.firstStoredIndex < $1.firstStoredIndex }
            .flatMap(\.records)
    }

    /// Orphans are a sparse view of a complete assignment profile. Their
    /// numeric order reserves the missing window's durable switcher slot, so
    /// display identity migration may rewrite only the topology and must not
    /// compact or regroup the records as though they were a complete profile.
    static func orphanedAssignments(
        _ stored: [PersistedWindowAssignment],
        current: [DisplayFingerprint]
    ) -> [PersistedWindowAssignment] {
        stored.map { original in
            guard let topology = original.displayTopology else { return original }
            var migrated = original
            migrated.displayTopology = canonicalTopology(topology, current: current)
            return migrated
        }
    }

    static func assignmentsAreStorageEquivalent(
        _ lhs: [PersistedWindowAssignment],
        _ rhs: [PersistedWindowAssignment]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            let leftTopology = left.displayTopology?.map(\.storageKey)
            let rightTopology = right.displayTopology?.map(\.storageKey)
            guard leftTopology == rightTopology else { return false }
            var left = left
            var right = right
            left.displayTopology = nil
            right.displayTopology = nil
            return left == right
        }
    }

    private static func preferredLayoutCandidate(
        _ lhs: LayoutCandidate,
        _ rhs: LayoutCandidate
    ) -> Bool {
        if lhs.layout.root.leafIDs.count != rhs.layout.root.leafIDs.count {
            return lhs.layout.root.leafIDs.count > rhs.layout.root.leafIDs.count
        }
        if lhs.currentNameMatches != rhs.currentNameMatches {
            return lhs.currentNameMatches
        }
        return lhs.storedIndex < rhs.storedIndex
    }

    private static func preferredProfileVariant(
        _ lhs: ProfileVariant,
        _ rhs: ProfileVariant
    ) -> Bool {
        if lhs.durableWindowCount != rhs.durableWindowCount {
            return lhs.durableWindowCount > rhs.durableWindowCount
        }
        if lhs.currentNameMatches != rhs.currentNameMatches {
            return lhs.currentNameMatches > rhs.currentNameMatches
        }
        return lhs.firstStoredIndex < rhs.firstStoredIndex
    }

    private static func canonicalTopology(
        _ topology: [DisplayFingerprint],
        current: [DisplayFingerprint]
    ) -> [DisplayFingerprint] {
        var fingerprintsByID: [String: DisplayFingerprint] = [:]
        for fingerprint in topology {
            let canonical = fingerprint.canonicalized(using: current)
            fingerprintsByID[canonical.id] = canonical
        }
        return fingerprintsByID.values.sorted { $0.id < $1.id }
    }

    private static func canonicalizedSectionOrder(
        _ records: [PersistedWindowAssignment]
    ) -> [PersistedWindowAssignment] {
        var sectionOrder: [UUID] = []
        var recordsBySection: [UUID: [(Int, PersistedWindowAssignment)]] = [:]
        for (index, record) in records.enumerated() {
            if recordsBySection[record.sectionID] == nil { sectionOrder.append(record.sectionID) }
            recordsBySection[record.sectionID, default: []].append((index, record))
        }
        return sectionOrder.flatMap { sectionID -> [PersistedWindowAssignment] in
            let ordered = recordsBySection[sectionID, default: []].sorted {
                if $0.1.order != $1.1.order { return $0.1.order < $1.1.order }
                return $0.0 < $1.0
            }.map(\.1)
            let contiguous = SwitcherOrder.grouped(
                ordered,
                bundleIdentifier: \PersistedWindowAssignment.bundleIdentifier
            )
            let activeID = contiguous.last(where: \.isActive)?.id
            return contiguous.enumerated().map { order, original in
                var assignment = original
                assignment.order = order
                assignment.isActive = assignment.id == activeID
                return assignment
            }
        }
    }

    private static func layoutsAreStorageEquivalent(
        _ lhs: [DisplayLayout],
        _ rhs: [DisplayLayout]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.fingerprint.storageKey == right.fingerprint.storageKey
                && left.root == right.root
                && left.gutter == right.gutter
        }
    }
}

struct WindowAssignmentPersistence {
    let url: URL
    let fallbackURL: URL?

    init(url: URL, fallbackURL: URL? = nil) {
        self.url = url
        self.fallbackURL = fallbackURL
    }

    static var live: WindowAssignmentPersistence {
        WindowAssignmentPersistence(
            url: ApplicationSupportMigration.liveDirectory.appendingPathComponent("window-assignments.json"),
            fallbackURL: ApplicationSupportMigration.legacyDirectory.appendingPathComponent("window-assignments.json")
        )
    }

    func load() -> [PersistedWindowAssignment] {
        for source in [url, fallbackURL].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: source),
                  let assignments = try? JSONDecoder().decode([PersistedWindowAssignment].self, from: data) else {
                continue
            }
            return assignments
        }
        return []
    }

    func save(_ assignments: [PersistedWindowAssignment]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(assignments)
        try data.write(to: url, options: .atomic)
    }
}

enum WindowTitleFormatter {
    static let characterLimit = 8

    static func display(_ title: String, limitCharacters: Bool) -> String {
        let value = title.isEmpty ? "Window" : title
        guard limitCharacters, value.count > characterLimit else { return value }
        return String(value.prefix(characterLimit)) + "…"
    }
}
