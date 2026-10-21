import Foundation

struct ImportedCanvas: Decodable {
    var x: Double
    var y: Double
}

struct ImportedTarget: Decodable {
    var id: String
    var name: String
    var kind: String
    var size: [Double]
    var rotationDegrees: Double
}

struct ImportedRoute: Decodable {
    var sceneVersion: Int
    var slide: Int
    var slideID: String
    var routeObjectID: String
    var segments: [Cubic]
    var target: ImportedTarget?
    var canvas: ImportedCanvas
    var source: ProjectSource
}

