import Foundation

/// Time-ordered identifiers (UUID version 7) that devices can generate offline without coordination.
public enum Identifiers {
    public static func newID(at date: Date = Date()) -> String {
        uuidV7(at: date).uuidString.lowercased()
    }

    static func uuidV7(at date: Date) -> UUID {
        let milliseconds = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded(.down)))
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * (5 - index)))
        }
        var generator = SystemRandomNumberGenerator()
        for index in 6..<16 {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70  // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 9562 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// UTC timestamps stored as ISO 8601 strings with millisecond precision ("2026-11-07T09:30:00.123Z").
public enum Timestamps {
    private static let secondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// The current time at the precision the archive stores.
    public static func now() -> Date {
        truncated(Date())
    }

    /// Rounds to whole milliseconds, the precision stored in the archive. Applying it twice changes nothing.
    public static func truncated(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    /// Formats milliseconds explicitly, so binary floating-point error can never shift the stored value.
    public static func string(_ date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        var seconds = milliseconds / 1000
        var remainder = milliseconds % 1000
        if remainder < 0 {
            remainder += 1000
            seconds -= 1
        }
        let base = secondsFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        let fraction = remainder < 10 ? "00\(remainder)" : (remainder < 100 ? "0\(remainder)" : "\(remainder)")
        return String(base.dropLast()) + ".\(fraction)Z"
    }

    public static func date(_ string: String) -> Date? {
        guard let parsed = fractionalFormatter.date(from: string) ?? secondsFormatter.date(from: string) else {
            return nil
        }
        return truncated(parsed)
    }
}
