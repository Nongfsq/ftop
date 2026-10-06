import Darwin
import Foundation
import FtopCore

/// Where `sudo ftop grant` installs the setuid copy of the helper.
public enum HelperInstall {
    public static let path = "/usr/local/libexec/ftop/ftop-helper"
}

/// Reads per-process CPU time and memory through the `ftop-helper` child process.
///
/// The helper is used in both cases so there is one code path: run as the user it
/// sees the user's processes; installed setuid root by `sudo ftop grant` it sees all.
final class ProcessProvider {
    static let privilegedHelperPath = HelperInstall.path

    private var process: Process?
    private var input: FileHandle?
    private var reader: UnsafeMutablePointer<FILE>?
    private var previous: [Int32: UInt64] = [:]
    private var previousTime: TimeInterval = 0
    private var privileged = false
    private let limit: Int

    init(limit: Int = 32) {
        self.limit = limit
    }

    deinit { stop() }

    static func helperURL() -> (url: URL, privileged: Bool)? {
        let manager = FileManager.default
        if let attributes = try? manager.attributesOfItem(atPath: privilegedHelperPath),
            (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
            ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o4000 != 0
        {
            return (URL(fileURLWithPath: privilegedHelperPath), true)
        }
        // Next to the running executable: inside the app bundle, or in the build folder.
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let sibling = executable.deletingLastPathComponent().appending(path: "ftop-helper")
        return manager.isExecutableFile(atPath: sibling.path) ? (sibling, false) : nil
    }

    func sample(now: TimeInterval) -> Reading<ProcessList> {
        guard let batch = readBatch() else {
            stop()
            return .unavailable("ftop-helper is missing or stopped answering")
        }
        if let elapsed = batch.elapsedNanoseconds {
            guard elapsed > 0 else { return .unavailable("waiting for a second sample") }
            let seconds = Double(elapsed) / 1_000_000_000
            func samples(_ rows: [Row]) -> [ProcessSample] {
                rows.prefix(limit).map {
                    ProcessSample(pid: $0.pid, name: $0.name, cpuPercent: Double($0.cpu) / (seconds * 1_000_000_000) * 100, memoryBytes: $0.memory)
                }
            }
            return .value(
                ProcessList(top: samples(batch.rows), byMemory: samples(batch.memoryRows), coversAllUsers: privileged, helperOutdated: batch.version < 3))
        }
        return legacySample(batch.rows, now: now)
    }

    /// A helper installed by an earlier version lists every process with its total CPU
    /// time; the comparison with the previous reading happens here.
    private func legacySample(_ rows: [Row], now: TimeInterval) -> Reading<ProcessList> {
        defer {
            previous = Dictionary(rows.map { ($0.pid, $0.cpu) }, uniquingKeysWith: { first, _ in first })
            previousTime = now
        }
        let seconds = now - previousTime
        guard previousTime > 0, seconds > 0 else { return .unavailable("waiting for a second sample") }

        var samples: [ProcessSample] = []
        samples.reserveCapacity(rows.count)
        for row in rows {
            guard let before = previous[row.pid],
                let percent = Metrics.cpuPercent(previousNanoseconds: before, currentNanoseconds: row.cpu, seconds: seconds)
            else { continue }
            samples.append(ProcessSample(pid: row.pid, name: row.name, cpuPercent: percent, memoryBytes: row.memory))
        }
        samples.sort { $0.cpuPercent != $1.cpuPercent ? $0.cpuPercent > $1.cpuPercent : $0.memoryBytes > $1.memoryBytes }
        return .value(ProcessList(top: Array(samples.prefix(limit)), coversAllUsers: privileged, helperOutdated: true))
    }

    private struct Row {
        var pid: Int32
        var cpu: UInt64
        var memory: UInt64
        var name: String
    }

    private struct Batch {
        /// Time the rows cover; nil from a helper that predates the header line.
        var elapsedNanoseconds: UInt64?
        var version = 1
        var rows: [Row]
        /// The same processes ordered by memory; version 3 and later.
        var memoryRows: [Row] = []
    }

    private func start() -> Bool {
        guard let helper = Self.helperURL() else { return false }
        let task = Process()
        let toHelper = Pipe()
        let fromHelper = Pipe()
        task.executableURL = helper.url
        task.standardInput = toHelper
        task.standardOutput = fromHelper
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        process = task
        input = toHelper.fileHandleForWriting
        reader = fdopen(dup(fromHelper.fileHandleForReading.fileDescriptor), "r")
        privileged = helper.privileged
        previous = [:]
        previousTime = 0
        return reader != nil
    }

    private func stop() {
        if let reader { fclose(reader) }
        reader = nil
        try? input?.close()
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    private func readBatch() -> Batch? {
        if process?.isRunning != true {
            stop()
            guard start() else { return nil }
        }
        guard let input, let reader else { return nil }
        do { try input.write(contentsOf: Data([0x0A])) } catch { return nil }

        var batch = Batch(elapsedNanoseconds: nil, rows: [])
        var first = true
        var inMemoryList = false
        var line: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(line) }
        while true {
            let length = getline(&line, &capacity, reader)
            guard length > 0, let line else { return nil }  // helper exited
            if length == 1 { return batch }  // blank line ends the batch
            let text = String(cString: line).dropLast()
            if first {
                first = false
                let header = text.split(separator: " ")
                if header.count == 3, header[0] == "ftop-helper", let version = Int(header[1]), version >= 2 {
                    batch.version = version
                    batch.elapsedNanoseconds = UInt64(header[2]) ?? 0
                    continue
                }
            }
            if text == "memory", batch.version >= 3 {
                inMemoryList = true
                continue
            }
            let parts = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = UInt64(parts[1]), let memory = UInt64(parts[2]) else { continue }
            let row = Row(pid: pid, cpu: cpu, memory: memory, name: parts[3].isEmpty ? "pid \(pid)" : String(parts[3]))
            if inMemoryList { batch.memoryRows.append(row) } else { batch.rows.append(row) }
        }
    }
}
