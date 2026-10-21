import CoreAudio
import Foundation

public enum AudioDiagnostics {
    /// Metadata only. Does not create taps, start I/O, or request recording access.
    public static func report() throws -> String {
        let output = try HAL.defaultOutput()
        let apps = try AudioProcessDiscovery.applications()
        let data: [String: Any] = [
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "defaultOutput": [
                "id": output,
                "name": try HAL.string(output, kAudioObjectPropertyName),
                "sampleRate": try HAL.read(output, kAudioDevicePropertyNominalSampleRate, initial: Double(0)),
                "inputChannels": try HAL.channelCounts(output, scope: kAudioObjectPropertyScopeInput),
                "outputChannels": try HAL.channelCounts(output, scope: kAudioObjectPropertyScopeOutput)
            ],
            "applications": apps.map { ["id": $0.id, "name": $0.name, "processCount": $0.processIDs.count, "isPlaying": $0.isPlaying] as [String: Any] },
            "captureStarted": false
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}
