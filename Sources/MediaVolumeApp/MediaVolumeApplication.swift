import AppKit
import AudioCore
import Darwin
import SwiftUI

@main
@MainActor
struct MediaVolumeApplication {
    static func main() {
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
private final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let controller = AudioController()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?

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
        if menuItem.action == #selector(stopProcessing(_:)) {
            return controller.isRunning
        }
        return true
    }

    private func createWindow() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Voice Master · 音频验证"
        panel.minSize = NSSize(width: 560, height: 610)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ValidationPanel(controller: controller))
        panel.setFrameAutosaveName("VoiceMasterValidationPanel")
        panel.center()
        window = panel
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = makeStatusIcon()
        item.button?.toolTip = "Voice Master · 媒体音量验证"
        let menu = NSMenu()
        menu.addItem(makeItem("打开验证面板…", action: #selector(showPanel(_:))))
        menu.addItem(makeItem("停止处理", action: #selector(stopProcessing(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem("退出 Voice Master", action: #selector(quit(_:)), key: "q"))
        item.menu = menu
        statusItem = item
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
        applicationMenu.addItem(makeItem("打开验证面板…", action: #selector(showPanel(_:)), key: "0"))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(makeItem("退出 Voice Master", action: #selector(quit(_:)), key: "q"))
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
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

    @objc private func stopProcessing(_ sender: Any?) {
        controller.stop()
    }

    @objc private func quit(_ sender: Any?) {
        NSApplication.shared.terminate(sender)
    }
}
