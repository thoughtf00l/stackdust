import SwiftUI
import StackdustCore

/// A subdued capsule showing the deletion risk of a dev-item category. Hovering it explains the
/// consequence. Shared by the contents list (per dev-item row) and the reclaim list (per group).
struct RiskBadge: View {
    let category: DevCategory

    var body: some View {
        let tier = category.riskTier
        Text(label(for: tier))
            .font(.caption2)
            .foregroundStyle(color(for: tier))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color(for: tier).opacity(0.18)))
            .help(category.consequence)
    }

    private func label(for tier: DevRiskTier) -> String {
        switch tier {
        case .safe: return "Safe"
        case .costsTime: return "Costs time"
        case .losesState: return "Loses data"
        }
    }

    private func color(for tier: DevRiskTier) -> Color {
        switch tier {
        case .safe: return .green
        case .costsTime: return .yellow
        case .losesState: return .orange
        }
    }
}
