import Foundation

final class Capture {
    let directory: URL
    let url: URL
    private let handle: FileHandle
    private let encoder = JSONEncoder()
    private let clock: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent("session-\(UUID().uuidString).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                              attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ type: String, fields: [String: String] = [:]) throws {
        var event = fields
        event["event"] = type
        event["captured_at"] = clock.string(from: Date())
        var data = try encoder.encode(event)
        data.append(10)
        try handle.write(contentsOf: data)
    }

    func snapshot(_ fields: [String: String]) throws {
        let target = directory.appendingPathComponent("latest.json")
        try encoder.encode(fields).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    deinit { try? handle.close() }
}
