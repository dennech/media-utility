import CryptoKit
import Darwin
import Foundation

enum ProcessStream: Sendable {
    case stdout
    case stderr
}

private final class YtDlpProgressParser {
    private let message: String
    private let emit: @Sendable (OperationUpdate) -> Void
    private let queue = DispatchQueue(label: "MediaUtility.ytdlp-progress")
    private var buffer = ""
    private var lastFraction: Double?
    private static let progressExpression = try? NSRegularExpression(
        pattern: #"\[download\]\s+(\d+(?:\.\d+)?)%"#
    )

    init(message: String, emit: @escaping @Sendable (OperationUpdate) -> Void) {
        self.message = message
        self.emit = emit
    }

    func consume(_ text: String) {
        guard !text.isEmpty else { return }
        queue.sync {
            self.buffer.append(text)
            self.flushCompleteLines()
            if self.buffer.count > 8192 { self.buffer = String(self.buffer.suffix(8192)) }
        }
    }

    private func flushCompleteLines() {
        var lineStart = buffer.startIndex
        var index = buffer.startIndex

        while index < buffer.endIndex {
            let character = buffer[index]
            guard character == "\n" || character == "\r" else {
                index = buffer.index(after: index)
                continue
            }

            processLine(String(buffer[lineStart..<index]))

            let next = buffer.index(after: index)
            if next < buffer.endIndex {
                let nextCharacter = buffer[next]
                if (character == "\r" && nextCharacter == "\n") || (character == "\n" && nextCharacter == "\r") {
                    index = next
                }
            }

            lineStart = buffer.index(after: index)
            index = lineStart
        }

        buffer = lineStart < buffer.endIndex ? String(buffer[lineStart...]) : ""
    }

    private func processLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        guard let expression = Self.progressExpression else { return }

        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: nsRange),
              let percentRange = Range(match.range(at: 1), in: line),
              let percent = Double(line[percentRange]) else {
            return
        }

        let fraction = min(max(percent / 100, 0), 1)
        guard lastFraction != fraction else { return }
        lastFraction = fraction
        emit(.downloading(message: message, fraction: fraction))
    }
}

private final class FFmpegProgressParser {
    private let message: String
    private let duration: TimeInterval?
    private let downloadFraction: Double?
    private let emit: @Sendable (OperationUpdate) -> Void
    private let queue = DispatchQueue(label: "MediaUtility.ffmpeg-progress")
    private var buffer = ""
    private var lastFraction: Double?

    init(
        message: String,
        duration: TimeInterval?,
        downloadFraction: Double?,
        emit: @escaping @Sendable (OperationUpdate) -> Void
    ) {
        self.message = message
        self.duration = duration
        self.downloadFraction = downloadFraction
        self.emit = emit
    }

    func consume(_ text: String) {
        guard !text.isEmpty else { return }
        queue.sync {
            self.buffer.append(text)
            self.flushCompleteLines()
            if self.buffer.count > 8192 { self.buffer = String(self.buffer.suffix(8192)) }
        }
    }

    private func flushCompleteLines() {
        var lineStart = buffer.startIndex
        var index = buffer.startIndex

        while index < buffer.endIndex {
            let character = buffer[index]
            guard character == "\n" || character == "\r" else {
                index = buffer.index(after: index)
                continue
            }

            processLine(String(buffer[lineStart..<index]))

            let next = buffer.index(after: index)
            if next < buffer.endIndex {
                let nextCharacter = buffer[next]
                if (character == "\r" && nextCharacter == "\n") || (character == "\n" && nextCharacter == "\r") {
                    index = next
                }
            }

            lineStart = buffer.index(after: index)
            index = lineStart
        }

        buffer = lineStart < buffer.endIndex ? String(buffer[lineStart...]) : ""
    }

    private func processLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let separatorIndex = line.firstIndex(of: "=") else { return }

        let key = String(line[..<separatorIndex])
        let value = String(line[line.index(after: separatorIndex)...])

        switch key {
        case "out_time":
            if let seconds = Self.parseClock(value) {
                emitProgress(seconds: seconds)
            }
        case "out_time_ms":
            if let rawValue = Double(value) {
                emitProgress(seconds: rawValue / 1_000_000)
            }
        case "out_time_us":
            if let rawValue = Double(value) {
                emitProgress(seconds: rawValue / 1_000_000)
            }
        case "progress":
            if value == "end" {
                lastFraction = 1
                emit(.processing(message: message, downloadFraction: downloadFraction, fraction: 1))
            }
        default:
            break
        }
    }

    private func emitProgress(seconds: TimeInterval) {
        guard let duration, duration > 0 else { return }
        let fraction = min(max(seconds / duration, 0), 1)
        guard lastFraction != fraction else { return }
        lastFraction = fraction
        emit(.processing(message: message, downloadFraction: downloadFraction, fraction: fraction))
    }

    private static func parseClock(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }

        return (hours * 3600) + (minutes * 60) + seconds
    }
}

struct SaveDestination {
    let url: URL
    let existed: Bool
    private let original: stat

    init(_ url: URL) throws {
        self.url = url
        var info = stat()
        existed = lstat(url.path, &info) == 0
        if !existed && errno != ENOENT { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        original = info
    }

    func publish(_ staged: URL) throws {
        if existed {
            var current = stat()
            guard lstat(url.path, &current) == 0, current.st_dev == original.st_dev,
                  current.st_ino == original.st_ino, current.st_size == original.st_size,
                  current.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
                  current.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else {
                throw DownloadError.conversionFailed("The destination changed during the download. Choose it again.")
            }
        }
        let result = existed ? rename(staged.path, url.path) : renamex_np(staged.path, url.path, UInt32(RENAME_EXCL))
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

final class DownloadCoordinator: @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let staleWorkspaceAge: TimeInterval = 24 * 60 * 60
    private let markerFileName = ".workspace.json"
    private let stateQueue = DispatchQueue(label: "MediaUtility.download-coordinator.state")

    private enum ProbeOutcome {
        case success(VideoMetadata)
        case failure(String)
    }

    private enum DefaultsKey {
        static let lastDirectory = "YouTubeUtilityApp.lastDirectory"
    }

    private let streamingProtocols: Set<String> = ["m3u8", "m3u8_native"]
    private let movCompatibleVideoCodecs: Set<String> = ["h264", "hevc", "prores", "mpeg4"]
    private let movCompatibleAudioCodecs: Set<String> = ["aac", "alac", "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le"]
    private var activeProcesses: [ObjectIdentifier: Process] = [:]
    private var cancellationRequested = false

    private struct WorkspaceMarker: Codable {
        let pid: Int32
        let createdAt: TimeInterval
    }

    private var legacyTemporaryRootDirectory: URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("YouTubeUtilityApp", isDirectory: true)
    }

    private var temporaryRootDirectory: URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("MediaUtility", isDirectory: true)
    }

    private var temporaryRootDirectories: [URL] {
        [temporaryRootDirectory, legacyTemporaryRootDirectory]
    }

    func cleanupTemporaryWorkspaces() {
        try? cleanupTemporaryWorkspaces(failIfRemovalBlocked: false)
    }

    func prepareWorkspaceForNewOperation() throws {
        try cleanupTemporaryWorkspaces(failIfRemovalBlocked: true)
    }

    private func cleanupTemporaryWorkspaces(failIfRemovalBlocked: Bool) throws {
        let now = Date()
        var firstFailure: Error?

        for rootDirectory in temporaryRootDirectories {
            guard fileManager.fileExists(atPath: rootDirectory.path) else {
                continue
            }

            let rootContents = (try? fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for candidate in rootContents {
                guard UUID(uuidString: candidate.lastPathComponent) != nil, isDirectory(candidate) else { continue }
                guard shouldDeleteWorkspace(at: candidate, now: now) else { continue }
                do {
                    try fileManager.removeItem(at: candidate)
                } catch {
                    if firstFailure == nil {
                        firstFailure = error
                    }
                }
            }


        }

        if failIfRemovalBlocked, let firstFailure {
            throw DownloadError.workspaceUnavailable(
                "Temporary workspace cleanup is blocked: \(firstFailure.localizedDescription)"
            )
        }
    }

    func startRequest() {
        stateQueue.sync { cancellationRequested = false }
    }

    func requestCancellation() -> [Process] {
        stateQueue.sync {
            cancellationRequested = true
            return Array(activeProcesses.values).filter { $0.isRunning }
        }
    }

    func prepareDownload(
        urlString: String,
        cookieAccessMode: CookieAccessMode,
        progress: @escaping @Sendable (OperationUpdate) -> Void
    ) async throws -> PreparedDownload {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else {
            throw DownloadError.invalidURL
        }

        try throwIfCancellationRequested()
        let service = SupportedService(url: url)
        progress(.status("Checking installed tools..."))
        let toolchain = try await ToolchainLocator.locate()
        try toolchain.requireTrustedExecution()

        let detailLabel = service == .generic ? "media details" : "\(service.displayName) details"
        progress(.status("Fetching \(detailLabel) (\(cookieAccessMode.statusLabel))..."))
        let metadata = try await probeMetadata(
            url: url,
            service: service,
            toolchain: toolchain,
            cookieAccessMode: cookieAccessMode
        )
        let sourceKind = classifySourceKind(from: metadata.formats)

        return PreparedDownload(
            requestURL: url,
            metadata: metadata,
            cookieAccessMode: cookieAccessMode,
            toolchain: toolchain,
            sourceKind: sourceKind,
            service: service
        )
    }

    func performDownload(
        prepared: PreparedDownload,
        mode: DownloadMode,
        videoSettings: VideoOutputSettings,
        destination: SaveDestination,
        progress: @escaping @Sendable (OperationUpdate) -> Void
    ) async throws -> URL {
        try prepared.toolchain.requireTrustedExecution()
        try throwIfCancellationRequested()
        let tempDirectory = try createTemporaryWorkspace()
        defer { try? fileManager.removeItem(at: tempDirectory) }

        // Foundation allocates the staging directory on the destination volume.
        let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: destination.url, create: true)
        defer { try? fileManager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("output." + mode.fileExtension)
        switch mode {
        case .videoMov:
            _ = try await downloadVideo(prepared: prepared, videoSettings: videoSettings,
                                        saveURL: staged, tempDirectory: tempDirectory, progress: progress)
        case .audioWav:
            _ = try await downloadAudio(prepared: prepared, saveURL: staged,
                                        tempDirectory: tempDirectory, progress: progress)
        }
        try publish(staged: staged, to: destination)
        return destination.url
    }

    func publish(staged: URL, to destination: SaveDestination) throws {
        var info = stat()
        guard lstat(staged.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else {
            throw DownloadError.conversionFailed("The converter produced an empty file.")
        }
        // Decide cancellation and commit under one lock. rename is atomic on the same volume.
        try stateQueue.sync {
            guard !cancellationRequested else { throw DownloadError.interrupted }
            try destination.publish(staged)
        }
    }

    func lastDirectoryURL() -> URL? {
        guard let path = defaults.string(forKey: DefaultsKey.lastDirectory), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func rememberLastDirectory(_ url: URL) {
        defaults.set(url.path, forKey: DefaultsKey.lastDirectory)
    }

    private func registerActiveProcess(_ process: Process) {
        let cancelled = stateQueue.sync {
            activeProcesses[ObjectIdentifier(process)] = process
            return cancellationRequested
        }
        if cancelled && process.isRunning { ProcessTreeTerminator.cancel(processes: [process]) }
    }

    private func unregisterActiveProcess(_ process: Process) {
        _ = stateQueue.sync {
            activeProcesses.removeValue(forKey: ObjectIdentifier(process))
        }
    }

    private func throwIfCancellationRequested() throws {
        let wasCancelled = stateQueue.sync { cancellationRequested }
        if wasCancelled {
            throw DownloadError.interrupted
        }
    }

    private func runTrackedProcess(
        executable: URL,
        arguments: [String],
        onOutput: (@Sendable (ProcessStream, String) -> Void)? = nil
    ) async throws -> ProcessOutput {
        try throwIfCancellationRequested()
        return try await ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            onOutput: onOutput,
            onStart: { [weak self] process in
                self?.registerActiveProcess(process)
            },
            onFinish: { [weak self] process in
                self?.unregisterActiveProcess(process)
            }
        )
    }

    func createTemporaryWorkspace() throws -> URL {
        try fileManager.createDirectory(at: temporaryRootDirectory, withIntermediateDirectories: true)

        let directory = temporaryRootDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        let marker = WorkspaceMarker(
            pid: ProcessInfo.processInfo.processIdentifier,
            createdAt: Date().timeIntervalSince1970
        )
        let markerData = try JSONEncoder().encode(marker)
        try markerData.write(to: directory.appendingPathComponent(markerFileName), options: [.atomic])
        return directory
    }

    private func shouldDeleteWorkspace(at directory: URL, now: Date) -> Bool {
        if let marker = loadWorkspaceMarker(from: directory) {
            return !isProcessAlive(marker.pid)
        }

        guard let date = workspaceTimestamp(for: directory) else {
            return false
        }
        return now.timeIntervalSince(date) > staleWorkspaceAge
    }

    private func loadWorkspaceMarker(from directory: URL) -> WorkspaceMarker? {
        let markerURL = directory.appendingPathComponent(markerFileName)
        guard let data = try? Data(contentsOf: markerURL) else {
            return nil
        }
        return try? JSONDecoder().decode(WorkspaceMarker.self, from: data)
    }

    private func workspaceTimestamp(for directory: URL) -> Date? {
        let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return values?.contentModificationDate ?? values?.creationDate
    }

    private func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    private func probeMetadata(
        url: URL,
        service: SupportedService,
        toolchain: Toolchain,
        cookieAccessMode: CookieAccessMode
    ) async throws -> VideoMetadata {
        let outcome = try await runMetadataProbe(url: url, toolchain: toolchain, cookieAccessMode: cookieAccessMode)
        switch outcome {
        case let .success(metadata):
            return metadata
        case let .failure(message):
            if url.scheme?.lowercased() == "https", cookieAccessMode == .anonymous, requiresAuthenticatedRetry(message) {
                throw DownloadError.authenticationRequired(
                    authChallenge(
                        for: url,
                        service: service,
                        stage: .metadata,
                        output: message
                    )
                )
            }
            throw DownloadError.metadataFailed(friendlyMessage(from: message))
        }
    }

    private func runMetadataProbe(
        url: URL,
        toolchain: Toolchain,
        cookieAccessMode: CookieAccessMode
    ) async throws -> ProbeOutcome {
        var arguments = ytDlpBaseArguments(toolchain: toolchain, cookieAccessMode: cookieAccessMode)
        arguments += ["-J", "--", url.absoluteString]

        let result = try await runTrackedProcess(executable: toolchain.python, arguments: arguments)
        try throwIfCancellationRequested()
        guard result.exitCode == 0 else {
            return .failure(result.stderr)
        }

        do {
            let data = Data(result.stdout.utf8)
            let metadata = try JSONDecoder().decode(VideoMetadata.self, from: data)
            return .success(metadata)
        } catch {
            return .failure("The source returned unreadable media information.")
        }
    }

    private func downloadVideo(
        prepared: PreparedDownload,
        videoSettings: VideoOutputSettings,
        saveURL: URL,
        tempDirectory: URL,
        progress: @escaping @Sendable (OperationUpdate) -> Void
    ) async throws -> URL {
        let video = try pickVideoFormat(from: prepared.metadata)
        let selector: String
        let shouldMerge: Bool

        if video.includesAudio {
            selector = video.formatID
            shouldMerge = false
        } else if let audio = pickAudioOnlyFormat(from: prepared.metadata) {
            selector = "\(video.formatID)+\(audio.formatID)"
            shouldMerge = true
        } else {
            selector = video.formatID
            shouldMerge = false
        }

        let template = tempDirectory.appendingPathComponent("download.video.%(ext)s").path
        let parser = YtDlpProgressParser(message: "Downloading source video...", emit: progress)

        try await runDownloadWithFallback(
            prepared: prepared,
            outputHandler: { _, text in
                parser.consume(text)
            },
            buildArguments: {
                var arguments = ytDlpBaseArguments(toolchain: prepared.toolchain, cookieAccessMode: prepared.cookieAccessMode)
                arguments += [
                    "--newline",
                    "-f", selector,
                ]
                if shouldMerge {
                    arguments += ["--merge-output-format", "mkv"]
                }
                arguments += ["-o", template, "--", prepared.requestURL.absoluteString]
                return arguments
            }
        )
        try throwIfCancellationRequested()

        let sourcePath = try resolveDownloadedSource(in: tempDirectory, prefix: "download.video.")
        progress(.downloading(message: "Downloading source video...", fraction: 1))

        try await convertToMov(
            sourcePath: sourcePath,
            outputPath: saveURL,
            toolchain: prepared.toolchain,
            videoSettings: videoSettings,
            progress: progress
        )
        return saveURL
    }

    private func downloadAudio(
        prepared: PreparedDownload,
        saveURL: URL,
        tempDirectory: URL,
        progress: @escaping @Sendable (OperationUpdate) -> Void
    ) async throws -> URL {
        let audio = try pickAudioFormat(from: prepared.metadata)
        let template = tempDirectory.appendingPathComponent("download.audio.%(ext)s").path
        let parser = YtDlpProgressParser(message: "Downloading source audio...", emit: progress)

        try await runDownloadWithFallback(
            prepared: prepared,
            outputHandler: { _, text in
                parser.consume(text)
            },
            buildArguments: {
                var arguments = ytDlpBaseArguments(toolchain: prepared.toolchain, cookieAccessMode: prepared.cookieAccessMode)
                arguments += [
                    "--newline",
                    "-f", audio.formatID,
                    "-o", template, "--",
                    prepared.requestURL.absoluteString,
                ]
                return arguments
            }
        )
        try throwIfCancellationRequested()

        let sourceURL = try resolveAudioSource(in: tempDirectory, preferredExtension: audio.ext)
        progress(.downloading(message: "Downloading source audio...", fraction: 1))

        let probe = try await probeMediaInfo(at: sourceURL, toolchain: prepared.toolchain)
        let duration = mediaDuration(from: probe)
        if duration != nil {
            progress(.processing(message: "Preparing WAV...", downloadFraction: 1, fraction: 0))
        } else {
            progress(.status("Preparing WAV..."))
        }

        let ffmpegParser = FFmpegProgressParser(
            message: "Preparing WAV...",
            duration: duration,
            downloadFraction: 1,
            emit: progress
        )
        let conversion = try await runTrackedProcess(
            executable: prepared.toolchain.ffmpeg,
            arguments: [
                "-y",
                "-i", sourceURL.path,
                "-vn",
                "-c:a", "pcm_s16le",
                "-progress", "pipe:2",
                "-nostats",
                saveURL.path,
            ],
            onOutput: { stream, text in
                guard stream == .stderr else { return }
                ffmpegParser.consume(text)
            }
        )
        try throwIfCancellationRequested()

        guard conversion.exitCode == 0 else {
            throw DownloadError.conversionFailed(friendlyMessage(from: conversion.combined))
        }
        progress(.processing(message: "Preparing WAV...", downloadFraction: 1, fraction: 1))
        return saveURL
    }

    private func resolveAudioSource(in directory: URL, preferredExtension: String) throws -> URL {
        let preferred = directory.appendingPathComponent("download.audio.\(preferredExtension)")
        if FileManager.default.fileExists(atPath: preferred.path) {
            return preferred
        }

        return try resolveDownloadedSource(in: directory, prefix: "download.audio.")
    }

    private func resolveDownloadedSource(in directory: URL, prefix: String) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        guard let match = contents.first(where: { $0.lastPathComponent.hasPrefix(prefix) }) else {
            throw DownloadError.downloadFailed("yt-dlp finished, but the downloaded source file could not be found.")
        }
        return match
    }

    private func runDownloadWithFallback(
        prepared: PreparedDownload,
        outputHandler: (@Sendable (ProcessStream, String) -> Void)? = nil,
        buildArguments: () -> [String]
    ) async throws {
        let result = try await runTrackedProcess(
            executable: prepared.toolchain.python,
            arguments: buildArguments(),
            onOutput: outputHandler
        )
        try throwIfCancellationRequested()

        if result.exitCode == 0 {
            return
        }

        if prepared.requestURL.scheme?.lowercased() == "https", prepared.cookieAccessMode == .anonymous, requiresAuthenticatedRetry(result.stderr) {
            throw DownloadError.authenticationRequired(
                authChallenge(
                    for: prepared.requestURL,
                    service: prepared.service,
                    stage: .download,
                    output: result.combined
                )
            )
        }

        throw DownloadError.downloadFailed(friendlyMessage(from: result.combined))
    }

    private func convertToMov(
        sourcePath: URL,
        outputPath: URL,
        toolchain: Toolchain,
        videoSettings: VideoOutputSettings,
        progress: @escaping @Sendable (OperationUpdate) -> Void
    ) async throws {
        let probe = try await probeMediaInfo(at: sourcePath, toolchain: toolchain)
        let streams = probe.streams
        guard let video = streams.first(where: { $0.codecType == "video" }) else {
            throw DownloadError.conversionFailed("Could not inspect the merged source streams.")
        }

        let audio = streams.first(where: { $0.codecType == "audio" })
        let duration = mediaDuration(from: probe)

        let videoCodec = video.codecName ?? ""
        let audioCodec = audio?.codecName ?? ""
        let canCopyVideo = movCompatibleVideoCodecs.contains(videoCodec)
        let canCopyAudio = audio == nil || movCompatibleAudioCodecs.contains(audioCodec)
        let canCopy = canCopyVideo && canCopyAudio
        let shouldPreserveOriginal = videoSettings.preserveOriginalWhenPossible && canCopy
        let processingMessage = shouldPreserveOriginal ? "Copying original video..." : videoSettings.processingMessage

        var arguments = [
            "-y",
            "-i", sourcePath.path,
            "-progress", "pipe:2",
            "-nostats",
        ]
        if duration != nil {
            progress(.processing(message: processingMessage, downloadFraction: 1, fraction: 0))
        } else {
            progress(.status(processingMessage))
        }

        if shouldPreserveOriginal {
            arguments += [
                "-c", "copy",
                "-movflags", "+faststart",
                outputPath.path,
            ]
        } else {
            arguments += [
                "-map", "0",
                "-c:v", "libx264",
                "-preset", videoSettings.preset.ffmpegPreset,
                "-crf", videoSettings.preset.crf,
                "-pix_fmt", "yuv420p",
            ]
            if let audio {
                if videoSettings.preserveOriginalWhenPossible && movCompatibleAudioCodecs.contains(audio.codecName ?? "") {
                    arguments += ["-c:a", "copy"]
                } else {
                    arguments += ["-c:a", "aac", "-b:a", videoSettings.preset.audioBitrate]
                }
            } else {
                arguments += ["-an"]
            }
            arguments += ["-movflags", "+faststart", outputPath.path]
        }

        let parser = FFmpegProgressParser(
            message: processingMessage,
            duration: duration,
            downloadFraction: 1,
            emit: progress
        )
        let conversion = try await runTrackedProcess(
            executable: toolchain.ffmpeg,
            arguments: arguments,
            onOutput: { stream, text in
                guard stream == .stderr else { return }
                parser.consume(text)
            }
        )
        try throwIfCancellationRequested()
        guard conversion.exitCode == 0 else {
            throw DownloadError.conversionFailed(friendlyMessage(from: conversion.combined))
        }
        progress(.processing(message: processingMessage, downloadFraction: 1, fraction: 1))
    }

    private func probeMediaInfo(at url: URL, toolchain: Toolchain) async throws -> ProbeStreams {
        let probe = try await runTrackedProcess(
            executable: toolchain.ffprobe,
            arguments: [
                "-v", "error",
                "-show_streams",
                "-show_format",
                "-of", "json",
                url.path,
            ]
        )
        try throwIfCancellationRequested()

        guard probe.exitCode == 0 else {
            throw DownloadError.conversionFailed(friendlyMessage(from: probe.combined))
        }

        let probeData = Data(probe.stdout.utf8)
        return try JSONDecoder().decode(ProbeStreams.self, from: probeData)
    }

    private func mediaDuration(from probe: ProbeStreams) -> TimeInterval? {
        guard let rawDuration = probe.format?.duration,
              let duration = Double(rawDuration),
              duration > 0 else {
            return nil
        }
        return duration
    }

    private func pickAudioFormat(from formats: [VideoFormat]) throws -> FormatChoice {
        let candidates = playableAudioCandidates(from: formats)

        guard !candidates.isEmpty else {
            throw DownloadError.unsupportedFormat("No playable audio formats were found for this source.")
        }

        return makeAudioChoice(from: candidates, metadata: nil)
    }

    private func pickAudioFormat(from metadata: VideoMetadata) throws -> FormatChoice {
        let candidates = playableAudioCandidates(from: metadata.formats)

        guard !candidates.isEmpty else {
            throw DownloadError.unsupportedFormat("No playable audio formats were found for this source.")
        }

        return makeAudioChoice(from: candidates, metadata: metadata)
    }

    private func pickAudioOnlyFormat(from metadata: VideoMetadata) -> FormatChoice? {
        let candidates = audioOnlyCandidates(from: metadata.formats)
        guard !candidates.isEmpty else {
            return nil
        }
        return makeAudioChoice(from: candidates, metadata: metadata)
    }

    private func pickAudioOnlyFormat(from formats: [VideoFormat]) -> FormatChoice? {
        let candidates = audioOnlyCandidates(from: formats)
        guard !candidates.isEmpty else {
            return nil
        }
        return makeAudioChoice(from: candidates, metadata: nil)
    }

    private func pickVideoFormat(from formats: [VideoFormat]) throws -> VideoChoice {
        try pickVideoFormat(from: VideoMetadata(id: nil, title: nil, language: nil, originalLanguage: nil, formats: formats))
    }

    private func pickVideoFormat(from metadata: VideoMetadata) throws -> VideoChoice {
        let videoOnlyCandidates = metadata.formats.filter { format in
            (format.vcodec ?? "none") != "none" &&
            (format.acodec ?? "none") == "none" &&
            !format.formatID.isEmpty
        }

        let muxedCandidates = metadata.formats.filter { format in
            (isUnspecifiedVideoFile(format) || (format.vcodec != "none" && hasPlayableAudioTrack(format) && !isAudioOnlyFormat(format))) &&
            !format.formatID.isEmpty
        }

        if (muxedCandidates.isEmpty || !audioOnlyCandidates(from: metadata.formats).isEmpty),
           let chosen = videoOnlyCandidates.max(by: { lhs, rhs in
            videoRank(for: lhs) < videoRank(for: rhs)
        }) {
            return VideoChoice(
                formatID: chosen.formatID,
                vcodec: chosen.vcodec ?? "unknown",
                width: chosen.width ?? 0,
                height: chosen.height ?? 0,
                fps: chosen.fps ?? 0,
                includesAudio: false
            )
        }

        guard let chosen = muxedCandidates.max(by: { lhs, rhs in
            isRank(
                muxedVideoRank(for: lhs, metadata: metadata),
                betterThan: muxedVideoRank(for: rhs, metadata: metadata)
            )
        }) else {
            throw DownloadError.unsupportedFormat("No downloadable video formats were found for this source.")
        }

        return VideoChoice(
            formatID: chosen.formatID,
            vcodec: chosen.vcodec ?? "unknown",
            width: chosen.width ?? 0,
            height: chosen.height ?? 0,
            fps: chosen.fps ?? 0,
            includesAudio: true
        )
    }

    private func audioRank(for format: VideoFormat) -> (Int, Double, Int, Double) {
        let protocolScore = streamingProtocols.contains(format.protocolName ?? "") ? 0 : 1
        let abr = format.abr ?? format.tbr ?? 0
        let asr = format.asr ?? 0
        let size = format.filesize ?? format.filesizeApprox ?? 0
        return (protocolScore, abr, asr, size)
    }

    private func videoRank(for format: VideoFormat) -> (Int, Int, Int, Double, Double) {
        let protocolScore = streamingProtocols.contains(format.protocolName ?? "") ? 0 : 1
        let height = format.height ?? 0
        let width = format.width ?? 0
        let fps = format.fps ?? 0
        let bitrate = format.tbr ?? format.vbr ?? 0
        return (protocolScore, height, width, fps, bitrate)
    }

    private func muxedVideoRank(for format: VideoFormat, metadata: VideoMetadata) -> [Double] {
        let language = languagePriority(for: format, metadata: metadata)
        let protocolScore = streamingProtocols.contains(format.protocolName ?? "") ? 0 : 1
        let height = format.height ?? 0
        let width = format.width ?? 0
        let fps = format.fps ?? 0
        let bitrate = format.tbr ?? format.vbr ?? 0
        return [
            Double(language.matchScore),
            Double(language.originalNoteScore),
            Double(language.preferenceScore),
            Double(protocolScore),
            Double(height),
            Double(width),
            fps,
            bitrate,
        ]
    }

    private func ytDlpBaseArguments(toolchain: Toolchain, cookieAccessMode: CookieAccessMode) -> [String] {
        var arguments = ["-I", "-S", toolchain.runtime.path, toolchain.ytDlp.path, "--ignore-config", "--no-plugin-dirs",
                         "--no-remote-components", "--no-js-runtimes", "--no-cache-dir", "--no-playlist", "--ffmpeg-location", toolchain.ffmpegDirectory.path]
        switch cookieAccessMode {
        case .anonymous:
            if let deno = toolchain.deno { arguments += ["--js-runtimes", "deno:" + deno.path] }
        case let .cookiesFile(url):
            arguments += ["--downloader", "native", "--cookies", url.path]
        }
        return arguments
    }

    private func audioOnlyCandidates(from formats: [VideoFormat]) -> [VideoFormat] {
        formats.filter(isAudioOnlyFormat)
    }

    private func playableAudioCandidates(from formats: [VideoFormat]) -> [VideoFormat] {
        let audioOnly = audioOnlyCandidates(from: formats)
        if !audioOnly.isEmpty {
            return audioOnly
        }

        return formats.filter { (hasPlayableAudioTrack($0) || isUnspecifiedVideoFile($0)) && !$0.formatID.isEmpty }
    }

    // Generic direct-file URLs often carry a container but no codec metadata.
    private func isUnspecifiedVideoFile(_ format: VideoFormat) -> Bool {
        format.vcodec == nil && format.acodec == nil
            && ["mp4", "mov", "mkv", "webm", "m4v"].contains(format.ext ?? "")
    }

    private func isAudioOnlyFormat(_ format: VideoFormat) -> Bool {
        (format.vcodec ?? "none") == "none" && hasPlayableAudioTrack(format)
    }

    private func hasPlayableAudioTrack(_ format: VideoFormat) -> Bool {
        if let acodec = format.acodec {
            return acodec != "none"
        }

        let note = format.formatNote?.lowercased() ?? ""
        return ["mp3", "m4a", "wav", "ogg", "opus", "flac", "aac"].contains(format.ext ?? "")
            || note.contains("audio")
            || (format.abr ?? 0) > 0
            || (format.asr ?? 0) > 0
    }

    private func makeAudioChoice(from candidates: [VideoFormat], metadata: VideoMetadata?) -> FormatChoice {
        let prioritized = filterBestLanguageCandidates(in: candidates, metadata: metadata)
        let preferred = prioritized.filter { ($0.acodec ?? "").hasPrefix("mp4a") }
        let pool = preferred.isEmpty ? prioritized : preferred

        let chosen = pool.max(by: { lhs, rhs in
            isRank(
                audioSortRank(for: lhs, metadata: metadata),
                betterThan: audioSortRank(for: rhs, metadata: metadata)
            )
        }) ?? pool[0]

        return FormatChoice(
            formatID: chosen.formatID,
            acodec: chosen.acodec ?? "unknown",
            abr: chosen.abr ?? chosen.tbr ?? 0,
            asr: chosen.asr ?? 0,
            ext: chosen.ext ?? "m4a"
        )
    }

    private func audioSortRank(for format: VideoFormat, metadata: VideoMetadata?) -> [Double] {
        let language = languagePriority(for: format, metadata: metadata)
        let note = format.formatNote?.lowercased() ?? ""
        let drcScore = note.contains("drc") ? 0 : 1
        let protocolScore = streamingProtocols.contains(format.protocolName ?? "") ? 0 : 1
        let abr = format.abr ?? format.tbr ?? 0
        let asr = format.asr ?? 0
        let size = format.filesize ?? format.filesizeApprox ?? 0
        return [
            Double(language.matchScore),
            Double(language.originalNoteScore),
            Double(language.preferenceScore),
            Double(drcScore),
            Double(protocolScore),
            abr,
            Double(asr),
            size,
        ]
    }

    private func isRank(_ lhs: [Double], betterThan rhs: [Double]) -> Bool {
        for (left, right) in zip(lhs, rhs) {
            if left != right {
                return left < right
            }
        }
        return false
    }

    private func filterBestLanguageCandidates(in candidates: [VideoFormat], metadata: VideoMetadata?) -> [VideoFormat] {
        guard let best = candidates.max(by: { lhs, rhs in
            let lhsPriority = languagePriority(for: lhs, metadata: metadata)
            let rhsPriority = languagePriority(for: rhs, metadata: metadata)
            return (lhsPriority.matchScore, lhsPriority.originalNoteScore, lhsPriority.preferenceScore) <
                (rhsPriority.matchScore, rhsPriority.originalNoteScore, rhsPriority.preferenceScore)
        }) else {
            return candidates
        }

        let target = languagePriority(for: best, metadata: metadata)
        return candidates.filter { candidate in
            let priority = languagePriority(for: candidate, metadata: metadata)
            return priority.matchScore == target.matchScore &&
                priority.originalNoteScore == target.originalNoteScore &&
                priority.preferenceScore == target.preferenceScore
        }
    }

    private func languagePriority(for format: VideoFormat, metadata: VideoMetadata?) -> (matchScore: Int, originalNoteScore: Int, preferenceScore: Int) {
        let preferredLanguage = metadata?.originalLanguage ?? metadata?.language
        let normalizedPreferredLanguage = normalizeLanguageCode(preferredLanguage)
        let normalizedCandidateLanguage = normalizeLanguageCode(format.language)
        let matchScore = languageMatches(normalizedCandidateLanguage, preferredLanguage: normalizedPreferredLanguage) ? 1 : 0
        let note = format.formatNote?.lowercased() ?? ""
        let originalNoteScore = note.contains("original") ? 1 : 0
        let preferenceScore = format.languagePreference ?? (matchScore == 1 ? 1 : 0)
        return (matchScore, originalNoteScore, preferenceScore)
    }

    private func languageMatches(_ candidate: String?, preferredLanguage: String?) -> Bool {
        guard let candidate, let preferredLanguage else { return false }
        if candidate == preferredLanguage {
            return true
        }

        let candidateBase = candidate.split(separator: "-").first.map(String.init)
        let preferredBase = preferredLanguage.split(separator: "-").first.map(String.init)
        return candidateBase == preferredBase
    }

    private func normalizeLanguageCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func classifySourceKind(from formats: [VideoFormat]) -> SourceKind {
        let hasVideo = formats.contains { ($0.vcodec ?? "none") != "none" || isUnspecifiedVideoFile($0) }
        let hasAudio = formats.contains(where: hasPlayableAudioTrack)

        if hasVideo || !hasAudio {
            return .video
        }
        return .audioOnly
    }

    private func requiresAuthenticatedRetry(_ output: String) -> Bool {
        let value = output.lowercased()
        return value.contains("sign in to confirm you’re not a bot")
            || value.contains("sign in to confirm you're not a bot")
            || value.contains("use --cookies-from-browser")
            || value.contains("cookies-from-browser")
            || value.contains("login required")
            || value.contains("you need to log in")
            || value.contains("requires login")
            || value.contains("age-restricted")
            || value.contains("age verification")
            || value.contains("this video is private")
            || value.contains("private video")
            || value.contains("members-only")
            || value.contains("content is not available without login")
    }

    private func authChallenge(
        for url: URL,
        service: SupportedService,
        stage: AuthChallengeStage,
        output: String
    ) -> AuthChallenge {
        AuthChallenge(
            service: service,
            host: (url.host ?? url.absoluteString).lowercased(),
            reason: friendlyMessage(from: output),
            stage: stage
        )
    }

    private func friendlyMessage(from output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let errorLine = lines.reversed().first(where: { $0.contains("ERROR:") }) {
            return safeDetail(errorLine.replacingOccurrences(of: "ERROR:", with: ""))
        }

        if let lastLine = lines.last {
            return safeDetail(lastLine)
        }

        return "The operation failed."
    }
    private func safeDetail(_ line: String) -> String {
        if line.range(of: #"(?i)(cookie:|authorization:|bearer |set-cookie|\{.*\})"#, options: .regularExpression) != nil {
            return "The media tool could not complete this operation."
        }
        let redacted = line.replacingOccurrences(of: #"(?i)https?://\S+"#, with: "[URL]", options: .regularExpression)
        return String(redacted.trimmingCharacters(in: .whitespacesAndNewlines).prefix(450))
    }

}

enum ToolchainLocator {
    private struct ReleaseLock: Decodable {
        let version: String
        let sha256: String
    }

    static func locate() async throws -> Toolchain {
        guard let lockURL = Bundle.main.url(forResource: "yt-dlp-lock", withExtension: "json"),
              let runtime = Bundle.main.url(forResource: "downloader_runtime", withExtension: "py") else {
            throw DownloadError.missingTools("Downloader release information is missing. Rebuild Media Utility.")
        }
        let lock = try JSONDecoder().decode(ReleaseLock.self, from: Data(contentsOf: lockURL))
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: false)
        let archive = support.appendingPathComponent("Media Utility/tools/" + lock.version + "/yt-dlp")
        guard let info = try? archive.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              info.isRegularFile == true, let size = info.fileSize, size < 16 * 1024 * 1024,
              let data = try? Data(contentsOf: archive),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == lock.sha256 else {
            throw DownloadError.missingTools("Install the verified downloader with ./script/install-tools.sh.")
        }
        let python = try homebrewTool("python3", formula: "python")
        let ffmpeg = try homebrewTool("ffmpeg", formula: "ffmpeg")
        let ffprobe = try homebrewTool("ffprobe", formula: "ffmpeg")
        guard ffprobe.deletingLastPathComponent() == ffmpeg.deletingLastPathComponent() else {
            throw DownloadError.toolchainBlocked("Install ffmpeg and ffprobe from the same Homebrew package.")
        }
        return Toolchain(runtime: runtime, deno: try? homebrewTool("deno", formula: "deno"), python: python, ytDlp: archive, ffmpeg: ffmpeg, ffprobe: ffprobe,
                         ytDlpVersion: lock.version, trustState: .trusted("Downloader checksum verified."))
    }

    private static func homebrewTool(_ name: String, formula: String) throws -> URL {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let resolved = URL(fileURLWithPath: prefix + "/bin/" + name).resolvingSymlinksInPath()
            let cellar = prefix + "/Cellar/"
            guard resolved.path.hasPrefix(cellar), FileManager.default.isExecutableFile(atPath: resolved.path) else { continue }
            let parts = resolved.path.dropFirst(cellar.count).split(separator: "/")
            guard let keg = parts.first, keg == formula || keg.hasPrefix(formula + "@") else { continue }
            if name == "python3" {
                guard parts.count >= 4, resolved.lastPathComponent.hasPrefix("python3") else { continue }
            } else {
                guard parts.count == 4, parts[2] == "bin", parts[3] == name else { continue }
            }
            return resolved
        }
        throw DownloadError.missingTools("Install " + formula + " with Homebrew to provide " + name + ".")
    }
}

enum ProcessTreeTerminator {
    static func cancel(processes: [Process]) {
        let rootPIDs = processes.filter { $0.isRunning }
            .map(\.processIdentifier)
            .filter { $0 > 0 }

        guard !rootPIDs.isEmpty else { return }

        let descendants = descendantProcessIDs(of: rootPIDs)
        let allPIDs = Array(Set(descendants + rootPIDs))

        send(SIGTERM, to: allPIDs)
        usleep(300_000)
        send(SIGKILL, to: allPIDs.filter(isProcessAlive))
    }

    private static func send(_ signal: Int32, to pids: [pid_t]) {
        for pid in pids where pid > 0 {
            _ = kill(pid, signal)
        }
    }

    private static func descendantProcessIDs(of roots: [pid_t]) -> [pid_t] {
        let table = processTable()
        guard !table.isEmpty else { return [] }

        var descendants: [pid_t] = []
        var frontier = Set(roots)

        while !frontier.isEmpty {
            let children = table.compactMap { row -> pid_t? in
                frontier.contains(row.ppid) ? row.pid : nil
            }

            let next = Set(children).subtracting(descendants)
            guard !next.isEmpty else { break }

            descendants.append(contentsOf: next)
            frontier = next
        }

        return descendants
    }

    private static func processTable() -> [(pid: pid_t, ppid: pid_t)] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }

        let output = String(decoding: data, as: UTF8.self)
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let columns = line.split(whereSeparator: \.isWhitespace)
                guard columns.count == 2,
                      let pid = pid_t(columns[0]),
                      let ppid = pid_t(columns[1]) else {
                    return nil
                }
                return (pid: pid, ppid: ppid)
            }
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }
}

enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        onOutput: (@Sendable (ProcessStream, String) -> Void)? = nil,
        onStart: (@Sendable (Process) -> Void)? = nil,
        onFinish: (@Sendable (Process) -> Void)? = nil
    ) async throws -> ProcessOutput {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = sanitizedEnvironment()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        onStart?(process)
        defer { onFinish?(process) }

        // Drain both pipes concurrently, to EOF, before inspecting the exit status.
        async let output = drain(stdout.fileHandleForReading, .stdout, limit: onOutput == nil ? 32 << 20 : 64 << 10, handler: onOutput)
        async let errors = drain(stderr.fileHandleForReading, .stderr, limit: 64 << 10, handler: onOutput)
        let (out, err) = await (output, errors)
        process.waitUntilExit()
        return ProcessOutput(exitCode: process.terminationStatus, stdout: out, stderr: err)
    }

    private static func drain(_ handle: FileHandle, _ stream: ProcessStream, limit: Int,
                              handler: (@Sendable (ProcessStream, String) -> Void)?) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var retained = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    handler?(stream, String(decoding: chunk, as: UTF8.self))
                    retained.append(chunk)
                    if retained.count > limit { retained.removeFirst(retained.count - limit) }
                }
                continuation.resume(returning: String(decoding: retained, as: UTF8.self))
            }
        }
    }

    private static func sanitizedEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let fallbackPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        let preservedKeys = ["HOME", "TMPDIR", "LANG", "LC_ALL"]
        var environment = ["PATH": fallbackPath]

        for key in preservedKeys {
            if let value = source[key], !value.isEmpty {
                environment[key] = value
            }
        }

        if environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        if environment["LC_ALL"] == nil {
            environment["LC_ALL"] = "en_US.UTF-8"
        }

        return environment
    }
}
