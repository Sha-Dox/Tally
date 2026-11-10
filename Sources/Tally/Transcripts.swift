import Foundation

enum ClaudePaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    static let sessions = root.appending(path: "sessions")
    static let projects = root.appending(path: "projects")
}

/// The subset of a transcript line Tally cares about. Decoding is lenient so
/// unexpected shapes are skipped instead of failing the whole scan.
private struct TranscriptLine: Decodable {
    var type: String?
    var subtype: String?
    var cwd: String?
    var timestamp: String?
    var isSidechain: Bool?
    var message: Message?

    struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?
    }

    struct Usage: Decodable {
        var input_tokens: Int?
        var output_tokens: Int?
        var cache_read_input_tokens: Int?
        var cache_creation_input_tokens: Int?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        subtype = try? c.decodeIfPresent(String.self, forKey: .subtype)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
        isSidechain = try? c.decodeIfPresent(Bool.self, forKey: .isSidechain)
        message = try? c.decodeIfPresent(Message.self, forKey: .message)
    }

    enum CodingKeys: String, CodingKey { case type, subtype, cwd, timestamp, isSidechain, message }

    var totals: TokenTotals? {
        guard type == "assistant", let u = message?.usage, message?.model != "<synthetic>" else { return nil }
        return TokenTotals(
            input: u.input_tokens ?? 0,
            output: u.output_tokens ?? 0,
            cacheRead: u.cache_read_input_tokens ?? 0,
            cacheWrite: u.cache_creation_input_tokens ?? 0,
            messages: 1
        )
    }
}

private enum Timestamps {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let plain = ISO8601DateFormatter()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
}

private let assistantMarker = Data(#""type":"assistant""#.utf8)
private let usageMarker = Data(#""usage""#.utf8)
private let compactMarker = Data(#""compact_boundary""#.utf8)
private let customTitleMarker = Data(#""type":"custom-title""#.utf8)
private let aiTitleMarker = Data(#""type":"ai-title""#.utf8)

enum TranscriptReader {
    static func url(forSession id: String) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: ClaudePaths.projects, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let candidate = dir.appending(path: "\(id).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The session's title: one the user set (/rename) wins over the one
    /// Claude generated. Both are re-written periodically, so the tail has them.
    static func latestTitle(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let start = size > 4 * 1024 * 1024 ? size - 4 * 1024 * 1024 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(size - start)) else { return nil }

        var custom: String?, generated: String?
        for raw in data.split(separator: 0x0A).reversed() {
            let isCustom = raw.range(of: customTitleMarker) != nil
            let isGenerated = raw.range(of: aiTitleMarker) != nil
            guard (isCustom && custom == nil) || (isGenerated && generated == nil),
                  let object = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any] else { continue }
            if isCustom, let t = object["customTitle"] as? String, !t.isEmpty { custom = t; break }
            if isGenerated, let t = object["aiTitle"] as? String, !t.isEmpty { generated = t }
        }
        return custom ?? generated
    }

    /// Reads backwards from the end of a transcript until it finds the latest
    /// main-chain reply (its usage is the current context) or a compaction.
    static func latestContext(at url: URL) -> (ContextReading?, cwd: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return (nil, nil) }

        var window: UInt64 = 512 * 1024
        var cwd: String?
        while true {
            let start = size > window ? size - window : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.read(upToCount: Int(size - start)) else { return (nil, cwd) }
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            // The first line of a partial window may be cut off.
            if start > 0, !lines.isEmpty { lines.removeFirst() }

            for raw in lines.reversed() {
                let isAssistant = raw.range(of: assistantMarker) != nil && raw.range(of: usageMarker) != nil
                let isCompaction = raw.range(of: compactMarker) != nil
                guard isAssistant || isCompaction else { continue }
                guard let line = try? JSONDecoder().decode(TranscriptLine.self, from: Data(raw)) else { continue }
                if line.isSidechain == true { continue }
                if cwd == nil { cwd = line.cwd }
                if line.type == "system", line.subtype == "compact_boundary" {
                    return (ContextReading(tokens: nil, model: nil, at: Timestamps.parse(line.timestamp), compacted: true), cwd)
                }
                if let t = line.totals {
                    let reading = ContextReading(
                        tokens: t.input + t.cacheRead + t.cacheWrite + t.output,
                        model: line.message?.model,
                        at: Timestamps.parse(line.timestamp),
                        compacted: false
                    )
                    return (reading, cwd)
                }
            }
            if start == 0 || window >= 16 * 1024 * 1024 { return (nil, cwd) }
            window *= 4
        }
    }
}

/// Incrementally totals token usage from every transcript, by local day and
/// project. Progress is cached on disk so only new bytes are read.
actor UsageScanner {
    private struct FileState: Codable {
        var offset: UInt64
        var recentIDs: [String]
        var cwd: String?
    }

    private struct Cache: Codable {
        var version = 2
        var files: [String: FileState] = [:]
        var days: [String: [String: TokenTotals]] = [:]
    }

    private var cache = Cache()
    private var loaded = false
    private let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Tally", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "usage-cache.json")
    }()

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func scan() -> [String: [String: TokenTotals]] {
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: cacheURL),
               let decoded = try? JSONDecoder().decode(Cache.self, from: data),
               decoded.version == Cache().version {
                cache = decoded
            }
        }

        var changed = false
        for url in transcriptFiles() {
            changed = scanFile(url) || changed
        }
        if changed, let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return cache.days
    }

    func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    private func transcriptFiles() -> [URL] {
        guard let e = FileManager.default.enumerator(at: ClaudePaths.projects, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    private func scanFile(_ url: URL) -> Bool {
        let key = url.path
        let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var state = cache.files[key] ?? FileState(offset: 0, recentIDs: [])
        if size < state.offset { state = FileState(offset: 0, recentIDs: []) }
        guard size > state.offset, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)

        var pending = Data()
        let decoder = JSONDecoder()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
            let complete = pending[pending.startIndex...lastNewline]
            for raw in complete.split(separator: 0x0A) {
                guard raw.range(of: assistantMarker) != nil, raw.range(of: usageMarker) != nil,
                      let line = try? decoder.decode(TranscriptLine.self, from: Data(raw)),
                      let totals = line.totals else { continue }
                if let id = line.message?.id {
                    if state.recentIDs.contains(id) { continue }
                    state.recentIDs.append(id)
                    if state.recentIDs.count > 64 { state.recentIDs.removeFirst(state.recentIDs.count - 64) }
                }
                if let cwd = line.cwd { state.cwd = cwd }
                let project = line.cwd ?? state.cwd ?? url.deletingLastPathComponent().lastPathComponent
                let day = dayKey(Timestamps.parse(line.timestamp) ?? .now)
                cache.days[day, default: [:]][project, default: TokenTotals()].add(totals)
            }
            state.offset += UInt64(complete.count)
            pending = Data(pending[pending.index(after: lastNewline)...])
        }
        cache.files[key] = state
        return true
    }
}
