import AppKit
import AudioCore
import SwiftUI

@MainActor
struct MainPanel: View {
    @ObservedObject var controller: AudioController
    @FocusState private var searchFocused: Bool
    @State private var otherProcessesExpanded = false
    @State private var diagnosticsExpanded = false

    private var applicationResults: [AudioApplication] {
        controller.filteredApplications.filter { $0.id.hasPrefix("app:") }
    }

    private var processResults: [AudioApplication] {
        controller.filteredApplications.filter { !$0.id.hasPrefix("app:") }
    }

    private var searching: Bool {
        !controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1).accessibilityHidden(true)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 740, minHeight: 580)
        .tint(PanelStyle.purple)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            Button("聚焦应用搜索") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onExitCommand {
            controller.searchQuery = ""
            searchFocused = true
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: ApplicationIconCache.shared.brandIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 35, height: 35)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice Master").font(.system(size: 15, weight: .semibold))
                    Text("应用独立音量").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            searchField
            searchHistory

            HStack {
                Text(searching ? "搜索结果" : "音频应用")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(String(controller.filteredApplications.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                refreshButton
            }
            .padding(.horizontal, 4)

            applicationList

            HStack(spacing: 5) {
                Image(systemName: "command")
                Text("F 搜索")
                Spacer()
                Text("仅调整选中应用")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(width: 274)
        .background(Color(nsColor: .windowBackgroundColor).overlay(Color.primary.opacity(0.025)))
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索应用名称", text: $controller.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit(commitSearch)
                .accessibilityLabel("搜索音频应用")
                .accessibilityIdentifier("application-search")
            if !controller.searchQuery.isEmpty {
                Button {
                    controller.searchQuery = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索 · Esc")
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(searchFocused ? PanelStyle.purple.opacity(0.65) : Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var searchHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("常用与最近搜索")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(controller.savedSearches, id: \.id) { search in
                        Menu(search.query) {
                            Button(search.isPinned ? "取消固定" : "固定搜索") {
                                controller.togglePinnedSearch(search.query)
                            }
                            Button("删除记录", role: .destructive) {
                                controller.removeSearch(id: search.id)
                            }
                        }
                    }
                    if !controller.savedSearches.isEmpty { Divider() }
                    Button("清空最近搜索", role: .destructive) { controller.clearSearchHistory() }
                        .disabled(controller.savedSearches.allSatisfy(\.isPinned))
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("管理已固定的搜索和最近记录")
                .accessibilityLabel("管理搜索记录")
            }
            .padding(.horizontal, 4)

            if controller.savedSearches.isEmpty {
                Text("输入后按回车，记住常用搜索。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(Array(controller.savedSearches.prefix(6)), id: \.id) { search in
                        searchChip(search)
                    }
                }
            }
        }
    }

    private func searchChip(_ search: SavedSearch) -> some View {
        let active = controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(search.query) == .orderedSame
        return Button {
            controller.useSearch(search.query)
            searchFocused = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: search.isPinned ? "pin.fill" : "clock")
                    .font(.system(size: 9, weight: .medium))
                Text(search.query)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? PanelStyle.purple : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(active ? PanelStyle.purple.opacity(0.11) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(search.query + (search.isPinned ? " · 已固定" : " · 右键可固定"))
        .contextMenu {
            Button(search.isPinned ? "取消固定" : "固定搜索") { controller.togglePinnedSearch(search.query) }
            Button("删除记录", role: .destructive) { controller.removeSearch(id: search.id) }
        }
    }

    private var refreshButton: some View {
        Button { controller.refreshApplications() } label: {
            if controller.isRefreshing {
                ProgressView().controlSize(.mini).frame(width: 14, height: 14)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 14, height: 14)
            }
        }
        .buttonStyle(.plain)
        .disabled(controller.isBusy || controller.isRefreshing)
        .keyboardShortcut("r", modifiers: .command)
        .help("刷新音频应用 · ⌘R")
        .accessibilityLabel("刷新音频应用")
    }

    @ViewBuilder private var applicationList: some View {
        if controller.filteredApplications.isEmpty {
            VStack(spacing: 10) {
                Spacer(minLength: 16)
                Image(systemName: searching ? "magnifyingglass" : "headphones")
                    .font(.system(size: 27, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(searching ? "没有找到匹配的应用" : "还没有音频应用")
                    .font(.system(size: 12, weight: .medium))
                Text(searching ? "换个名称试试，或查看全部应用。" : "先播放音乐或视频，再刷新列表。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if searching {
                    Button("清除搜索") { controller.searchQuery = "" }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(applicationResults) { application in
                        applicationRow(application)
                    }
                    if !processResults.isEmpty {
                        DisclosureGroup(isExpanded: Binding(
                            get: { searching || otherProcessesExpanded },
                            set: { otherProcessesExpanded = $0 }
                        )) {
                            VStack(spacing: 5) {
                                ForEach(processResults) { application in applicationRow(application) }
                            }
                            .padding(.top, 7)
                        } label: {
                            HStack {
                                Text("其他音频进程")
                                Spacer()
                                Text(String(processResults.count)).monospacedDigit()
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                        .padding(.top, applicationResults.isEmpty ? 0 : 10)
                        .tint(.secondary)
                    }
                }
                .padding(.trailing, 2)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
        }
    }

    private func applicationRow(_ application: AudioApplication) -> some View {
        ApplicationListRow(
            application: application,
            selected: application.id == controller.selectedApplicationID,
            action: { controller.selectApplication(application) }
        )
        .disabled(controller.isBusy)
    }

    @ViewBuilder private var detail: some View {
        if let application = controller.selectedApplication {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    selectedHeader(application)
                    gainCard
                    primaryAction
                    outputDevice
                    statusMessage
                    diagnostics(application)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        } else {
            VStack(spacing: 17) {
                Image(systemName: "waveform")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(PanelStyle.purple.opacity(0.75))
                    .frame(width: 88, height: 88)
                    .background(PanelStyle.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
                Text("选择一个音频应用")
                    .font(.title3.weight(.semibold))
                Text("在左侧搜索或选择媒体应用，\n为它设置合适的音量。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                Label("为每个应用记住上次使用的音量", systemImage: "arrow.clockwise.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                if controller.statusKind == .error || controller.statusKind == .warning {
                    statusMessage.padding(.top, 10).frame(maxWidth: 360)
                }
                Button("权限设置…", action: openPrivacySettings)
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectedHeader(_ application: AudioApplication) -> some View {
        HStack(alignment: .center, spacing: 13) {
            ApplicationIcon(application: application, size: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(application.name)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(2)
                    .help(application.name)
                Text(application.isPlaying ? "正在输出声音" : "等待应用播放")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 5, height: 5)
                Text(controller.isBusy ? "处理中" : controller.isRunning ? "已启用" : "未启用")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(statusColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(statusColor.opacity(0.09), in: Capsule())
        }
    }

    private var gainCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("播放增益")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(Int((controller.gain * 100).rounded())))
                            .font(.system(size: 58, weight: .semibold, design: .rounded).monospacedDigit())
                        Text("%")
                            .font(.system(size: 23, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("播放增益")
                    .accessibilityValue("\(Int((controller.gain * 100).rounded()))%")
                }
                Spacer()
                Image(systemName: controller.gain == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(PanelStyle.purple.opacity(0.8))
                    .frame(width: 54, height: 54)
                    .background(PanelStyle.purple.opacity(0.08), in: Circle())
                    .accessibilityHidden(true)
            }

            VStack(spacing: 5) {
                Slider(value: $controller.gain, in: 0...4)
                    .controlSize(.large)
                    .accessibilityLabel("播放增益")
                    .accessibilityValue("\(Int((controller.gain * 100).rounded()))%")
                HStack {
                    Text("0% · 静音")
                    Spacer()
                    Text("400%")
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
            }

            HStack(spacing: 7) {
                ForEach([100, 150, 200], id: \.self) { percent in
                    Button { controller.gain = Double(percent) / 100 } label: {
                        Text("\(percent)%")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(abs(controller.gain * 100 - Double(percent)) < 0.5 ? PanelStyle.purple : Color.secondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                abs(controller.gain * 100 - Double(percent)) < 0.5 ? PanelStyle.purple.opacity(0.12) : Color.primary.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("设置增益为 \(percent)%")
                }
                Spacer(minLength: 4)
                Button { controller.gain = 1 } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 27, height: 27)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("0", modifiers: .command)
                .help("恢复 100% · ⌘0")
                .accessibilityLabel("恢复 100%")
            }

            Text("自动记住此应用的音量，下次选择时恢复。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay { RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.02)) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.035), lineWidth: 1)
        }
        .disabled(controller.isBusy)
    }

    private var primaryAction: some View {
        Button {
            if controller.isRunning { controller.stop() } else { controller.start() }
        } label: {
            HStack(spacing: 8) {
                if controller.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: controller.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(controller.isBusy ? "正在切换…" : controller.isRunning ? "停止调节" : "开启音量调节")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(controller.isBusy)
    }

    private var outputDevice: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("输出设备").font(.system(size: 10)).foregroundStyle(.tertiary)
                Text(controller.outputDeviceName.isEmpty ? "跟随系统默认输出" : controller.outputDeviceName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            Text("跟随系统")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var statusMessage: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: statusSymbol)
                .font(.system(size: 12))
                .foregroundStyle(statusColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 7) {
                Text(controller.status)
                    .font(.system(size: 11))
                    .foregroundStyle(controller.statusKind == .error ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if controller.statusKind == .error || controller.statusKind == .warning {
                    Button("检查权限设置…", action: openPrivacySettings)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusColor.opacity(controller.statusKind == .error || controller.statusKind == .warning ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private func diagnostics(_ application: AudioApplication) -> some View {
        DisclosureGroup(isExpanded: $diagnosticsExpanded) {
            VStack(alignment: .leading, spacing: 11) {
                LabeledContent("音频格式", value: controller.formatDescription.isEmpty ? "尚未启动" : controller.formatDescription)
                    .textSelection(.enabled)
                SignalMeter(label: "输入峰值", peak: controller.inputPeak)
                SignalMeter(label: "输出峰值", peak: controller.outputPeak)
                LabeledContent("限幅帧数", value: String(controller.limitedFrames))
                LabeledContent("音频进程", value: application.pids.map { String($0) }.joined(separator: ", "))
                    .textSelection(.enabled)
                HStack {
                    Text("电平表示当前处理链路中的信号。")
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 5)
                    Button("权限设置…", action: openPrivacySettings).buttonStyle(.link)
                }
            }
            .font(.system(size: 10).monospacedDigit())
            .padding(.top, 12)
        } label: {
            Text("诊断信息").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }

    private var statusColor: Color {
        switch controller.statusKind {
        case .error: return .red
        case .warning: return .orange
        case .working: return PanelStyle.purple
        case .success: return .green
        case .idle: return controller.isRunning ? PanelStyle.purple : .secondary
        }
    }

    private var statusSymbol: String {
        switch controller.statusKind {
        case .error: return "exclamationmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .working: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .idle: return "info.circle"
        }
    }

    private func commitSearch() {
        guard !controller.isBusy else { return }
        controller.selectNextSearchResult()
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") else { return }
        NSWorkspace.shared.open(url)
    }
}

// Preserve the existing app entry point while its lifecycle code adopts the new name.
typealias ValidationPanel = MainPanel
