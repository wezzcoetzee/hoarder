import Foundation

public struct DiskSpace: Sendable, Equatable {
    public let free: Int64
    public let total: Int64

    public init(free: Int64, total: Int64) {
        self.free = free
        self.total = total
    }

    /// Free space as `df` reports it. Finder's figure also counts purgeable space, which reads calmer
    /// than it is when a build is filling the disk.
    public static func current(volume: String = "/") -> DiskSpace? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: volume).resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity else { return nil }
        return DiskSpace(free: Int64(free), total: Int64(total))
    }
}

/// Low-disk alerting: one alert per dip below the limit. Climbing back above the limit plus a margin
/// re-arms it and ends any snooze, so hovering at the limit does not alert on every wobble. A snooze
/// silences it until the snooze ends, then alerts once more if the disk is still low.
public struct AlertState: Codable, Sendable, Equatable {
    public static let rearmMargin: Int64 = 2_000_000_000

    public private(set) var alerted = false
    public private(set) var snoozedUntil: Date?

    public init() {}

    /// Returns true when an alert should be sent now.
    public mutating func evaluate(free: Int64, limit: Int64, now: Date = .now) -> Bool {
        guard free < limit else {
            if free >= limit + Self.rearmMargin {
                alerted = false
                snoozedUntil = nil
            }
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

    /// Ends a snooze early. Unsnoozing happens in the popover, so while the disk is low the user has
    /// just seen it: that counts as this dip's alert, and the next one comes after a recovery.
    public mutating func unsnooze(low: Bool) {
        snoozedUntil = nil
        alerted = low
    }

    public func isSnoozed(now: Date = .now) -> Bool {
        snoozedUntil.map { now < $0 } ?? false
    }
}
