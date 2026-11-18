import AppKit
import CryptoKit
import Security
import WebKit

@MainActor
final class SiteSignIn: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let address = NSTextField(labelWithString: "")
    private var observation: NSKeyValueObservation?

    static func authorize(_ url: URL, in directory: URL, coordinator: DownloadCoordinator, renew: Bool) async throws -> URL? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else { throw DownloadError.invalidURL }
        let name = host + (url.port.map { ":\($0)" } ?? "")
        let key = SHA256.hash(data: Data("\(host):\(url.port ?? 443)".utf8)).map { String(format: "%02x", $0) }.joined()
        let defaults = UserDefaults.standard
        let chrome = installedChrome()
        let marker = "MediaUtility.SiteSession." + (chrome == nil ? "web." : "chrome.") + key
        let saved = defaults.bool(forKey: marker) && !renew
        let consent = NSAlert()
        consent.messageText = "Use a site session for \(name)?"
        consent.informativeText = chrome == nil
            ? "Sign in in a separate Media Utility window. Only this site’s session can be used for this download."
            : "Media Utility uses a separate Chrome profile for this site. Only this site’s session can be used for this download. macOS may ask about Chrome Safe Storage."
        consent.addButton(withTitle: saved ? "Use Site Session" : "Sign In…")
        consent.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        if saved { consent.addButton(withTitle: "Sign In Again…") }
        let choice = consent.runModal()
        guard choice == .alertFirstButtonReturn || (saved && choice == .alertThirdButtonReturn) else { return nil }
        let signIn = !saved || choice == .alertThirdButtonReturn
        let file: URL
        if let chrome {
            if signIn {
                let fm = FileManager.default
                let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let profile = support.appendingPathComponent("Media Utility/Site Browsers/" + key, isDirectory: true)
                try fm.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard profile.resolvingSymlinksInPath().path == support.resolvingSymlinksInPath().appendingPathComponent("Media Utility/Site Browsers/" + key).path else {
                    throw DownloadError.invalidCookiesFile("The site profile could not be opened safely.")
                }
                let token = profile.appendingPathComponent(".media-utility-site")
                try Data(key.utf8).write(to: token, options: .atomic)
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                config.arguments = ["--user-data-dir=" + profile.path, "--profile-directory=Default",
                                    "--no-first-run", "--no-default-browser-check", "--disable-sync",
                                    "--disable-extensions", "--new-window", url.absoluteString]
                let browser = try await NSWorkspace.shared.openApplication(at: chrome, configuration: config)
                let ready = NSAlert()
                ready.messageText = "Finish signing in to \(name)"
                ready.informativeText = "Check that the page opens in the separate Chrome window. Then close that window, return here and continue."
                ready.addButton(withTitle: "Continue Download")
                ready.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
                DispatchQueue.main.async { browser.activate(options: []) }
                guard ready.runModal() == .alertFirstButtonReturn else { return nil }
            }
            do { file = try await coordinator.prepareChromeSession(for: url, in: directory) }
            catch {
                defaults.removeObject(forKey: marker)
                if saved && !signIn, case DownloadError.invalidCookiesFile = error {
                    return try await authorize(url, in: directory, coordinator: coordinator, renew: true)
                }
                throw error
            }
        } else {
            let session = SiteSignIn()
            let uuid = NSUUID(uuidBytes: Array(SHA256.hash(data: Data(key.utf8))).prefix(16).map { $0 }) as UUID
            let store = WKWebsiteDataStore(forIdentifier: uuid)
            if signIn && !session.present(url, store: store) { return nil }
            let cookies = await store.httpCookieStore.allCookies()
            let target = directory.appendingPathComponent("session.txt")
            do { try writeWebSession(cookies, for: host, to: target) }
            catch {
                defaults.removeObject(forKey: marker)
                if saved && !signIn, case DownloadError.invalidCookiesFile = error {
                    return try await authorize(url, in: directory, coordinator: coordinator, renew: true)
                }
                throw error
            }
            file = target
        }
        defaults.set(true, forKey: marker)
        return file
    }

    private static func installedChrome() -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { return nil }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"com.google.Chrome\" and certificate leaf[subject.OU] = \"EQHXZ8M8AV\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        return app
    }

    private static func writeWebSession(_ cookies: [HTTPCookie], for host: String, to target: URL) throws {
        var rows = ["# Netscape HTTP Cookie File"]
        for cookie in cookies {
            let raw = cookie.domain.lowercased()
            let domain = String(raw.drop(while: { $0 == "." }))
            guard !domain.isEmpty, host == domain || (raw.hasPrefix(".") && host.hasSuffix("." + domain)),
                  cookie.expiresDate.map({ $0 > Date() }) ?? true, cookie.path.hasPrefix("/"),
                  !cookie.name.isEmpty, ![cookie.name, cookie.value, cookie.path].contains(where: {
                      $0.rangeOfCharacter(from: .controlCharacters) != nil
                  }) else { continue }
            let expiry = cookie.expiresDate.map { String(Int64($0.timeIntervalSince1970)) } ?? "0"
            rows.append([(cookie.isHTTPOnly ? "#HttpOnly_" : "") + host, "FALSE", cookie.path, "TRUE",
                         expiry, cookie.name, cookie.value].joined(separator: "\t"))
        }
        guard rows.count > 1 else { throw DownloadError.invalidCookiesFile("No session for this site yet. Sign in and try again.") }
        guard FileManager.default.createFile(atPath: target.path, contents: Data((rows.joined(separator: "\n") + "\n").utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw DownloadError.invalidCookiesFile("The site session could not be prepared.")
        }
    }

    private func present(_ url: URL, store: WKWebsiteDataStore) -> Bool {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        observation = web.observe(\.url, options: [.initial, .new]) { [weak self] web, _ in
            let display = web.url?.host ?? ""
            Task { @MainActor in self?.address.stringValue = display }
        }
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 960, height: 720)
        let width = min(700, visible.width * 0.68)
        web.widthAnchor.constraint(equalToConstant: width).isActive = true
        web.heightAnchor.constraint(equalToConstant: min(445, visible.height * 0.52)).isActive = true
        let stack = NSStackView(views: [address, web])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame.size = stack.fittingSize
        let alert = NSAlert()
        alert.messageText = "Sign in to " + (url.host ?? "the site")
        alert.informativeText = "When you can open the media, choose Continue Download."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Continue Download").keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        web.load(URLRequest(url: url))
        defer { observation = nil; web.stopLoading() }
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let target = action.request.url
        decisionHandler(target?.scheme?.lowercased() == "https" && target?.user == nil && target?.password == nil ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil && action.request.url?.scheme?.lowercased() == "https" { webView.load(action.request) }
        return nil
    }
}
