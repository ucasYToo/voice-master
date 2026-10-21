import CoreAudio

// The callback's context must outlive both its registration and the aggregate device.
// Failed teardown handles remain available for retry; a rare failed teardown leaks
// the context at process exit rather than allowing a callback into freed memory.
final class SessionResources {
    var tap: AudioObjectID = 0
    var aggregate: AudioObjectID = 0
    var hasIOProc = false
    var started = false
    var stopIO: () -> OSStatus = { noErr }
    var destroyIO: () -> OSStatus = { noErr }
    var destroyAggregate: (AudioObjectID) -> OSStatus = AudioHardwareDestroyAggregateDevice
    var destroyTap: (AudioObjectID) -> OSStatus = AudioHardwareDestroyProcessTap
    var releaseContext: () -> Void = {}
    private var contextReleased = false

    @discardableResult func cleanup() -> [OSStatus] {
        var errors: [OSStatus] = []
        if started {
            let result = stopIO()
            if result == noErr { started = false } else { errors.append(result) }
        }
        if hasIOProc {
            let result = destroyIO()
            if result == noErr { hasIOProc = false; started = false } else { errors.append(result) }
        }
        if aggregate != 0 {
            let result = destroyAggregate(aggregate)
            if result == noErr { aggregate = 0; hasIOProc = false; started = false } else { errors.append(result) }
        }
        // Always try to release the tap even when device cleanup fails, restoring direct output.
        if tap != 0 {
            let result = destroyTap(tap)
            if result == noErr { tap = 0 } else { errors.append(result) }
        }
        if !hasIOProc && !started && !contextReleased {
            releaseContext()
            contextReleased = true
        }
        return errors
    }

    var isEmpty: Bool { tap == 0 && aggregate == 0 && !hasIOProc && !started }
    deinit { cleanup() }
}
