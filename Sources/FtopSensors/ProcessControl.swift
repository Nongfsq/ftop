import AppKit
import Darwin
import FtopCore

/// Ends the user's own processes, without admin rights. The setuid helper only reads;
/// nothing here goes through it. The rules are `ProcessControlPolicy`; this reads the
/// facts they need and sends the request.
public enum ProcessControl {
    /// When `pid` started, or nil when the system does not tell (another user's process).
    static func startTime(of pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info.ri_proc_start_abstime : nil
    }

    /// What the system says about `pid` now; nil when no such process runs.
    public static func facts(of pid: Int32) -> ProcessFacts? {
        guard pid > 0 else { return nil }
        // The short form: the full one is refused for another user's process.
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        // A process whose real and effective users differ (a setuid program) is another
        // user's when either is.
        let user = info.pbsi_uid != getuid() ? info.pbsi_uid : info.pbsi_ruid
        return ProcessFacts(pid: pid, startTime: startTime(of: pid), userID: user)
    }

    static func refusal(for identity: ProcessIdentity) -> ProcessRefusal? {
        ProcessControlPolicy.refusal(for: identity, facts: facts(of: identity.pid), selfPID: getpid(), userID: getuid())
    }

    /// What End and Force End on `sample`'s row would act on, checked against the
    /// process that was sampled. An app's row acts on the app's main process, not on
    /// the helper that happened to be its busiest.
    @MainActor public static func target(for sample: ProcessSample) -> Result<ProcessTarget, ProcessRefusal> {
        guard let shown = sample.identity else {
            // No start time was readable when sampled.
            if sample.pid <= 1 || sample.pid == getpid() { return .failure(.protected) }
            if let facts = facts(of: sample.pid), facts.userID != getuid() { return .failure(.otherUser) }
            return .failure(.gone)
        }
        if let refusal = refusal(for: shown) { return .failure(refusal) }
        guard let bundle = sample.appPath else { return .success(ProcessTarget(name: sample.name, identity: shown, kind: .process)) }
        if let app = runningApp(at: bundle) {
            guard let start = startTime(of: app.processIdentifier) else { return .failure(.gone) }
            let main = ProcessIdentity(pid: app.processIdentifier, startTime: start)
            if let refusal = refusal(for: main) { return .failure(refusal) }
            return .success(ProcessTarget(name: app.localizedName ?? sample.name, identity: main, kind: .app(bundlePath: bundle)))
        }
        // No app the system knows runs from there: one process is ended as a process;
        // several have no one process to ask.
        guard sample.members.isEmpty else { return .failure(.noMainProcess) }
        return .success(ProcessTarget(name: sample.name, identity: shown, kind: .process))
    }

    /// Sends End (`force` false) or Force End, after checking once more that the target
    /// is still the process the block named. Nil when the request was taken; an app asked
    /// to quit may still ask to save, or decline.
    @MainActor public static func end(_ target: ProcessTarget, force: Bool) -> ProcessRefusal? {
        if let refusal = refusal(for: target.identity) { return refusal }
        let pid = target.identity.pid
        switch target.kind {
        case .app(let bundle):
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, appPath(of: pid) == bundle else { return .replaced }
            return (force ? app.forceTerminate() : app.terminate()) ? nil : .failed
        case .process:
            guard kill(pid, force ? SIGKILL : SIGTERM) == 0 else {
                switch errno {
                case ESRCH: return .gone
                case EPERM: return .otherUser
                default: return .failed
                }
            }
            return nil
        }
    }

    /// The running app whose bundle is `bundle`. Matched by where its process runs from,
    /// the way the list found the bundle, and not by the app's own URL, which can name a
    /// link to the place the system keeps it. A helper app nested in the bundle is not it.
    @MainActor private static func runningApp(at bundle: String) -> NSRunningApplication? {
        let name = URL(fileURLWithPath: bundle).lastPathComponent
        return NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.bundleURL?.lastPathComponent == name && appPath(of: $0.processIdentifier) == bundle
        }
    }

    /// The outermost app bundle `pid` runs from.
    static func appPath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return ProcessSample.appPath(ofExecutable: buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }
}
