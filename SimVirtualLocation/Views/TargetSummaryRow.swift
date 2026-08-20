import SwiftUI

/// One line naming what the app is pointed at, standing in for five controls.
///
/// Platform, simulator-or-device, transport and the device picker are set once and then
/// never touched again, but they used to occupy the top third of the panel permanently.
/// Collapsed they read as a single answer to "where is this going?"; expanding is for the
/// rare occasion that answer needs to change.
struct TargetSummaryRow: View {

    @EnvironmentObject var locationController: LocationController

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                locationController.isTargetExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundColor(locationController.isTargetReady ? .accentColor : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(locationController.targetName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(locationController.targetDetail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: locationController.isTargetExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        if locationController.platform == .android { return "candybarphone" }
        return locationController.deviceMode == .simulator ? "iphone.gen3.badge.play" : "iphone.gen3"
    }
}
