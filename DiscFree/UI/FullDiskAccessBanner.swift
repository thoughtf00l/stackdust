import SwiftUI

/// Non-blocking hint shown on the start screen when Full Disk Access is missing.
struct FullDiskAccessBanner: View {
    let onOpenSettings: () -> Void
    let onRecheck: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Grant Full Disk Access for complete results")
                    .font(.callout.weight(.medium))
                Text("Without it, some system and other users' folders can't be measured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Open Settings", action: onOpenSettings)
            Button("Recheck", action: onRecheck)
                .buttonStyle(.borderless)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.3)))
        .frame(maxWidth: 540)
    }
}

/// Unobtrusive "N folders couldn't be read" note for the result screen. Opens System
/// Settings when Full Disk Access is the likely cause.
struct UnreadableIndicator: View {
    let count: Int
    let fdaMissing: Bool
    let onOpenSettings: () -> Void

    private var text: String {
        count == 1 ? "1 folder couldn’t be read" : "\(count) folders couldn’t be read"
    }

    var body: some View {
        if fdaMissing {
            Button(action: onOpenSettings) {
                Label(text, systemImage: "lock")
            }
            .buttonStyle(.link)
            .help("Grant Full Disk Access to measure these folders")
        } else {
            Label(text, systemImage: "lock")
                .foregroundStyle(.secondary)
        }
    }
}
