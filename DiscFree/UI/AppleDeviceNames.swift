import Foundation

/// Marketing names for Apple device model identifiers (the `<model>,<variant>` strings Xcode
/// writes into `<platform> DeviceSupport` folder names) plus the parser that turns such a folder
/// name into a friendly label for the Reclaim list.
///
/// Maintenance: this table is intentionally partial and hand-verified — extend it as new hardware
/// ships. A missing identifier is never an error: `deviceSupportLabel` falls back to the raw model
/// id (and then the raw folder name), so an unmapped device only yields a slightly less friendly
/// label, never a wrong or crashing one.
enum AppleDeviceNames {

    static let marketingNames: [String: String] = [
        // iPhone (iPhone8,x – iPhone17,x)
        "iPhone8,1": "iPhone 6s",
        "iPhone8,2": "iPhone 6s Plus",
        "iPhone8,4": "iPhone SE (1st generation)",
        "iPhone9,1": "iPhone 7",
        "iPhone9,2": "iPhone 7 Plus",
        "iPhone9,3": "iPhone 7",
        "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8",
        "iPhone10,2": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X",
        "iPhone10,4": "iPhone 8",
        "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS",
        "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",

        // iPad (iPad8,x and later)
        "iPad8,1": "iPad Pro (11-inch)",
        "iPad8,2": "iPad Pro (11-inch)",
        "iPad8,3": "iPad Pro (11-inch)",
        "iPad8,4": "iPad Pro (11-inch)",
        "iPad8,5": "iPad Pro (12.9-inch, 3rd generation)",
        "iPad8,6": "iPad Pro (12.9-inch, 3rd generation)",
        "iPad8,7": "iPad Pro (12.9-inch, 3rd generation)",
        "iPad8,8": "iPad Pro (12.9-inch, 3rd generation)",
        "iPad8,9": "iPad Pro (11-inch, 2nd generation)",
        "iPad8,10": "iPad Pro (11-inch, 2nd generation)",
        "iPad8,11": "iPad Pro (12.9-inch, 4th generation)",
        "iPad8,12": "iPad Pro (12.9-inch, 4th generation)",
        "iPad13,1": "iPad Air (4th generation)",
        "iPad13,2": "iPad Air (4th generation)",
        "iPad13,4": "iPad Pro (11-inch, 3rd generation)",
        "iPad13,5": "iPad Pro (11-inch, 3rd generation)",
        "iPad13,6": "iPad Pro (11-inch, 3rd generation)",
        "iPad13,7": "iPad Pro (11-inch, 3rd generation)",
        "iPad13,8": "iPad Pro (12.9-inch, 5th generation)",
        "iPad13,9": "iPad Pro (12.9-inch, 5th generation)",
        "iPad13,10": "iPad Pro (12.9-inch, 5th generation)",
        "iPad13,11": "iPad Pro (12.9-inch, 5th generation)",
        "iPad13,16": "iPad Air (5th generation)",
        "iPad13,17": "iPad Air (5th generation)",
        "iPad13,18": "iPad (10th generation)",
        "iPad13,19": "iPad (10th generation)",
        "iPad14,1": "iPad mini (6th generation)",
        "iPad14,2": "iPad mini (6th generation)",
        "iPad14,3": "iPad Pro (11-inch, 4th generation)",
        "iPad14,4": "iPad Pro (11-inch, 4th generation)",
        "iPad14,5": "iPad Pro (12.9-inch, 6th generation)",
        "iPad14,6": "iPad Pro (12.9-inch, 6th generation)",

        // Apple Watch (Watch6,x and later)
        "Watch6,1": "Apple Watch Series 6",
        "Watch6,2": "Apple Watch Series 6",
        "Watch6,3": "Apple Watch Series 6",
        "Watch6,4": "Apple Watch Series 6",
        "Watch6,6": "Apple Watch Series 7",
        "Watch6,7": "Apple Watch Series 7",
        "Watch6,8": "Apple Watch Series 7",
        "Watch6,9": "Apple Watch Series 7",
        "Watch6,10": "Apple Watch SE (2nd generation)",
        "Watch6,11": "Apple Watch SE (2nd generation)",
        "Watch6,12": "Apple Watch SE (2nd generation)",
        "Watch6,13": "Apple Watch SE (2nd generation)",
        "Watch6,14": "Apple Watch Series 8",
        "Watch6,15": "Apple Watch Series 8",
        "Watch6,16": "Apple Watch Series 8",
        "Watch6,17": "Apple Watch Series 8",
        "Watch6,18": "Apple Watch Ultra",
        "Watch7,1": "Apple Watch Series 9",
        "Watch7,2": "Apple Watch Series 9",
        "Watch7,3": "Apple Watch Series 9",
        "Watch7,4": "Apple Watch Series 9",
        "Watch7,5": "Apple Watch Ultra 2",

        // Apple TV
        "AppleTV11,1": "Apple TV 4K (2nd generation)",
        "AppleTV14,1": "Apple TV 4K (3rd generation)",
    ]

    /// Builds a friendly label for one device-support folder from its own name and the platform
    /// word taken from the parent `<platform> DeviceSupport` directory (e.g. "iOS", "watchOS").
    /// Reads nothing from disk — the folder name carries everything.
    ///
    /// Folder names come in two shapes (and, defensively, neither):
    /// - Modern: `iPhone14,2 15.0 (19A346)` → model id, OS version, build.
    /// - Old:    `15.0 (19A346) arm64e`     → no model id; version, build, architecture.
    ///
    /// Result, in order of preference:
    /// - known model id → "<marketing name> — <platform> <version>" ("iPhone 13 Pro — iOS 15.0")
    /// - unknown model id → "<model id> — <platform> <version>"
    /// - no model id but a parseable version → "<platform> <version>" ("iOS 15.0")
    /// - nothing parseable → the raw folder name, unchanged.
    static func deviceSupportLabel(childName: String, platform: String) -> String {
        let tokens = childName.split(separator: " ").map(String.init)
        var modelId: String?
        var versionIndex = 0
        if let first = tokens.first, isModelIdentifier(first) {
            modelId = first
            versionIndex = 1
        }
        let version = (tokens.count > versionIndex && startsWithDigit(tokens[versionIndex]))
            ? tokens[versionIndex] : nil

        guard let version else { return childName }

        if let modelId {
            let marketing = marketingNames[modelId] ?? modelId
            return "\(marketing) — \(platform) \(version)"
        }
        return "\(platform) \(version)"
    }

    /// Whether `token` looks like an Apple model identifier: letters, then digits, a comma, then
    /// digits (e.g. "iPhone14,2", "iPad13,1", "AppleTV14,1").
    private static func isModelIdentifier(_ token: String) -> Bool {
        guard let comma = token.firstIndex(of: ",") else { return false }
        let tail = token[token.index(after: comma)...]
        guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { return false }
        let head = token[..<comma]
        let letters = head.prefix { $0.isLetter }
        let digits = head.dropFirst(letters.count)
        return !letters.isEmpty && !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    private static func startsWithDigit(_ token: String) -> Bool {
        token.first?.isNumber ?? false
    }
}
