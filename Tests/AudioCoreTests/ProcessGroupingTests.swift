import CoreAudio
import Foundation
import Testing
@testable import AudioCore

struct ProcessGroupingTests {
    private func process(
        _ pid: pid_t, bundle: String? = nil, host: String? = nil,
        hostID: String? = nil, playing: Bool = false
    ) -> AudioProcessDescriptor {
        AudioProcessDescriptor(
            objectID: AudioObjectID(pid + 1_000), pid: pid, bundleID: bundle,
            name: "Source", hostBundleURL: host.map { URL(fileURLWithPath: $0, isDirectory: true) },
            hostBundleID: hostID, hostName: host == nil ? nil : "Host", isPlaying: playing
        )
    }

    private func group(_ processes: [AudioProcessDescriptor]) -> [AudioApplication] {
        AudioProcessDiscovery.grouped(
            processes, ownPID: 42, ownBundleID: "local.MediaVolume",
            ownBundleURL: URL(fileURLWithPath: "/Applications/MediaVolume.app", isDirectory: true)
        )
    }

    @Test func nestedBrowserHelperResolvesToOuterApplication() {
        let helper = URL(fileURLWithPath: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")
        #expect(AudioProcessDiscovery.outermostApplicationURL(containing: helper)?.path == "/Applications/Browser.app")
        #expect(AudioProcessDiscovery.outermostApplicationURL(containing: URL(fileURLWithPath: "/Applications/Browser.application/helper")) == nil)
    }

    @Test func hostGroupsHelpersAndAggregatesPlaybackState() {
        let result = group([
            process(10, bundle: "org.browser", host: "/Applications/Browser.app", hostID: "org.browser"),
            process(11, bundle: "org.browser.helper", host: "/Applications/Browser.app", hostID: "org.browser", playing: true)
        ])
        #expect(result.count == 1)
        #expect(result.first?.pids == [10, 11])
        #expect(result.first?.processIDs == [1_010, 1_011])
        #expect(result.first?.isPlaying == true)
    }

    @Test func similarBundleIdentifiersDoNotGuessCommonOwnership() {
        let result = group([
            process(10, bundle: "org.browser.helper"),
            process(11, bundle: "org.browser.helper.extra"),
            process(12, bundle: "org.browser.helper")
        ])
        #expect(result.count == 3)
    }

    @Test func selfAndFaceTimeAreExcludedIncludingTheirNestedHelpers() {
        let result = group([
            process(42),
            process(10, bundle: "local.MediaVolume"),
            process(11, host: "/Applications/MediaVolume.app"),
            process(12, bundle: "com.apple.FaceTime"),
            process(13, bundle: "com.apple.FaceTime.helper", hostID: "com.apple.FaceTime"),
            process(15, bundle: "com.apple.avconferenced", playing: true),
            process(16, bundle: "com.apple.TelephonyUtilities"),
            process(17, bundle: "com.apple.FaceTime.FaceTimeNotificationExtension"),
            process(14, bundle: "org.media")
        ])
        #expect(result.flatMap(\.pids) == [14])
    }

    @Test func appPathsWithCommonPrefixRemainSeparate() throws {
        let result = group([
            process(10, host: "/Applications/Browser.app"),
            process(11, host: "/Applications/Browser Beta.app")
        ])
        try #require(result.count == 2)
        #expect(result[0].id != result[1].id)
    }
}
