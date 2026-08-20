//
//  LocationSettingsPanel.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 18.04.2022.
//

import SwiftUI
import Foundation

/// The control panel, split by what you are actually doing.
///
/// Holding a point and driving a route share no controls, so showing both at once made
/// eleven equally-weighted buttons out of what is really two short lists. The mode picker
/// decides which list is on screen; each one then has a single obvious primary action.
struct LocationSettingsPanel: View {
    @EnvironmentObject var locationController: LocationController

    @State private var isPresentedSetToCoordinate = false
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var latitudeLongitude = ""
    @State private var showSavedLocations = false

    var body: some View {
        VStack(spacing: 10) {
            Picker("Mode", selection: $locationController.panelMode) {
                Text("Place").tag(PanelMode.place)
                Text("Route").tag(PanelMode.route)
                Text("Day").tag(PanelMode.day)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            switch locationController.panelMode {
            case .place:
                placeControls
            case .route:
                routeControls
            case .day:
                DayPlanPanel()
                    .environmentObject(locationController)
            }

            Spacer()

            HStack {
                Button("Saved locations") {
                    showSavedLocations.toggle()
                }
                .popover(isPresented: $showSavedLocations, arrowEdge: .trailing) {
                    LocationsView()
                        .environmentObject(locationController)
                        .frame(width: 320, height: 380)
                }

                Spacer()

                Button("Reset") {
                    locationController.reset()
                }
            }
            .font(.system(size: 12))
        }
    }

    // MARK: - Place

    @ViewBuilder
    private var placeControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: {
                    locationController.setSelectedLocation()
                }, label: {
                    Text("Set to map pin").frame(maxWidth: .infinity)
                })
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Click anywhere on the map to move the pin.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(action: {
                        latitude = ""
                        longitude = ""
                        latitudeLongitude = ""
                        isPresentedSetToCoordinate = true
                    }, label: {
                        Text("Coordinate…").frame(maxWidth: .infinity)
                    })
                    .alert("Enter your coordinate", isPresented: $isPresentedSetToCoordinate) {
                        TextField("Latitude", text: $latitude)
                        TextField("Longitude", text: $longitude)
                        TextField("Latitude, Longitude", text: $latitudeLongitude)
                        Button("Move") {
                            if latitude.isEmpty || longitude.isEmpty {
                                locationController.setToCoordinate(latLngString: latitudeLongitude)
                            } else {
                                locationController.setToCoordinate(latString: latitude, lngString: longitude)
                            }
                        }
                        Button("Cancel", role: .cancel) { }
                    }

                    Button(action: {
                        locationController.setCurrentLocation()
                    }, label: {
                        Text("My Mac").frame(maxWidth: .infinity)
                    })
                }

                Button(action: {
                    locationController.savePointA()
                }, label: {
                    Text("Save this point").frame(maxWidth: .infinity)
                })
            }
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Keep location applied", isOn: $locationController.isKeepAliveEnabled)

                if locationController.isKeepAliveEnabled {
                    Picker("Re-apply every", selection: $locationController.keepAliveInterval) {
                        Text("5s").tag(5.0)
                        Text("15s").tag(15.0)
                        Text("30s").tag(30.0)
                        Text("60s").tag(60.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                Text("A set point is released by the device a short while after its session ends. Re-applying keeps it in place instead of quietly returning to real GPS.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Route

    @ViewBuilder
    private var routeControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button(action: {
                        locationController.setSelectedLocation()
                    }, label: {
                        Text("Set to A").frame(maxWidth: .infinity)
                    })
                    Button(action: {
                        locationController.setSelectedLocation(toBPoint: true)
                    }, label: {
                        Text("Set to B").frame(maxWidth: .infinity)
                    })
                }

                HStack(spacing: 8) {
                    Button(action: {
                        locationController.savePointA()
                    }, label: {
                        Text("Save A").frame(maxWidth: .infinity)
                    })
                    Button(action: {
                        locationController.savePointB()
                    }, label: {
                        Text("Save B").frame(maxWidth: .infinity)
                    })
                }
                .font(.system(size: 12))

                Picker("Transport type", selection: $locationController.transportType) {
                    Text("Driving").tag(TransportType.driving)
                    Text("Walking").tag(TransportType.walking)
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Button(action: {
                    locationController.makeRoute()
                }, label: {
                    Text("Make route").frame(maxWidth: .infinity)
                })

                Divider()

                Button(action: {
                    locationController.simulateRoute()
                }, label: {
                    Text("Drive the route").frame(maxWidth: .infinity)
                })
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(locationController.isSimulating)

                Button(action: {
                    locationController.simulateFromAToB()
                }, label: {
                    Text("Straight line A to B").frame(maxWidth: .infinity)
                })
                .disabled(locationController.isSimulating)

                HStack(spacing: 8) {
                    Button(action: {
                        locationController.togglePauseSimulation()
                    }, label: {
                        Text(locationController.isPaused ? "Resume" : "Pause").frame(maxWidth: .infinity)
                    })
                    .disabled(!locationController.isSimulating)

                    Button(action: {
                        locationController.stopSimulation()
                    }, label: {
                        Text("Stop").frame(maxWidth: .infinity)
                    })
                    .disabled(!locationController.isSimulating)
                }
            }
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Slider(
                    value: $locationController.speed,
                    in: LocationController.minimumSpeed...LocationController.maximumSpeed,
                    step: 5
                ) {
                    Text("Speed")
                }
                Text("\(Int(locationController.speed.rounded(.up))) km/h")
                    .font(.system(size: 12))

                if let summary = locationController.routeSummary {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Text("Arrive in")
                    TextField("min", text: $locationController.targetDurationMinutes)
                        .frame(width: 52)
                    Text("min")
                    Spacer()
                    Button("Set speed") {
                        locationController.applyTargetDuration()
                    }
                }
                .font(.system(size: 12))
                .disabled(locationController.routeDistance == 0)
            }
        }
    }
}

struct LocationSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        LocationSettingsPanel()
            .environmentObject(LocationController(mapView: MapView()))
    }
}
