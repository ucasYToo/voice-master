import AppKit
import AudioCore
import Foundation
import SwiftUI

/// Renders this app's own views offscreen with isolated preferences and no capture session.
@MainActor
enum PanelPreview {
    static func render(to directory: URL) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let suite = "local.voicemaster.panel-preview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw PreviewFailure("无法创建独立的预览设置。")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let applications = fixtureApplications()
        let preferences = AudioPreferences(defaults: defaults)
        preferences.selectedApplicationID = applications[0].id
        preferences.saveGain(1.5, for: applications[0])
        preferences.recordSearch("Chrome")
        preferences.togglePinnedSearch("Chrome")
        preferences.recordSearch("音乐")
        preferences.togglePinnedSearch("音乐")
        preferences.recordSearch("Safari")
        preferences.lastSearchQuery = ""

        let controller = AudioController(
            preferences: preferences,
            initialApplications: applications,
            enableMonitoring: false
        )
        defer { controller.shutdown() }

        try writePanel(controller, size: NSSize(width: 840, height: 650), dark: false,
                       to: directory.appendingPathComponent("main-light.png"))
        try writePanel(controller, size: NSSize(width: 840, height: 650), dark: true,
                       to: directory.appendingPathComponent("main-dark.png"))
        try writePanel(controller, size: NSSize(width: 740, height: 580), dark: false,
                       to: directory.appendingPathComponent("main-minimum.png"))

        // Filtering must leave the selected app and its remembered gain intact.
        controller.searchQuery = "没有匹配的应用"
        try writePanel(controller, size: NSSize(width: 840, height: 650), dark: false,
                       to: directory.appendingPathComponent("search-empty.png"))

        preferences.lastSearchQuery = ""
        preferences.selectedApplicationID = nil
        let emptyController = AudioController(
            preferences: preferences,
            initialApplications: [],
            enableMonitoring: false
        )
        defer { emptyController.shutdown() }
        try writePanel(emptyController, size: NSSize(width: 840, height: 650), dark: false,
                       to: directory.appendingPathComponent("empty-state.png"))
    }

    private static func writePanel(_ controller: AudioController, size: NSSize,
                                   dark: Bool, to file: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // The window is entirely outside display coordinates. Only its own view
        // hierarchy is cached; no screen or other application content is captured.
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -12_000, y: -12_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        let view = NSHostingView(rootView: MainPanel(controller: controller)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key))
        view.appearance = appearance
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        // Allow SwiftUI's initial layout transaction to reach this offscreen window.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw PreviewFailure("无法创建 \(file.lastPathComponent) 的预览位图。")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewFailure("无法编码 \(file.lastPathComponent) 的 PNG。")
        }
        try data.write(to: file, options: .atomic)
    }

    private static func fixtureApplications() -> [AudioApplication] {
        func path(_ bundleID: String, fallback: String) -> String {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path ?? fallback
        }
        return [
            AudioApplication(
                id: "app:\(path("com.google.Chrome", fallback: "/Applications/Google Chrome.app"))",
                name: "Google Chrome", bundleID: "com.google.Chrome",
                processIDs: [1001, 1002], pids: [1042, 1043], isPlaying: true
            ),
            AudioApplication(
                id: "app:\(path("com.apple.Music", fallback: "/System/Applications/Music.app"))",
                name: "音乐", bundleID: "com.apple.Music",
                processIDs: [1003], pids: [1050], isPlaying: false
            ),
            AudioApplication(
                id: "app:\(path("com.apple.Safari", fallback: "/Applications/Safari.app"))",
                name: "Safari", bundleID: "com.apple.Safari",
                processIDs: [1004], pids: [1052], isPlaying: false
            ),
            AudioApplication(
                id: "process:1234", name: "其他音频进程 (PID 1234)", bundleID: nil,
                processIDs: [1005], pids: [1234], isPlaying: false
            )
        ]
    }
}

private struct PreviewFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
