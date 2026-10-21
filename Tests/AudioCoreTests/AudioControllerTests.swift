import Foundation
import Testing
@testable import AudioCore

@MainActor
struct AudioControllerTests {
    private let browser = AudioApplication(id: "app:/Test/Browser.app", name: "Browser", bundleID: "test.browser", processIDs: [1], pids: [1], isPlaying: true)
    private let music = AudioApplication(id: "app:/Test/Music.app", name: "音乐", bundleID: "test.music", processIDs: [2], pids: [2], isPlaying: false)

    @Test func switchesAndRestoresIndependentGainsAcrossControllerRestart() {
        let suite = "VoiceMaster.ControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AudioPreferences(defaults: defaults)
        let apps = [browser, music]
        let controller = AudioController(preferences: preferences, initialApplications: apps, enableMonitoring: false)
        controller.selectApplication(browser)
        controller.gain = 2.25
        controller.selectApplication(music)
        #expect(controller.gain == 1)
        controller.gain = 0.75
        controller.selectApplication(browser)
        #expect(controller.gain == 2.25)
        controller.searchQuery = "bro"
        controller.shutdown()
        let restored = AudioController(preferences: AudioPreferences(defaults: defaults), initialApplications: apps, enableMonitoring: false)
        defer { restored.shutdown() }
        #expect(restored.selectedApplicationID == browser.id)
        #expect(restored.gain == 2.25)
        #expect(restored.searchQuery == "bro")
        #expect(!restored.isRunning)
        #expect(!restored.isBusy)
        restored.selectApplication(music)
        #expect(restored.gain == 0.75)
    }

    @Test func searchingDoesNotChangeSelectionOrSavePartialQueries() {
        let suite = "VoiceMaster.ControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AudioController(preferences: AudioPreferences(defaults: defaults), initialApplications: [browser, music], enableMonitoring: false)
        defer { controller.shutdown() }
        controller.selectApplication(browser)
        controller.gain = 2
        controller.searchQuery = "音"
        controller.searchQuery = "yinyue"
        #expect(controller.filteredApplications == [music])
        #expect(controller.selectedApplicationID == browser.id)
        #expect(controller.gain == 2)
        #expect(controller.savedSearches.isEmpty)
        controller.selectNextSearchResult()
        #expect(controller.selectedApplicationID == music.id)
        #expect(controller.gain == 1)
        #expect(controller.savedSearches.first?.query == "yinyue")
        #expect(controller.savedSearches.first?.useCount == 1)
        controller.searchQuery = "no such application"
        controller.selectNextSearchResult()
        #expect(controller.selectedApplicationID == music.id)
        #expect(controller.filteredApplications.isEmpty)
    }

    @Test func refreshDoesNotOverwriteActionableStartError() async throws {
        let suite = "VoiceMaster.ControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AudioController(preferences: AudioPreferences(defaults: defaults), initialApplications: [browser], enableMonitoring: false, applicationProvider: { [] })
        defer { controller.shutdown() }
        controller.selectApplication(browser)
        controller.start()
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isBusy)
        #expect(!controller.isRunning)
        #expect(controller.statusKind == .error)
        let error = controller.status
        controller.refreshApplications()
        for _ in 0..<100 where controller.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isRefreshing)
        #expect(controller.statusKind == .error)
        #expect(controller.status == error)
    }

    @Test func replacementBundleAtSamePathDoesNotInheritGain() async throws {
        let suite = "VoiceMaster.ControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let replacement = AudioApplication(id: browser.id, name: "Replacement", bundleID: "test.replacement", processIDs: [9], pids: [9], isPlaying: false)
        let controller = AudioController(preferences: AudioPreferences(defaults: defaults), initialApplications: [browser], enableMonitoring: false, applicationProvider: { [replacement] })
        defer { controller.shutdown() }
        controller.selectApplication(browser)
        controller.gain = 3
        controller.refreshApplications()
        for _ in 0..<100 where controller.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.selectedApplication?.bundleID == "test.replacement")
        #expect(controller.gain == 1)
    }

    @Test func sourceReplacementBeforeStartIsRejectedBeforeCreatingTap() async throws {
        let suite = "VoiceMaster.ControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let replacement = AudioApplication(id: browser.id, name: "Replacement", bundleID: "test.replacement", processIDs: [], pids: [], isPlaying: false)
        let controller = AudioController(preferences: AudioPreferences(defaults: defaults), initialApplications: [browser], enableMonitoring: false, applicationProvider: { [replacement] })
        defer { controller.shutdown() }
        controller.selectApplication(browser)
        controller.gain = 3
        controller.start()
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isRunning)
        #expect(controller.statusKind == .error)
        #expect(controller.status.contains("身份已更新"))
    }
}
