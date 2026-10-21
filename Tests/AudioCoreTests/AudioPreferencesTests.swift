import Foundation
import Testing
@testable import AudioCore

@MainActor
struct AudioPreferencesTests {
    private func app(_ id: String = "app:/Applications/Player.app", bundle: String? = "org.example.player", object: UInt32 = 101) -> AudioApplication {
        AudioApplication(id: id, name: "Player", bundleID: bundle, processIDs: [object], pids: [100], isPlaying: false)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "VoiceMaster.PreferencesTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func persistsSettingsAndKeepsApplicationGainsSeparate() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AudioPreferences(defaults: defaults)
        let player = app()
        let other = app("app:/Applications/Other.app", bundle: "org.example.other")
        preferences.selectedApplicationID = player.id
        preferences.lastSearchQuery = "网易云 音乐"
        preferences.saveGain(2.25, for: player)
        #expect(preferences.gain(for: other) == 1)
        preferences.saveGain(0.75, for: other)
        #expect(preferences.gain(for: player) == 2.25)
        #expect(preferences.gain(for: nil) == 0.75)

        defaults.synchronize()
        let reloadedDefaults = try #require(UserDefaults(suiteName: suite))
        let reloaded = AudioPreferences(defaults: reloadedDefaults)
        #expect(reloaded.selectedApplicationID == player.id)
        #expect(reloaded.lastSearchQuery == "网易云 音乐")
        #expect(reloaded.lastGain == 0.75)
        #expect(reloaded.gain(for: player) == 2.25)
        #expect(reloaded.gain(for: other) == 0.75)
    }

    @Test func bundleIdentitySurvivesMovedAppAndPathWorksWithoutBundleID() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AudioPreferences(defaults: defaults)
        preferences.saveGain(1.7, for: app())
        #expect(preferences.gain(for: app("app:/Users/test/Apps/Player.app")) == 1.7)
        let unbundled = app("app:/Applications/Standalone.app", bundle: nil)
        preferences.saveGain(2.8, for: unbundled)
        let reloaded = AudioPreferences(defaults: defaults)
        #expect(reloaded.gain(for: unbundled) == 2.8)
        #expect(reloaded.gain(for: app("app:/Applications/Different.app", bundle: nil)) == 1)
    }

    @Test func migratesLegacySelectionGainOnceWithoutDeletingOldData() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = app()
        defaults.set(player.id, forKey: "selectedApplicationID")
        defaults.set(3.2, forKey: "gain")
        let preferences = AudioPreferences(defaults: defaults)
        #expect(preferences.selectedApplicationID == player.id)
        #expect(preferences.lastGain == 3.2)
        #expect(preferences.gain(for: player) == 3.2)
        #expect(preferences.gain(for: app("app:/Applications/New.app", bundle: "org.example.new")) == 1)
        #expect(defaults.string(forKey: "selectedApplicationID") == player.id)
        #expect(defaults.double(forKey: "gain") == 3.2)

        // Looking up the original app promotes the path migration to its bundle identity.
        #expect(AudioPreferences(defaults: defaults).gain(for: app("app:/Moved/Player.app")) == 3.2)
        #expect(AudioPreferences(defaults: defaults).gain(for: app(player.id, bundle: "org.example.replacement")) == 1)
        preferences.selectedApplicationID = nil
        preferences.lastGain = 1.2
        let reloaded = AudioPreferences(defaults: defaults)
        #expect(reloaded.selectedApplicationID == nil)
        #expect(reloaded.lastGain == 1.2)
    }

    @Test func isolatedProcessProfilesAndSelectionCannotSurvivePIDReuse() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let isolated = app("process:100", bundle: "org.shared.helper")
        defaults.set(isolated.id, forKey: "selectedApplicationID")
        defaults.set(3.5, forKey: "gain")
        let preferences = AudioPreferences(defaults: defaults)
        #expect(preferences.selectedApplicationID == nil)
        #expect(preferences.gain(for: isolated) == 1)
        preferences.selectedApplicationID = isolated.id
        preferences.saveGain(2.6, for: isolated)
        #expect(preferences.selectedApplicationID == isolated.id)
        #expect(preferences.gain(for: isolated) == 2.6)
        #expect(preferences.gain(for: app("process:100", bundle: "org.shared.helper", object: 999)) == 1)
        let reloaded = AudioPreferences(defaults: defaults)
        #expect(reloaded.selectedApplicationID == nil)
        #expect(reloaded.gain(for: isolated) == 1)
        #expect(defaults.dictionary(forKey: AudioPreferences.Keys.appProfiles)?.isEmpty == true)
    }

    @Test func clampsGainsAndRejectsCorruptDefaults() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("loud", forKey: AudioPreferences.Keys.lastGain)
        defaults.set(123, forKey: AudioPreferences.Keys.selectedApplicationID)
        defaults.set(false, forKey: AudioPreferences.Keys.lastSearchQuery)
        defaults.set(["bundle:org.example.player": true, "process:100": 3.0, "bundle:org.example.other": 9.0], forKey: AudioPreferences.Keys.appProfiles)
        defaults.set(Data("invalid json".utf8), forKey: AudioPreferences.Keys.searchHistory)
        let preferences = AudioPreferences(defaults: defaults)
        #expect(preferences.lastGain == 1)
        #expect(preferences.selectedApplicationID == nil)
        #expect(preferences.lastSearchQuery == "")
        #expect(preferences.gain(for: app()) == 1)
        #expect(preferences.gain(for: app("app:/Applications/Other.app", bundle: "org.example.other")) == 4)
        #expect(preferences.savedSearches.isEmpty)
        preferences.saveGain(-8, for: app())
        #expect(preferences.gain(for: app()) == 0)
        preferences.saveGain(99, for: app())
        #expect(preferences.gain(for: app()) == 4)
        preferences.saveGain(.infinity, for: app())
        #expect(preferences.gain(for: app()) == 1)
        preferences.lastGain = .nan
        #expect(preferences.lastGain == 1)
        #expect(defaults.dictionary(forKey: AudioPreferences.Keys.appProfiles)?["process:100"] == nil)
    }

    @Test func searchHistoryDeduplicatesWhitespaceCaseAndDiacritics() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AudioPreferences(defaults: defaults)
        preferences.recordSearch("  CAFÉ\n  Music  ")
        preferences.recordSearch("cafe\t music")
        preferences.recordSearch("  \n ")
        let saved = try #require(preferences.savedSearches.first)
        #expect(preferences.savedSearches.count == 1)
        #expect(saved.id == "cafe music")
        #expect(saved.query == "cafe music")
        #expect(saved.useCount == 2)
        #expect(preferences.lastSearchQuery == "cafe music")
        #expect(AudioPreferences(defaults: defaults).savedSearches == preferences.savedSearches)
    }

    @Test func searchHistorySortsPinsThenUsageThenRecency() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AudioPreferences(defaults: defaults)
        preferences.recordSearch("frequent")
        preferences.recordSearch("frequent")
        preferences.recordSearch("older")
        preferences.recordSearch("newer")
        preferences.togglePinnedSearch("shortcut")
        #expect(preferences.savedSearches.map(\.query) == ["shortcut", "frequent", "newer", "older"])
        #expect(preferences.savedSearches.first?.useCount == 0)
    }

    @Test func limitsRecentSearchesAndPinnedShortcuts() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AudioPreferences(defaults: defaults)
        for index in 0..<20 { preferences.recordSearch("recent \(index)") }
        #expect(preferences.savedSearches.count == 8)
        #expect(preferences.savedSearches.first?.query == "recent 19")
        for index in 0..<6 { preferences.togglePinnedSearch("pinned \(index)") }
        #expect(preferences.savedSearches.filter(\.isPinned).count == 5)
        #expect(preferences.savedSearches.filter { !$0.isPinned }.count <= 8)
        #expect(preferences.savedSearches.count <= 13)
        #expect(preferences.savedSearches.first(where: { $0.query == "pinned 0" })?.isPinned != true)
        #expect(preferences.savedSearches.first(where: { $0.query == "pinned 5" })?.isPinned == true)
    }

    @Test func clearingHistoryKeepsPinsAndRemovingPinPersists() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AudioPreferences(defaults: defaults)
        preferences.recordSearch("browser")
        preferences.recordSearch("music")
        preferences.togglePinnedSearch("MUSIC")
        preferences.clearSearchHistory()
        let remaining = try #require(preferences.savedSearches.first)
        #expect(preferences.savedSearches.count == 1)
        #expect(remaining.id == "music")
        #expect(remaining.isPinned)
        let reloaded = AudioPreferences(defaults: defaults)
        #expect(reloaded.savedSearches == preferences.savedSearches)
        reloaded.removeSearch(id: remaining.id)
        #expect(AudioPreferences(defaults: defaults).savedSearches.isEmpty)
    }

    @Test func togglingPinDoesNotRecordAnExtraSearchUse() {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AudioPreferences(defaults: defaults)
        preferences.recordSearch("browser")
        preferences.togglePinnedSearch(" BROWSER ")
        #expect(preferences.savedSearches.first?.isPinned == true)
        #expect(preferences.savedSearches.first?.useCount == 1)
        preferences.togglePinnedSearch("browser")
        #expect(preferences.savedSearches.first?.isPinned == false)
        #expect(preferences.savedSearches.first?.useCount == 1)
        preferences.clearSearchHistory()
        #expect(preferences.savedSearches.isEmpty)
    }
}
