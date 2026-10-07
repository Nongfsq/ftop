/// One logical CPU as the panel groups and names it.
public struct CoreIdentity: Sendable, Equatable {
    public var kind: CoreKind
    public var tier: CoreTier
    /// The IODeviceTree cluster type letter as ASCII, 0 when the CPU has none.
    public var type: UInt8
    /// 0 for the fastest cores, counting up; cores without a type come last.
    public var rank: Int
}

public enum CoreTopology {
    /// Groups and names logical CPUs from what the system reports, without a list of
    /// known chips: `types` is the cluster type letter of each logical CPU (0 when
    /// missing), `levels` the kernel's performance levels, fastest first
    /// (`hw.perflevelN.name` and `.logicalcpu`).
    ///
    /// The fastest type forms the performance group and every other core the group
    /// below it. A type is matched to a level by its core count; when counts tie,
    /// by the order P, M, E. Whatever cannot be told is `unknown`, never a guess, and
    /// a machine that reports no types at all is still one group of cores.
    public static func classify(types: [UInt8], levels: [(name: String, count: Int)]) -> [CoreIdentity] {
        var counts: [UInt8: Int] = [:]
        for type in types where type != 0 { counts[type, default: 0] += 1 }
        let order: [UInt8] = [80, 77, 69]  // 'P', 'M', 'E'
        let letters = counts.keys.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs) ?? order.count
            let right = order.firstIndex(of: rhs) ?? order.count
            return left != right ? left < right : lhs < rhs
        }

        // Level of each type: by core count when that is unambiguous, else by order.
        var level: [UInt8: Int] = [:]
        let levelCounts = levels.map(\.count)
        let byCount = letters.count == levels.count && Set(levelCounts).count == levels.count && Set(counts.values) == Set(levelCounts)
        for (position, letter) in letters.enumerated() {
            if byCount, let index = levelCounts.firstIndex(of: counts[letter] ?? 0) {
                level[letter] = index
            } else if letters.count == levels.count, order.contains(letter) || letters.count == 1 {
                level[letter] = position
            }
        }
        let ranked = letters.enumerated().sorted { lhs, rhs in
            let left = level[lhs.element] ?? letters.count
            let right = level[rhs.element] ?? letters.count
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
        let rank = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1, $0) })

        return types.map { type in
            guard type != 0, let position = rank[type] else {
                return CoreIdentity(kind: letters.isEmpty ? .performance : .efficiency, tier: .unknown, type: 0, rank: letters.count)
            }
            return CoreIdentity(
                kind: position == 0 ? .performance : .efficiency, tier: tier(type: type, level: level[type].map { levels[$0].name }),
                type: type, rank: position)
        }
    }

    /// The kernel's name for the level when it is one ftop knows, else the usual
    /// meaning of 'P' and 'E'. 'M' has no meaning of its own.
    private static func tier(type: UInt8, level name: String?) -> CoreTier {
        switch name?.lowercased() {
        case "super": return .superCore
        case "performance": return .performance
        case "efficiency": return .efficiency
        default: break
        }
        switch type {
        case 80: return .performance
        case 69: return .efficiency
        default: return .unknown
        }
    }
}
