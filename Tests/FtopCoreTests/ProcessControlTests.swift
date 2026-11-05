import Testing

@testable import FtopCore

/// The rules End and Force End go by: the process must still be the one shown, the user's
/// own, and neither ftop, launchd, nor the kernel.
@Suite struct ProcessControlPolicyTests {
    let me: UInt32 = 501
    let ftop: Int32 = 4_000
    let shown = ProcessIdentity(pid: 812, startTime: 9_000_000)

    func refusal(_ identity: ProcessIdentity, _ facts: ProcessFacts?) -> ProcessRefusal? {
        ProcessControlPolicy.refusal(for: identity, facts: facts, selfPID: ftop, userID: me)
    }

    @Test func theProcessShownMayBeEnded() {
        #expect(refusal(shown, ProcessFacts(pid: 812, startTime: 9_000_000, userID: me)) == nil)
    }

    /// The process exited and another program took its id: never signalled.
    @Test func aReusedProcessIDIsRefused() {
        #expect(refusal(shown, ProcessFacts(pid: 812, startTime: 9_500_000, userID: me)) == .replaced)
        // Also when the newcomer is another user's: it is not the process shown either way.
        #expect(refusal(shown, ProcessFacts(pid: 812, startTime: 9_500_000, userID: 0)) == .replaced)
    }

    @Test func anExitedProcessIsRefused() {
        #expect(refusal(shown, nil) == .gone)
        #expect(refusal(shown, ProcessFacts(pid: 813, startTime: 9_000_000, userID: me)) == .gone)
    }

    /// The kernel, launchd, and any id at or below 1 (a negative one names a process group).
    @Test func theSystemsOwnProcessesAreProtected() {
        for pid: Int32 in [1, 0, -1, -812] {
            let identity = ProcessIdentity(pid: pid, startTime: 1)
            #expect(refusal(identity, ProcessFacts(pid: pid, startTime: 1, userID: me)) == .protected)
        }
    }

    @Test func ftopItselfIsProtected() {
        let identity = ProcessIdentity(pid: ftop, startTime: 1)
        #expect(refusal(identity, ProcessFacts(pid: ftop, startTime: 1, userID: me)) == .protected)
    }

    @Test func anotherUsersProcessIsRefused() {
        #expect(refusal(shown, ProcessFacts(pid: 812, startTime: 9_000_000, userID: 0)) == .otherUser)
        // Without admin rights its start time cannot be read.
        #expect(refusal(shown, ProcessFacts(pid: 812, startTime: nil, userID: 0)) == .otherUser)
    }

    /// Its own process whose start cannot be read cannot be told from a later one.
    @Test func anUnreadableStartIsRefused() {
        #expect(refusal(shown, ProcessFacts(pid: 812, startTime: nil, userID: me)) == .gone)
    }

    /// An app's entry names its representative process, and keeps that process's start time.
    @Test func foldingKeepsTheRepresentativesStartTime() {
        let path = "/Applications/Example.app"
        let list = [
            ProcessSample(pid: 20, name: "Example Helper", cpuPercent: 5, memoryBytes: 10, appPath: path, startTime: 200),
            ProcessSample(pid: 10, name: "Example", cpuPercent: 30, memoryBytes: 10, appPath: path, startTime: 100),
            ProcessSample(pid: 30, name: "tool", cpuPercent: 1, memoryBytes: 10, startTime: 300),
        ]
        let folded = ProcessSample.folded(list, by: .cpu)
        #expect(folded[0].identity == ProcessIdentity(pid: 10, startTime: 100))
        #expect(folded[1].identity == ProcessIdentity(pid: 30, startTime: 300))
        #expect(ProcessSample(pid: 40, name: "unread", cpuPercent: 0, memoryBytes: 0).identity == nil)
    }
}
