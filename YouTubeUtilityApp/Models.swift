import Foundation

enum DownloadMode: String, CaseIterable, Identifiable {
    case videoMov
    case audioWav

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videoMov:
            return "Video (.mov)"
        case .audioWav:
            return "Audio (.wav)"
        }
    }

    var fileExtension: String {
        switch self {
        case .videoMov:
            return "mov"
        case .audioWav:
            return "wav"
        }
    }

    var phaseDescription: String {
        switch self {
        case .videoMov:
            return "Preparing MOV..."
        case .audioWav:
            return "Preparing WAV..."
        }
    }
}

enum VideoCompressionPreset: String, CaseIterable, Identifiable {
    case small
    case balanced
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small:
            return "Small"
        case .balanced:
            return "Balanced"
        case .high:
            return "High"
        }
    }

    var ffmpegPreset: String {
        switch self {
        case .small:
            return "faster"
        case .balanced:
            return "fast"
        case .high:
            return "medium"
        }
    }

    var crf: String {
        switch self {
        case .small:
            return "28"
        case .balanced:
            return "24"
        case .high:
            return "20"
        }
    }

    var audioBitrate: String {
        switch self {
        case .small:
            return "128k"
        case .balanced:
            return "160k"
        case .high:
            return "192k"
        }
    }

    var summary: String {
        switch self {
        case .small:
            return "Small reduces size the most and encodes the fastest."
        case .balanced:
            return "Balanced keeps a good tradeoff between size and quality."
        case .high:
            return "High is the default and preserves more detail, but files stay larger and encoding takes longer."
        }
    }
}

struct VideoOutputSettings {
    let preset: VideoCompressionPreset
    let preserveOriginalWhenPossible: Bool

    var processingMessage: String {
        "Preparing MOV (\(preset.title))..."
    }
}

enum SourceKind {
    case video
    case audioOnly

    var description: String {
        switch self {
        case .video:
            return "video"
        case .audioOnly:
            return "audio-only"
        }
    }
}

enum SupportedService: String {
    case youtube
    case vimeo
    case dailymotion
    case twitch
    case tiktok
    case instagram
    case facebook
    case twitterX
    case vk
    case rutube
    case soundcloud
    case generic

    // A parent domain may authorize a subdomain only for these known services.
    static let domains: [(String, SupportedService)] = [
        ("youtube.com", .youtube), ("youtu.be", .youtube), ("vimeo.com", .vimeo),
        ("dailymotion.com", .dailymotion), ("dai.ly", .dailymotion), ("twitch.tv", .twitch),
        ("tiktok.com", .tiktok), ("instagram.com", .instagram), ("facebook.com", .facebook),
        ("fb.watch", .facebook), ("twitter.com", .twitterX), ("x.com", .twitterX),
        ("vk.com", .vk), ("vkvideo.ru", .vk), ("rutube.ru", .rutube), ("soundcloud.com", .soundcloud)
    ]

    init(url: URL) {
        let host = (url.host ?? "").lowercased()
        self = Self.domains.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1 ?? .generic
    }

    var displayName: String {
        switch self {
        case .youtube:
            return "YouTube"
        case .vimeo:
            return "Vimeo"
        case .dailymotion:
            return "Dailymotion"
        case .twitch:
            return "Twitch"
        case .tiktok:
            return "TikTok"
        case .instagram:
            return "Instagram"
        case .facebook:
            return "Facebook"
        case .twitterX:
            return "X/Twitter"
        case .vk:
            return "VK"
        case .rutube:
            return "Rutube"
        case .soundcloud:
            return "SoundCloud"
        case .generic:
            return "This source"
        }
    }

    var detailLabel: String {
        switch self {
        case .generic:
            return "Generic / embedded player"
        default:
            return displayName
        }
    }

}

enum DownloadStatusKind {
    case idle
    case progress
    case success
    case failure
}

struct DownloadStatus {
    let kind: DownloadStatusKind
    let title: String
    let detail: String

    static let idle = DownloadStatus(
        kind: .idle,
        title: "Ready",
        detail: "Paste a media link to download a MOV or extract a WAV."
    )

    static func progress(_ detail: String) -> DownloadStatus {
        DownloadStatus(
            kind: .progress,
            title: "Working...",
            detail: detail
        )
    }

    static func success(fileName: String) -> DownloadStatus {
        DownloadStatus(
            kind: .success,
            title: "Saved",
            detail: fileName
        )
    }

    static func failure(_ detail: String) -> DownloadStatus {
        DownloadStatus(
            kind: .failure,
            title: "Download failed",
            detail: detail
        )
    }

    static func note(_ detail: String) -> DownloadStatus {
        DownloadStatus(
            kind: .idle,
            title: "Ready",
            detail: detail
        )
    }
}

struct OperationUpdate {
    let message: String
    let downloadFraction: Double?
    let processingFraction: Double?

    static func status(_ message: String) -> OperationUpdate {
        OperationUpdate(message: message, downloadFraction: nil, processingFraction: nil)
    }

    static func downloading(message: String, fraction: Double) -> OperationUpdate {
        OperationUpdate(
            message: message,
            downloadFraction: min(max(fraction, 0), 1),
            processingFraction: nil
        )
    }

    static func processing(message: String, downloadFraction: Double? = nil, fraction: Double) -> OperationUpdate {
        OperationUpdate(
            message: message,
            downloadFraction: downloadFraction.map { min(max($0, 0), 1) },
            processingFraction: min(max(fraction, 0), 1)
        )
    }
}

enum CookieAccessMode: Equatable {
    case anonymous
    case cookiesFile(URL)

    var statusLabel: String {
        switch self {
        case .anonymous:
            return "anonymous"
        case .cookiesFile:
            return "manual cookies file"
        }
    }
}

enum AuthChallengeStage {
    case metadata
    case download

    var description: String {
        switch self {
        case .metadata:
            return "metadata"
        case .download:
            return "download"
        }
    }
}

struct AuthChallenge: Equatable {
    let service: SupportedService
    let host: String
    let reason: String
    let stage: AuthChallengeStage

    var promptTitle: String { "Sign in to " + host + "?" }

    var promptMessage: String {
        "This site requires a session. Choose a Netscape cookie export from a dedicated profile. Only matching entries are copied for this download. Anyone with your session cookies may be able to use your account."
    }
}

enum ToolTrustState: Equatable {
    case trusted(String)
    case manualButBlocked(String)
    case untrusted(String)

    var isTrusted: Bool {
        if case .trusted = self {
            return true
        }
        return false
    }

    var statusText: String {
        switch self {
        case let .trusted(message),
             let .manualButBlocked(message),
             let .untrusted(message):
            return message
        }
    }

    var blockingReason: String? {
        switch self {
        case .trusted:
            return nil
        case let .manualButBlocked(message),
             let .untrusted(message):
            return message
        }
    }
}

struct Toolchain {
    let runtime: URL
    let deno: URL?
    let python: URL
    let ytDlp: URL
    let ffmpeg: URL
    let ffprobe: URL
    let ytDlpVersion: String
    let trustState: ToolTrustState

    var ffmpegDirectory: URL {
        ffmpeg.deletingLastPathComponent()
    }

    func requireTrustedExecution() throws {
        if let blockingReason = trustState.blockingReason {
            throw DownloadError.toolchainBlocked(blockingReason)
        }
    }
}

struct PreparedDownload {
    let requestURL: URL
    let metadata: VideoMetadata
    let cookieAccessMode: CookieAccessMode
    let toolchain: Toolchain
    let sourceKind: SourceKind
    let service: SupportedService

    var suggestedBaseName: String {
        NameCleaner.clean(metadata.title ?? metadata.id ?? "video")
    }

    func resolvedMode(for requestedMode: DownloadMode) -> DownloadMode {
        guard requestedMode == .videoMov, sourceKind == .audioOnly else {
            return requestedMode
        }
        return .audioWav
    }

    var autoSwitchMessage: String {
        guard sourceKind == .audioOnly else {
            return ""
        }
        if service == .generic {
            return "This source is audio-only, saving as WAV instead."
        }
        return "\(service.displayName) is audio-only, saving as WAV instead."
    }
}

enum YtDlpUpdateState: Equatable {
    case unavailable(localVersion: String?)
    case checking(localVersion: String)
    case upToDate(localVersion: String)
    case updateAvailable(localVersion: String, latestVersion: String)
    case blocked(localVersion: String, message: String)

    var infoText: String {
        switch self {
        case let .unavailable(version):
            return version.map { "yt-dlp " + $0 + " · Release check unavailable" } ?? "Downloader unavailable"
        case let .checking(version):
            return "yt-dlp " + version + " · Checking releases…"
        case let .upToDate(version):
            return "yt-dlp " + version + " · Current stable release"
        case let .updateAvailable(version, latest):
            return "Using " + version + " · Latest stable " + latest
        case let .blocked(_, message):
            return message
        }
    }
}

struct ProcessOutput {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var combined: String {
        [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct FormatChoice {
    let formatID: String
    let acodec: String
    let abr: Double
    let asr: Int
    let ext: String
}

struct VideoChoice {
    let formatID: String
    let vcodec: String
    let width: Int
    let height: Int
    let fps: Double
    let includesAudio: Bool
}

struct VideoMetadata: Decodable {
    let id: String?
    let title: String?
    let language: String?
    let originalLanguage: String?
    let formats: [VideoFormat]

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case language
        case originalLanguage = "original_language"
        case formats
    }
}

struct VideoFormat: Decodable {
    let formatID: String
    let vcodec: String?
    let acodec: String?
    let protocolName: String?
    let height: Int?
    let width: Int?
    let fps: Double?
    let tbr: Double?
    let vbr: Double?
    let abr: Double?
    let asr: Int?
    let filesize: Double?
    let filesizeApprox: Double?
    let ext: String?
    let language: String?
    let languagePreference: Int?
    let sourcePreference: Int?
    let formatNote: String?

    enum CodingKeys: String, CodingKey {
        case formatID = "format_id"
        case vcodec
        case acodec
        case protocolName = "protocol"
        case height
        case width
        case fps
        case tbr
        case vbr
        case abr
        case asr
        case filesize
        case filesizeApprox = "filesize_approx"
        case ext
        case language
        case languagePreference = "language_preference"
        case sourcePreference = "source_preference"
        case formatNote = "format_note"
    }
}

struct ProbeStreams: Decodable {
    let streams: [ProbeStream]
    let format: ProbeFormat?
}

struct ProbeStream: Decodable {
    let codecType: String?
    let codecName: String?

    enum CodingKeys: String, CodingKey {
        case codecType = "codec_type"
        case codecName = "codec_name"
    }
}

struct ProbeFormat: Decodable {
    let duration: String?
}

enum DownloadError: LocalizedError {
    case invalidURL
    case missingTools(String)
    case toolchainBlocked(String)
    case metadataFailed(String)
    case authenticationRequired(AuthChallenge)
    case downloadFailed(String)
    case conversionFailed(String)
    case invalidCookiesFile(String)
    case cancelled
    case interrupted
    case unsupportedFormat(String)
    case workspaceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid media link."
        case let .missingTools(message):
            return message
        case let .toolchainBlocked(message):
            return message
        case let .metadataFailed(message):
            return message
        case let .authenticationRequired(challenge):
            return challenge.promptMessage
        case let .downloadFailed(message):
            return message
        case let .conversionFailed(message):
            return message
        case let .invalidCookiesFile(message):
            return message
        case .cancelled:
            return "Save canceled."
        case .interrupted:
            return "The current operation was canceled."
        case let .unsupportedFormat(message):
            return message
        case let .workspaceUnavailable(message):
            return message
        }
    }
}

enum NameCleaner {
    static func clean(_ raw: String) -> String {
        var value = raw
        value = replacing(#"^\[\s*([^\]]+?)\s*\]\s*"#, in: value, with: "$1 - ")
        value = replacing(#"\[\s*([^\]]+?)\s*\]"#, in: value, with: "$1")
        value = value.replacingOccurrences(of: "|", with: " - ")
        value = value.replacingOccurrences(of: ":", with: " -")
        value = replacing(#"\s+_\s+"#, in: value, with: " - ")
        value = replacing(#"[<>"/\\|?*\u{0000}-\u{001F}]"#, in: value, with: "")
        value = replacing(#"\s*-\s*"#, in: value, with: " - ")
        value = replacing(#"\s+"#, in: value, with: " ")
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if value.isEmpty {
            return "video"
        }
        return String(value.prefix(180))
    }

    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: replacement)
    }
}

enum CookieFileValidator {
    static func writeScopedCopy(from source: URL, host: String, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let limit = 10 * 1024 * 1024
        guard values.isRegularFile == true, let size = values.fileSize, size <= limit else {
            throw DownloadError.invalidCookiesFile("Choose a cookie file smaller than 10 MB.")
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, let sourceText = String(data: data, encoding: .utf8) else {
            throw DownloadError.invalidCookiesFile("The cookie export must be a UTF-8 text file.")
        }

        let host = host.lowercased()
        let now = Int64(Date().timeIntervalSince1970)
        var rows = ["# Netscape HTTP Cookie File"]
        for line in sourceText.split(whereSeparator: \.isNewline) {
            let httpOnly = line.hasPrefix("#HttpOnly_")
            if line.hasPrefix("#") && !httpOnly { continue }
            let record = httpOnly ? line.dropFirst(10) : line[...]
            var fields = record.components(separatedBy: "\t")
            guard fields.count == 7, ["TRUE", "FALSE"].contains(fields[1]),
                  fields[2].hasPrefix("/"), ["TRUE", "FALSE"].contains(fields[3]),
                  !fields[5].isEmpty else {
                throw DownloadError.invalidCookiesFile("Invalid Netscape cookie row.")
            }
            let domain = String(fields[0].lowercased().drop(while: { $0 == "." }))
            let allowedParent = fields[1] == "TRUE" && host.hasSuffix("." + domain)
                && SupportedService.domains.contains { $0.0 == domain }
            guard host == domain || allowedParent else { continue }
            guard let expiry = Int64(fields[4].isEmpty ? "0" : fields[4]) else {
                throw DownloadError.invalidCookiesFile("Invalid cookie expiry.")
            }
            guard expiry == 0 || expiry > now else { continue }
            fields[0] = (httpOnly ? "#HttpOnly_" : "") + host
            fields[1] = "FALSE"
            fields[3] = "TRUE"
            if expiry == 0 { fields[4] = "0" }
            rows.append(fields.joined(separator: "\t"))
        }
        guard rows.count > 1 else {
            throw DownloadError.invalidCookiesFile("No current cookies matched " + host + ". Use the full HTTPS media URL.")
        }
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
