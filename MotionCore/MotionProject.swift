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
    var rotationDegrees: Double? = nil
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
    /// Optional keeps P1/P2 project files readable while allowing the advanced
    /// preview tools to be saved alongside the original motion recipe.
    var effects: MotionEffects? = MotionEffects.sample

    var duration: Double {
        spans.last.map { $0.start + $0.duration } ?? 0
    }

    var route: Route { Route(segments) }

    func timeline() -> Timeline? { try? Timeline(spans: spans) }

    func pose(at seconds: Double) -> Pose {
        let sampled = route.pose(progress: progress(at: seconds))
        let angle = orientation == .fixed ? (target.rotationDegrees ?? 0) * .pi / 180 : sampled.angle
        return Pose(route: sampled.route, center: sampled.route - anchorOffset.rotated(angle), angle: angle)
    }

    var previewDuration: Double { effectDuration * (playback == .pingPong ? 2 : 1) }

    var effectSettings: MotionEffects { effects ?? MotionEffects.sample }

    var effectDuration: Double { duration * Double(max(1, min(99, effectSettings.loopCount))) }

    /// Display a bounded playhead while the monotonic playback clock continues.
    func playhead(at elapsed: Double) -> Double {
        playback == .once ? min(previewDuration, max(0, elapsed)) : max(0, elapsed).truncatingRemainder(dividingBy: max(0.001, previewDuration))
    }

    var nativeExportIssue: String? {
        guard slideID != nil, routeObjectID != nil, targetObjectID != nil else { return "先从文稿中选择路线和目标，点击“导入到预览”。" }
        guard spans.count == 1, spans[0].start == 0, spans[0].from == 0, spans[0].to == 1 else { return "停靠与分段速度当前仅支持预览，暂不能生成副本。" }
        guard (0.1...600).contains(duration) else { return "导出时长需要在 0.1 至 600 秒之间。" }
        guard playback == .once else { return "循环与往返当前用于预览；生成副本前请切换为单次。" }
        let advanced = effectSettings
        if advanced.camera.enabled || !advanced.parallax.isEmpty || !advanced.textCues.isEmpty || advanced.arrayWave.enabled || advanced.audioBeats.enabled || advanced.loopCount > 1 {
            return "镜头、视差、文字、阵列波浪、声音卡点和多次循环已支持预览与项目保存；原生 Keynote 副本导出将在下一阶段写入对应动画轨道。"
        }
        if orientation == .routeTangent && (abs(target.anchor.x - 0.5) > 1e-8 || abs(target.anchor.y - 0.5) > 1e-8) {
            return "非中心贴线点导出支持固定朝向；沿线转向的支点仍在验证。"
        }
        return nil
    }

    func validated() throws -> MotionProject {
        func finite(_ p: Vec) -> Bool { p.x.isFinite && p.y.isFinite }
        guard formatVersion == 1 else { throw ProjectError.invalid("不支持此项目版本。") }
        guard finite(canvas), canvas.x > 0, canvas.y > 0, max(canvas.x, canvas.y) <= 100000,
              finite(target.size), min(target.size.x, target.size.y) > 0,
              finite(target.anchor), (0...1).contains(target.anchor.x), (0...1).contains(target.anchor.y),
              (target.rotationDegrees ?? 0).isFinite, [30, 60].contains(fps),
              !segments.isEmpty, segments.count <= 10000 else { throw ProjectError.invalid("项目的画布、对象尺寸或贴线位置无效。") }
        for (index, segment) in segments.enumerated() {
            guard [segment.p0, segment.p1, segment.p2, segment.p3].allSatisfy({ finite($0) && abs($0.x) <= 1e7 && abs($0.y) <= 1e7 }),
                  index == 0 || (segments[index-1].p3 - segment.p0).length < 1e-5 else {
                throw ProjectError.invalid("项目路线无效或不连续。")
            }
        }
        _ = try Timeline(spans: spans)
        guard duration.isFinite, duration <= 86400, route.length > 1e-6,
              source.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw ProjectError.invalid("项目时长、来源指纹或路线长度无效。")
        }
        let advanced = effectSettings
        guard advanced.loopCount >= 1, advanced.loopCount <= 99,
              advanced.camera.startZoom.isFinite, advanced.camera.endZoom.isFinite,
              advanced.camera.startZoom > 0, advanced.camera.endZoom > 0,
              advanced.camera.startCenter.x.isFinite, advanced.camera.startCenter.y.isFinite,
              advanced.camera.endCenter.x.isFinite, advanced.camera.endCenter.y.isFinite,
              advanced.parallax.count <= 64,
              advanced.parallax.allSatisfy({ $0.depth.isFinite && (-4...4).contains($0.depth) && $0.size.x > 0 && $0.size.y > 0 }),
              advanced.textCues.count <= 128,
              advanced.textCues.allSatisfy({ $0.duration > 0 && $0.duration.isFinite && $0.position.x.isFinite && $0.position.y.isFinite }),
              advanced.arrayWave.count >= 1, advanced.arrayWave.count <= 128,
              advanced.arrayWave.spacing.isFinite, advanced.arrayWave.amplitude.isFinite,
              advanced.audioBeats.bpm.isFinite, advanced.audioBeats.bpm > 0,
              advanced.audioBeats.beatsPerBar >= 1, advanced.audioBeats.beatsPerBar <= 16 else {
            throw ProjectError.invalid("高级动效设置无效。")
        }
        return self
    }

    func progress(at seconds: Double) -> Double {
        guard let timeline = timeline(), timeline.duration > 0 else { return 0 }
        let t = max(0, seconds)
        switch playback {
        case .once:
            let cycle = max(0.001, duration)
            return timeline.progress(at: effectSettings.loopCount > 1 ? t.truncatingRemainder(dividingBy: cycle) : t)
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
            fps: 30,
            effects: .sample
        )
    }
}

enum ProjectError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
