import Foundation

/// Appends to ~/Library/Logs/XcodeTailscaleBridge.log (and stderr).
enum Log {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/XcodeTailscaleBridge.log")

    private static let maxSize = 5 * 1024 * 1024
    private static let queue = DispatchQueue(label: "log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func info(_ message: String) {
        let date = Date()
        queue.async {
            let line = Data("\(formatter.string(from: date)) \(message)\n".utf8)
            FileHandle.standardError.write(line)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > maxSize || !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? line.write(to: url)
            } else if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            }
        }
    }
}
