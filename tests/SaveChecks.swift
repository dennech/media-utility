import Foundation

@main
struct SaveChecks {
    static func mustFail(_ action: () throws -> Void) {
        var failed = false
        do { try action() } catch { failed = true }
        precondition(failed)
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        try await withThrowingTaskGroup(of: Void.self) { children in
            for _ in 0..<32 {
                children.addTask {
                    let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
                    precondition(result.exitCode == 0)
                }
            }
            try await children.waitForAll()
        }

        let coordinator = DownloadCoordinator()
        for ext in ["mov", "wav"] {
            let original = root.appendingPathComponent("media." + ext)
            let stage = root.appendingPathComponent("stage." + ext)
            let old = Data("original".utf8)
            let new = Data("converted".utf8)
            try old.write(to: original)
            let destination = try SaveDestination(original)
            coordinator.startRequest()
            try Data().write(to: stage)
            mustFail { try coordinator.publish(staged: stage, to: destination) }
            try new.write(to: stage)
            _ = coordinator.requestCancellation()
            mustFail { try coordinator.publish(staged: stage, to: destination) }
            let afterCancel = try Data(contentsOf: original)
            precondition(afterCancel == old)
            coordinator.startRequest()
            try coordinator.publish(staged: stage, to: destination)
            let afterSuccess = try Data(contentsOf: original)
            precondition(afterSuccess == new)
            let competing = root.appendingPathComponent("racing." + ext)
            let absent = try SaveDestination(competing)
            try old.write(to: competing)
            try new.write(to: stage)
            mustFail { try coordinator.publish(staged: stage, to: absent) }
            let retained = try Data(contentsOf: competing)
            precondition(retained == old)
        }

        let short = URL(string: "https://youtu.be/abcdefghijk?t=7")!
        precondition(SupportedService.mediaURL(short).absoluteString == "https://www.youtube.com/watch?v=abcdefghijk&t=7")
        for string in ["https://youtu.be.example.invalid/abcdefghijk", "https://other.invalid/watch",
                       "https://www.youtube.com:8443/watch?v=abcdefghijk"] {
            let address = URL(string: string)!
            precondition(SupportedService.mediaURL(address) == address)
        }

        let source = root.appendingPathComponent("export")
        let target = root.appendingPathComponent("scoped")
        let rows = "# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tFALSE\t0\tselected\tfixture\nother.invalid\tFALSE\t/\tTRUE\t0\tomitted\tfixture\n"
        try Data(rows.utf8).write(to: source)
        try CookieFileValidator.writeScopedCopy(from: source, host: "www.youtube.com", to: target)
        let filtered = try String(contentsOf: target, encoding: .utf8)
        precondition(filtered.contains("www.youtube.com\tFALSE\t/\tTRUE") && !filtered.contains("omitted"))
        let untouched = try String(contentsOf: source, encoding: .utf8)
        precondition(untouched == rows)
        print("Passed MOV/WAV commit, cancellation, empty output, competing destination and scoped cookie checks.")

        if CommandLine.arguments.count >= 2 {
            let address = CommandLine.arguments[1]
            coordinator.startRequest()
            let media = try await coordinator.prepareDownload(urlString: address, cookieAccessMode: .anonymous) { _ in }
            for mode in DownloadMode.allCases {
                let file = root.appendingPathComponent("integration." + mode.fileExtension)
                let saved = try await coordinator.performDownload(prepared: media, mode: mode,
                    videoSettings: .init(preset: .high, preserveOriginalWhenPossible: true),
                    destination: SaveDestination(file)) { _ in }
                let info = try await ProcessRunner.run(executable: media.toolchain.ffprobe,
                    arguments: ["-v", "error", "-show_entries", "stream=codec_type,codec_name", "-of", "csv=p=0", saved.path])
                precondition(info.exitCode == 0 && info.stdout.contains(mode == .audioWav ? "pcm_s16le" : "video"))
                print("Verified", mode.fileExtension, info.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                let successful = try Data(contentsOf: file)
                coordinator.startRequest()
                var cancelled = false
                do {
                    _ = try await coordinator.performDownload(prepared: media, mode: mode,
                        videoSettings: .init(preset: .high, preserveOriginalWhenPossible: false),
                        destination: SaveDestination(file)) { update in
                            if update.processingFraction != nil { _ = coordinator.requestCancellation() }
                        }
                } catch DownloadError.interrupted { cancelled = true }
                let afterCancel = try Data(contentsOf: file)
                precondition(cancelled && afterCancel == successful)
                print("Canceled conversion preserved", mode.fileExtension)
                coordinator.startRequest()
                if CommandLine.arguments.count == 3 {
                    let broken = try await coordinator.prepareDownload(urlString: CommandLine.arguments[2], cookieAccessMode: .anonymous) { _ in }
                    var failed = false
                    do {
                        _ = try await coordinator.performDownload(prepared: broken, mode: mode,
                            videoSettings: .init(preset: .high, preserveOriginalWhenPossible: true),
                            destination: SaveDestination(file)) { _ in }
                    } catch { failed = true }
                    let afterFailure = try Data(contentsOf: file)
                    precondition(failed && afterFailure == successful)
                    print("Failed conversion preserved", mode.fileExtension)
                }

            }
        }
    }
}
