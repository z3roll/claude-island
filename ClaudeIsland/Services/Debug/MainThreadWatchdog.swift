//
//  MainThreadWatchdog.swift
//  ClaudeIsland
//
//  Detects main-thread hangs and dumps a backtrace to /tmp/ci-hang.log.
//  Remove this file from the build once the freeze is diagnosed.
//

import Foundation

enum MainThreadWatchdog {
    private static let threshold: TimeInterval = 3.0  // seconds before considered "hung"
    private static let logPath = "/tmp/ci-hang.log"

    /// Start watching. Call once from applicationDidFinishLaunching.
    static func start() {
        let queue = DispatchQueue(label: "ci.watchdog", qos: .userInteractive)
        var lastPong = Date()
        let lock = NSLock()

        // Ping main thread every second
        queue.async {
            while true {
                Thread.sleep(forTimeInterval: 1.0)

                // Check if main thread responded to last ping
                lock.lock()
                let elapsed = Date().timeIntervalSince(lastPong)
                lock.unlock()

                if elapsed > threshold {
                    // Main thread is hung — dump info
                    let msg = """
                    ===== MAIN THREAD HANG DETECTED =====
                    Time: \(Date())
                    Elapsed since last pong: \(String(format: "%.1f", elapsed))s
                    Threshold: \(threshold)s

                    Thread backtraces:
                    \(captureBacktrace())

                    =====================================

                    """
                    appendToLog(msg)
                }

                // Schedule pong on main thread
                DispatchQueue.main.async {
                    lock.lock()
                    lastPong = Date()
                    lock.unlock()
                }
            }
        }
    }

    private static func captureBacktrace() -> String {
        // Use Thread.callStackSymbols for the current (watchdog) thread,
        // and log what we can about main thread state
        var info = "Watchdog thread stack:\n"
        info += Thread.callStackSymbols.joined(separator: "\n")
        info += "\n\nNote: This is the watchdog thread's stack. "
        info += "The main thread is blocked somewhere else. "
        info += "Use 'sample' or 'spindump' for the actual main-thread stack.\n"

        // Try to run `sample` to get the real main-thread stack
        let pid = Foundation.ProcessInfo.processInfo.processIdentifier
        let sampleProcess = Process()
        let pipe = Pipe()
        sampleProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampleProcess.arguments = ["\(pid)", "1", "10"]  // 1 second, 10ms interval
        sampleProcess.standardOutput = pipe
        sampleProcess.standardError = FileHandle.nullDevice

        do {
            try sampleProcess.run()
            sampleProcess.waitUntilExit()
            if let data = try? pipe.fileHandleForReading.readDataToEndOfFile(),
               let output = String(data: data, encoding: .utf8) {
                info += "\n\n===== sample output =====\n"
                // Only keep lines mentioning main thread or our code
                let relevant = output.components(separatedBy: "\n")
                    .filter { $0.contains("Thread") || $0.contains("ClaudeIsland") || $0.contains("main") || $0.contains("SwiftUI") || $0.contains("AppKit") || $0.contains("_dispatch") || $0.contains("start_wqthread") }
                info += relevant.prefix(100).joined(separator: "\n")
            }
        } catch {
            info += "\nFailed to run sample: \(error)"
        }

        return info
    }

    private static func appendToLog(_ message: String) {
        let data = message.data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }
}
