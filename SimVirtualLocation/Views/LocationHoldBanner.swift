import SwiftUI

/// Always-visible answer to "is my location actually set right now?".
///
/// The app used to show a simulation flag that nothing ever cleared, so a location
/// that had silently reverted to real GPS still looked applied. This banner is driven
/// by confirmed injection outcomes only.
struct LocationHoldBanner: View {

    @EnvironmentObject var locationController: LocationController

    private var status: LocationHoldStatus { locationController.holdStatus }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tint)

                if let detail = status.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if status.isActive {
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

    private var tint: Color {
        switch status.severity {
        case .neutral:
            return .secondary
        case .ok:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private var symbol: String {
        switch status {
        case .idle:
            return "location.slash"
        case .applying:
            return "arrow.triangle.2.circlepath"
        case .holding:
            return "checkmark.circle.fill"
        case .route:
            return "car.fill"
        case .recovering:
            return "exclamationmark.triangle.fill"
        case .lost:
            return "xmark.octagon.fill"
        }
    }
}

struct LocationHoldBanner_Previews: PreviewProvider {
    static var previews: some View {
        LocationHoldBanner()
            .environmentObject(LocationController(mapView: MapView()))
    }
}
