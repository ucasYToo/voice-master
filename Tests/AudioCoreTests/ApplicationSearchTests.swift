import Foundation
import Testing
@testable import AudioCore

struct ApplicationSearchTests {
    private func app(_ id: String, _ name: String, bundleID: String? = nil, playing: Bool = false) -> AudioApplication {
        AudioApplication(id: id, name: name, bundleID: bundleID, processIDs: [], pids: [], isPlaying: playing)
    }

    @Test func emptyQueryReturnsOriginalApplicationsInOrder() {
        let apps = [app("a", "网易云音乐"), app("b", "Google Chrome", playing: true)]
        #expect(ApplicationSearch.filter(apps, query: " \n\t ") == apps)
        #expect(ApplicationSearch.filter([], query: "anything").isEmpty)
    }

    @Test func matchesChineseEnglishAndBundleWithoutCaseOrAccentSensitivity() {
        let music = app("a", "网易云音乐", bundleID: "com.netease.163music")
        let chrome = app("b", "Google Chrome", bundleID: "com.google.Chrome")
        let cafe = app("c", "Café Player")
        let apps = [music, chrome, cafe]
        #expect(ApplicationSearch.filter(apps, query: "网易") == [music])
        #expect(ApplicationSearch.filter(apps, query: "CHROME") == [chrome])
        #expect(ApplicationSearch.filter(apps, query: "NETEASE.163") == [music])
        #expect(ApplicationSearch.filter(apps, query: "cafe") == [cafe])
        #expect(ApplicationSearch.filter(apps, query: "café") == [cafe])
    }

    @Test func matchesFullPinyinAndInitialsIncludingUsualMusicPronunciation() {
        let music = app("a", "网易云音乐")
        let player = app("b", "播放器")
        let apps = [music, player]
        #expect(ApplicationSearch.filter(apps, query: "wangyiyunyinyue") == [music])
        #expect(ApplicationSearch.filter(apps, query: "wyyyy") == [music])
        #expect(ApplicationSearch.filter(apps, query: "bofangqi") == [player])
        #expect(ApplicationSearch.filter(apps, query: "bfq") == [player])
    }

    @Test func matchesMixedLatinAndChineseNameInitials() {
        let music = app("a", "QQ音乐")
        #expect(ApplicationSearch.filter([music], query: "qqyinyue") == [music])
        #expect(ApplicationSearch.filter([music], query: "qqyy") == [music])
    }

    @Test func everyQueryWordMustMatchAcrossAvailableFields() {
        let music = app("a", "网易云音乐", bundleID: "com.netease.163music")
        let chrome = app("b", "Google Chrome", bundleID: "com.google.Chrome")
        let apps = [music, chrome]
        #expect(ApplicationSearch.filter(apps, query: " wang yi  163music \n") == [music])
        #expect(ApplicationSearch.filter(apps, query: "Google org.invalid").isEmpty)
        #expect(ApplicationSearch.filter(apps, query: "Chrome 网易").isEmpty)
    }

    @Test func filteringPreservesPlayingPriorityAndDistinctSourceIdentities() {
        let playing = app("process:10", "Browser Audio", bundleID: "org.browser.helper", playing: true)
        let idle = app("process:11", "Browser Audio", bundleID: "org.browser.helper.extra")
        let apps = [playing, app("other", "Music"), idle]
        #expect(ApplicationSearch.filter(apps, query: "browser") == [playing, idle])
        #expect(ApplicationSearch.filter(apps, query: "org.browser.helper") == [playing, idle])
    }
}
