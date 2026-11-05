import Foundation
import FtopCore
import Testing

@testable import FtopSensors

/// End and Force End against real processes this test starts.
@MainActor
@Suite(.serialized) struct ProcessControlTests {
    /// A child that sleeps until it is ended.
    func sleeper() throws -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["60"]
        try task.run()
        return task
    }

    func sample(of task: Process, startTime: UInt64?) -> ProcessSample {
        ProcessSample(pid: task.processIdentifier, name: "sleep", cpuPercent: 0, memoryBytes: 0, startTime: startTime)
    }

    func waitForExit(_ task: Process) {
        let deadline = Date().addingTimeInterval(5)
        while task.isRunning, Date() < deadline { usleep(10_000) }
    }

    @Test func theSampledProcessIsEnded() throws {
        let task = try sleeper()
        defer { if task.isRunning { task.terminate() } }
        let start = try #require(ProcessControl.startTime(of: task.processIdentifier))
        let target = try ProcessControl.target(for: sample(of: task, startTime: start)).get()
        #expect(target.kind == .process)
        #expect(target.identity == ProcessIdentity(pid: task.processIdentifier, startTime: start))
        #expect(ProcessControl.end(target, force: false) == nil)
        waitForExit(task)
        #expect(!task.isRunning)
        #expect(task.terminationReason == .uncaughtSignal && task.terminationStatus == SIGTERM)
    }

    @Test func forceEndSendsSIGKILL() throws {
        let task = try sleeper()
        defer { if task.isRunning { task.terminate() } }
        let start = try #require(ProcessControl.startTime(of: task.processIdentifier))
        let target = try ProcessControl.target(for: sample(of: task, startTime: start)).get()
        #expect(ProcessControl.end(target, force: true) == nil)
        waitForExit(task)
        #expect(task.terminationStatus == SIGKILL)
    }

    /// A row sampled from an earlier process with the same id: the menu offers nothing,
    /// and a target made before the id was reused is not signalled after confirmation.
    @Test func aStalePIDIsNeverSignalled() throws {
        let task = try sleeper()
        defer { if task.isRunning { task.terminate() } }
        let start = try #require(ProcessControl.startTime(of: task.processIdentifier))
        #expect(throws: ProcessRefusal.replaced) { try ProcessControl.target(for: sample(of: task, startTime: start &- 1)).get() }
        let stale = ProcessTarget(name: "sleep", identity: ProcessIdentity(pid: task.processIdentifier, startTime: start &+ 1), kind: .process)
        #expect(ProcessControl.end(stale, force: true) == .replaced)
        usleep(100_000)
        #expect(task.isRunning)
    }

    @Test func anExitedProcessIsGone() throws {
        let task = try sleeper()
        let start = try #require(ProcessControl.startTime(of: task.processIdentifier))
        task.terminate()
        task.waitUntilExit()
        let target = ProcessTarget(name: "sleep", identity: ProcessIdentity(pid: task.processIdentifier, startTime: start), kind: .process)
        #expect(ProcessControl.end(target, force: false) == .gone)
    }

    @Test func protectedAndOtherUsersProcessesAreRefused() throws {
        let me = getpid()
        let own = try #require(ProcessControl.startTime(of: me))
        #expect(throws: ProcessRefusal.protected) {
            try ProcessControl.target(for: ProcessSample(pid: me, name: "ftop", cpuPercent: 0, memoryBytes: 0, startTime: own)).get()
        }
        #expect(ProcessControl.end(ProcessTarget(name: "ftop", identity: ProcessIdentity(pid: me, startTime: own), kind: .process), force: true) == .protected)
        // launchd runs as root; its id is refused before anything is read.
        #expect(throws: ProcessRefusal.protected) { try ProcessControl.target(for: ProcessSample(pid: 1, name: "launchd", cpuPercent: 0, memoryBytes: 0)).get() }
        // A root process the user does not own: no start time is readable without admin rights.
        let root = try #require(rootProcess())
        #expect(throws: ProcessRefusal.otherUser) { try ProcessControl.target(for: ProcessSample(pid: root, name: "root", cpuPercent: 0, memoryBytes: 0)).get() }
    }

    /// WindowServer runs as its own user; the full process info is refused for it, so
    /// the refusal must come from the short form and say whose it is, not "exited".
    @Test func anotherUsersProcessIsNamedAsSuch() throws {
        let server = try #require(processes().first { name(of: $0) == "WindowServer" })
        let facts = try #require(ProcessControl.facts(of: server))
        #expect(facts.userID != getuid())
        #expect(throws: ProcessRefusal.otherUser) {
            try ProcessControl.target(for: ProcessSample(pid: server, name: "WindowServer", cpuPercent: 0, memoryBytes: 0)).get()
        }
    }

    func processes() -> [Int32] {
        var count = proc_listallpids(nil, 0)
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(count, 0))))
    }

    /// The short form of the process info: the name is readable for every user's process.
    func name(of pid: Int32) -> String {
        var info = proc_bsdshortinfo()
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0 else { return "" }
        return withUnsafeBytes(of: info.pbsi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Some process other than launchd that runs as root.
    func rootProcess() -> Int32? {
        processes().first { $0 > 1 && ProcessControl.facts(of: $0)?.userID == 0 }
    }
}
