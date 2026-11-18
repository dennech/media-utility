import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var downloadViewModel: DownloadViewModel?
    weak var trackedWindow: NSWindow?
    private var skipNextTerminationPrompt = false
    private var terminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyApplicationIcon()
    }

    func configure(window: NSWindow, viewModel: DownloadViewModel) {
        downloadViewModel = viewModel

        if trackedWindow !== window {
            trackedWindow?.delegate = nil
            trackedWindow = window
            trackedWindow?.delegate = self
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if skipNextTerminationPrompt {
            skipNextTerminationPrompt = false
            return .terminateNow
        }

        guard let downloadViewModel, downloadViewModel.requiresTerminationConfirmation else {
            return .terminateNow
        }

        guard shouldQuitCurrentOperation() else {
            return .terminateCancel
        }

        terminationTask?.cancel()
        terminationTask = Task { @MainActor [weak self, weak downloadViewModel] in
            defer { self?.terminationTask = nil }
            guard let downloadViewModel else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }

            await downloadViewModel.cancelCurrentOperationForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let downloadViewModel, downloadViewModel.requiresTerminationConfirmation else {
            return true
        }

        guard shouldQuitCurrentOperation() else {
            return false
        }

        terminationTask?.cancel()
        terminationTask = Task { @MainActor [weak self, weak downloadViewModel] in
            defer { self?.terminationTask = nil }
            guard let self else { return }
            guard let downloadViewModel else {
                skipNextTerminationPrompt = true
                NSApp.terminate(nil)
                return
            }

            await downloadViewModel.cancelCurrentOperationForTermination()
            skipNextTerminationPrompt = true
            NSApp.terminate(nil)
        }
        return false
    }

    private func applyApplicationIcon() {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
            return
        }

        if let icon = NSImage(named: "AppIcon") {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    private func shouldQuitCurrentOperation() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Cancel current download and quit?"
        alert.informativeText = "A download or conversion is still running. If you quit now, the current operation will stop and temporary files will be cleaned up."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Download and Quit")
        alert.addButton(withTitle: "Keep Working")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@main
struct YouTubeUtilityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = DownloadViewModel()

    var body: some Scene {
        Window("Media Utility", id: "main") {
            ContentView(viewModel: viewModel)
                .background(
                    WindowAccessor { window in
                        appDelegate.configure(window: window, viewModel: viewModel)
                    }
                )
        }
        .defaultSize(width: 500, height: 385)
        .windowResizability(.contentMinSize)
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}
