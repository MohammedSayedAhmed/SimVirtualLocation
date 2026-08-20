import SwiftUI

/// Plan a day: a list of places, when to leave each, and how fast.
///
/// Arrival times are never entered — they fall out of the routed distance and the speed
/// you chose, which is the thing you actually control.
struct DayPlanPanel: View {

    @EnvironmentObject var locationController: LocationController

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if locationController.dayPlan.stops.isEmpty {
                    Text("Drop a pin on the map, then add it as your first stop.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(locationController.dayPlan.stops.enumerated()), id: \.element.id) { index, stop in
                        stopRow(index: index, stop: stop)
                        if index < locationController.dayPlan.stops.count - 1 {
                            legRow(index: index)
                        }
                    }
                }

                Button(action: {
                    locationController.addDayStop()
                }, label: {
                    Text("Add stop from map pin").frame(maxWidth: .infinity)
                })
            }
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: {
                    Task { await locationController.buildDaySchedule() }
                }, label: {
                    Text("Work out the day").frame(maxWidth: .infinity)
                })
                .disabled(locationController.dayPlan.stops.count < 2)

                if let status = locationController.dayPlanStatus {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: {
                    locationController.startDayPlan()
                }, label: {
                    Text("Run the day").frame(maxWidth: .infinity)
                })
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(locationController.daySchedule == nil || locationController.isDayPlanRunning)

                Button(action: {
                    locationController.stopDayPlan()
                }, label: {
                    Text("Stop").frame(maxWidth: .infinity)
                })
                .disabled(!locationController.isDayPlanRunning)

                // A day plan is mostly waiting, and waiting looks exactly like nothing
                // happening. Say which part of the day is currently in force.
                if let now = nowText() {
                    Divider()
                    Text(now)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Runs off your Mac's clock, so it picks the day up correctly after a restart or a spell unplugged.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func stopRow(index: Int, stop: DayPlanStop) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.secondary.opacity(0.25)))

                TextField("Name", text: nameBinding(index: index))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))

                Button {
                    locationController.showDayStopOnMap(at: index)
                } label: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .buttonStyle(.plain)
                .help("Show on map")

                Button {
                    locationController.removeDayStop(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help("Remove")
            }

            Text(Coordinate(latitude: stop.latitude, longitude: stop.longitude).formatted)
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            if let arrival = arrivalText(forStopAt: index) {
                Text(arrival)
                    .font(.system(size: 10))
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func legRow(index: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .frame(width: 16)

            Text("Leave")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            TextField("09:00", text: departureBinding(index: index))
                .frame(width: 54)
                .font(.system(size: 11))

            TextField("60", value: speedBinding(index: index), format: .number)
                .frame(width: 40)
                .font(.system(size: 11))

            Text("km/h")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    // MARK: - Bindings

    private func nameBinding(index: Int) -> Binding<String> {
        Binding(
            get: { locationController.dayPlan.stops[safe: index]?.name ?? "" },
            set: { newValue in
                guard locationController.dayPlan.stops.indices.contains(index) else { return }
                locationController.dayPlan.stops[index].name = newValue
            }
        )
    }

    private func departureBinding(index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let minutes = locationController.dayPlan.stops[safe: index]?.departureMinutes else { return "" }
                return DayPlanStop.formatted(minutes: minutes)
            },
            set: { newValue in
                guard locationController.dayPlan.stops.indices.contains(index) else { return }
                locationController.dayPlan.stops[index].departureMinutes = Self.parseTime(newValue)
            }
        )
    }

    private func speedBinding(index: Int) -> Binding<Double> {
        Binding(
            get: { locationController.dayPlan.stops[safe: index]?.speedKph ?? 60 },
            set: { newValue in
                guard locationController.dayPlan.stops.indices.contains(index) else { return }
                locationController.dayPlan.stops[index].speedKph = max(newValue, 1)
            }
        )
    }

    /// "9:05", "09:05" and "0905" all mean the same thing to someone typing quickly.
    static func parseTime(_ text: String) -> Int? {
        let digits = text.filter { $0.isNumber || $0 == ":" }
        let parts = digits.split(separator: ":")

        let hour: Int
        let minute: Int

        if parts.count == 2 {
            hour = Int(parts[0]) ?? 0
            minute = Int(parts[1]) ?? 0
        } else if let value = Int(digits), digits.count == 4 {
            hour = value / 100
            minute = value % 100
        } else if let value = Int(digits), digits.count <= 2 {
            hour = value
            minute = 0
        } else {
            return nil
        }

        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// What the plan is doing at this moment, in the same words the list uses.
    private func nowText() -> String? {
        switch locationController.dayActivity {
        case .stopped:
            return nil

        case .waiting(let stopIndex, let until):
            guard let stop = locationController.daySchedule?.stops[safe: stopIndex] else { return nil }
            guard let until else { return "At \(stop.name) for the rest of the day" }
            return "At \(stop.name) until \(Self.clock.string(from: until))"

        case .travelling(let legIndex, let arrival):
            guard let schedule = locationController.daySchedule,
                  let leg = schedule.legs[safe: legIndex],
                  let to = schedule.stops[safe: leg.fromIndex + 1] else { return nil }
            return "On the way to \(to.name), arriving \(Self.clock.string(from: arrival))"
        }
    }

    private func arrivalText(forStopAt index: Int) -> String? {
        guard let schedule = locationController.daySchedule else { return nil }
        guard let leg = schedule.legs.first(where: { $0.fromIndex == index - 1 }) else { return nil }

        let arrival = Self.clock.string(from: leg.arrival)
        let distance = String(format: "%.1f km", leg.distance / 1000)

        if leg.isLate {
            return "Arrive \(arrival) · \(distance) · left later than planned"
        }
        return "Arrive \(arrival) · \(distance)"
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

extension Array {
    /// Index that returns `nil` rather than trapping, for view code reading a list that
    /// can change underneath it.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct DayPlanPanel_Previews: PreviewProvider {
    static var previews: some View {
        DayPlanPanel()
            .environmentObject(LocationController(mapView: MapView()))
    }
}
