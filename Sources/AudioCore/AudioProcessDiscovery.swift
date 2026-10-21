import AppKit
import CoreAudio
import Darwin
import Foundation

public struct AudioApplication: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleID: String?
    public let processIDs: [AudioObjectID]
    public let pids: [pid_t]
    public let isPlaying: Bool

    public init(id: String, name: String, bundleID: String?, processIDs: [AudioObjectID], pids: [pid_t], isPlaying: Bool) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.processIDs = processIDs
        self.pids = pids
        self.isPlaying = isPlaying
    }
}

// The grouping inputs are separate from HAL so identity boundaries can be tested
// without audio permission or a running browser.
struct AudioProcessDescriptor {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
    let hostBundleURL: URL?
    let hostBundleID: String?
    let hostName: String?
    let isPlaying: Bool
}

public enum AudioProcessDiscovery {
    // FaceTime's rendered audio may be owned by the shared AV conference daemon
    // instead of the visible application. Keep these exact system call services
    // out of the selectable media sources as well.
    private static let excludedCallBundleIDs: Set<String> = [
        "com.apple.facetime",
        "com.apple.avconferenced",
        "com.apple.telephonyutilities",
        "com.apple.facetime.facetimenotificationextension",
        "com.apple.facetime.notificationviewbridgeservice"
    ]

    public static func applications() throws -> [AudioApplication] {
        let objects = try processObjects()
        let descriptors = objects.compactMap { object -> AudioProcessDescriptor? in
            // Processes can exit between reading the process list and its properties.
            guard let pid: pid_t = try? scalar(object, kAudioProcessPropertyPID, initial: 0), pid > 0 else {
                return nil
            }
            let runningApplication = NSRunningApplication(processIdentifier: pid)
            let bundleID = string(object, kAudioProcessPropertyBundleID) ?? runningApplication?.bundleIdentifier
            let hostURL = owningApplicationURL(pid: pid, runningApplication: runningApplication)
            let hostBundle = hostURL.flatMap(Bundle.init(url:))
            let executableName = executableURL(pid: pid)?.lastPathComponent
            let name = runningApplication?.localizedName ?? executableName ?? bundleID ?? "进程 \(pid)"
            let hostName = hostBundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? hostBundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? hostURL?.deletingPathExtension().lastPathComponent
            let playing: UInt32 = (try? scalar(object, kAudioProcessPropertyIsRunningOutput, initial: 0)) ?? 0
            return AudioProcessDescriptor(
                objectID: object, pid: pid, bundleID: bundleID, name: name,
                hostBundleURL: hostURL, hostBundleID: hostBundle?.bundleIdentifier,
                hostName: hostName, isPlaying: playing != 0
            )
        }
        return grouped(
            descriptors,
            ownPID: getpid(),
            ownBundleID: Bundle.main.bundleIdentifier,
            ownBundleURL: outermostApplicationURL(containing: Bundle.main.bundleURL)
        )
    }

    static func grouped(
        _ descriptors: [AudioProcessDescriptor], ownPID: pid_t,
        ownBundleID: String?, ownBundleURL: URL?
    ) -> [AudioApplication] {
        let allowed = descriptors.filter { process in
            guard process.pid != ownPID else { return false }
            let bundleIDs = [process.bundleID, process.hostBundleID].compactMap { $0?.lowercased() }
            guard !bundleIDs.contains(where: excludedCallBundleIDs.contains) else { return false }
            if let ownBundleID = ownBundleID?.lowercased(), bundleIDs.contains(ownBundleID) { return false }
            if let ownBundleURL, process.hostBundleURL == ownBundleURL { return false }
            return true
        }
        let groups = Dictionary(grouping: allowed) { process -> String in
            if let hostURL = process.hostBundleURL { return "app:\(hostURL.path)" }
            // A bundle identifier by itself is insufficient evidence that two
            // helper processes belong to the same user application.
            return "process:\(process.pid)"
        }
        return groups.map { identity, members in
            let ordered = members.sorted { $0.pid < $1.pid }
            let first = ordered[0]
            let fallbackName = first.hostBundleURL == nil ? "\(first.name) (PID \(first.pid))" : first.name
            return AudioApplication(
                id: identity,
                name: first.hostName ?? fallbackName,
                bundleID: first.hostBundleID ?? first.bundleID,
                processIDs: Array(Set(members.map(\.objectID))).sorted(),
                pids: Array(Set(members.map(\.pid))).sorted(),
                isPlaying: members.contains(where: \.isPlaying)
            )
        }.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    /// A nested Chrome Helper.app belongs to the enclosing Chrome.app. Use path
    /// components rather than string prefixes (Foo.app must not match Foobar.app).
    static func outermostApplicationURL(containing url: URL) -> URL? {
        let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard let index = components.firstIndex(where: { ($0 as NSString).pathExtension.lowercased() == "app" }) else {
            return nil
        }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])), isDirectory: true)
    }

    private static func owningApplicationURL(pid: pid_t, runningApplication: NSRunningApplication?) -> URL? {
        if let bundleURL = runningApplication?.bundleURL,
           let host = outermostApplicationURL(containing: bundleURL) { return host }
        if let executable = executableURL(pid: pid),
           let host = outermostApplicationURL(containing: executable) { return host }

        // Some helpers have an executable in a framework or XPC service. A live
        // parent chain is useful evidence; a generic WebKit bundle ID is not.
        var nextPID = pid
        var visited = Set<pid_t>()
        for _ in 0..<16 {
            guard nextPID > 1, visited.insert(nextPID).inserted else { break }
            var info = proc_bsdinfo()
            guard proc_pidinfo(nextPID, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                    == Int32(MemoryLayout<proc_bsdinfo>.size) else { break }
            nextPID = pid_t(info.pbi_ppid)
            guard nextPID > 1 else { break }
            if let application = NSRunningApplication(processIdentifier: nextPID),
               let bundleURL = application.bundleURL,
               let host = outermostApplicationURL(containing: bundleURL) { return host }
            if let executable = executableURL(pid: nextPID),
               let host = outermostApplicationURL(containing: executable) { return host }
        }
        return nil
    }

    private static func executableURL(pid: pid_t) -> URL? {
        // The PROC_PIDPATHINFO_MAXSIZE expression macro is not imported by Swift.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = path.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path))
    }

    private static func processObjects() throws -> [AudioObjectID] {
        var address = property(kAudioHardwarePropertyProcessObjectList)
        var byteCount: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount))
        guard byteCount > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioObjectID>.size)
        try objects.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, bytes.baseAddress!))
        }
        return Array(objects.prefix(Int(byteCount) / MemoryLayout<AudioObjectID>.size))
    }

    private static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = property(selector)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &result) { pointer in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer)))
        }
        return result
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    private static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw DiscoveryError(status: status) }
    }
}

private struct DiscoveryError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "无法读取音频进程列表（Core Audio \(status)）。请刷新重试。" }
}
