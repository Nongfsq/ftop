import CFtopSys
import Testing

/// How the GPU's states are matched to its frequency table: arithmetic only, it needs no hardware.
@Suite struct GPUFrequencyTests {
    private struct Result {
        var mhz: Double?
        var top: Double?
        var steps: Int
        var uncovered: String?
    }

    private static func frequency(_ states: [(name: String, residency: Int64)], table: [Double]) -> Result {
        var out = ftop_gpu_freq()
        ftop_gpu_frequency(states.map(\.residency), states.map { UInt8(ftop_state_is_idle($0.name)) }, Int32(states.count), table, Int32(table.count), &out)
        return Result(
            mhz: out.mhz > 0 ? out.mhz : nil, top: out.max_mhz > 0 ? out.max_mhz : nil, steps: Int(out.steps),
            uncovered: out.uncovered_state >= 0 ? states[Int(out.uncovered_state)].name : nil)
    }

    private static func states(_ residencies: [Int64]) -> [(name: String, residency: Int64)] {
        residencies.enumerated().map { (name: $0.offset == 0 ? "OFF" : "P\($0.offset)", residency: $0.element) }
    }

    /// The table of the M6 Mac mini of issue 8: 13 values. The report shows the first three and the
    /// last (502, 669, 834, 1735 MHz); the nine between are placeholders that only keep the order.
    private static let m6Table: [Double] = [502, 669, 834, 920, 1010, 1100, 1190, 1280, 1370, 1460, 1550, 1640, 1735]

    /// GPUPH on that Mac, OFF then P1 to P15, from the reporter's two runs of `ftop doctor --states`.
    private static let m6Idle = states([14_985_837, 10_269_255] + Array(repeating: 0, count: 14))
    private static let m6Loaded = states([88435, 2963, 0, 0, 0, 0, 0, 994_145, 904_902, 850_389, 494_715, 300_414, 224_682, 21_076_909, 0, 0])

    @Test func anIdleM6RunsAtTheFirstValue() {
        let result = Self.frequency(Self.m6Idle, table: Self.m6Table)
        #expect(result.mhz == 502)
        #expect(result.top == 1735)
        #expect(result.steps == 15)
        #expect(result.uncovered == nil)
    }

    @Test func aLoadedM6RunsNearTheTopOfTheTable() throws {
        let result = Self.frequency(Self.m6Loaded, table: Self.m6Table)
        let mhz = try #require(result.mhz)
        var weighted = 0.0
        var active = 0.0
        for (state, value) in zip(Self.m6Loaded.dropFirst(), Self.m6Table) {
            weighted += Double(state.residency) * value
            active += Double(state.residency)
        }
        #expect(abs(mhz - weighted / active) < 0.001)
        // 85% of the active time is in P13; whatever the values between, that alone puts it above this.
        #expect(mhz > 1548 && mhz <= 1735)
        #expect(result.top == 1735)
        #expect(result.uncovered == nil)
    }

    @Test func aStateBeyondTheTableThatRanLeavesNoFrequency() {
        var states = Self.m6Loaded
        states[14].residency = 1
        let result = Self.frequency(states, table: Self.m6Table)
        #expect(result.mhz == nil)
        #expect(result.top == nil)
        #expect(result.uncovered == "P14")

        // The first of them is the one named.
        states[14].residency = 0
        states[15].residency = 40
        #expect(Self.frequency(states, table: Self.m6Table).uncovered == "P15")
        states[14].residency = 40
        #expect(Self.frequency(states, table: Self.m6Table).uncovered == "P14")
    }

    @Test func matchingCountsReadAsBefore() {
        // An M4 Pro's shape: as many active states as table values.
        let table: [Double] = [338, 618, 796, 924, 952, 1056, 1062, 1182, 1182, 1312, 1242, 1380, 1326, 1470, 1578]
        var residencies = [Int64](repeating: 0, count: 16)
        residencies[0] = 700
        residencies[1] = 100
        residencies[15] = 300
        let result = Self.frequency(Self.states(residencies), table: table)
        // (100 × 338 + 300 × 1578) / 400
        #expect(result.mhz == 1268)
        #expect(result.top == 1578)
        #expect(result.uncovered == nil)
    }

    @Test func aTableLongerThanTheStatesUsesItsFirstRun() {
        // The node may list the steps once per power domain; the first run is the table.
        let result = Self.frequency(Self.states([0, 10, 30]), table: [400, 800, 400, 800])
        #expect(result.mhz == 700)
        #expect(result.top == 800)
    }

    @Test func nothingIsKnownWithoutATableOrActiveTime() {
        let none = Self.frequency(Self.m6Loaded, table: [])
        #expect(none.mhz == nil && none.top == nil && none.uncovered == nil)

        // Powered down for the whole interval: the top is known, the frequency is not.
        let off = Self.frequency(Self.states([500] + Array(repeating: 0, count: 15)), table: Self.m6Table)
        #expect(off.mhz == nil && off.top == 1735 && off.uncovered == nil)

        let stateless = Self.frequency([(name: "OFF", residency: 9)], table: Self.m6Table)
        #expect(stateless.mhz == nil && stateless.top == nil && stateless.steps == 0)
    }

    @Test func theNodeSaysHowLongItsTableIs() {
        // An M4 Pro: 16 states declared, 30 values listed (two power domains of 15).
        #expect(ftop_gpu_table_length(30, 16) == 15)
        // The M6 of issue 8: 14 states declared, 13 values listed.
        #expect(ftop_gpu_table_length(13, 14) == 13)
        // No count, or one that does not fit the values: every value is kept, as before.
        #expect(ftop_gpu_table_length(13, -1) == 13)
        #expect(ftop_gpu_table_length(13, 5) == 13)
        #expect(ftop_gpu_table_length(13, 20) == 13)
        #expect(ftop_gpu_table_length(13, 1) == 13)
        #expect(ftop_gpu_table_length(0, 14) == 0)
    }

    @Test(arguments: ["OFF", "IDLE", "DOWN"]) func idleNames(name: String) {
        #expect(ftop_state_is_idle(name) != 0)
        #expect(ftop_state_is_idle("P1") == 0)
    }
}
