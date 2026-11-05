/// One run of a program: its process id and when it started. A process id is reused
/// once its process exits, so the id alone can name a different program later.
public struct ProcessIdentity: Sendable, Codable, Equatable, Hashable {
    public var pid: Int32
    /// In the system's absolute time units (`ri_proc_start_abstime`).
    public var startTime: UInt64

    public init(pid: Int32, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }
}

/// What the system says about a process id right now.
public struct ProcessFacts: Sendable, Equatable {
    public var pid: Int32
    /// Nil where the system does not tell: another user's process, without admin rights.
    public var startTime: UInt64?
    /// The real user the process runs as.
    public var userID: UInt32

    public init(pid: Int32, startTime: UInt64?, userID: UInt32) {
        self.pid = pid
        self.startTime = startTime
        self.userID = userID
    }
}

/// Why ftop will not end a process.
public enum ProcessRefusal: Error, Sendable, Equatable {
    /// The kernel's own processes, launchd, and ftop itself.
    case protected
    /// Another user's process; ftop ends only the user's own, without admin rights.
    case otherUser
    /// The process has exited.
    case gone
    /// The process id now names a different process than the one shown.
    case replaced
    /// An app entry whose processes have no one main process to ask.
    case noMainProcess
    /// The system did not take the request.
    case failed
}

/// The rules that decide whether a process may be ended. They hold no system calls, so
/// they can be tested; `FtopSensors` reads the facts and sends the signal.
public enum ProcessControlPolicy {
    /// Nil when `identity` may be ended: it is still the process that was shown, it runs
    /// as `userID`, and it is neither ftop (`selfPID`) nor launchd nor the kernel.
    /// `facts` is what the system reports for `identity.pid` now, nil when it has exited.
    public static func refusal(for identity: ProcessIdentity, facts: ProcessFacts?, selfPID: Int32, userID: UInt32) -> ProcessRefusal? {
        // 0 is the kernel, 1 launchd; a negative id would signal a whole process group.
        guard identity.pid > 1, identity.pid != selfPID else { return .protected }
        guard let facts, facts.pid == identity.pid else { return .gone }
        if let start = facts.startTime, start != identity.startTime { return .replaced }
        guard facts.userID == userID else { return .otherUser }
        // Its own process whose start cannot be read: it cannot be told from a later one.
        guard facts.startTime != nil else { return .gone }
        return nil
    }
}

/// The process an End or Force End is sent to, found when the control block opens.
public struct ProcessTarget: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// An app's main process, asked to quit as the Dock asks it: it may ask to save, or refuse.
        case app(bundlePath: String)
        /// A process outside any running app, sent SIGTERM or SIGKILL.
        case process
    }

    public var name: String
    public var identity: ProcessIdentity
    public var kind: Kind

    public init(name: String, identity: ProcessIdentity, kind: Kind) {
        self.name = name
        self.identity = identity
        self.kind = kind
    }
}
