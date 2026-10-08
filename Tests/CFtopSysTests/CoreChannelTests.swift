import CFtopSys
import Testing

/// Only the naming of IOReport's core channels is tested here: it needs no hardware.
@Suite struct CoreChannelTests {
    private static func parse(_ name: String) -> (kind: Character, index: Int)? {
        var kind: CChar = 0
        var index: Int32 = -1
        guard ftop_core_channel_parse(name, &kind, &index) != 0 else { return nil }
        return (Character(UnicodeScalar(UInt8(bitPattern: kind))), Int(index))
    }

    private static func sorted(_ names: [String]) -> [String] {
        names.sorted { ftop_core_channel_compare($0, $1) < 0 }
    }

    /// The channels of the M6 Mac mini of issue 8: 2 super, 4 performance, 6 efficiency cores.
    private static let m6 = [
        "EACC_ECPU0", "EACC_ECPU1", "EACC_ECPU2", "EACC_ECPU3", "EACC_ECPU4", "EACC_ECPU5",
        "PACC0_PCPU0", "PACC0_PCPU1", "PACC0_MCPU2", "PACC0_MCPU3", "PACC0_MCPU4", "PACC0_MCPU5",
    ]

    @Test func channelsWithAClusterPrefixAreCores() throws {
        for (position, name) in Self.m6.enumerated() {
            let core = try #require(Self.parse(name), "\(name)")
            #expect(core.kind == (position < 6 ? "E" : position < 8 ? "P" : "M"), "\(name)")
            // The M cores go on counting where the P cores of their cluster stopped.
            #expect(core.index == (position < 6 ? position : position - 6), "\(name)")
        }
    }

    @Test func channelsWithoutAPrefixAreCoresAsBefore() throws {
        let p = try #require(Self.parse("PCPU000"))
        #expect(p.kind == "P" && p.index == 0)
        let e = try #require(Self.parse("ECPU030"))
        #expect(e.kind == "E" && e.index == 30)
        let last = try #require(Self.parse("PCPU140"))
        #expect(last.kind == "P" && last.index == 140)
        #expect(Self.parse("MCPU7")?.kind == "M")
    }

    @Test(arguments: [
        "", "_", "CPU0", "PCPU", "PCPUx", "PCPU0x", "PCPU-1", "pCPU0", "1CPU0", "PCPU0000000", "PCPU 0", "PGPU0",
        "GPUPH", "ECPM", "PACC0_", "PACC0_PCPU", "PACC0_CPU0", "EACC_CPM", "PCPU0_EACC", "PACC0_PCPU0_", "ECPU0 residency",
    ])
    func otherNamesAreNotCores(name: String) {
        #expect(Self.parse(name) == nil)
    }

    @Test func eachKindKeepsItsChannelsInCoreOrder() {
        // The provider takes the nth channel of a kind for its nth core, whatever the numbers are.
        let order = Self.sorted(Self.m6.shuffled())
        #expect(order.filter { $0.contains("_E") } == Array(Self.m6[0..<6]))
        #expect(order.filter { $0.contains("_P") } == ["PACC0_PCPU0", "PACC0_PCPU1"])
        #expect(order.filter { $0.contains("_M") } == ["PACC0_MCPU2", "PACC0_MCPU3", "PACC0_MCPU4", "PACC0_MCPU5"])
    }

    @Test func numbersWithoutLeadingZerosOrderAsNumbers() {
        let names = (0..<12).map { "EACC_ECPU\($0)" }
        #expect(Self.sorted(names.shuffled()) == names)
        #expect(Self.sorted(["PACC1_PCPU0", "PACC0_PCPU10", "PACC0_PCPU9"]) == ["PACC0_PCPU9", "PACC0_PCPU10", "PACC1_PCPU0"])
    }

    @Test func channelsWithoutAPrefixOrderAsBefore() {
        // An M4 Pro's channels; before, the order was the plain order of the names.
        let names = ["ECPU000", "ECPU010", "ECPU020", "ECPU030"] + (0..<2).flatMap { cluster in (0..<5).map { "PCPU\(cluster)\($0)0" } }
        #expect(Self.sorted(names.shuffled()) == names.sorted())
    }
}
