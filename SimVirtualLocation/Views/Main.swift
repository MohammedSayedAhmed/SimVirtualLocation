//
//  Main.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 20.02.2022.
//

import SwiftUI

@main
struct SimVirtualLocationApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var root = AppRootState()

    var body: some Scene {
        WindowGroup {
            ContentView(mapView: root.mapView, locationController: root.locationController)
                .onAppear {
                    // The delegate refuses to quit while a point is being held.
                    appDelegate.locationController = root.locationController
                }
        }
    }
}

/// Owns `MapView` and `LocationController` so SwiftUI does not recreate them on every `WindowGroup` update.
final class AppRootState: ObservableObject {
    let mapView: MapView
    let locationController: LocationController

    init() {
        let mapView = MapView()
        self.mapView = mapView
        self.locationController = LocationController(mapView: mapView)
    }
}
