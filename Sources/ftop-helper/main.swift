import Darwin

// Reports the processes that used the most CPU since the previous request, and the
// ones holding the most memory.
//
// Protocol (version 3): for each line read on stdin, write a header line
// "ftop-helper 3 <nanoseconds since the previous request>", then one line per process
// ("pid cpu_nanoseconds_used footprint_bytes name"), busiest first, then a line
// "memory" and the same kind of lines ordered by memory, then an empty line.
// The first request has nothing to compare with and lists no processes.
//
// Run unprivileged it sees the caller's own processes; installed setuid root by
// `sudo ftop grant` it sees all of them. It takes no arguments, reads no environment,
// and writes no files, so the privileged surface is this file alone.

let rowLimit = 32

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
setvbuf(stdout, nil, _IOFBF, 1 << 14)

let numer = UInt64(timebase.numer)
let denom = UInt64(timebase.denom)
let nanoseconds: (UInt64) -> UInt64 = { ticks in
    ticks / denom * numer + (ticks % denom) * numer / denom
}

struct Usage {
    var start: UInt64
    var ticks: UInt64
}

struct Row {
    var pid: pid_t
    var used: UInt64
    var footprint: UInt64
}

var pids = [pid_t](repeating: 0, count: 8192)
var name = [CChar](repeating: 0, count: 64)
var previous: [pid_t: Usage] = [:]
var previousTime: UInt64 = 0

while let _ = readLine(strippingNewline: true) {
    let now = mach_absolute_time()
    let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    let count = max(0, min(Int(bytes), pids.count))
    var current: [pid_t: Usage] = [:]
    current.reserveCapacity(count)
    var rows: [Row] = []
    rows.reserveCapacity(count)
    for pid in pids.prefix(count) where pid > 0 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { continue }
        let ticks = info.ri_user_time &+ info.ri_system_time
        // A process id can be reused; the start time tells the two processes apart.
        if let before = previous[pid], before.start == info.ri_proc_start_abstime, ticks >= before.ticks {
            rows.append(Row(pid: pid, used: ticks - before.ticks, footprint: info.ri_phys_footprint))
        }
        current[pid] = Usage(start: info.ri_proc_start_abstime, ticks: ticks)
    }
    func write(_ list: ArraySlice<Row>) {
        for row in list {
            name[0] = 0
            proc_name(row.pid, &name, UInt32(name.count))
            print(row.pid, nanoseconds(row.used), row.footprint, name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
    }
    print("ftop-helper 3", previousTime == 0 ? 0 : nanoseconds(now - previousTime))
    rows.sort { $0.used != $1.used ? $0.used > $1.used : $0.footprint > $1.footprint }
    write(rows.prefix(rowLimit))
    print("memory")
    rows.sort { $0.footprint > $1.footprint }
    write(rows.prefix(rowLimit))
    print("")
    fflush(stdout)
    previous = current
    previousTime = now
}
