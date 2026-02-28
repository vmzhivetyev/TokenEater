import Foundation

final class UsageLogger {
    static let shared = UsageLogger()
    private init() {}

    private let fileName = "usage-log.ndjson"

    var logURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TokenEater", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    func append(_ usage: UsageResponse) {
        let entry = LogEntry(fetchedAt: Date(), usage: usage)
        guard let line = try? JSONEncoder().encode(entry),
              let text = String(data: line, encoding: .utf8) else { return }
        let lineWithNewline = text + "\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(lineWithNewline.utf8))
            try? handle.close()
        } else {
            try? lineWithNewline.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}

private struct LogEntry: Encodable {
    let fetchedAt: Date
    let usage: UsageResponse

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let iso = ISO8601DateFormatter()
        try c.encode(iso.string(from: fetchedAt), forKey: .fetchedAt)
        try c.encode(usage, forKey: .usage)
    }

    enum CodingKeys: String, CodingKey {
        case fetchedAt = "fetched_at"
        case usage
    }
}
