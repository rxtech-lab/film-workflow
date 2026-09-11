import Foundation
import MapKit

public struct RemotionCoordinate: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    var value: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}
public struct RemotionMapMarker: Codable, Equatable, Sendable {
    public var coordinate: RemotionCoordinate
    public var color: String?
    public var label: String?
    public init(coordinate: RemotionCoordinate, color: String? = nil, label: String? = nil) {
        self.coordinate = coordinate; self.color = color; self.label = label
    }
}
public struct RemotionMapRoute: Codable, Equatable, Sendable {
    public var coordinates: [RemotionCoordinate]
    public var color: String?
    public var width: Double?
    public init(coordinates: [RemotionCoordinate], color: String? = nil, width: Double? = nil) {
        self.coordinates = coordinates; self.color = color; self.width = width
    }
}
public struct RemotionMapRequest: Codable, Equatable, Sendable {
    public enum Style: String, Codable, Sendable { case standard, muted, satellite, hybrid }
    public var center: RemotionCoordinate
    public var zoom: Double
    public var width: Int
    public var height: Int
    public var markers: [RemotionMapMarker]
    public var routes: [RemotionMapRoute]
    public var mapStyle: Style?
    public init(center: RemotionCoordinate, zoom: Double, width: Int, height: Int,
                markers: [RemotionMapMarker] = [], routes: [RemotionMapRoute] = [], mapStyle: Style = .standard) {
        self.center = center; self.zoom = zoom; self.width = width; self.height = height
        self.markers = markers; self.routes = routes; self.mapStyle = mapStyle
    }
}
public struct RemotionMapSnapshot: Codable, Sendable {
    /// PNG containing the full map and its original attribution, plus requested overlays.
    public let png: Data
    /// Pixel positions measured from the top-left of the image.
    public let markerPoints: [CGPoint]
    public let routePoints: [[CGPoint]]
}
