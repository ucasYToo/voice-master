import CoreAudio
import Testing
@testable import AudioCore

struct SessionResourcesTests {
    @Test func partialInitializationAndRepeatedStop() {
        var events: [String] = []
        let resources = SessionResources()
        resources.tap = 12
        resources.destroyTap = { _ in events.append("tap"); return noErr }
        resources.releaseContext = { events.append("context") }
        #expect(resources.cleanup().isEmpty)
        #expect(resources.cleanup().isEmpty)
        #expect(events == ["tap", "context"])
        #expect(resources.isEmpty)
    }

    @Test func teardownOrderAndIdempotency() {
        var events: [String] = []
        let resources = SessionResources()
        resources.tap = 12; resources.aggregate = 23
        resources.started = true; resources.hasIOProc = true
        resources.stopIO = { events.append("stop"); return noErr }
        resources.destroyIO = { events.append("io"); return noErr }
        resources.destroyAggregate = { _ in events.append("aggregate"); return noErr }
        resources.destroyTap = { _ in events.append("tap"); return noErr }
        resources.releaseContext = { events.append("context") }
        #expect(resources.cleanup().isEmpty)
        resources.cleanup()
        #expect(events == ["stop", "io", "aggregate", "tap", "context"])
    }

    @Test func failedStopStillReleasesTapAndRetainsCallbackContextUntilRetry() {
        var contextReleased = false
        var tapped = true
        let resources = SessionResources()
        resources.tap = 1; resources.aggregate = 2
        resources.started = true; resources.hasIOProc = true
        resources.stopIO = { -1 }; resources.destroyIO = { -2 }
        resources.destroyAggregate = { _ in -3 }
        resources.destroyTap = { _ in tapped = false; return noErr }
        resources.releaseContext = { contextReleased = true }
        #expect(resources.cleanup() == [-1, -2, -3])
        #expect(!tapped)
        #expect(!contextReleased)
        resources.stopIO = { noErr }; resources.destroyIO = { noErr }
        resources.destroyAggregate = { _ in noErr }
        #expect(resources.cleanup().isEmpty)
        #expect(contextReleased)
        #expect(resources.isEmpty)
    }
}
