import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var urlText = ""
    @Published var selectedMode: DownloadMode {
        didSet {
            defaults.set(selectedMode.rawValue, forKey: DefaultsKey.selectedMode)
        }
    }
    @Published var videoCompressionPreset: VideoCompressionPreset {
        didSet {
            defaults.set(videoCompressionPreset.rawValue, forKey: DefaultsKey.videoCompressionPreset)
        }
    }
    @Published var preserveOriginalWhenPossible: Bool {
        didSet {
            defaults.set(preserveOriginalWhenPossible, forKey: DefaultsKey.preserveOriginalWhenPossible)
        }
    }
    @Published var status = DownloadStatus.idle
    @Published var updateState: YtDlpUpdateState = .unavailable(localVersion: nil)
    @Published var toolchainStatusText = "Checking toolchain trust..."
    @Published var isWorking = false
    @Published var downloadProgress: Double?
    @Published var processingProgress: Double?
    @Published var lastSavedURL: URL?

    private let coordinator = DownloadCoordinator()
    private let updateCoordinator = YtDlpUpdateCoordinator()
    private let defaults = UserDefaults.standard

    private enum DefaultsKey {
        static let selectedMode = "YouTubeUtilityApp.selectedMode"
        static let videoCompressionPreset = "MediaUtility.videoCompressionPreset"
        static let preserveOriginalWhenPossible = "MediaUtility.preserveOriginalWhenPossible"
    }

    init() {
        let storedMode = defaults.string(forKey: DefaultsKey.selectedMode)
        let storedPreset = defaults.string(forKey: DefaultsKey.videoCompressionPreset)
        self.selectedMode = DownloadMode(rawValue: storedMode ?? "") ?? .videoMov
        self.videoCompressionPreset = VideoCompressionPreset(rawValue: storedPreset ?? "") ?? .high
        if defaults.object(forKey: DefaultsKey.preserveOriginalWhenPossible) == nil {
            self.preserveOriginalWhenPossible = true
        } else {
            self.preserveOriginalWhenPossible = defaults.bool(forKey: DefaultsKey.preserveOriginalWhenPossible)
        }
        coordinator.cleanupTemporaryWorkspaces()
        Task {
            await refreshUpdateState()
        }
    }

    private var requestID = UUID()
    private var downloadTask: Task<Void, Never>?
    var canStartDownload: Bool { !isWorking }
    var requiresTerminationConfirmation: Bool { isWorking }

    var videoOutputSettings: VideoOutputSettings {
        VideoOutputSettings(
            preset: videoCompressionPreset,
            preserveOriginalWhenPossible: preserveOriginalWhenPossible
        )
    }

    func startDownload() {
        guard canStartDownload else { return }

        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = .failure("Enter a valid media link to get started.")
            return
        }

        isWorking = true
        requestID = UUID()
        coordinator.startRequest()
        downloadTask = Task {
            await runDownload(with: trimmed)
        }
    }

    func openLastSaved() {
        guard let lastSavedURL else { return }
        NSWorkspace.shared.open(lastSavedURL)
    }

    func revealLastSaved() {
        guard let lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastSavedURL])
    }

    func cancelCurrentOperation() {
        guard isWorking else { return }
        status = .progress("Canceling…")
        let processes = coordinator.requestCancellation()
        Task.detached { ProcessTreeTerminator.cancel(processes: processes) }
    }

    func cancelCurrentOperationForTermination() async {
        cancelCurrentOperation()
        await downloadTask?.value
    }

    private func runDownload(with urlString: String) async {
        lastSavedURL = nil
        resetProgress()
        var cookieAccessMode: CookieAccessMode = .anonymous
        let request = requestID
        var destination: SaveDestination?
        var cookieWorkspace: URL?

        defer {
            if let cookieWorkspace { try? FileManager.default.removeItem(at: cookieWorkspace) }
            downloadTask = nil
            isWorking = false
        }

        while true {
            status = .progress("Checking installed tools...")

            do {
                try coordinator.prepareWorkspaceForNewOperation()
                let prepared = try await coordinator.prepareDownload(
                    urlString: urlString,
                    cookieAccessMode: cookieAccessMode
                ) { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.isWorking, self.requestID == request else { return }
                        self.apply(update)
                    }
                }

                let requestedMode = selectedMode
                let effectiveMode = prepared.resolvedMode(for: requestedMode)
                if effectiveMode != requestedMode {
                    status = .progress(prepared.autoSwitchMessage)
                }

                if destination?.url.pathExtension.lowercased() != effectiveMode.fileExtension {
                    let suggestedName = "\(prepared.suggestedBaseName).\(effectiveMode.fileExtension)"
                    guard let saveURL = presentSavePanel(suggestedName: suggestedName, mode: effectiveMode) else {
                        resetProgress()
                        status = .note(DownloadError.cancelled.localizedDescription)
                        return
                    }
                    destination = try SaveDestination(saveURL)
                    coordinator.rememberLastDirectory(saveURL.deletingLastPathComponent())
                }

                if cookieAccessMode != .anonymous {
                    let serviceLabel = prepared.service == .generic ? (prepared.requestURL.host ?? "this source") : prepared.service.displayName
                    status = .progress("Retrying \(serviceLabel) with \(cookieAccessMode.statusLabel) for this request only...")
                } else {
                    status = .progress(initialPhaseDescription(for: effectiveMode))
                }

                guard let destination else { return }
                let finalURL = try await coordinator.performDownload(
                    prepared: prepared,
                    mode: effectiveMode,
                    videoSettings: videoOutputSettings,
                    destination: destination
                ) { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.isWorking, self.requestID == request else { return }
                        self.apply(update)
                    }
                }

                lastSavedURL = finalURL
                resetProgress()
                status = .success(fileName: finalURL.lastPathComponent)
                return
            } catch let error as DownloadError {
                resetProgress()
                if case let .authenticationRequired(challenge) = error {
                    status = .progress(challenge.promptMessage)
                    guard let nextMode = presentCookieAccessPrompt(for: challenge, workspace: &cookieWorkspace) else {
                        status = .note("Authentication retry canceled.")
                        return
                    }
                    cookieAccessMode = nextMode
                    continue
                }

                if case .interrupted = error {
                    status = .note(error.localizedDescription)
                } else {
                    status = .failure(error.localizedDescription)
                }
                return
            } catch {
                resetProgress()
                status = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                return
            }
        }
    }

    private func refreshUpdateState(forceNetwork: Bool = false) async {
        do {
            let toolchain = try await ToolchainLocator.locate()
            toolchainStatusText = toolchain.trustState.statusText
            updateState = .checking(localVersion: toolchain.ytDlpVersion)
            updateState = await updateCoordinator.refreshState(using: toolchain, forceNetwork: forceNetwork)
        } catch {
            toolchainStatusText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            updateState = .unavailable(localVersion: nil)
        }
    }

    private func apply(_ update: OperationUpdate) {
        status = .progress(update.message)
        if let downloadFraction = update.downloadFraction {
            downloadProgress = downloadFraction
        }
        if let processingFraction = update.processingFraction {
            processingProgress = processingFraction
        }
    }

    private func resetProgress() {
        downloadProgress = nil
        processingProgress = nil
    }

    private func initialPhaseDescription(for mode: DownloadMode) -> String {
        switch mode {
        case .videoMov:
            return videoOutputSettings.processingMessage
        case .audioWav:
            return mode.phaseDescription
        }
    }

    private func presentSavePanel(suggestedName: String, mode: DownloadMode) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        panel.title = "Save \(mode == .videoMov ? "Video" : "Audio")"
        panel.prompt = "Save"

        if let type = UTType(filenameExtension: mode.fileExtension) {
            panel.allowedContentTypes = [type]
        }

        if let directoryURL = coordinator.lastDirectoryURL() {
            panel.directoryURL = directoryURL
        }

        let response = panel.runModal()
        return response == .OK ? panel.url : nil
    }

    private func presentCookieAccessPrompt(for challenge: AuthChallenge, workspace: inout URL?) -> CookieAccessMode? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = challenge.promptTitle
        alert.informativeText = challenge.promptMessage
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Choose Cookies File…")
        guard alert.runModal() == .alertSecondButtonReturn else { return nil }

        while let source = presentCookiesFileOpenPanel() {
            do {
                let directory = try coordinator.createTemporaryWorkspace()
                workspace = directory
                let copy = directory.appendingPathComponent("session.txt")
                try CookieFileValidator.writeScopedCopy(from: source, host: challenge.host, to: copy)
                return .cookiesFile(copy)
            } catch {
                if let directory = workspace { try? FileManager.default.removeItem(at: directory) }
                workspace = nil
                presentValidationError(message: error.localizedDescription)
            }
        }
        return nil
    }

    private func presentCookiesFileOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Cookies File"
        panel.message = "Select a Netscape cookies file to use for this request only."
        panel.prompt = "Use File"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func presentValidationError(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cookies file rejected"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
