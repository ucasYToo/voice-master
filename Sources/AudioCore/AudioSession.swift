import CoreAudio
import Foundation
import RealtimeDSP

// Confined to AudioController's serial worker queue, never the audio thread.
final class AudioSession: @unchecked Sendable {
    private var resources: SessionResources?
    private var renderState: OpaquePointer?
    private var device: AudioObjectID = 0
    private var sampleRate: Double = 0
    private var startedAt = Date()
    private var lastSignalAt = Date()
    private var outputConfiguration: [UInt32] = []
    private var inputConfiguration: [UInt32] = []
    private var lastCallbackCount: UInt64 = 0
    private var lastCallbackAt = Date()
    private(set) var deviceName = "跟随系统默认输出"
    private(set) var formatDescription = "尚未启动"

    func start(processIDs: [AudioObjectID], gain: Float) throws {
        let previousErrors = stop()
        guard resources == nil else {
            throw AudioFailure(message: "上一次音频资源尚未释放（\(previousErrors)），请退出后重新打开应用。")
        }
        guard !processIDs.isEmpty else { throw AudioFailure(message: "未找到音源，请先播放媒体并刷新列表。") }
        let handles = SessionResources()
        resources = handles
        do {
            device = try HAL.defaultOutput()
            let uid = try HAL.string(device, kAudioDevicePropertyDeviceUID)
            deviceName = try HAL.string(device, kAudioObjectPropertyName)
            sampleRate = try HAL.read(device, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
            guard sampleRate.isFinite && (8_000...192_000).contains(sampleRate) else {
                throw AudioFailure(message: "不支持当前输出采样率。")
            }
            let physicalOutput = try HAL.channelCounts(device, scope: kAudioObjectPropertyScopeOutput)
            let physicalInput = try HAL.channelCounts(device, scope: kAudioObjectPropertyScopeInput)
            guard physicalInput.reduce(0, +) == 0 else {
                throw AudioFailure(message: "当前默认输出同时含麦克风输入。阶段 A 尚未验证这类设备的流隔离；请切换至内建扬声器或输出专用设备后重试。")
            }
            let channels = physicalOutput.reduce(0, +)
            guard channels == 1 || channels == 2 else {
                throw AudioFailure(message: "阶段 A 暂只支持单声道或立体声输出设备，当前设备有 \(channels) 声道。")
            }

            let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
            description.name = "Voice Master Media Tap"
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            // A whitelist tap never includes this app or FaceTime; discovery supplies the exact objects.
            try AudioFailure.check(AudioHardwareCreateProcessTap(description, &handles.tap), "创建音源捕获")
            let tapUID = try HAL.string(handles.tap, kAudioTapPropertyUID)
            let tapFormat = try HAL.read(handles.tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard tapFormat.mChannelsPerFrame == 2 else {
                throw AudioFailure(message: "音源未提供立体声混合流。")
            }

            // Restrict the hardware subdevice to output. Never consume microphone channels.
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Voice Master Private Output",
                kAudioAggregateDeviceUIDKey: "local.voicemaster.aggregate.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: uid,
                kAudioAggregateDeviceSubDeviceListKey: [[
                    kAudioSubDeviceUIDKey: uid,
                    kAudioSubDeviceInputChannelsKey: 0,
                    kAudioSubDeviceOutputChannelsKey: channels
                ]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]],
                // Do not block the UI/worker indefinitely while a paused application has no audio.
                kAudioAggregateDeviceTapAutoStartKey: false
            ]
            try AudioFailure.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &handles.aggregate), "创建私有播放设备")
            // HAL may publish aggregate streams shortly after creating the object.
            // This bounded wait runs only on the control queue, before starting capture.
            for _ in 0..<20 {
                let inputs = try? HAL.channelCounts(handles.aggregate, scope: kAudioObjectPropertyScopeInput)
                let outputs = try? HAL.channelCounts(handles.aggregate, scope: kAudioObjectPropertyScopeOutput)
                if inputs?.reduce(0, +) == 2 && outputs?.reduce(0, +) == channels { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            let installedTaps = try HAL.strings(handles.aggregate, kAudioAggregateDevicePropertyTapList)
            guard installedTaps == [tapUID] else {
                throw AudioFailure(message: "私有设备的媒体捕获映射不符，已停止处理。")
            }
            inputConfiguration = try HAL.channelCounts(handles.aggregate, scope: kAudioObjectPropertyScopeInput)
            outputConfiguration = try HAL.channelCounts(handles.aggregate, scope: kAudioObjectPropertyScopeOutput)
            // Refuse ambiguous aggregate layouts instead of accidentally forwarding microphone audio.
            guard inputConfiguration.reduce(0, +) == 2,
                  outputConfiguration.reduce(0, +) == channels else {
                throw AudioFailure(message: "当前设备无法建立仅包含媒体的两声道输入，已停止。验证版不读取麦克风；请尝试内建扬声器或不含输入的耳机输出。")
            }
            try HAL.validateFloatStreams(handles.aggregate, scope: kAudioObjectPropertyScopeInput, sampleRate: sampleRate)
            try HAL.validateFloatStreams(handles.aggregate, scope: kAudioObjectPropertyScopeOutput, sampleRate: sampleRate)

            guard let state = MVRenderStateCreate(sampleRate, 0, channels, gain) else {
                throw AudioFailure(message: "无法分配实时音频处理状态。")
            }
            renderState = state
            handles.releaseContext = { MVRenderStateDestroy(state) }
            var ioProc: AudioDeviceIOProcID?
            try AudioFailure.check(AudioDeviceCreateIOProcID(handles.aggregate, MVAudioIOProc, UnsafeMutableRawPointer(state), &ioProc), "注册音频回调")
            guard let ioProc else { throw AudioFailure(message: "系统未返回音频回调。") }
            handles.hasIOProc = true
            let aggregate = handles.aggregate
            handles.stopIO = { AudioDeviceStop(aggregate, ioProc) }
            handles.destroyIO = { AudioDeviceDestroyIOProcID(aggregate, ioProc) }
            // Balance Stop even if Start fails partway through system permission handling.
            handles.started = true
            try AudioFailure.check(AudioDeviceStart(aggregate, ioProc), "启动媒体处理")
            formatDescription = "\(Int(sampleRate)) Hz · Float32 · 立体声 → \(channels) 声道"
            startedAt = Date()
            lastSignalAt = startedAt
            lastCallbackAt = startedAt
            lastCallbackCount = 0
        } catch {
            stop()
            throw error
        }
    }

    func setGain(_ value: Float) {
        if let renderState { MVRenderSetGain(renderState, value) }
    }

    @discardableResult func stop() -> [OSStatus] {
        guard let handles = resources else { return [] }
        let errors = handles.cleanup()
        renderState = nil
        if handles.isEmpty { resources = nil }
        return errors
    }

    struct Snapshot {
        let input: Float
        let output: Float
        let limited: UInt64
        let silent: Bool
        let routeChanged: Bool
    }

    func snapshot() throws -> Snapshot? {
        guard let handles = resources, handles.started, let renderState else { return nil }
        let metrics = MVRenderReadMetrics(renderState)
        let now = Date()
        let currentOutput = try HAL.defaultOutput()
        if currentOutput != device { return Snapshot(input: 0, output: 0, limited: metrics.limitedFrames, silent: true, routeChanged: true) }
        let rate = try HAL.read(device, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
        let input = try HAL.channelCounts(handles.aggregate, scope: kAudioObjectPropertyScopeInput)
        let output = try HAL.channelCounts(handles.aggregate, scope: kAudioObjectPropertyScopeOutput)
        if rate != sampleRate || input != inputConfiguration || output != outputConfiguration {
            return Snapshot(input: 0, output: 0, limited: metrics.limitedFrames, silent: true, routeChanged: true)
        }
        try HAL.validateFloatStreams(handles.aggregate, scope: kAudioObjectPropertyScopeInput, sampleRate: sampleRate)
        try HAL.validateFloatStreams(handles.aggregate, scope: kAudioObjectPropertyScopeOutput, sampleRate: sampleRate)
        let alive = try HAL.read(device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))
        guard alive != 0 else { throw AudioFailure(message: "输出设备已断开，处理已停止。") }
        guard metrics.invalidBuffers == 0 else {
            throw AudioFailure(message: "音频回调的布局或帧数发生变化，已停止处理并释放捕获。")
        }
        if metrics.callbackCount != lastCallbackCount { lastCallbackCount = metrics.callbackCount; lastCallbackAt = now }
        guard now.timeIntervalSince(lastCallbackAt) < 5 else {
            throw AudioFailure(message: "5 秒未收到音频回调，已停止。请检查系统音频录制权限和设备。")
        }
        if metrics.inputPeak > 0.00001 { lastSignalAt = now }
        guard now.timeIntervalSince(lastSignalAt) < 15 else {
            throw AudioFailure(message: "连续 15 秒未检测到媒体信号，已停止。请确认音源正在播放、允许系统音频录制，或改选对应辅助进程。受保护媒体可能无法捕获。")
        }
        return Snapshot(input: metrics.inputPeak, output: metrics.outputPeak, limited: metrics.limitedFrames,
                        silent: now.timeIntervalSince(lastSignalAt) > 2, routeChanged: false)
    }

    deinit { stop() }
}
