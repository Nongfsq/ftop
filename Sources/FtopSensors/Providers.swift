import CFtopSys
import Darwin
import Foundation
import FtopCore

// Every provider keeps the previous counters it needs for deltas and returns a
// `Reading`: a value, or the reason it is unavailable. Nothing here throws.

final class CPUProvider {
    private var previousTicks: [[UInt32]] = []
    private var temperature: Reading<Temperature> = .unavailable("not read yet")
    private var temperatureAge = 0
    private let sampler = ftop_cpu_sampler_create()
    /// Cluster type letter per logical CPU from IODeviceTree, 0 where it has none.
    private let types: [UInt8]
    private let levels: [(name: String, count: Int)]
    private var identities: [CoreIdentity] = []

    init() {
        var buffer = [CChar](repeating: 0, count: 256)
        let count = Int(ftop_cpu_cluster_types(&buffer, Int32(buffer.count)))
        types = buffer.prefix(max(0, count)).map { UInt8(bitPattern: $0) }
        levels = Self.readLevels()
    }

    deinit { ftop_cpu_sampler_destroy(sampler) }

    /// `detail` false reads usage only, which is all the menu bar number needs.
    func sample(detail: Bool = true) -> Reading<CPUSample> {
        guard let ticks = Self.readTicks() else { return .unavailable("host_processor_info failed") }
        defer { previousTicks = ticks }
        let frequencies = detail ? readFrequencies() : ([:], "not read while the panel is hidden")
        guard previousTicks.count == ticks.count else { return .unavailable("waiting for a second sample") }
        if identities.count != ticks.count {
            // A CPU IODeviceTree does not list has no type; it is still shown.
            let padded = (0..<ticks.count).map { $0 < types.count ? types[$0] : 0 }
            identities = CoreTopology.classify(types: padded, levels: levels)
        }

        var cores: [CoreSample] = []
        var groupCounters: [CoreKind: Int] = [:]
        var typeCounters: [UInt8: Int] = [:]
        // Fastest cores first, each type in logical order.
        let order = ticks.indices.sorted { lhs, rhs in
            if identities[lhs].rank != identities[rhs].rank { return identities[lhs].rank < identities[rhs].rank }
            return lhs < rhs
        }
        for logical in order {
            let identity = identities[logical]
            let number = groupCounters[identity.kind, default: 0] + 1
            groupCounters[identity.kind] = number
            // IOReport names a core by its type letter; the nth channel of a type is its nth core.
            let position = typeCounters[identity.type, default: 0]
            typeCounters[identity.type] = position + 1
            let frequency: Reading<Double>
            var top: Double?
            let letter = String(UnicodeScalar(identity.type))
            if let failure = frequencies.failure {
                frequency = .unavailable(failure)
            } else if identity.type == 0 {
                frequency = .unavailable("IODeviceTree gives no cluster type for this core")
            } else if let list = frequencies.cores[identity.type], list.count == types.count(where: { $0 == identity.type }) {
                top = list[position].max_mhz > 0 ? list[position].max_mhz : nil
                frequency =
                    list[position].mhz > 0 ? .value(list[position].mhz) : .unavailable("no frequency table fits the states IOReport reports for \(letter) cores")
            } else {
                frequency = .unavailable(
                    "IOReport has \(frequencies.cores[identity.type]?.count ?? 0) \(letter)CPU channels for \(types.count(where: { $0 == identity.type })) \(letter) cores"
                )
            }
            cores.append(
                CoreSample(
                    id: logical, kind: identity.kind, tier: identity.tier, number: number,
                    usage: Metrics.usage(previous: previousTicks[logical], current: ticks[logical]) ?? 0,
                    frequencyMHz: frequency, maxFrequencyMHz: top))
        }
        // Temperature moves slowly; read it every fifth sample.
        if detail {
            if temperatureAge % 5 == 0 { temperature = Self.readTemperature() }
            temperatureAge += 1
        }
        return .value(CPUSample(cores: cores, temperature: temperature))
    }

    /// The raw residency states of the last sample, for `ftop doctor`.
    func describeStates() -> String {
        var buffer = [CChar](repeating: 0, count: 16384)
        ftop_cpu_sampler_describe(sampler, &buffer, Int32(buffer.count))
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// Channels by cluster type letter, each list in channel order.
    private func readFrequencies() -> (cores: [UInt8: [ftop_core_freq]], failure: String?) {
        var buffer = [ftop_core_freq](repeating: ftop_core_freq(), count: 128)
        let count = Int(ftop_cpu_sampler_update(sampler, &buffer, Int32(buffer.count)))
        guard count >= 0 else { return ([:], "IOReport returned no CPU sample") }
        return (Dictionary(grouping: buffer.prefix(count), by: { UInt8(bitPattern: $0.kind) }), nil)
    }

    /// The kernel's performance levels, fastest first.
    private static func readLevels() -> [(name: String, count: Int)] {
        var levelCount: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.nperflevels", &levelCount, &size, nil, 0) == 0 else { return [] }
        var levels: [(name: String, count: Int)] = []
        for level in 0..<Int(levelCount) {
            var cpus: Int32 = 0
            size = MemoryLayout<Int32>.size
            guard sysctlbyname("hw.perflevel\(level).logicalcpu", &cpus, &size, nil, 0) == 0 else { return [] }
            var name = [CChar](repeating: 0, count: 64)
            size = name.count - 1
            let named = sysctlbyname("hw.perflevel\(level).name", &name, &size, nil, 0) == 0
            levels.append((named ? name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : "", Int(cpus)))
        }
        return levels
    }

    private static func readTicks() -> [[UInt32]]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
            let info
        else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            // user, system, idle, nice
            (0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) }
        }
    }

    private static func readTemperature() -> Reading<Temperature> {
        var raw = ftop_temperature()
        guard ftop_read_temperature(&raw) == 0 else { return .unavailable("no CPU thermal sensor answered") }
        return .value(Temperature(celsius: raw.average, source: raw.source == 1 ? .cpuCluster : .chipDie, sensorCount: Int(raw.sensor_count)))
    }
}

struct MemoryProvider {
    func sample() -> Reading<MemorySample> {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return .unavailable("host_statistics64 failed") }

        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0 else { return .unavailable("hw.memsize failed") }

        let page = UInt64(sysconf(_SC_PAGESIZE))
        let compressed = UInt64(stats.compressor_page_count) * page
        // Activity Monitor: used = app memory (anonymous minus purgeable) + wired + compressed.
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count)) * page + compressed

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        let pressure: Reading<PressureLevel>
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0, let known = PressureLevel(rawValue: Int(level)) {
            pressure = .value(known)
        } else {
            pressure = .unavailable("kern.memorystatus_vm_pressure_level returned \(level)")
        }
        return .value(
            MemorySample(
                total: total, used: min(used, total), compressed: compressed,
                swapUsed: hasSwap ? swap.xsu_used : 0, swapTotal: hasSwap ? swap.xsu_total : 0, pressure: pressure))
    }
}

final class NetworkProvider {
    private var previous: (received: UInt64, sent: UInt64, time: TimeInterval)?
    /// Whether an interface index is a physical one. Looking a name up lists every
    /// interface, so each index is looked up once.
    private var physical: [UInt16: Bool] = [:]
    private var buffer: [UInt8] = []

    func sample(now: TimeInterval) -> Reading<NetworkSample> {
        guard let totals = readTotals() else { return .unavailable("interface statistics unavailable") }
        defer { previous = (totals.received, totals.sent, now) }
        guard let previous else { return .unavailable("waiting for a second sample") }
        let seconds = now - previous.time
        guard let down = Metrics.rate(previous: previous.received, current: totals.received, seconds: seconds),
            let up = Metrics.rate(previous: previous.sent, current: totals.sent, seconds: seconds)
        else {
            return .unavailable("counters reset")
        }
        return .value(NetworkSample(downBytesPerSecond: down, upBytesPerSecond: up))
    }

    /// 64-bit byte counters summed over physical interfaces (en*). Tunnels and bridges
    /// are skipped because their traffic is already counted on the interface carrying it.
    private func readTotals() -> (received: UInt64, sent: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        // Room for an interface appearing between the two calls.
        if buffer.count < length + 2048 { buffer = [UInt8](repeating: 0, count: length + 4096) }
        length = buffer.count
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var offset = 0
        var seen = 0
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let detail = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    seen += 1
                    if isPhysical(detail.ifm_index), detail.ifm_flags & IFF_LOOPBACK == 0 {
                        received += detail.ifm_data.ifi_ibytes
                        sent += detail.ifm_data.ifi_obytes
                    }
                }
                offset += messageLength
            }
        }
        // Interfaces came or went: indexes may now name something else.
        if seen != physical.count { physical = [:] }
        return (received, sent)
    }

    private func isPhysical(_ index: UInt16) -> Bool {
        if let known = physical[index] { return known }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        let answer = if_indextoname(UInt32(index), &name) != nil && name[0] == 101 && name[1] == 110  // "en"
        physical[index] = answer
        return answer
    }
}
