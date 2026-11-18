import Foundation

actor YtDlpUpdateCoordinator {
    private let defaults = UserDefaults.standard
    private let cacheLifetime: TimeInterval = 12 * 60 * 60

    private enum DefaultsKey {
        static let latestVersion = "MediaUtility.ytDlp.latestVersion"
        static let lastCheckDate = "MediaUtility.ytDlp.lastCheckDate"
    }

    private struct ReleaseResponse: Decodable {
        let tagName: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }

    func refreshState(using toolchain: Toolchain, forceNetwork: Bool) async -> YtDlpUpdateState {
        if let blockingReason = toolchain.trustState.blockingReason {
            return .blocked(localVersion: toolchain.ytDlpVersion, message: blockingReason)
        }

        if !forceNetwork, let cachedVersion = cachedLatestVersionIfFresh() {
            return evaluate(localVersion: toolchain.ytDlpVersion, latestVersion: cachedVersion)
        }

        do {
            let latestVersion = try await fetchLatestVersion()
            defaults.set(latestVersion, forKey: DefaultsKey.latestVersion)
            defaults.set(Date().timeIntervalSince1970, forKey: DefaultsKey.lastCheckDate)
            return evaluate(localVersion: toolchain.ytDlpVersion, latestVersion: latestVersion)
        } catch {
            return .unavailable(localVersion: toolchain.ytDlpVersion)
        }
    }

    private func cachedLatestVersionIfFresh() -> String? {
        guard let latestVersion = cachedLatestVersion() else {
            return nil
        }
        let lastCheck = defaults.double(forKey: DefaultsKey.lastCheckDate)
        guard lastCheck > 0 else {
            return nil
        }
        let age = Date().timeIntervalSince1970 - lastCheck
        return age <= cacheLifetime ? latestVersion : nil
    }

    private func cachedLatestVersion() -> String? {
        guard let version = defaults.string(forKey: DefaultsKey.latestVersion), !version.isEmpty else {
            return nil
        }
        return version
    }

    private func fetchLatestVersion() async throws -> String {
        let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MediaUtility/1.0", forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateError.releaseCheckFailed
        }

        let release = try JSONDecoder().decode(ReleaseResponse.self, from: data)
        let version = canonicalVersion(release.tagName)
        guard !version.isEmpty else {
            throw UpdateError.releaseCheckFailed
        }
        return version
    }

    private func evaluate(localVersion: String, latestVersion: String) -> YtDlpUpdateState {
        let local = canonicalVersion(localVersion)
        let latest = canonicalVersion(latestVersion)

        switch compare(local, latest) {
        case .orderedSame, .orderedDescending:
            return .upToDate(localVersion: local)
        case .orderedAscending:
            return .updateAvailable(localVersion: local, latestVersion: latest)
        }
    }

    private func canonicalVersion(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.anchored])
    }

    private func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsComponents = numericComponents(in: lhs)
        let rhsComponents = numericComponents(in: rhs)
        let count = max(lhsComponents.count, rhsComponents.count)

        for index in 0..<count {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0

            if lhsValue < rhsValue { return .orderedAscending }
            if lhsValue > rhsValue { return .orderedDescending }
        }
        return .orderedSame
    }

    private func numericComponents(in value: String) -> [Int] {
        value
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

}

private enum UpdateError: Error {
    case releaseCheckFailed
}
