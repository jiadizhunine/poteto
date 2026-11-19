import AppKit
import CoreFoundation
import Darwin
import Foundation
import OSLog
import SQLite3

enum NativeChatReferences {
    struct Summary: Codable, Equatable, Sendable {
        let accounts: Int
        let chats: Int
        let missingRecords: Int
    }

    private struct Repair {
        let summary: Summary
        let updated: Data
    }

    static let desktopBundleID = "com.openai.codex"
    private static let ownerPrefix = "electron-owner-atoms:"
    private static let referencePrefix = "thread-reference-capability:"
    private static let zstdDecoder = ["/usr/bin/zstd", "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    private static let supportedBuilds = ["26.1111.21308": "27194", "26.1111.71704": "29030"]
    private static let logger = Logger(subsystem: "io.poteto.menubar", category: "chat-references")

    static func supported(_ app: URL?) -> Bool {
        guard let app, let bundle = Bundle(url: app), bundle.bundleIdentifier == desktopBundleID,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return false }
        return supportedBuilds[version] == build
    }

    static func available() -> Bool {
        supported(NSWorkspace.shared.urlForApplication(withBundleIdentifier: desktopBundleID))
    }

    static func check(profile: URL) throws -> Summary? {
        let file = profile.appendingPathComponent(".codex-global-state.json")
        guard let stamp = try NativeStateFile.snapshot(file) else { return nil }
        let data = try NativeStateFile.read(file, expected: stamp)
        return try prepare(data, profile: profile)?.summary
    }

    @discardableResult
    static func apply(profile: URL, support: URL, isRunning: () -> Bool) throws -> Summary? {
        guard !isRunning() else { throw PotetoError.running }
        let file = profile.appendingPathComponent(".codex-global-state.json")
        guard let stamp = try NativeStateFile.snapshot(file) else { return nil }
        let data = try NativeStateFile.read(file, expected: stamp)
        guard let repair = try prepare(data, profile: profile) else { return nil }
        guard repair.summary.missingRecords > 0 else { return repair.summary }
        guard !isRunning() else { throw PotetoError.running }
        guard try NativeStateFile.snapshot(file) == stamp else { throw PotetoError.changed }
        let backup = support.appendingPathComponent("chat-references-before-update.json")
        try PrivateFiles.write(data, to: backup, limit: NativeStateFile.limit)
        guard try PrivateFiles.read(backup, limit: NativeStateFile.limit) == data else { throw PotetoError.changed }
        try NativeStateFile.write(repair.updated, to: file, expected: stamp) {
            guard !isRunning() else { throw PotetoError.running }
        }
        guard let after = try NativeStateFile.snapshot(file),
              try NativeStateFile.read(file, expected: after) == repair.updated else { throw PotetoError.changed }
        logger.notice("Restored \(repair.summary.missingRecords, privacy: .public) local chat reference records for \(repair.summary.accounts, privacy: .public) accounts")
        return repair.summary
    }

    private static func prepare(_ data: Data, profile: URL) throws -> Repair? {
        var info = stat()
        guard lstat(profile.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              (info.st_mode & 0o022) == 0 else { throw PotetoError.privateFile }
        var parser = UniqueJSONKeys(bytes: Array(data))
        let ranges = try parser.objectMembers()
        parser.whitespace()
        guard parser.index == data.count, let state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw PotetoError.projectState }
        guard let owner = safeLabel(state["electron-renderer-content-owner"]), owner != "signed-out",
              !state.keys.contains(where: { $0.hasPrefix("electron-account-renderer-state-") }) else { return nil }

        var owners: [String: [String: Any]] = [:]
        var known: Set<String> = []
        for (key, value) in state where key.hasPrefix(ownerPrefix) && key != ownerPrefix + "signed-out" {
            guard let atoms = value as? [String: Any] else { throw PotetoError.projectState }

            var supported: Set<String> = []
            for (name, flag) in atoms where name.hasPrefix(referencePrefix) {
                let id = String(name.dropFirst(referencePrefix.count))
                if let flag = flag as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue,
                   UUID(uuidString: id)?.uuidString.lowercased() == id {
                    supported.insert(id)
                }
            }
            let identity = atoms["local-document-identity"] as? [String: Any]
            let initialized = safeLabel(identity?["accountId"]) != nil && safeLabel(identity?["userId"]) != nil
            if initialized || !supported.isEmpty {
                owners[key] = atoms
                known.formUnion(supported)
            }
        }
        guard owners[ownerPrefix + owner] != nil, owners.count > 1 else { return nil }
        guard let hosts = (state["thread-project-membership-host-ids"] ?? [:]) as? [String: String] else {
            throw PotetoError.projectState
        }
        let keys = try localThreadIDs(in: profile, candidates: known, hosts: hosts).sorted().map { referencePrefix + $0 }
        var edits: [(index: Int, insert: Data)] = []
        var total = 0
        for (key, atoms) in owners {
            let additions = keys.filter { atoms[$0] == nil }
            guard !additions.isEmpty else { continue }
            guard let end = ranges[key]?.upperBound, data[end - 1] == 125 else { throw PotetoError.projectState }
            let fields = additions.map { "\"\($0)\":true" }.joined(separator: ",")
            edits.append((end - 1, Data(("," + fields).utf8)))
            total += additions.count
        }
        var updated = data
        for edit in edits.sorted(by: { $0.index > $1.index }) {
            updated.insert(contentsOf: edit.insert, at: edit.index)
        }
        guard updated.count <= NativeStateFile.limit else { throw PotetoError.projectState }
        return Repair(summary: Summary(accounts: owners.count, chats: keys.count, missingRecords: total), updated: updated)
    }

    private static func localThreadIDs(in profile: URL, candidates: Set<String>, hosts: [String: String]) throws -> Set<String> {
        guard let resolvedProfile = realpath(profile.path, nil) else { throw PotetoError.privateFile }
        defer { free(resolvedProfile) }
        let index = String(cString: resolvedProfile) + "/state_5.sqlite"
        let sessions = profile.appendingPathComponent("sessions", isDirectory: true).resolvingSymlinksInPath()
        var info = stat()
        if lstat(index, &info) != 0 {
            if errno == ENOENT { return [] }
            throw PotetoError.privateFile
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else {
            throw PotetoError.privateFile
        }
        var db: OpaquePointer?
        let result = sqlite3_open_v2(index, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil)
        defer { sqlite3_close(db) }
        guard result == SQLITE_OK else { throw PotetoError.changed }
        let query = """
        SELECT id, rollout_path, EXISTS (
            SELECT 1 FROM thread_dynamic_tools WHERE thread_id = threads.id AND name = 'read_thread'
        )
        FROM threads
        WHERE archived = 0 AND originator = 'Codex Desktop' AND thread_source = 'user'
            AND model_provider = 'openai' AND attached_thread_parent_id IS NULL
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw PotetoError.projectState }

        var found: Set<String> = []
        var next = sqlite3_step(statement)
        while next == SQLITE_ROW {
            if let rawID = sqlite3_column_text(statement, 0), let rawPath = sqlite3_column_text(statement, 1) {
                let id = String(cString: rawID)
                if UUID(uuidString: id)?.uuidString.lowercased() == id,
                   hosts[id, default: "local"] == "local",
                   let history = localHistory(String(cString: rawPath), in: sessions) {
                    if candidates.contains(id) || sqlite3_column_int(statement, 2) == 1 ||
                        headerDeclaresReadThread(id: id, history: history) {
                        found.insert(id)
                    }
                }
            }
            next = sqlite3_step(statement)
        }
        guard next == SQLITE_DONE else { throw PotetoError.changed }
        return found
    }

    private static func localHistory(_ path: String, in sessions: URL) -> URL? {
        guard path.hasPrefix("/"), path.hasSuffix(".jsonl") else { return nil }
        let url = URL(fileURLWithPath: path)
        return [url, url.appendingPathExtension("zst")].first { file in
            var info = stat()
            return lstat(file.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG &&
                info.st_uid == getuid() && info.st_size > 0 &&
                file.resolvingSymlinksInPath().path.hasPrefix(sessions.path + "/")
        }
    }

    private static func headerDeclaresReadThread(id: String, history: URL) -> Bool {
        let fd = open(history.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return false }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        guard history.pathExtension == "zst" else { return headerDeclaresReadThread(id: id, input: input) }
        guard let zstdDecoder else { return false }

        let decoder = Process()
        let output = Pipe()
        decoder.executableURL = URL(fileURLWithPath: zstdDecoder)
        decoder.arguments = ["-d", "-c", "--memory=64MB"]
        decoder.standardInput = input
        decoder.standardOutput = output
        decoder.standardError = FileHandle.nullDevice
        do { try decoder.run() } catch { return false }
        defer {
            try? output.fileHandleForReading.close()
            if decoder.isRunning { decoder.terminate() }
            decoder.waitUntilExit()
        }
        return headerDeclaresReadThread(id: id, input: output.fileHandleForReading)
    }

    private static func headerDeclaresReadThread(id: String, input: FileHandle) -> Bool {
        let limit = 1_048_576
        var header = Data()
        while header.count < limit, !Task.isCancelled,
              let chunk = try? input.read(upToCount: min(16_384, limit - header.count)), !chunk.isEmpty {
            guard let newline = chunk.firstIndex(of: 10) else {
                header.append(chunk)
                continue
            }
            header.append(contentsOf: chunk.prefix(upTo: newline))
            guard let record = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any],
                  record["type"] as? String == "session_meta",
                  let meta = record["payload"] as? [String: Any], meta["id"] as? String == id,
                  let tools = (meta["dynamic_tools"] ?? meta["dynamicTools"]) as? [[String: Any]] else { return false }
            return tools.contains { tool in
                if tool["name"] as? String == "read_thread" { return true }
                return (tool["tools"] as? [[String: Any]])?.contains { $0["name"] as? String == "read_thread" } == true
            }
        }
        return false
    }

    static func observerReady() {
        logger.notice("Watching for normal Codex desktop exit to update local chat references")
    }

    static func reportSkipped() {
        logger.error("Could not update local Codex chat references")
    }
}
