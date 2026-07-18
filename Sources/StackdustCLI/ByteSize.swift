import Foundation

/// Parsing and formatting of byte counts.
///
/// Sizes use *decimal* units throughout (K = 1000, M = 1_000_000, ...) so the `--min-size`
/// flag and the human-readable output agree, and so they match Finder's convention.
enum ByteSize {

    /// Thrown when a `--min-size` value cannot be understood.
    struct ParseError: Error, Equatable {
        let input: String
    }

    private static let multipliers: [Character: Int64] = [
        "K": 1_000,
        "M": 1_000_000,
        "G": 1_000_000_000,
        "T": 1_000_000_000_000,
    ]

    /// Parses a SIZE argument into a byte count.
    ///
    /// Accepts a raw non-negative integer (`1048576`) or a decimal value with a single
    /// case-insensitive suffix `K`/`M`/`G`/`T` (`500M`, `1.5G`, `0.5K`). A fractional value is
    /// only allowed with a suffix; raw byte counts must be whole. Anything else throws.
    ///
    ///     ByteSize.parse("1.5G")   // 1_500_000_000
    static func parse(_ raw: String) throws -> Int64 {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ParseError(input: raw) }

        // Split off a trailing unit letter, if present.
        let last = trimmed[trimmed.index(before: trimmed.endIndex)]
        if let multiplier = multipliers[Character(last.uppercased())] {
            let numberPart = String(trimmed.dropLast())
            guard let value = Double(numberPart), value >= 0, value.isFinite else {
                throw ParseError(input: raw)
            }
            let bytes = (value * Double(multiplier)).rounded()
            guard bytes <= Double(Int64.max) else { throw ParseError(input: raw) }
            return Int64(bytes)
        }

        // No unit: must be a whole, non-negative byte count.
        guard let bytes = Int64(trimmed), bytes >= 0 else { throw ParseError(input: raw) }
        return bytes
    }

    /// Formats a byte count for humans using decimal units, one decimal place above bytes.
    ///
    ///     ByteSize.human(1_500_000_000)   // "1.5 GB"
    ///     ByteSize.human(512)             // "512 B"
    static func human(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[index])
    }
}
