import AppKit
import AudioCore
import SwiftUI

enum PanelStyle {
    static let purple = Color(red: 0.55, green: 0.36, blue: 0.83)
}

@MainActor
final class ApplicationIconCache {
    static let shared = ApplicationIconCache()
    private let images = NSCache<NSString, NSImage>()

    private init() { images.countLimit = 128 }

    lazy var brandIcon: NSImage = {
        if let file = Bundle.main.path(forResource: "AppIcon", ofType: "icns"), let image = NSImage(contentsOfFile: file) {
            return image
        }
        return NSApplication.shared.applicationIconImage
    }()

    func icon(for application: AudioApplication) -> NSImage {
        let key = application.id as NSString
        if let cached = images.object(forKey: key) { return cached }
        let image: NSImage
        if application.id.hasPrefix("app:") {
            image = NSWorkspace.shared.icon(forFile: String(application.id.dropFirst(4)))
        } else if let bundleID = application.bundleID,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 32, height: 32))
        }
        images.setObject(image, forKey: key)
        return image
    }
}

@MainActor
struct ApplicationIcon: View {
    let application: AudioApplication
    let size: CGFloat

    var body: some View {
        Image(nsImage: ApplicationIconCache.shared.icon(for: application))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor
struct ApplicationListRow: View {
    let application: AudioApplication
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ApplicationIcon(application: application, size: 31)
                VStack(alignment: .leading, spacing: 4) {
                    Text(application.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(application.isPlaying ? "有音频输出" : "等待播放")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 3)
                if application.isPlaying {
                    Circle().fill(Color.green.opacity(0.85)).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? PanelStyle.purple.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? PanelStyle.purple.opacity(0.13) : Color.clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(application.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(application.name + (application.isPlaying ? "，有音频输出" : "，等待播放"))
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SignalMeter: View {
    let label: String
    let peak: Float

    private var safePeak: Double { peak.isFinite ? max(0, Double(peak)) : 0 }
    private var level: String {
        safePeak > 0.000001 ? String(format: "%.1f dBFS", 20 * log10(safePeak)) : "−∞ dBFS"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 62, alignment: .leading)
            ProgressView(value: min(safePeak, 1), total: 1)
                .tint(safePeak > 0.95 ? .orange : PanelStyle.purple)
                .accessibilityLabel(label)
                .accessibilityValue(level)
            Text(level)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 10).monospacedDigit())
    }
}
