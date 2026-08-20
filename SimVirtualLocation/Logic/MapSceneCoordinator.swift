import AppKit
import CoreLocation
import MapKit

/// Map annotations, route overlay, and `MKMapViewDelegate` — decoupled from device runners and persistence.
final class MapSceneCoordinator: NSObject, MKMapViewDelegate {

    private let mapView: MKMapView
    private var pointAnnotations: [MKPointAnnotation] = []
    private(set) var route: MKRoute?

    /// Called when the user commits a dropped pin from its callout. The map is the
    /// natural place to say "here" — clicking it and then hunting for a button in the
    /// panel was two steps for one intention.
    var onSetLocationRequested: ((CLLocationCoordinate2D) -> Void)?

    /// Only Place mode offers to apply a pin; in Route mode the pins are route ends.
    var isPlaceMode: Bool = true

    /// The point currently applied to the device, drawn apart from the rest.
    private var heldCoordinate: CLLocationCoordinate2D?

    let currentSimulationAnnotation = MKPointAnnotation()

    init(mapView: MKMapView) {
        self.mapView = mapView
        super.init()
        mapView.delegate = self
    }

    func handleMapClick(_ sender: NSClickGestureRecognizer, pointsMode: PointsMode) {
        let point = sender.location(in: mapView)
        let clickLocation = mapView.convert(point, toCoordinateFrom: mapView)
        addLocation(coordinate: clickLocation, pointsMode: pointsMode)
    }

    func addLocation(coordinate: CLLocationCoordinate2D, pointsMode: PointsMode) {
        if pointsMode == .single {
            mapView.removeAnnotations(pointAnnotations)
            pointAnnotations = []
        }

        if pointAnnotations.count == 2 {
            mapView.removeAnnotations(mapView.annotations)
            pointAnnotations = []
            return
        }

        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate
        annotation.title = pointAnnotations.count == 0 ? "A" : "B"

        pointAnnotations.append(annotation)
        mapView.addAnnotation(annotation)

        // Open the callout straight away: the pin and the way to act on it should arrive
        // together, rather than needing a second click to discover.
        mapView.selectAnnotation(annotation, animated: true)
    }

    /// Marks which pin is applied so it reads differently from one merely dropped.
    func setHeldCoordinate(_ coordinate: CLLocationCoordinate2D?) {
        heldCoordinate = coordinate
        for annotation in pointAnnotations {
            guard let view = mapView.view(for: annotation) as? MKMarkerAnnotationView else { continue }
            view.markerTintColor = tint(for: annotation)
        }
    }

    private func isHeld(_ annotation: MKAnnotation) -> Bool {
        guard let heldCoordinate else { return false }
        return abs(annotation.coordinate.latitude - heldCoordinate.latitude) < 0.000001
            && abs(annotation.coordinate.longitude - heldCoordinate.longitude) < 0.000001
    }

    private func tint(for annotation: MKAnnotation) -> NSColor {
        if isHeld(annotation) { return .systemGreen }
        return (annotation.title ?? "") == "B" ? .systemOrange : .controlAccentColor
    }

    @objc private func setLocationTapped(_ sender: NSButton) {
        guard let coordinate = mapView.selectedAnnotations.first?.coordinate else { return }
        onSetLocationRequested?(coordinate)
    }

    func annotationEndpoints() -> [MKPointAnnotation] {
        pointAnnotations
    }

    func makeRoute(
        transportType: TransportType,
        showAlert: @escaping (String) -> Void,
        onRouteReady: @escaping (MKRoute) -> Void = { _ in }
    ) {
        guard pointAnnotations.count == 2 else {
            showAlert("Route requires two points")
            return
        }

        let startPoint = pointAnnotations[0].coordinate
        let endPoint = pointAnnotations[1].coordinate

        let sourcePlacemark = MKPlacemark(coordinate: startPoint, addressDictionary: nil)
        let destinationPlacemark = MKPlacemark(coordinate: endPoint, addressDictionary: nil)

        let sourceMapItem = MKMapItem(placemark: sourcePlacemark)
        let destinationMapItem = MKMapItem(placemark: destinationPlacemark)

        let sourceAnnotation = MKPointAnnotation()
        if let location = sourcePlacemark.location {
            sourceAnnotation.coordinate = location.coordinate
        }

        let destinationAnnotation = MKPointAnnotation()
        if let location = destinationPlacemark.location {
            destinationAnnotation.coordinate = location.coordinate
        }

        mapView.removeAnnotations(mapView.annotations)
        mapView.showAnnotations([sourceAnnotation, destinationAnnotation], animated: true)

        let directionRequest = MKDirections.Request()
        directionRequest.source = sourceMapItem
        directionRequest.destination = destinationMapItem
        directionRequest.transportType = transportType == .driving ? .automobile : .walking

        let directions = MKDirections(request: directionRequest)

        directions.calculate { [weak self] response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let response = response else {
                    if let error = error {
                        showAlert(error.localizedDescription)
                    }
                    return
                }

                let route = response.routes[0]

                if let currentRoute = self.route {
                    self.mapView.removeOverlay(currentRoute.polyline)
                }
                self.route = route
                self.mapView.addOverlay(route.polyline, level: .aboveRoads)

                let rect = route.polyline.boundingMapRect
                self.mapView.setRegion(MKCoordinateRegion(rect.insetBy(dx: -1000, dy: -1000)), animated: true)

                onRouteReady(route)
            }
        }
    }

    func removeSimulationAnnotationFromMap() {
        mapView.removeAnnotation(currentSimulationAnnotation)
    }

    func placeSimulationAnnotation(at coordinate: CLLocationCoordinate2D) {
        currentSimulationAnnotation.coordinate = coordinate
        mapView.addAnnotation(currentSimulationAnnotation)
    }

    func resetMapVisuals() {
        mapView.removeAnnotations(mapView.annotations)
        pointAnnotations = []

        if let route = route {
            mapView.removeOverlay(route.polyline)
        }
        route = nil
    }

    func handlePointsModeChange(to pointsMode: PointsMode) {
        if pointsMode == .single && pointAnnotations.count == 2, let second = pointAnnotations.last {
            mapView.removeAnnotation(second)

            if let route = route {
                mapView.removeOverlay(route.polyline)
            }

            pointAnnotations = [pointAnnotations[0]]
        }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        let renderer = MKPolylineRenderer(overlay: overlay)
        renderer.strokeColor = NSColor(red: 17.0 / 255.0, green: 147.0 / 255.0, blue: 255.0 / 255.0, alpha: 1)
        renderer.lineWidth = 5.0
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation === currentSimulationAnnotation {
            let marker = MKMarkerAnnotationView(
                annotation: currentSimulationAnnotation,
                reuseIdentifier: "simulationMarker"
            )
            marker.markerTintColor = .orange
            return marker
        }

        guard let point = annotation as? MKPointAnnotation, pointAnnotations.contains(point) else {
            return nil
        }

        let marker = MKMarkerAnnotationView(annotation: point, reuseIdentifier: "pointMarker")
        marker.canShowCallout = true
        marker.markerTintColor = tint(for: point)
        marker.glyphText = isHeld(point) ? nil : point.title
        marker.glyphImage = isHeld(point) ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) : nil

        if isPlaceMode, !isHeld(point) {
            let button = NSButton(
                title: "Set location here",
                target: self,
                action: #selector(setLocationTapped(_:))
            )
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.sizeToFit()
            marker.rightCalloutAccessoryView = button
        }

        return marker
    }
}
