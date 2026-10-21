import CoreAudio
import Foundation

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static func check(_ code: OSStatus, _ operation: String) throws {
        guard code == noErr else {
            let bits = UInt32(bitPattern: code)
            let bytes = (0..<4).map { UInt8((bits >> (24 - $0 * 8)) & 0xff) }
            let fourCC = bytes.allSatisfy { (32...126).contains($0) }
                ? " / '\(String(bytes: bytes, encoding: .ascii) ?? "")'" : ""
            throw AudioFailure(message: "\(operation)失败（\(code)\(fourCC)）。若与权限有关，请在系统设置的「隐私与安全性 → 屏幕与系统音频录制」中允许 Voice Master，随后重新打开应用。")
        }
    }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        initial: T) throws -> T {
        var result = initial
        var property = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &result) { pointer in
            try AudioFailure.check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, UnsafeMutableRawPointer(pointer)), "读取音频属性")
        }
        return result
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try AudioFailure.check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), "读取设备名称")
        guard let value else { throw AudioFailure(message: "音频设备返回空名称或标识。") }
        return value.takeRetainedValue() as String
    }

    static func strings(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [String] {
        var property = address(selector)
        var value: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        try AudioFailure.check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), "读取捕获列表")
        guard let value else { throw AudioFailure(message: "设备没有返回捕获列表。") }
        return value.takeRetainedValue() as? [String] ?? []
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var property = address(selector, scope)
        var size: UInt32 = 0
        try AudioFailure.check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "读取音频列表长度")
        guard size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        try result.withUnsafeMutableBytes { bytes in
            try AudioFailure.check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, bytes.baseAddress!), "读取音频列表")
        }
        return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
    }

    static func channelCounts(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [UInt32] {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        try AudioFailure.check(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size), "读取声道布局长度")
        guard size >= MemoryLayout<AudioBufferList>.size else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try AudioFailure.check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, raw), "读取声道布局")
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map(\.mNumberChannels)
    }

    static func defaultOutput() throws -> AudioObjectID {
        let device = try read(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
        guard device != kAudioObjectUnknown else { throw AudioFailure(message: "没有可用的系统输出设备。") }
        return device
    }

    static func validateFloatStreams(_ device: AudioObjectID, scope: AudioObjectPropertyScope,
                                     sampleRate: Double) throws {
        let streams = try objects(device, kAudioDevicePropertyStreams, scope: scope)
        guard !streams.isEmpty else { throw AudioFailure(message: "设备没有可用的音频流。") }
        for stream in streams {
            let format = try read(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
                  format.mBitsPerChannel == 32,
                  format.mChannelsPerFrame > 0,
                  format.mBytesPerFrame == 4 * (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : format.mChannelsPerFrame),
                  abs(format.mSampleRate - sampleRate) < 1 else {
                throw AudioFailure(message: "当前设备的音频格式暂不支持，请尝试内建扬声器或其他输出设备。")
            }
        }
    }
}
