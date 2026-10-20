import Foundation

struct ProjectSource: Codable, Equatable, Sendable {
    var relativePath: String
    var sha256: String
}

struct ProjectTarget: Codable, Equatable, Sendable {
    var name: String
    var size: Vec
    /// Normalized point inside the target. (0,0) is the top-left corner.
    var anchor: Vec
}

enum ProjectOrientation: String, Codable, CaseIterable, Sendable {
    case fixed
    case routeTangent = "route-tangent"
}

enum PlaybackMode: String, Codable, CaseIterable, Sendable {
    case once
    case loop
    case pingPong = "ping-pong"
}

/// Persisted P1 project settings. The Keynote package remains the source document;
/// this JSON stores the motion recipe and lets the same setup be reopened later.
struct MotionProject: Codable, Sendable {
    var formatVersion: Int
    var projectID: String
    var source: ProjectSource
    /// Stable object ids from the imported Keynote scene. Optional keeps P1
    /// project files readable when they were created before P2 route import.
    var slideID: String?
    var routeObjectID: String?
    var targetObjectID: String?
    var canvas: Vec
    var segments: [Cubic]
    var target: ProjectTarget
    var orientation: ProjectOrientation
    var spans: [TimeSpan]
    var drawLine: Bool
    var playback: PlaybackMode
    var fps: Int

    var duration: Double {
        spans.last.map { $0.start + $0.duration } ?? 0
    }

    var route: Route { Route(segments) }

    func timeline() -> Timeline? { try? Timeline(spans: spans) }

    func pose(at seconds: Double) -> Pose {
        guard timeline() != nil else {
            return route.pose(progress: 0, anchorOffset: anchorOffset)
        }
        return route.pose(progress: progress(at: seconds), anchorOffset: anchorOffset)
    }

    func progress(at seconds: Double) -> Double {
        guard let timeline = timeline(), timeline.duration > 0 else { return 0 }
        let t = max(0, seconds)
        switch playback {
        case .once:
            return timeline.progress(at: t)
        case .loop:
            return timeline.progress(at: t.truncatingRemainder(dividingBy: timeline.duration))
        case .pingPong:
            let cycle = timeline.duration * 2
            let phase = t.truncatingRemainder(dividingBy: cycle)
            return phase <= timeline.duration
                ? timeline.progress(at: phase)
                : timeline.progress(at: cycle - phase)
        }
    }

    var anchorOffset: Vec {
        Vec(x: (target.anchor.x - 0.5) * target.size.x,
            y: (target.anchor.y - 0.5) * target.size.y)
    }

    static func sample(sourcePath: String = "", sha256: String = "") -> MotionProject {
        let normalizedHash = sha256.isEmpty ? String(repeating: "0", count: 64) : sha256
        return MotionProject(
            formatVersion: 1,
            projectID: UUID().uuidString,
            source: ProjectSource(relativePath: sourcePath, sha256: normalizedHash),
            slideID: nil,
            routeObjectID: nil,
            targetObjectID: nil,
            canvas: Vec(x: 1920, y: 1080),
            segments: [
                Cubic(p0: Vec(x: 150, y: 760), p1: Vec(x: 350, y: 450), p2: Vec(x: 520, y: 820), p3: Vec(x: 760, y: 570)),
                Cubic(p0: Vec(x: 760, y: 570), p1: Vec(x: 980, y: 350), p2: Vec(x: 1220, y: 720), p3: Vec(x: 1720, y: 330))
            ],
            target: ProjectTarget(name: "目标对象", size: Vec(x: 120, y: 80), anchor: Vec(x: 0.5, y: 0.5)),
            orientation: .routeTangent,
            spans: [
                TimeSpan(start: 0, duration: 2, from: 0, to: 0.3),
                TimeSpan(start: 2, duration: 1, from: 0.3, to: 0.3),
                TimeSpan(start: 3, duration: 4, from: 0.3, to: 0.72),
                TimeSpan(start: 7, duration: 1, from: 0.72, to: 0.72),
                TimeSpan(start: 8, duration: 2, from: 0.72, to: 1)
            ],
            drawLine: true,
            playback: .once,
            fps: 30
        )
    }
}
