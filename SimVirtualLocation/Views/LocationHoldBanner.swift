import SwiftUI

/// Always-visible answer to "is my location actually set right now?".
///
/// Driven only by confirmed injections, so it cannot show a point as applied after the
/// device has quietly gone back to real GPS.
struct LocationHoldBanner: View {

    @EnvironmentObject var locationController: LocationController

    private var state: LocationHoldSupervisor.State { locationController.holdState }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tint)

                if let detail = locationController.holdSummary {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if state != .idle {
                Button("Re-apply now") {
                    locationController.reapplyHeldLocation()
                }
                .font(.system(size: 11))

                Button("Stop") {
                    locationController.stopSimulation()
                }
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(tint.opacity(0.35)),
            alignment: .bottom
        )
    }

    private var title: String {
        switch state {
        case .idle:
            return "No simulated location"
        case .applying:
            return "Applying location…"
        case .held:
            return "Location held"
        case .failed:
            return "LOCATION NOT SET — the device is on its real GPS"
        }
    }

    private var tint: Color {
        switch state {
        case .idle:
            return .secondary
        case .applying:
            return .orange
        case .held:
            return .green
        case .failed:
            return .red
        }
    }

    private var symbol: String {
        switch state {
        case .idle:
            return "location.slash"
        case .applying:
            return "arrow.triangle.2.circlepath"
        case .held:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }
}
