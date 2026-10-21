import AppKit
import Combine
import CoreAudio
import Foundation

public enum AudioStatusKind: Equatable, Sendable {
    case idle, working, warning, error, success
}

@MainActor
public final class AudioController: ObservableObject {
    @Published public private(set) var applications: [AudioApplication] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var status = "选择一个应用，开始独立调节音量。"
    @Published public private(set) var statusKind: AudioStatusKind = .idle
    @Published public private(set) var outputDeviceName = "跟随系统默认输出"
    @Published public private(set) var formatDescription = "连接后显示"
    @Published public private(set) var inputPeak: Float = 0
    @Published public private(set) var outputPeak: Float = 0
    @Published public private(set) var limitedFrames: UInt64 = 0
    @Published public private(set) var savedSearches: [SavedSearch] = []

    @Published public var searchQuery: String {
        didSet { preferences.lastSearchQuery = searchQuery }
    }

    @Published public var selectedApplicationID: String? {
        didSet {
            guard oldValue != selectedApplicationID else { return }
            preferences.selectedApplicationID = selectedApplicationID
            if isRunning || isBusy {
                stop(reason: "已切换应用，点击「开始调节」启用。")
            }
            gain = preferences.gain(for: selectedApplication)
            if !isBusy, let application = selectedApplication {
                setStatus("已准备好 \(application.name)，点击「开启音量调节」即可开始。", kind: .idle)
            }
        }
    }

    @Published public var gain: Double {
        didSet {
            let clamped = gain.isFinite ? min(4, max(0, gain)) : 1
            if gain != clamped { gain = clamped }
            preferences.saveGain(clamped, for: selectedApplication)
            let value = Float(clamped)
            worker.async { [session] in session.setGain(value) }
        }
    }

    public var selectedApplication: AudioApplication? {
        applications.first { $0.id == selectedApplicationID }
    }

    public var filteredApplications: [AudioApplication] {
        if cachedSearchQuery == searchQuery && cachedSearchApplications == applications { return cachedSearchResults }
        cachedSearchQuery = searchQuery
        cachedSearchApplications = applications
        cachedSearchResults = ApplicationSearch.filter(applications, query: searchQuery)
        return cachedSearchResults
    }

    public var rememberedGain: Double? {
        selectedApplication.map { preferences.gain(for: $0) }
    }

    private let preferences: AudioPreferences
    private let applicationProvider: @Sendable () throws -> [AudioApplication]
    private let worker = DispatchQueue(label: "local.voicemaster.audio-control", qos: .userInitiated)
    private let session = AudioSession()
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var pollPending = false
    private var generation = 0
    private var refreshGeneration = 0
    private var clockTicks = 0
    private var activeProcessIDs: [UInt32] = []
    private var isShuttingDown = false
    private var cachedSearchQuery: String?
    private var cachedSearchApplications: [AudioApplication] = []
    private var cachedSearchResults: [AudioApplication] = []

    /// Initial applications and disabled monitoring allow isolated preferences tests
    /// and offscreen previews without audio capture or access to the user's settings.
    public init(preferences: AudioPreferences? = nil, initialApplications: [AudioApplication]? = nil,
                enableMonitoring: Bool = true,
                applicationProvider: @escaping @Sendable () throws -> [AudioApplication] = { try AudioProcessDiscovery.applications() }) {
        let preferences = preferences ?? AudioPreferences()
        self.preferences = preferences
        self.applicationProvider = applicationProvider
        applications = initialApplications ?? []
        selectedApplicationID = preferences.selectedApplicationID
        searchQuery = preferences.lastSearchQuery
        savedSearches = preferences.savedSearches
        gain = preferences.gain(for: initialApplications?.first { $0.id == preferences.selectedApplicationID })
        if let application = selectedApplication { status = "已恢复 \(application.name) 的上次设置。" }
        if let device = try? HAL.defaultOutput(), let name = try? HAL.string(device, kAudioObjectPropertyName) {
            outputDeviceName = name
        }
        if initialApplications == nil { refreshApplications(silent: true) }
        guard enableMonitoring else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning || self.isBusy else { return }
                self.stop(reason: "电脑已进入睡眠。唤醒后点击「开始调节」即可继续。", kind: .warning)
            }
        }
    }

    public func selectApplication(_ app: AudioApplication) {
        guard !isBusy, applications.contains(where: { $0.id == app.id }) else { return }
        submitSearch()
        selectedApplicationID = app.id
    }

    public func submitSearch() {
        preferences.recordSearch(searchQuery)
        savedSearches = preferences.savedSearches
    }

    public func useSearch(_ query: String) {
        searchQuery = query
        submitSearch()
    }

    public func togglePinnedSearch(_ query: String) {
        preferences.togglePinnedSearch(query)
        savedSearches = preferences.savedSearches
    }

    public func removeSearch(id: String) {
        preferences.removeSearch(id: id)
        savedSearches = preferences.savedSearches
    }

    public func clearSearchHistory() {
        preferences.clearSearchHistory()
        savedSearches = preferences.savedSearches
    }

    public func selectNextSearchResult() {
        guard let first = filteredApplications.first else { submitSearch(); return }
        selectApplication(first)
    }

    public func refreshApplications() { refreshApplications(silent: false) }

    private func refreshApplications(silent: Bool) {
        guard !isRefreshing, !isBusy, !isShuttingDown else { return }
        isRefreshing = true
        refreshGeneration += 1
        let request = refreshGeneration
        let provider = applicationProvider
        worker.async { [weak self] in
            let result = Result { try provider() }
            let outputName = try? HAL.string(HAL.defaultOutput(), kAudioObjectPropertyName)
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown, self.refreshGeneration == request else { return }
                self.isRefreshing = false
                switch result {
                case .success(let apps):
                    self.applyApplications(apps)
                    if let outputName, !self.isRunning { self.outputDeviceName = outputName }
                    // Inventory refreshes must never hide an actionable audio error.
                    if !silent && !self.isRunning && !self.isBusy && self.statusKind == .idle {
                        self.status = apps.isEmpty ? "先打开媒体应用并播放声音，即可在这里找到它。" : "应用列表已更新。"
                    }
                case .failure(let error):
                    if !silent { self.setStatus(error.localizedDescription, kind: .error) }
                }
            }
        }
    }

    private func applyApplications(_ apps: [AudioApplication]) {
        let previousIdentity = Self.profileIdentity(selectedApplication)
        applications = apps
        guard previousIdentity != Self.profileIdentity(selectedApplication) else { return }
        if isRunning || isBusy {
            stop(reason: selectedApplication == nil
                ? "应用已退出。重新打开并播放声音后，即可继续调节。"
                : "音源身份已变化，请重新开启音量调节。", kind: .warning)
        }
        if let app = selectedApplication {
            gain = preferences.gain(for: app)
            if !isBusy && statusKind == .idle { status = "已恢复 \(app.name) 的上次设置。" }
        }
    }

    private nonisolated static func profileIdentity(_ application: AudioApplication?) -> String? {
        guard let application else { return nil }
        if application.id.hasPrefix("process:") {
            return "\(application.id)|\(application.processIDs.sorted())"
        }
        if let bundle = application.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundle.isEmpty {
            return "bundle:\(bundle.lowercased())"
        }
        return application.id
    }

    public func start() {
        guard !isRunning, !isBusy, !isShuttingDown else { return }
        guard let selectedID = selectedApplicationID else {
            setStatus("请先在左侧选择一个媒体应用。", kind: .warning)
            return
        }
        isBusy = true
        generation += 1
        let request = generation
        let value = Float(gain)
        let provider = applicationProvider
        let expectedIdentity = Self.profileIdentity(selectedApplication)
        setStatus("正在连接音源…首次使用请允许系统音频录制。", kind: .working)
        worker.async { [weak self, session] in
            let result = Result { () -> (AudioApplication, [AudioApplication], String, String) in
                let apps = try provider()
                guard let app = apps.first(where: { $0.id == selectedID }) else {
                    throw AudioFailure(message: "未找到这个应用的音频进程。请打开应用、播放媒体后重试。")
                }
                guard Self.profileIdentity(app) == expectedIdentity else {
                    throw AudioFailure(message: "应用的音源身份已更新，请刷新列表后重新开启音量调节。")
                }
                try session.start(processIDs: app.processIDs, gain: value)
                return (app, apps, session.deviceName, session.formatDescription)
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == request, !self.isShuttingDown else { return }
                self.isBusy = false
                switch result {
                case .success(let data):
                    self.isRunning = true
                    self.applications = data.1
                    self.outputDeviceName = data.2
                    self.formatDescription = data.3
                    self.activeProcessIDs = data.0.processIDs.sorted()
                    self.limitedFrames = 0
                    self.setStatus("正在为 \(data.0.name) 独立调节音量。", kind: .success)
                case .failure(let error):
                    self.isRunning = false
                    self.setStatus(error.localizedDescription, kind: .error)
                }
            }
        }
    }

    public func stop() { stop(reason: "已停止独立音量调节。") }

    private func stop(reason: String, kind: AudioStatusKind = .idle, thenRestart: Bool = false) {
        guard !isShuttingDown else { return }
        generation += 1
        let request = generation
        isRunning = false
        isBusy = true
        inputPeak = 0
        outputPeak = 0
        setStatus("正在断开音源…", kind: .working)
        worker.async { [weak self, session] in
            let errors = session.stop()
            Task { @MainActor [weak self] in
                guard let self, self.generation == request, !self.isShuttingDown else { return }
                self.isBusy = false
                if errors.isEmpty {
                    self.setStatus(reason, kind: kind)
                    if thenRestart { self.start() }
                } else {
                    self.setStatus("音频资源释放返回错误 \(errors)。请退出应用后重试。", kind: .error)
                }
            }
        }
    }

    public func shutdown() {
        isShuttingDown = true
        generation += 1
        refreshGeneration += 1
        timer?.invalidate()
        timer = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        sleepObserver = nil
        let errors = worker.sync { session.stop() }
        if !errors.isEmpty { NSLog("Voice Master teardown OSStatus: %@", String(describing: errors)) }
        isRunning = false
        isBusy = false
        isRefreshing = false
    }

    private func setStatus(_ value: String, kind: AudioStatusKind) {
        status = value
        statusKind = kind
    }

    private func tick() {
        guard !isShuttingDown else { return }
        clockTicks += 1
        if isRunning { poll() }
        else if clockTicks % 8 == 0 { refreshApplications(silent: true) }
    }

    private func poll() {
        guard isRunning, !isBusy, !pollPending else { return }
        pollPending = true
        let updateProcesses = clockTicks % 8 == 0
        let request = generation
        let provider = applicationProvider
        worker.async { [weak self, session] in
            let result = Result { () -> (AudioSession.Snapshot?, [AudioApplication]?) in
                (try session.snapshot(), updateProcesses ? try provider() : nil)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pollPending = false
                guard self.generation == request, self.isRunning, !self.isShuttingDown else { return }
                switch result {
                case .failure(let error): self.stop(reason: error.localizedDescription, kind: .error)
                case .success(let data):
                    guard let snapshot = data.0 else { self.stop(); return }
                    self.inputPeak = snapshot.input
                    self.outputPeak = snapshot.output
                    self.limitedFrames = snapshot.limited
                    if snapshot.routeChanged {
                        self.stop(reason: "输出设备已变化，正在重新连接。", thenRestart: true)
                        return
                    }
                    if let apps = data.1 {
                        self.applyApplications(apps)
                        guard self.isRunning else { return }
                        guard let selected = self.selectedApplication else {
                            self.stop(reason: "应用已退出。重新打开并播放声音后，即可继续调节。", kind: .warning)
                            return
                        }
                        if selected.processIDs.sorted() != self.activeProcessIDs {
                            self.stop(reason: "音源已更新，正在重新连接。", thenRestart: true)
                            return
                        }
                    }
                    self.setStatus(snapshot.silent
                        ? "等待应用播放声音；连续 15 秒无信号将自动停止。"
                        : "独立音量已启用。", kind: snapshot.silent ? .warning : .success)
                }
            }
        }
    }
}
