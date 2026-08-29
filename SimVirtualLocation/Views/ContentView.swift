//
//  ContentView.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 20.02.2022.
//

import SwiftUI
import MapKit

struct ContentView: View {

    let mapView: MapView
    @ObservedObject var locationController: LocationController

    var body: some View {
        VStack(spacing: 0) {
            LocationHoldBanner()
                .environmentObject(locationController)

            HStack(alignment: .top, spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    mapView
                        .frame(minWidth: 400)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack {
                        Image(systemName: "plus")
                            .foregroundColor(Color.white)
                            .frame(width: 32, height: 32)
                            .background(Color.secondary)
                            .opacity(0.5)
                            .cornerRadius(16)
                            .onTapGesture {
                                var region: MKCoordinateRegion = mapView.mkMapView.region
                                region.span.latitudeDelta /= 2.0
                                region.span.longitudeDelta /= 2.0
                                mapView.mkMapView.setRegion(region, animated: true)
                            }
                        Image(systemName: "minus")
                            .foregroundColor(Color.white)
                            .frame(width: 32, height: 32)
                            .background(Color.secondary)
                            .opacity(0.5)
                            .cornerRadius(16)
                            .onTapGesture {
                                var region: MKCoordinateRegion = mapView.mkMapView.region
                                region.span.latitudeDelta *= 2.0
                                region.span.longitudeDelta *= 2.0
                                mapView.mkMapView.setRegion(region, animated: true)
                            }
                        Image(systemName: "location")
                            .foregroundColor(Color.white)
                            .frame(width: 32, height: 32)
                            .background(Color.secondary)
                            .opacity(0.5)
                            .cornerRadius(16)
                            .onTapGesture {
                                locationController.updateMapRegion(force: true)
                            }
                    }.padding()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Device mode", selection: $locationController.platform) {
                            Text("iOS").tag(AppPlatform.iOS)
                            Text("Android").tag(AppPlatform.android)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)

                        if locationController.platform == .iOS {
                            iOSPanel()
                                .environmentObject(locationController)
                        } else {
                            AndroidPanel()
                                .environmentObject(locationController)
                        }
                    }
                    .frame(width: 250, alignment: .leading)
                    .padding(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 0))
                }
                .frame(minWidth: 266, maxWidth: 266, maxHeight: .infinity)

                LocationsView()
                    .environmentObject(locationController)
                    .frame(minWidth: 300, maxWidth: 300, maxHeight: .infinity)
                    .padding(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))

            }
            .frame(minWidth: 1100, minHeight: 280)
            .frame(maxHeight: .infinity)
                .onAppear {
                    locationController.updateMapRegion()
                }
                .modifier(SimVirtualLocationAlertModifier(isPresented: $locationController.showingAlert, text: locationController.alertText))

            // Observes the log store alone, so a log line redraws these rows and
            // leaves the map, the panel and the banner untouched.
            LogPane(store: locationController.logStore)
        }
        .frame(minWidth: 900, minHeight: 480)
    }

    init(mapView: MapView, locationController: LocationController) {
        self.mapView = mapView
        self.locationController = locationController
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let mapView = MapView()
        let locationController = LocationController(mapView: mapView)
        return ContentView(mapView: mapView, locationController: locationController)
    }
}
