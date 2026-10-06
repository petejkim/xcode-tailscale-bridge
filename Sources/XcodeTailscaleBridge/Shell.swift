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
    /// macOS has no "kill me when my parent dies", so the command runs under a small shell
    /// that polls for this app and stops the command once the app is gone. The shell starts
    /// the command as its own child, so the PID it kills can't have been reused by an
    /// unrelated process. Terminating the shell (`stop()`) stops the command too.
    private static let supervisor = #"""
        parent=$1; shift
        "$@" & child=$!
        ( while kill -0 "$parent" 2>/dev/null; do sleep 2; done; kill "$child" 2>/dev/null ) & watcher=$!
        trap 'kill "$child" "$watcher" 2>/dev/null' TERM INT HUP
        wait "$child"
        kill "$watcher" 2>/dev/null
        """#

    private let process = Process()
    private var buffer = Data()

    init(_ path: String, _ arguments: [String], queue: DispatchQueue, onLine: @escaping (String) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.supervisor, "line-stream", String(getpid()), path] + arguments
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
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }
}
