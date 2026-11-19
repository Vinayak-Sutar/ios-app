import Foundation

/// Lexicographically sortable 26-character id: a 48-bit millisecond timestamp
/// followed by 80 bits of randomness, in Crockford base32. Same scheme as
/// `mnemo/db.py`, so ids are interchangeable with the Python vault's.
///
/// Sorting by id therefore sorts by creation time, which several queries rely
/// on instead of keeping a separate index.
public enum ULID {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func generate(
        milliseconds: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        randomHigh: UInt64 = UInt64.random(in: 0...UInt64.max),
        randomLow: UInt64 = UInt64.random(in: 0...UInt64.max)
    ) -> String {
        // 128 bits laid out as (ms << 80) | rand80, emitted five bits at a
        // time from the low end and then reversed — the same construction as
        // the Python version, just without a big-integer type.
        var low: UInt64 = randomLow                       // bits 0..<64
        var high: UInt64 = (milliseconds << 16) | ((randomHigh >> 48) & 0xFFFF)  // bits 64..<128

        var out = [Character]()
        out.reserveCapacity(26)
        for _ in 0..<26 {
            out.append(alphabet[Int(low & 0x1F)])
            low = (low >> 5) | ((high & 0x1F) << 59)
            high >>= 5
        }
        return String(out.reversed())
    }

    public static func isValid(_ text: String) -> Bool {
        guard text.count == 26 else { return false }
        return text.allSatisfy { alphabet.contains($0) }
    }
}
