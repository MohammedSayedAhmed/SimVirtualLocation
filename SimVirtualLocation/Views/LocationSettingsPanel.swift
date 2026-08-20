//
//  LocationSettingsPanel.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 18.04.2022.
//

import SwiftUI
import Foundation

struct LocationSettingsPanel: View {
    @EnvironmentObject var locationController: LocationController
    
    @State private var isPresentedSetToCoordinate = false
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var latitudeLongitude = ""
    @State private var showDayPlan = false
    
    var body: some View {
        VStack {
            GroupBox {
                Picker("Points mode", selection: $locationController.pointsMode) {
                    Text("Single").tag(PointsMode.single)
                    Text("Two").tag(PointsMode.two)
                }.pickerStyle(.segmented)

                Picker("Transport type", selection: $locationController.transportType) {
                    Text("Driving").tag(TransportType.driving)
                    Text("Walking").tag(TransportType.walking)
                }.pickerStyle(.segmented)

                Button(action: {
                    locationController.setCurrentLocation()
                }, label: {
                    Text("Set to current location").frame(maxWidth: .infinity)
                })
                
                Button(action: {
                    latitude = ""
                    longitude = ""
                    latitudeLongitude = ""
                    isPresentedSetToCoordinate = true
                }, label: {
                    Text("Set to Coordinate").frame(maxWidth: .infinity)
                })
                .alert("Enter your coordinate", isPresented: $isPresentedSetToCoordinate) {
                    TextField("Latitude", text: $latitude)
                    TextField("Longitude", text: $longitude)
                    TextField("Latitude, Longitude", text: $latitudeLongitude)
                    Button("Move"){
                        if latitude.isEmpty || longitude.isEmpty {
                            locationController.setToCoordinate(latLngString: latitudeLongitude)
                        } else {
                            locationController.setToCoordinate(latString: latitude, lngString: longitude)
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                }

                HStack {
                    Button(action: {
                        locationController.setSelectedLocation()
                    }, label: {
                        Text("Set to A").frame(maxWidth: .infinity)
                    })
                    Button(action: {
                        locationController.savePointA()
                    }, label: {
                        Text("Save point A").frame(maxWidth: .infinity)
                    })
                }
                
                HStack {
                    Button(action: {
                        locationController.setSelectedLocation(toBPoint: true)
                    }, label: {
                        Text("Set to B").frame(maxWidth: .infinity)
                    })
                    Button(action: {
                        locationController.savePointB()
                    }, label: {
                        Text("Save point B").frame(maxWidth: .infinity)
                    })
                }

                Button(action: {
                    locationController.makeRoute()
                }, label: {
                    Text("Make route").frame(maxWidth: .infinity)
                })

                Button(action: {
                    locationController.simulateRoute()
                }, label: {
                    Text("Simulate route").frame(maxWidth: .infinity)
                })

                Button(action: {
                    locationController.simulateFromAToB()
                }, label: {
                    Text("Simulate from A to B").frame(maxWidth: .infinity)
                })

                Button(action: {
                    locationController.togglePauseSimulation()
                }, label: {
                    Text(locationController.isPaused ? "Resume simulation" : "Pause simulation")
                        .frame(maxWidth: .infinity)
                })
                .disabled(!locationController.isSimulating)

                Button(action: {
                    locationController.stopSimulation()
                }, label: {
                    Text("Stop simulation").frame(maxWidth: .infinity)
                })
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Keep location applied", isOn: $locationController.isKeepAliveEnabled)

                    Text("A set point is released by the device a short while after its session ends. Re-applying keeps it in place instead of quietly returning to real GPS.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if locationController.isKeepAliveEnabled {
                        Picker("Re-apply every", selection: $locationController.keepAliveInterval) {
                            Text("5s").tag(5.0)
                            Text("15s").tag(15.0)
                            Text("30s").tag(30.0)
                            Text("60s").tag(60.0)
                        }
                        .pickerStyle(.segmented)
                    }

                    if let summary = locationController.holdSummary {
                        HStack(spacing: 6) {
                            Text(summary)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 4)

                            Button("Re-apply") {
                                locationController.reapplyHeldLocation()
                            }
                            .font(.system(size: 10))
                        }
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading) {
                    Slider(
                        value: $locationController.speed,
                        in: LocationController.minimumSpeed...LocationController.maximumSpeed,
                        step: 5
                    ) {
                        Text("Speed")
                    }
                    Text("\(Int(locationController.speed.rounded(.up))) km/h")

                    if let summary = locationController.routeSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Text("Arrive in")
                        TextField("min", text: $locationController.targetDurationMinutes)
                            .frame(width: 56)
                        Text("min")
                        Spacer()
                        Button("Set speed") {
                            locationController.applyTargetDuration()
                        }
                    }
                    .disabled(locationController.routeDistance == 0)
                }
            }
            
            GroupBox {
                if locationController.useRSD {
                    Picker("Location update frequency", selection: $locationController.timeScale) {
                        Text("5s").tag(5.0)
                        Text("10s").tag(10.0)
                        Text("15s").tag(15.0)
                    }
                    .pickerStyle(.segmented)
                    .disabled(locationController.isSimulating)
                    .onAppear {
                        locationController.timeScale = 5.0
                    }
                } else {
                    Picker("Location update frequency", selection: $locationController.timeScale) {
                        Text("1s").tag(1.0)
                        Text("1.5s").tag(1.5)
                        Text("2s").tag(2.0)
                    }
                    .pickerStyle(.segmented)
                    .disabled(locationController.isSimulating)
                }
            }

            // Collapsed by default so the panel reads the way it always has. A whole
            // planned day is a separate job from setting a point, and it is a long list
            // of controls, so it stays folded away until it is the thing being done.
            DisclosureGroup("Day plan", isExpanded: $showDayPlan) {
                DayPlanPanel()
                    .environmentObject(locationController)
            }

            Spacer()

            GroupBox {
                Button(action: {
                    locationController.reset()
                }, label: {
                    Text("Reset").frame(maxWidth: .infinity)
                })
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
