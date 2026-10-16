import Foundation
import OSLog
import SwiftData

/// Syncs the dictionary through a git repository so local builds (which have no
/// CloudKit) share vocabulary and replacements across Macs.
///
/// The clone is treated as a cache: each sync resets it to the remote, merges the
/// remote file into the local store, re-exports the store, and pushes only when the
/// export differs. Merging happens in the store, so git never sees a conflict.
///
/// Enabled when `GitDictionarySyncRepoPath` (default `~/.voiceink-dictionary`)
/// is a git clone. Deletions are not propagated: merge only adds entries.
@MainActor
final class GitDictionarySyncService {
    static let shared = GitDictionarySyncService()

    static let repoPathKey = "GitDictionarySyncRepoPath"
    private static let defaultRepoPath = "~/.voiceink-dictionary"
    private static let fileName = "dictionary.json"
    private static let pollInterval: TimeInterval = 5 * 60
    private static let debounceInterval: Duration = .seconds(5)
    private static let maximumPushAttempts = 3

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "GitDictionarySync")
    private var modelContainer: ModelContainer?
    private var isSyncing = false
    private var needsAnotherSync = false
    private var debounceTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    private var repoURL: URL {
        let path = UserDefaults.standard.string(forKey: Self.repoPathKey) ?? Self.defaultRepoPath
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private var isEnabled: Bool {
        FileManager.default.fileExists(atPath: repoURL.appendingPathComponent(".git").path)
    }

    func start(modelContainer: ModelContainer) {
        guard self.modelContainer == nil else { return }
        self.modelContainer = modelContainer
        guard isEnabled else {
            logger.notice("Git dictionary sync disabled: no clone at \(self.repoURL.path, privacy: .public)")
            return
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in GitDictionarySyncService.shared.scheduleSync() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .wordReplacementsDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in GitDictionarySyncService.shared.scheduleSync() }
        })
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in await GitDictionarySyncService.shared.sync() }
        }

        Task { await sync() }
    }

    func scheduleSync() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    func sync() async {
        guard isEnabled, let modelContainer else { return }
        guard !isSyncing else {
            needsAnotherSync = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        do {
            for attempt in 1...Self.maximumPushAttempts {
                if try await syncOnce(modelContext: modelContainer.mainContext) { break }
                logger.notice("Git dictionary push rejected, retrying attempt=\(attempt, privacy: .public)")
            }
        } catch {
            logger.error("Git dictionary sync failed: \(error.localizedDescription, privacy: .public)")
        }

        if needsAnotherSync {
            needsAnotherSync = false
            scheduleSync()
        }
    }

    /// Returns false when the push was rejected because the remote moved.
    private func syncOnce(modelContext: ModelContext) async throws -> Bool {
        let repo = repoURL
        let fileURL = repo.appendingPathComponent(Self.fileName)

        let branch = try await git(["symbolic-ref", "--short", "HEAD"], in: repo)
        try await git(["fetch", "--quiet", "origin"], in: repo)
        if (try? await git(["rev-parse", "--verify", "--quiet", "origin/\(branch)"], in: repo)) != nil {
            try await git(["reset", "--quiet", "--hard", "origin/\(branch)"], in: repo)
        }

        if let data = try? Data(contentsOf: fileURL) {
            let payload = try DictionaryImportExportService.decodeArchiveData(data)
            let summary = try await DictionaryImportExportService.preview(
                payload, mode: .merge, modelContext: modelContext)
            if summary.hasImportableEntries {
                _ = try await DictionaryImportExportService.apply(
                    archive: payload.archive, mode: .merge, modelContext: modelContext)
                NotificationCenter.default.post(name: .wordReplacementsDidChange, object: nil)
                logger.notice("Git dictionary sync imported remote entries")
            }
        }

        let exported = try DictionaryImportExportService.makeArchive(modelContext: modelContext)
        // A fixed timestamp keeps the file stable so unchanged dictionaries never commit.
        let stable = DictionaryArchive(
            exportedAt: Date(timeIntervalSince1970: 0),
            vocabulary: exported.vocabulary,
            replacements: exported.replacements
        )
        let data = try DictionaryImportExportService.encodeArchive(stable)
        guard (try? Data(contentsOf: fileURL)) != data else { return true }

        try data.write(to: fileURL, options: .atomic)
        try await git(["add", Self.fileName], in: repo)
        let host = Host.current().localizedName ?? "Mac"
        try await git(["commit", "--quiet", "-m", "Update dictionary from \(host)"], in: repo)
        do {
            try await git(["push", "--quiet", "origin", "HEAD:\(branch)"], in: repo)
        } catch {
            return false
        }
        logger.notice("Git dictionary sync pushed changes")
        return true
    }

    struct GitError: LocalizedError {
        let arguments: [String]
        let output: String
        var errorDescription: String? { "git \(arguments.joined(separator: " ")): \(output)" }
    }

    @discardableResult
    private nonisolated func git(_ arguments: [String], in directory: URL) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            // GUI apps get a minimal PATH; credential helpers like gh live in Homebrew.
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_AUTHOR_NAME"] = environment["GIT_AUTHOR_NAME"] ?? "VoiceInk"
            environment["GIT_AUTHOR_EMAIL"] = environment["GIT_AUTHOR_EMAIL"] ?? "voiceink@localhost"
            environment["GIT_COMMITTER_NAME"] = environment["GIT_COMMITTER_NAME"] ?? "VoiceInk"
            environment["GIT_COMMITTER_EMAIL"] = environment["GIT_COMMITTER_EMAIL"] ?? "voiceink@localhost"
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw GitError(arguments: arguments, output: output)
            }
            return output
        }.value
    }
}
