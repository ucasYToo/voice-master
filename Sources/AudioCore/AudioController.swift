import AppKit
import Combine
import CoreAudio
import Foundation

@MainActor
public final class AudioController: ObservableObject {
    @Published public private(set) var applications: [AudioApplication] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var status = "请播放媒体、选择音源，然后启动验证。"
    @Published public private(set) var outputDeviceName = "跟随系统默认输出"
    @Published public private(set) var formatDescription = "尚未启动"
    @Published public private(set) var inputPeak: Float = 0
    @Published public private(set) var outputPeak: Float = 0
    @Published public private(set) var limitedFrames: UInt64 = 0
    @Published public var selectedApplicationID: String? {
        didSet {
            UserDefaults.standard.set(selectedApplicationID, forKey: "selectedApplicationID")
            if oldValue != selectedApplicationID && (isRunning || busy) { stop() }
        }
    }
    @Published public var gain: Double {
        didSet {
            let clamped = gain.isFinite ? min(4, max(0, gain)) : 1
            if gain != clamped { gain = clamped }
            UserDefaults.standard.set(clamped, forKey: "gain")
            let value = Float(clamped)
            worker.async { [session] in session.setGain(value) }
        }
    }

    private let worker = DispatchQueue(label: "local.voicemaster.audio-control", qos: .userInitiated)
    private let session = AudioSession()
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var busy = false
    private var pollPending = false
    private var generation = 0
    private var ticks = 0
    private var activeProcessIDs: [UInt32] = []

    public init() {
        let savedGain = UserDefaults.standard.object(forKey: "gain") as? Double ?? 1
        gain = savedGain.isFinite ? min(4, max(0, savedGain)) : 1
        selectedApplicationID = UserDefaults.standard.string(forKey: "selectedApplicationID")
        if let device = try? HAL.defaultOutput(), let name = try? HAL.string(device, kAudioObjectPropertyName) {
            outputDeviceName = name
        }
        refreshApplications()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop(reason: "电脑即将睡眠，已停止处理。唤醒后请手动启动。") }
        }
    }

    public func refreshApplications() {
        do {
            applications = try AudioProcessDiscovery.applications()
            if !isRunning && !busy {
                status = applications.isEmpty ? "暂未发现音频应用。请先播放媒体，再刷新。" : "已发现 \(applications.count) 个音频应用；选择后可启动。"
            }
        } catch { status = error.localizedDescription }
    }

    public func start() {
        guard !isRunning && !busy else { return }
        // Re-resolve the selected identity immediately before capture, never trust stale PIDs.
        do { applications = try AudioProcessDiscovery.applications() }
        catch { status = error.localizedDescription; return }
        guard let app = applications.first(where: { $0.id == selectedApplicationID }) else {
            status = "所选音源已退出或尚未建立音频进程，请播放媒体并重新选择。"
            return
        }
        busy = true
        generation += 1
        let request = generation
        let value = Float(gain)
        status = "正在启动；首次使用请允许系统音频录制。"
        worker.async { [weak self, session] in
            let result: Result<(String, String), Error>
            do {
                try session.start(processIDs: app.processIDs, gain: value)
                result = .success((session.deviceName, session.formatDescription))
            } catch { result = .failure(error) }
            Task { @MainActor [weak self] in
                guard let self, self.generation == request else { return }
                self.busy = false
                switch result {
                case .success(let info):
                    self.isRunning = true
                    self.outputDeviceName = info.0
                    self.formatDescription = info.1
                    self.activeProcessIDs = app.processIDs.sorted()
                    self.limitedFrames = 0
                    self.status = "正在处理 \(app.name)。请在真实 FaceTime 通话中对比效果。"
                case .failure(let error):
                    self.isRunning = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    public func stop() { stop(reason: "已停止处理，已释放媒体捕获。") }

    private func stop(reason: String, thenRestart: Bool = false) {
        generation += 1
        let request = generation
        isRunning = false
        busy = true
        inputPeak = 0
        outputPeak = 0
        status = "正在停止…"
        worker.async { [weak self, session] in
            let errors = session.stop()
            Task { @MainActor [weak self] in
                guard let self, self.generation == request else { return }
                self.busy = false
                self.status = errors.isEmpty ? reason : "音频资源释放返回错误 \(errors)。请退出并检查媒体是否恢复播放。"
                if thenRestart && errors.isEmpty { self.start() }
            }
        }
    }

    public func shutdown() {
        generation += 1
        timer?.invalidate()
        timer = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        let errors = worker.sync { session.stop() }
        if !errors.isEmpty { NSLog("Voice Master teardown OSStatus: %@", String(describing: errors)) }
        isRunning = false
    }

    private func poll() {
        guard isRunning && !busy && !pollPending else { return }
        pollPending = true
        ticks += 1
        let updateProcesses = ticks % 8 == 0
        let request = generation
        worker.async { [weak self, session] in
            let result = Result { () -> (AudioSession.Snapshot?, [AudioApplication]?) in
                (try session.snapshot(), updateProcesses ? try AudioProcessDiscovery.applications() : nil)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pollPending = false
                guard self.generation == request && self.isRunning else { return }
                switch result {
                case .failure(let error): self.stop(reason: error.localizedDescription)
                case .success(let data):
                    guard let snapshot = data.0 else { self.stop(); return }
                    self.inputPeak = snapshot.input
                    self.outputPeak = snapshot.output
                    self.limitedFrames = snapshot.limited
                    if snapshot.routeChanged {
                        self.stop(reason: "输出设备或格式已变化，正在重建音频路径。", thenRestart: true)
                        return
                    }
                    if let apps = data.1 {
                        self.applications = apps
                        guard let selected = apps.first(where: { $0.id == self.selectedApplicationID }) else {
                            self.stop(reason: "音源已退出，已停止处理。重新播放后请刷新并启动。")
                            return
                        }
                        if selected.processIDs.sorted() != self.activeProcessIDs {
                            self.stop(reason: "音源辅助进程已变化，正在重建捕获。", thenRestart: true)
                            return
                        }
                    }
                    self.status = snapshot.silent
                        ? "暂未检测到媒体信号；请检查播放状态、权限或辅助进程。连续 15 秒无信号会自动停止。"
                        : "正在处理媒体；FaceTime 通话效果仍需实机验证。"
                }
            }
        }
    }
}
