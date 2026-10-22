import Foundation

/// The six production helpers are kept as data in the project file so an effect
/// can be reopened and edited without touching the original Keynote package.
struct CameraMotion: Codable, Sendable {
    var enabled: Bool = false
    var startCenter: Vec = Vec(x: 960, y: 540)
    var endCenter: Vec = Vec(x: 960, y: 540)
    var startZoom: Double = 1
    var endZoom: Double = 1

    func transform(at seconds: Double, duration: Double, canvas: Vec) -> CameraTransform {
        let t = duration > 0 ? min(1, max(0, seconds / duration)) : 0
        let eased = t * t * (3 - 2 * t)
        let center = enabled ? startCenter + (endCenter - startCenter) * eased : Vec(x: canvas.x / 2, y: canvas.y / 2)
        let zoom = enabled ? max(0.1, min(8, startZoom + (endZoom - startZoom) * eased)) : 1
        return CameraTransform(center: center, zoom: zoom)
    }
}

struct CameraTransform: Equatable, Sendable {
    var center: Vec
    var zoom: Double
}

struct ParallaxLayer: Codable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var name: String = "视差层"
    /// 0 is locked to the camera, 1 follows the main object, negative values move oppositely.
    var depth: Double = 0.5
    var size: Vec = Vec(x: 260, y: 120)
    var offset: Vec = Vec(x: 0, y: 0)
}

struct TextCue: Codable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var text: String = "沿线动效"
    var start: Double = 0
    var duration: Double = 2
    var position: Vec = Vec(x: 960, y: 180)
    var startOpacity: Double = 0
    var endOpacity: Double = 1
    var startScale: Double = 0.7
    var endScale: Double = 1

    func state(at seconds: Double) -> (opacity: Double, scale: Double)? {
        guard duration > 0, seconds >= start, seconds <= start + duration else { return nil }
        let t = min(1, max(0, (seconds - start) / duration))
        let eased = t * t * (3 - 2 * t)
        return (startOpacity + (endOpacity - startOpacity) * eased,
                startScale + (endScale - startScale) * eased)
    }
}

struct ArrayWaveEffect: Codable, Sendable {
    var enabled: Bool = false
    var count: Int = 5
    var spacing: Double = 90
    var amplitude: Double = 35
    var frequency: Double = 1.5
    var phase: Double = 0
}

struct AudioBeatMap: Codable, Sendable {
    var enabled: Bool = false
    var audioPath: String? = nil
    var bpm: Double = 120
    var offset: Double = 0
    var beatsPerBar: Int = 4

    func beatTimes(duration: Double) -> [Double] {
        guard enabled, bpm.isFinite, bpm > 0 else { return [] }
        let step = 60 / bpm
        guard step > 0 else { return [] }
        var values: [Double] = []
        var t = offset
        while t <= duration + 1e-9 {
            if t >= 0 { values.append(t) }
            t += step
            if values.count > 10000 { break }
        }
        return values
    }

    func nearestBeat(to seconds: Double, duration: Double) -> Double? {
        beatTimes(duration: duration).min { abs($0 - seconds) < abs($1 - seconds) }
    }
}

struct MotionEffects: Codable, Sendable {
    var camera: CameraMotion = CameraMotion()
    var parallax: [ParallaxLayer] = []
    var textCues: [TextCue] = []
    var arrayWave: ArrayWaveEffect = ArrayWaveEffect()
    var audioBeats: AudioBeatMap = AudioBeatMap()
    /// Number of times a completed motion should be repeated in the preview/export recipe.
    var loopCount: Int = 1

    static var sample: MotionEffects {
        MotionEffects(
            camera: CameraMotion(),
            parallax: [],
            textCues: [],
            arrayWave: ArrayWaveEffect(),
            audioBeats: AudioBeatMap(),
            loopCount: 1)
    }
}

extension MotionProject {
    func camera(at seconds: Double) -> CameraTransform {
        effectSettings.camera.transform(at: seconds, duration: duration, canvas: canvas)
    }

    func arrayPoses(at seconds: Double) -> [Pose] {
        let base = pose(at: seconds)
        let wave = effectSettings.arrayWave
        guard wave.enabled, wave.count > 1 else { return [base] }
        let tangent = Vec(x: cos(base.angle), y: sin(base.angle))
        let normal = Vec(x: -tangent.y, y: tangent.x)
        let mid = Double(wave.count - 1) / 2
        return (0..<wave.count).map { index in
            let i = Double(index) - mid
            let phase = wave.phase + Double(index) * wave.frequency
            let offset = tangent * (i * wave.spacing) + normal * (sin(phase) * wave.amplitude)
            return Pose(route: base.route + offset,
                        center: base.center + offset,
                        angle: base.angle)
        }
    }

    func visibleTextCues(at seconds: Double) -> [(TextCue, Double, Double)] {
        effectSettings.textCues.compactMap { cue in
            guard let state = cue.state(at: seconds) else { return nil }
            return (cue, state.opacity, state.scale)
        }
    }

    func parallaxOffsets(at seconds: Double) -> [(ParallaxLayer, Vec)] {
        let base = pose(at: seconds).route
        return effectSettings.parallax.map { layer in
            (layer, layer.offset + (base - Vec(x: canvas.x / 2, y: canvas.y / 2)) * layer.depth)
        }
    }

    func beatMarker(at seconds: Double) -> Double? {
        effectSettings.audioBeats.nearestBeat(to: seconds, duration: duration)
    }
}
