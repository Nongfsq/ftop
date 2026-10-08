import Foundation
import FtopCore

/// Produces a `Snapshot` on a timer. All providers live on one serial queue; the
/// first snapshot has no rates yet because rates need two readings.
public final class SystemSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.ftop.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let cpu = CPUProvider()
    private let memory = MemoryProvider()
    private let network = NetworkProvider()
    private let processes = ProcessProvider()
    private let gpu = GPUProvider()
    private let power = PowerProvider()
    private var modules: Set<ModuleID> = Set(ModuleID.allCases)
    private var usageOnly = false
    private var tick = 0
    private var lastProcesses: Reading<ProcessList> = .unavailable("waiting for a second sample")

    public init() {}

    /// Takes one snapshot on the calling thread. Used by the CLI.
    public func sampleNow() -> Snapshot {
        queue.sync { collect() }
    }

    /// What decides the CPU's and the GPU's frequencies on this Mac, for `ftop doctor --states`.
    public func describeStates() -> String {
        queue.sync { cpu.describeStates() + gpu.describeStates() }
    }

    /// Starts or restarts periodic sampling. `handler` runs on the sampler's queue.
    /// `usageOnly` leaves out the processor's frequencies and temperature, for when only the menu bar item shows.
    public func start(interval: Double, modules: [ModuleID], usageOnly: Bool = false, handler: @escaping @Sendable (Snapshot) -> Void) {
        queue.async {
            self.timer?.cancel()
            self.modules = Set(modules)
            self.usageOnly = usageOnly
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            // Leeway lets the system coalesce wakeups; a late tick is skipped, not queued.
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
            timer.setEventHandler { [self] in
                handler(self.collect())
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func collect() -> Snapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let off = "module is turned off"
        // Listing every process is the costliest reading; do it every other tick. A two-tick
        // window also steadies the per-process CPU figures.
        if modules.contains(.processes), tick % 2 == 0 || lastProcesses.value == nil { lastProcesses = processes.sample(now: now) }
        tick += 1
        return Snapshot(
            time: Date(),
            cpu: modules.contains(.cpu) ? cpu.sample(detail: !usageOnly) : .unavailable(off),
            memory: modules.contains(.memory) ? memory.sample() : .unavailable(off),
            network: modules.contains(.network) ? network.sample(now: now) : .unavailable(off),
            processes: modules.contains(.processes) ? lastProcesses : .unavailable(off),
            gpu: modules.contains(.gpu) ? gpu.sample() : .unavailable(off),
            power: modules.contains(.power) ? power.sample(gpuWatts: gpu.watts(now: now)) : .unavailable(off)
        )
    }
}
