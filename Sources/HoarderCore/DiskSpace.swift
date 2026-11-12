import Foundation

public struct DiskSpace: Sendable, Equatable {
    public let free: Int64
    public let total: Int64

    /// Free space as `df` reports it. Finder's figure also counts purgeable space, which reads calmer
    /// than it is when a build is filling the disk.
    public static func current(volume: String = "/") -> DiskSpace? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: volume).resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity else { return nil }
        return DiskSpace(free: Int64(free), total: Int64(total))
    }
}

/// Low-disk alerting: one alert per dip below the limit. Climbing back above re-arms it, and a snooze
/// silences it until the snooze ends, then alerts once more if the disk is still low.
public struct AlertState: Codable, Sendable, Equatable {
    public private(set) var alerted = false
    public private(set) var snoozedUntil: Date?

    public init() {}

    /// Returns true when an alert should be sent now.
    public mutating func evaluate(free: Int64, limit: Int64, now: Date = .now) -> Bool {
        guard free < limit else {
            alerted = false
            return false
        }
        if let snoozedUntil, now < snoozedUntil { return false }
        snoozedUntil = nil
        guard !alerted else { return false }
        alerted = true
        return true
    }

    public mutating func snooze(until date: Date) {
        snoozedUntil = date
        alerted = false
    }

    public func isSnoozed(now: Date = .now) -> Bool {
        snoozedUntil.map { now < $0 } ?? false
    }
}
