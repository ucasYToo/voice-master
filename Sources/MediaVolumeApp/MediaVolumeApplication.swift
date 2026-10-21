import AppKit
import AudioCore
import Darwin
import SwiftUI

@main
@MainActor
struct MediaVolumeApplication {
    static func main() {
        if let argument = CommandLine.arguments.firstIndex(of: "--render-preview") {
            guard CommandLine.arguments.indices.contains(argument + 1) else {
                fputs("Usage: VoiceMaster --render-preview <directory>\n", stderr)
                exit(EXIT_FAILURE)
            }
            do {
                try PanelPreview.render(to: URL(fileURLWithPath: CommandLine.arguments[argument + 1], isDirectory: true))
            } catch {
                fputs("UI preview failed: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            do {
                print(try AudioDiagnostics.report())
            } catch {
                FileHandle.standardError.write(Data("诊断失败：\(error.localizedDescription)\n".utf8))
                exit(EXIT_FAILURE)
            }
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let controller = AudioController()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusSummaryItem: NSMenuItem?
    private var toggleProcessingItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationIcon()
        installMainMenu()
        installStatusItem()
        createWindow()
        showPanel(nil)
        controller.refreshApplications()

        // Exercise the actual app lifecycle without starting a tap or requesting capture permission.
        if CommandLine.arguments.contains("--smoke-test") {
            guard bundledIconsAreValid else {
                FileHandle.standardError.write(Data("VOICE_MASTER_ICONS_MISSING_OR_INVALID\n".utf8))
                controller.shutdown()
                exit(EXIT_FAILURE)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("VOICE_MASTER_ICONS_OK")
                print("VOICE_MASTER_SMOKE_TEST_OK")
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleProcessing(_:)) {
            return !controller.isBusy && (controller.isRunning || controller.selectedApplication != nil)
        }
        if menuItem.action == #selector(resetGain(_:)) {
            return !controller.isBusy && controller.selectedApplication != nil
        }
        return true
    }

    private func createWindow() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Voice Master"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.minSize = NSSize(width: 740, height: 608)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: MainPanel(controller: controller))
        panel.setFrameAutosaveName("VoiceMasterMainPanel")
        panel.center()
        window = panel
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = makeStatusIcon()
        item.button?.toolTip = "Voice Master · 应用独立音量"
        let menu = NSMenu()
        menu.delegate = self
        let summary = NSMenuItem(title: "Voice Master", action: nil, keyEquivalent: "")
        menu.addItem(summary)
        statusSummaryItem = summary
        menu.addItem(.separator())
        menu.addItem(makeItem("打开音量面板…", action: #selector(showPanel(_:))))
        let toggle = makeItem("开启音量调节", action: #selector(toggleProcessing(_:)))
        menu.addItem(toggle)
        toggleProcessingItem = toggle
        menu.addItem(makeItem("恢复 100%", action: #selector(resetGain(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem("退出 Voice Master", action: #selector(quit(_:)), key: "q"))
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        let name = controller.selectedApplication?.name ?? "未选择应用"
        statusSummaryItem?.title = "\(name) · \(Int((controller.gain * 100).rounded()))%"
        toggleProcessingItem?.title = controller.isBusy ? "正在切换…" : controller.isRunning ? "停止调节" : "开启音量调节"
    }

    private func installApplicationIcon() {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return }
        NSApplication.shared.applicationIconImage = image
    }

    private func makeStatusIcon() -> NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for name in ["StatusIcon", "StatusIcon@2x"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else { continue }
            representation.size = image.size
            image.addRepresentation(representation)
        }
        if image.representations.isEmpty {
            // Direct executable launches outside the packaged .app have no bundled artwork.
            return NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Voice Master")
        }
        image.isTemplate = true
        image.accessibilityDescription = "Voice Master"
        return image
    }

    private var bundledIconsAreValid: Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "AppIcon.icns",
              let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let appIcon = NSImage(contentsOf: url), appIcon.isValid,
              let statusIcon = statusItem?.button?.image, statusIcon.isTemplate,
              statusIcon.size == NSSize(width: 18, height: 18) else { return false }
        return statusIcon.representations.contains { $0.pixelsWide == 18 && $0.pixelsHigh == 18 }
            && statusIcon.representations.contains { $0.pixelsWide == 36 && $0.pixelsHigh == 36 }
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(makeItem("打开音量面板…", action: #selector(showPanel(_:)), key: "1"))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(makeItem("退出 Voice Master", action: #selector(quit(_:)), key: "q"))
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("撤销", NSSelectorFromString("undo:"), "z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApplication.shared.mainMenu = menu
    }

    private func makeItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showPanel(_ sender: Any?) {
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func toggleProcessing(_ sender: Any?) {
        if controller.isRunning { controller.stop() } else { controller.start() }
    }

    @objc private func resetGain(_ sender: Any?) {
        controller.gain = 1
    }

    @objc private func quit(_ sender: Any?) {
        NSApplication.shared.terminate(sender)
    }
}
