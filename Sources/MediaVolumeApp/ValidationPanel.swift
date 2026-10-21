import AppKit
import AudioCore
import SwiftUI

@MainActor
struct ValidationPanel: View {
    @ObservedObject var controller: AudioController

    private var selectedApplication: AudioApplication? {
        controller.applications.first { $0.id == controller.selectedApplicationID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                applicationPicker
                gainControl
                controls
                diagnostics
                verificationNote
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 540, minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("媒体独立音量")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("阶段 A · 验证版")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("选择一个媒体应用，调整它的播放增益。")
                .foregroundStyle(.secondary)
        }
    }

    private var applicationPicker: some View {
        GroupBox("音频来源") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("应用", selection: $controller.selectedApplicationID) {
                        Text("请选择媒体应用").tag(nil as String?)
                        ForEach(controller.applications) { application in
                            Text(application.name + (application.isPlaying ? " · 正在播放" : ""))
                                .tag(Optional(application.id))
                        }
                    }
                    .disabled(controller.isRunning)
                    Button("刷新") { controller.refreshApplications() }
                        .disabled(controller.isRunning)
                }
                if let application = selectedApplication {
                    Text("已识别 \(application.processIDs.count) 个音频进程 · PID \(application.pids.map { String($0) }.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("先让媒体开始播放，再刷新列表。浏览器会按可识别的宿主应用合并音频进程。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var gainControl: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("媒体增益").font(.headline)
                    Spacer()
                    Text("\(Int((controller.gain * 100).rounded()))%")
                        .font(.title2.monospacedDigit().weight(.medium))
                        .accessibilityLabel("增益百分比")
                    Button("恢复 100%") { controller.gain = 1 }
                }
                Slider(value: $controller.gain, in: 0...4, step: 0.01)
                    .accessibilityLabel("媒体增益")
                HStack {
                    Text("0%")
                    Spacer()
                    Text("400%")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                Text("100% 为单位增益。限幅会抑制过大的峰值；实际听感需实测。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if controller.isRunning {
                    Button("停止处理") { controller.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else {
                    Button("启动处理") { controller.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedApplication == nil)
                }
                Spacer()
                Button("权限设置…", action: openPrivacySettings)
                    .help("打开系统设置的隐私与安全性，检查系统音频录制权限。")
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: controller.isRunning ? "waveform.circle.fill" : "info.circle")
                    .foregroundStyle(controller.isRunning ? Color.accentColor : Color.secondary)
                Text(controller.status)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var diagnostics: some View {
        GroupBox("链路状态") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("系统输出", value: controller.outputDeviceName.isEmpty ? "尚未读取" : controller.outputDeviceName)
                LabeledContent("音频格式", value: controller.formatDescription.isEmpty ? "启动后显示" : controller.formatDescription)
                Divider()
                SignalMeter(label: "捕获峰值", peak: controller.inputPeak)
                SignalMeter(label: "处理后峰值", peak: controller.outputPeak)
                LabeledContent("发生限幅的帧数", value: String(controller.limitedFrames))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(6)
        }
    }

    private var verificationNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("FaceTime 通话效果尚未实机验证", systemImage: "testtube.2")
                .font(.callout.weight(.medium))
            Text("请自行开始通话，对比停止与启动处理时的媒体和通话音量，并验证说话、静默及停止后的恢复。电平表仅表示处理链路信号，不能证明最终听感。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("关闭窗口后仍可从菜单栏打开。重启应用不会自动开始处理。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SignalMeter: View {
    let label: String
    let peak: Float

    private var safePeak: Double {
        peak.isFinite ? max(0, Double(peak)) : 0
    }

    private var level: String {
        safePeak > 0.000001 ? String(format: "%.1f dBFS", 20 * log10(safePeak)) : "−∞ dBFS"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 80, alignment: .leading)
            ProgressView(value: min(safePeak, 1), total: 1)
                .tint(safePeak > 0.95 ? .orange : .accentColor)
                .accessibilityLabel(label)
                .accessibilityValue(level)
            Text(level)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .trailing)
        }
    }
}
