import Foundation
import Testing

@testable import FtopCore

@Suite struct MetricsTests {
    @Test func usageIsBusyShareOfTheInterval() {
        // user, system, idle, nice
        #expect(Metrics.usage(previous: [100, 50, 800, 0], current: [130, 60, 860, 0]) == 0.4)
    }

    @Test func usageSurvivesCounterWrap() {
        let previous: [UInt32] = [UInt32.max - 9, 0, 0, 0]
        let current: [UInt32] = [20, 0, 70, 0]
        #expect(Metrics.usage(previous: previous, current: current) == 0.3)
    }

    @Test func usageIsUnknownWhenNoTimePassed() {
        #expect(Metrics.usage(previous: [1, 2, 3, 4], current: [1, 2, 3, 4]) == nil)
    }

    @Test func rateIsUnknownAfterCounterReset() {
        #expect(Metrics.rate(previous: 5_000, current: 100, seconds: 1) == nil)
        #expect(Metrics.rate(previous: 1_000, current: 3_000, seconds: 2) == 1_000)
    }

    @Test func cpuPercentCountsCores() {
        // 2.5 s of CPU time in one second is two and a half cores.
        #expect(Metrics.cpuPercent(previousNanoseconds: 0, currentNanoseconds: 2_500_000_000, seconds: 1) == 250)
    }
}

@Suite struct FormatTests {
    @Test func ratesSwitchUnits() {
        #expect(Format.rate(180_000).text == "180 KB/s")
        #expect(Format.rate(2_400_000).text == "2.4 MB/s")
        #expect(Format.rate(2_400_000).shortText == "2.4M")
        #expect(Format.rate(999_600).text == "1.0 MB/s")
        #expect(Format.rate(-5).text == "0 KB/s")
    }

    @Test func memoryUsesBinaryGigabytes() {
        #expect(Format.gigabytes(36 * 1_073_741_824) == "36.0")
        #expect(Format.gigabytesCompact(36 * 1_073_741_824) == "36")
        #expect(Format.processMemory(512 * 1_048_576) == "512M")
        #expect(Format.processMemory(4_402_341_478) == "4.1G")
    }

    @Test func frequencyAndTemperature() {
        #expect(Format.gigahertz(2870) == "2.87")
        #expect(Format.degrees(57.6) == "58°")
        #expect(Format.percent(0.416) == "42")
    }
}

@Suite struct ConfigTests {
    @Test func emptyFileGivesDefaults() throws {
        #expect(try Config.decode(Data("{}".utf8)) == Config())
    }

    @Test func templateDecodesToDefaults() throws {
        #expect(try Config.decode(Data(Config.template.utf8)) == Config())
    }

    @Test func outOfRangeValuesAreClamped() throws {
        let config = try Config.decode(Data(#"{ interval: 0.01, maxProcesses: 99, modules: ["cpu", "cpu"], palette: "warm" }"#.utf8))
        #expect(config.interval == 0.5)
        #expect(config.maxProcesses == 24)
        #expect(config.modules == [.cpu])
        #expect(config.palette == .warm)
    }

    @Test func unknownPaletteIsAnError() {
        #expect(throws: (any Error).self) { try Config.decode(Data(#"{ palette: "neon" }"#.utf8)) }
    }
}

@Suite struct ReadingTests {
    @Test func snapshotRoundTripsThroughJSON() throws {
        var snapshot = Snapshot.sample()
        snapshot.network = .unavailable("waiting for a second sample")
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(Snapshot.self, from: data) == snapshot)
    }

    @Test func frequencyFractionNeedsBothValues() {
        var core = CoreSample(id: 0, kind: .performance, number: 1, usage: 0.5, frequencyMHz: .value(2200), maxFrequencyMHz: 4400)
        #expect(core.frequencyFraction == 0.5)
        core.frequencyMHz = .unavailable("no table")
        #expect(core.frequencyFraction == nil)
    }
}

@Suite struct CoreTopologyTests {
    private static func types(_ text: String) -> [UInt8] { text.utf8.map { $0 == 46 ? 0 : $0 } }  // "." is a CPU without a type

    @Test func performanceAndEfficiencyCores() {
        // M4 Pro: efficiency cores have the low logical ids.
        let cores = CoreTopology.classify(types: Self.types("EEEEPPPPPPPPPP"), levels: [("Performance", 10), ("Efficiency", 4)])
        #expect(cores.prefix(4).allSatisfy { $0.kind == .efficiency && $0.tier == .efficiency && $0.rank == 1 })
        #expect(cores.dropFirst(4).allSatisfy { $0.kind == .performance && $0.tier == .performance && $0.rank == 0 })
    }

    @Test func superAndPerformanceCoresOfAnM5Pro() {
        // Ten 'M' cores the kernel calls "Performance" under five 'P' cores it calls "Super".
        let cores = CoreTopology.classify(types: Self.types("MMMMMMMMMMPPPPP"), levels: [("Super", 5), ("Performance", 10)])
        #expect(cores.prefix(10).allSatisfy { $0.kind == .efficiency && $0.tier == .performance })
        #expect(cores.suffix(5).allSatisfy { $0.kind == .performance && $0.tier == .superCore })
    }

    @Test func equalCountsFallBackToTheLetterOrder() {
        let cores = CoreTopology.classify(types: Self.types("EEEEPPPP"), levels: [("Super", 4), ("Efficiency", 4)])
        #expect(cores.first?.tier == .efficiency)
        #expect(cores.last?.kind == .performance)
        #expect(cores.last?.tier == .superCore)
    }

    @Test func aTypeNoLevelExplainsIsShownButNotNamed() {
        // Three types, two levels: nothing says what 'M' is called.
        let cores = CoreTopology.classify(types: Self.types("EEMMPP"), levels: [("Performance", 4), ("Efficiency", 2)])
        #expect(cores.map(\.rank) == [2, 2, 1, 1, 0, 0])
        #expect(cores.map(\.tier) == [.efficiency, .efficiency, .unknown, .unknown, .performance, .performance])
        #expect(cores.map(\.kind) == [.efficiency, .efficiency, .efficiency, .efficiency, .performance, .performance])
    }

    @Test func aLetterNeverSeenBeforeIsPlacedByItsCoreCount() {
        let cores = CoreTopology.classify(types: Self.types("XXXXXXPP"), levels: [("Performance", 6), ("Efficiency", 2)])
        #expect(cores.first?.kind == .performance)
        #expect(cores.first?.tier == .performance)
        #expect(cores.last?.tier == .efficiency)
    }

    @Test func coresWithoutATypeAreStillCores() {
        let none = CoreTopology.classify(types: Self.types("........"), levels: [("Performance", 8)])
        #expect(none.count == 8)
        #expect(none.allSatisfy { $0.kind == .performance && $0.tier == .unknown })

        let some = CoreTopology.classify(types: Self.types("PP.."), levels: [])
        #expect(some.map(\.kind) == [.performance, .performance, .efficiency, .efficiency])
        #expect(some.map(\.tier) == [.performance, .performance, .unknown, .unknown])
    }
}

@Suite struct UpdateTests {
    private static func feed(tag: String = "v0.2.0", name: String = "Ftop-0.2.0-arm64.zip", host: String = "github.com/Nongfsq/ftop", prerelease: Bool = false) -> Data {
        Data(
            """
            {"tag_name": "\(tag)", "draft": false, "prerelease": \(prerelease), "assets": [
              {"name": "notes.txt", "browser_download_url": "https://\(host)/releases/download/\(tag)/notes.txt"},
              {"name": "\(name)", "browser_download_url": "https://\(host)/releases/download/\(tag)/\(name)",
               "digest": "sha256:\(String(repeating: "ab", count: 32))"}]}
            """.utf8)
    }

    @Test func versionsCompareByNumber() throws {
        let old = try #require(AppVersion("0.1.9"))
        let new = try #require(AppVersion("v0.1.10"))
        #expect(old < new)
        #expect(AppVersion("0.2") == AppVersion("0.2.0"))
        #expect(new.description == "0.1.10")
        #expect(try #require(AppVersion("1")) > new)
    }

    @Test func versionsThatAreNotNumbersAreRejected() {
        for text in ["", "v", "1..2", "1.2-beta", "1.x", "../1", "1.2.3.4.5", "１.2"] { #expect(AppVersion(text) == nil) }
    }

    @Test func releaseIsReadFromTheFeed() throws {
        let release = try #require(UpdateFeed.release(from: Self.feed()))
        #expect(release.version == AppVersion("0.2.0"))
        #expect(release.archive.absoluteString == "https://github.com/Nongfsq/ftop/releases/download/v0.2.0/Ftop-0.2.0-arm64.zip")
        #expect(release.sha256 == String(repeating: "ab", count: 32))
    }

    @Test func releasesThatCannotBeTrustedAreIgnored() {
        #expect(UpdateFeed.release(from: Self.feed(host: "example.com/Nongfsq/ftop")) == nil)  // archive from elsewhere
        #expect(UpdateFeed.release(from: Self.feed(name: "Ftop-0.3.0-arm64.zip")) == nil)  // archive of another version
        #expect(UpdateFeed.release(from: Self.feed(tag: "nightly")) == nil)
        #expect(UpdateFeed.release(from: Self.feed(prerelease: true)) == nil)
        #expect(UpdateFeed.release(from: Data("{}".utf8)) == nil)
        #expect(UpdateFeed.release(from: Data("not json".utf8)) == nil)
    }

    @Test func updatesSettingIsReadFromTheFile() throws {
        #expect(try Config.decode(Data("{}".utf8)).updates == .install)
        #expect(try Config.decode(Data("{updates: \"off\"}".utf8)).updates == .off)
        #expect(try Config.decode(Data(Config.template.utf8)) == Config())
    }
}

@Suite struct LayoutLadderTests {
    /// A stand-in for measured sizes: richer layouts need more room.
    static func measure(_ candidate: LayoutCandidate) -> Extent {
        switch candidate.tier {
        case .micro: return Extent(width: 50, height: 20)
        case .strip:
            switch candidate.strip {
            case .vertical: return Extent(width: 50, height: 140)
            case .rich: return Extent(width: 420, height: 24)
            default: return Extent(width: 230, height: 24)
            }
        case .corner: return Extent(width: 150, height: 120)
        default:
            let detail: Double = candidate.tier == .detailed ? 120 : 0
            let width = (220 + detail) / Double(candidate.columns) * (1 + 0.6 * Double(candidate.columns - 1))
            let rows = Double(candidate.processCount) * 20
            let height = candidate.columns == 1 ? 230 + rows : max(150, 60 + rows)
            return Extent(width: width, height: height)
        }
    }

    static func choose(_ width: Double, _ height: Double, maxProcesses: Int = 12) -> LayoutChoice {
        LayoutLadder.choose(available: Extent(width: width, height: height), maxProcesses: maxProcesses, measure: measure)
    }

    @Test func tinyWindowFallsBackToMicroAtItsSmallestScale() {
        let choice = Self.choose(20, 8)
        #expect(choice.candidate.tier == .micro)
        #expect(choice.scale == LayoutLadder.minimumMicroScale)
    }

    @Test func thinWindowsGetStripsNotASingleNumber() {
        #expect(Self.choose(600, 28).candidate.strip == .rich)
        #expect(Self.choose(260, 28).candidate.strip == .plain)
        #expect(Self.choose(60, 400).candidate.strip == .vertical)
    }

    @Test func cornerSizeKeepsCoreColumns() {
        #expect(Self.choose(170, 130).candidate.tier == .corner)
    }

    @Test func largeWindowAddsProcessesUpToTheLimit() {
        #expect(Self.choose(520, 1000).candidate.processCount >= 9)
        #expect(Self.choose(520, 1000, maxProcesses: 5).candidate.processCount == 5)
    }

    /// The window snaps to the chosen layout, so the choice should leave little of the dragged size unused.
    @Test func choiceCoversMostOfTheBestPossibleArea() {
        let candidates = LayoutLadder.candidates(maxProcesses: 12, showsProcesses: true)
        for width in stride(from: 240.0, through: 1200, by: 80) {
            for height in stride(from: 240.0, through: 900, by: 60) {
                let choice = Self.choose(width, height)
                let size = Self.measure(choice.candidate)
                let covered = size.width * size.height * choice.scale * choice.scale
                let best = candidates.map { candidate -> Double in
                    let size = Self.measure(candidate)
                    let scale = min(LayoutLadder.maximumScale, min(width / size.width, height / size.height))
                    return scale >= 1 ? size.width * size.height * scale * scale : 0
                }.max()!
                #expect(covered >= best * LayoutLadder.richnessTolerance - 0.001)
            }
        }
    }

    @Test func scaleNeverExceedsTheMaximumOrTheWindow() {
        for width in stride(from: 40.0, through: 1600, by: 97) {
            for height in stride(from: 20.0, through: 1000, by: 61) {
                let choice = Self.choose(width, height)
                let size = Self.measure(choice.candidate)
                #expect(choice.scale <= LayoutLadder.maximumScale)
                if choice.candidate.tier != .micro || choice.scale > LayoutLadder.minimumMicroScale {
                    #expect(size.width * choice.scale <= width + 0.001)
                    #expect(size.height * choice.scale <= height + 0.001)
                }
            }
        }
    }

    @Test func threeColumnsOnlyWhereTheMiddleColumnIsBalanced() {
        let wide = LayoutLadder.candidates(maxProcesses: 12, showsProcesses: true).filter { $0.columns == 3 }
        #expect(!wide.isEmpty)
        #expect(wide.allSatisfy { $0.processCount == 5 })
    }

    @Test func withoutProcessesNoCandidateShowsThem() {
        let candidates = LayoutLadder.candidates(maxProcesses: 12, showsProcesses: false)
        #expect(candidates.allSatisfy { $0.processCount == 0 })
    }
}
