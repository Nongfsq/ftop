import AppKit
import FtopCore
import FtopSensors
import FtopUI

/// End and Force End from the control block opened on a process row: what the block
/// shows, the confirmation, and the request. Nothing here runs between samples.
@MainActor
final class ProcessEnding {
    /// What the open block's actions act on; nil when it offers none.
    private var target: ProcessTarget?

    /// The block's process section for `sample`'s row, and the target its actions will use.
    func context(for sample: ProcessSample) -> ControlPanel.ProcessContext {
        switch ProcessControl.target(for: sample) {
        case .success(let found):
            target = found
            return ControlPanel.ProcessContext(name: found.name, pid: found.identity.pid)
        case .failure(let refusal):
            target = nil
            return ControlPanel.ProcessContext(name: sample.name, pid: sample.pid, refusal: Self.short(refusal, pid: sample.pid))
        }
    }

    /// The block opened somewhere else: no process.
    func clear() { target = nil }

    /// Asks first, with Cancel as the default, then checks the process once more and sends the request.
    func end(force: Bool) {
        guard let target else { return }
        self.target = nil
        let isApp = if case .app = target.kind { true } else { false }
        let action = force ? Strings.pick("Force End", "强制结束") : Strings.pick("End", "结束")
        let alert = NSAlert()
        alert.alertStyle = force ? .critical : .warning
        alert.messageText = Strings.pick("\(action) “\(target.name)”?", "\(action)“\(target.name)”？")
        let detail =
            switch (isApp, force) {
            case (true, false): Strings.pick("The app is asked to quit. It may ask to save changes, or decline.", "将请应用退出。应用可能会提示保存，也可能不退出。")
            case (true, true): Strings.pick("The app stops at once. Unsaved changes are lost.", "应用会立即停止，未保存的内容会丢失。")
            case (false, false): Strings.pick("The process is asked to stop (SIGTERM).", "将请进程停止（SIGTERM）。")
            case (false, true): Strings.pick("The process stops at once (SIGKILL). Unsaved work is lost.", "进程会立即停止（SIGKILL），未保存的内容会丢失。")
            }
        alert.informativeText = "PID \(target.identity.pid)\n" + detail
        // The first button is the default one, so Return cancels; Escape does too.
        alert.addButton(withTitle: Strings.pick("Cancel", "取消"))
        let confirm = alert.addButton(withTitle: action)
        confirm.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        guard let refusal = ProcessControl.end(target, force: force) else { return }
        let failure = NSAlert()
        failure.alertStyle = .warning
        failure.messageText = Strings.pick("“\(target.name)” was not ended", "未能结束“\(target.name)”")
        failure.informativeText = Self.long(refusal, force: force)
        failure.addButton(withTitle: Strings.pick("OK", "好"))
        failure.runModal()
    }

    /// In the block, beside the dimmed End.
    private static func short(_ refusal: ProcessRefusal, pid: Int32) -> String {
        switch refusal {
        case .protected:
            pid == ProcessInfo.processInfo.processIdentifier ? Strings.pick("ftop itself", "ftop 自身") : Strings.pick("System process", "系统进程")
        case .otherUser: Strings.pick("Another user's", "其他用户的进程")
        case .gone: Strings.pick("Has exited", "已退出")
        case .replaced: Strings.pick("No longer this process", "已不是这个进程")
        case .noMainProcess: Strings.pick("No main process", "没有主进程")
        case .failed: Strings.pick("Not available", "不可用")
        }
    }

    /// After confirmation, when the request was not sent or not taken.
    private static func long(_ refusal: ProcessRefusal, force: Bool) -> String {
        switch refusal {
        case .protected: Strings.pick("ftop does not end itself or the system's processes.", "ftop 不结束自身或系统进程。")
        case .otherUser: Strings.pick("It belongs to another user. ftop ends only your own processes.", "它属于其他用户。ftop 只结束你自己的进程。")
        case .gone: Strings.pick("It has already exited.", "它已经退出。")
        case .replaced:
            Strings.pick(
                "Its process ID now belongs to a different process, so nothing was sent. Right-click its row again.", "它的进程号已属于另一个进程，所以没有发送任何请求。请重新右键点按它的行。")
        case .noMainProcess: Strings.pick("Its processes have no one main process to ask.", "它的几个进程中没有可以请求的主进程。")
        case .failed:
            force
                ? Strings.pick("The system did not take the request.", "系统没有接受这个请求。")
                : Strings.pick("It did not take the request. Force End may work.", "它没有接受这个请求，可以试试强制结束。")
        }
    }
}
