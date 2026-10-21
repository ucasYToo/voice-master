import CoreFoundation
import Foundation

public struct SavedSearch: Identifiable, Equatable, Sendable {
    public let id: String
    public let query: String
    public let useCount: Int
    public let isPinned: Bool

    public init(id: String, query: String, useCount: Int, isPinned: Bool) {
        self.id = id
        self.query = query
        self.useCount = useCount
        self.isPinned = isPinned
    }
}

private func cleanSearchQuery(_ query: String) -> String {
    query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func searchIdentity(_ query: String) -> String {
    cleanSearchQuery(query).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .lowercased(with: Locale(identifier: "en_US_POSIX"))
}

private struct StoredSearch: Codable {
    var query: String
    var useCount: Int
    var isPinned: Bool
    var lastUsed: UInt64
    var id: String { searchIdentity(query) }
}

/// Local preferences only. Calls belong to the same main actor as AudioController.
@MainActor
public final class AudioPreferences {
    enum Keys {
        static let version = "voiceMaster.preferences.version"
        static let selectedApplicationID = "voiceMaster.preferences.selectedApplicationID"
        static let lastGain = "voiceMaster.preferences.lastGain"
        static let lastSearchQuery = "voiceMaster.preferences.lastSearchQuery"
        static let appProfiles = "voiceMaster.preferences.appProfiles"
        static let searchHistory = "voiceMaster.preferences.searchHistory"
    }

    private let defaults: UserDefaults
    private var selectedID: String?
    private var currentGain: Double
    private var searchQuery: String
    private var profiles: [String: Double]
    private var transientGains: [String: Double] = [:]
    private var history: [StoredSearch]

    public var selectedApplicationID: String? {
        get { selectedID }
        set {
            selectedID = newValue
            // A helper's PID may belong to a different process after restarting.
            if let newValue, !newValue.hasPrefix("process:") {
                defaults.set(newValue, forKey: Keys.selectedApplicationID)
            } else {
                defaults.removeObject(forKey: Keys.selectedApplicationID)
            }
        }
    }

    public var lastGain: Double {
        get { currentGain }
        set {
            currentGain = Self.clampedGain(newValue)
            defaults.set(currentGain, forKey: Keys.lastGain)
        }
    }

    public var lastSearchQuery: String {
        get { searchQuery }
        set {
            searchQuery = newValue
            defaults.set(newValue, forKey: Keys.lastSearchQuery)
        }
    }

    public var savedSearches: [SavedSearch] {
        sortedHistory().map { SavedSearch(id: $0.id, query: $0.query, useCount: $0.useCount, isPinned: $0.isPinned) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profiles = Self.readProfiles(defaults.dictionary(forKey: Keys.appProfiles) ?? [:])
        currentGain = Self.readGain(defaults.object(forKey: Keys.lastGain)) ?? 1
        searchQuery = defaults.object(forKey: Keys.lastSearchQuery) as? String ?? ""
        let persistedSelection = defaults.object(forKey: Keys.selectedApplicationID) as? String
        selectedID = persistedSelection?.hasPrefix("process:") == false ? persistedSelection : nil
        if let data = defaults.data(forKey: Keys.searchHistory),
           let decoded = try? JSONDecoder().decode([StoredSearch].self, from: data) {
            history = decoded
        } else {
            history = []
        }

        // Import old keys once and leave them intact. A path profile is promoted
        // to the preferred bundle identity when that application is discovered.
        let needsMigration = defaults.integer(forKey: Keys.version) < 1
        if needsMigration {
            let legacyGain = Self.readGain(defaults.object(forKey: "gain")) ?? 1
            if Self.readGain(defaults.object(forKey: Keys.lastGain)) == nil { currentGain = legacyGain }
            if selectedID == nil, let legacySelection = defaults.object(forKey: "selectedApplicationID") as? String,
               !legacySelection.hasPrefix("process:") {
                selectedID = legacySelection
            }
            if let legacySelection = defaults.object(forKey: "selectedApplicationID") as? String,
               Self.isStableProfileID(legacySelection), profiles[legacySelection] == nil {
                profiles[legacySelection] = legacyGain
            }
        }
        defaults.set(currentGain, forKey: Keys.lastGain)
        defaults.set(profiles, forKey: Keys.appProfiles)
        if let selectedID { defaults.set(selectedID, forKey: Keys.selectedApplicationID) }
        else { defaults.removeObject(forKey: Keys.selectedApplicationID) }
        normalizeHistory()
        persistHistory()
        if needsMigration { defaults.set(1, forKey: Keys.version) }
    }

    /// A newly selected application starts at unity rather than inheriting an
    /// unrelated application's last gain. nil represents the unselected state.
    public func gain(for application: AudioApplication?) -> Double {
        guard let application else { return lastGain }
        guard let profileID = Self.profileID(for: application) else {
            return transientGains[Self.transientID(for: application)] ?? 1
        }
        if let value = profiles[profileID] {
            if profileID != application.id, profiles.removeValue(forKey: application.id) != nil {
                defaults.set(profiles, forKey: Keys.appProfiles)
            }
            return value
        }
        if profileID != application.id, let migrated = profiles[application.id] {
            profiles[profileID] = migrated
            // Consume the legacy path alias: a different bundle installed at the
            // same path later must not inherit the original application's gain.
            profiles.removeValue(forKey: application.id)
            defaults.set(profiles, forKey: Keys.appProfiles)
            return migrated
        }
        return 1
    }

    public func saveGain(_ gain: Double, for application: AudioApplication?) {
        let value = Self.clampedGain(gain)
        lastGain = value
        guard let application else { return }
        if let profileID = Self.profileID(for: application) {
            profiles[profileID] = value
            defaults.set(profiles, forKey: Keys.appProfiles)
        } else {
            transientGains[Self.transientID(for: application)] = value
        }
    }

    /// Called when a search is submitted or used to select an app, never on each keystroke.
    public func recordSearch(_ query: String) {
        let cleaned = cleanSearchQuery(query)
        guard !cleaned.isEmpty else { return }
        lastSearchQuery = cleaned
        let id = searchIdentity(cleaned)
        let recency = nextRecency()
        if let index = history.firstIndex(where: { $0.id == id }) {
            history[index].query = cleaned
            if history[index].useCount < Int.max { history[index].useCount += 1 }
            history[index].lastUsed = recency
        } else {
            history.append(StoredSearch(query: cleaned, useCount: 1, isPinned: false, lastUsed: recency))
        }
        normalizeHistory()
        persistHistory()
    }

    public func togglePinnedSearch(_ query: String) {
        let cleaned = cleanSearchQuery(query)
        guard !cleaned.isEmpty else { return }
        let id = searchIdentity(cleaned)
        let recency = nextRecency()
        let index: Int
        if let existing = history.firstIndex(where: { $0.id == id }) {
            index = existing
        } else {
            history.append(StoredSearch(query: cleaned, useCount: 0, isPinned: false, lastUsed: recency))
            index = history.count - 1
        }
        if !history[index].isPinned {
            let pinned = history.indices.filter { history[$0].isPinned }
            // Pinning a sixth search demotes the least recently used pinned item.
            if pinned.count >= 5, let oldest = pinned.min(by: { history[$0].lastUsed < history[$1].lastUsed }) {
                history[oldest].isPinned = false
            }
        }
        history[index].isPinned.toggle()
        history[index].lastUsed = recency
        normalizeHistory()
        persistHistory()
    }

    public func removeSearch(id: String) {
        history.removeAll { $0.id == id }
        persistHistory()
    }

    /// Clear recent searches while preserving the user's explicitly pinned shortcuts.
    public func clearSearchHistory() {
        history.removeAll { !$0.isPinned }
        persistHistory()
    }

    private static func clampedGain(_ value: Double) -> Double {
        value.isFinite ? min(4, max(0, value)) : 1
    }

    private static func readGain(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return clampedGain(number.doubleValue)
    }

    private static func isStableProfileID(_ id: String) -> Bool {
        (id.hasPrefix("bundle:") && id.count > "bundle:".count)
            || (id.hasPrefix("app:/") && id.count > "app:/".count)
    }

    private static func profileID(for application: AudioApplication) -> String? {
        // Shared helpers can carry a generic bundle ID. An isolated PID identity
        // never becomes a persistent application profile, even in that case.
        guard !application.id.hasPrefix("process:") else { return nil }
        if let bundleID = application.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty {
            return "bundle:\(bundleID.lowercased())"
        }
        return isStableProfileID(application.id) ? application.id : nil
    }

    private static func transientID(for application: AudioApplication) -> String {
        "\(application.id)|\(application.processIDs.sorted().map(String.init).joined(separator: ","))"
    }

    private static func readProfiles(_ raw: [String: Any]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (id, rawValue) in raw where isStableProfileID(id) {
            if let value = readGain(rawValue) { result[id] = value }
        }
        return result
    }

    private func sortedHistory() -> [StoredSearch] {
        history.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            return $0.id < $1.id
        }
    }

    private func nextRecency() -> UInt64 {
        let maximum = history.map(\.lastUsed).max() ?? 0
        guard maximum == UInt64.max else { return maximum + 1 }
        // A corrupt or centuries-old counter should not overflow or freeze recency.
        let indices = history.indices.sorted { history[$0].lastUsed < history[$1].lastUsed }
        for (offset, index) in indices.enumerated() { history[index].lastUsed = UInt64(offset + 1) }
        return UInt64(history.count + 1)
    }

    private func normalizeHistory() {
        var unique: [String: StoredSearch] = [:]
        for var entry in history {
            entry.query = cleanSearchQuery(entry.query)
            guard !entry.query.isEmpty else { continue }
            entry.useCount = max(0, entry.useCount)
            if let existing = unique[entry.id] {
                let combined = existing.useCount.addingReportingOverflow(entry.useCount)
                var merged = entry.lastUsed >= existing.lastUsed ? entry : existing
                merged.useCount = combined.overflow ? Int.max : combined.partialValue
                merged.isPinned = entry.isPinned || existing.isPinned
                unique[entry.id] = merged
            } else { unique[entry.id] = entry }
        }
        history = Array(unique.values)
        let retainedPins = Set(sortedHistory().filter(\.isPinned).prefix(5).map(\.id))
        for index in history.indices where history[index].isPinned && !retainedPins.contains(history[index].id) {
            history[index].isPinned = false
        }
        let sorted = sortedHistory()
        history = Array(sorted.filter(\.isPinned).prefix(5)) + Array(sorted.filter { !$0.isPinned }.prefix(8))
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Keys.searchHistory) }
    }
}
