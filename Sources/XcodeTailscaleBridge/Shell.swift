import Foundation

struct BridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs a command to completion. Blocks; don't call on the main thread.
    @discardableResult
    static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        // Drain stderr concurrently so a full pipe can't block the process.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }
}

/// Runs a long-lived command and delivers its stdout line by line.
/// The command is stopped if this app dies, even from SIGKILL.
final class LineStream {
    private let process = Process()
    private let watchdog = Process()
    private var buffer = Data()

    init(_ path: String, _ arguments: [String], queue: DispatchQueue, onLine: @escaping (String) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            queue.async {
                guard let self else { return }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                self.buffer.append(data)
                while let newline = self.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: self.buffer[..<newline], as: UTF8.self)
                    self.buffer.removeSubrange(...newline)
                    onLine(line)
                }
            }
        }
        try process.run()

        // macOS has no "kill me when my parent dies", so a tiny shell polls for this app
        // and stops the command once it's gone.
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null && kill -0 "$2" 2>/dev/null; do sleep 2; done; kill "$2" 2>/dev/null"#,
                              "watchdog", String(getpid()), String(process.processIdentifier)]
        watchdog.standardInput = FileHandle.nullDevice
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        try? watchdog.run()
    }

    func stop() {
        if process.isRunning { process.terminate() }
        if watchdog.isRunning { watchdog.terminate() }
    }

    deinit { stop() }
}
