import Foundation

@main struct ProjectChecks {
    static func main() throws {
        var project = MotionProject.sample()
        project.orientation = .fixed
        project.target.anchor = Vec(x:1,y:0.2)
        project.target.rotationDegrees = 37
        for i in 0...1000 {
            let pose = project.pose(at: Double(i) / 100)
            precondition((pose.center + project.anchorOffset.rotated(37 * .pi / 180) - pose.route).length < 1e-8)
            precondition(abs(pose.angle - 37 * .pi / 180) < 1e-8)
        }
        project.orientation = .routeTangent
        for i in 0...1000 {
            let pose = project.pose(at:Double(i)/100)
            precondition((pose.center + project.anchorOffset.rotated(pose.angle) - pose.route).length < 1e-8)
        }
        project.playback = .pingPong
        precondition(project.previewDuration == 20)
        precondition(abs(project.progress(at:15)-project.progress(at:5)) < 1e-8)
        precondition(abs(project.playhead(at:27)-7) < 1e-8)
        project.playback = .loop
        precondition(abs(project.progress(at:25)-project.progress(at:5)) < 1e-8)
        let reverse = try Timeline(spans: [
            TimeSpan(start: 0, duration: 2, from: 1, to: 0.6),
            TimeSpan(start: 2, duration: 1, from: 0.6, to: 0.6),
            TimeSpan(start: 3, duration: 3, from: 0.6, to: 0)
        ])
        precondition(reverse.progress(at: 0) == 1)
        precondition(reverse.progress(at: 2.5) == 0.6)
        precondition(reverse.progress(at: 6) == 0)
        let data = try JSONEncoder().encode(project)
        let roundtrip = try JSONDecoder().decode(MotionProject.self,from:data).validated()
        precondition(roundtrip.target == project.target)
        // P1 files have neither object ids nor a rotation field.
        var old = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        for key in ["slideID","routeObjectID","targetObjectID"] {old.removeValue(forKey:key)}
        var target = old["target"] as! [String:Any];target.removeValue(forKey:"rotationDegrees");old["target"]=target
        let migrated = try JSONDecoder().decode(MotionProject.self,from:JSONSerialization.data(withJSONObject:old)).validated()
        precondition(migrated.target.rotationDegrees == nil)
        precondition(migrated.nativeExportIssue != nil)
        var invalid = project;invalid.canvas.x = 0
        do {_ = try invalid.validated();fatalError("Invalid canvas accepted")} catch {}
        invalid = project;invalid.segments[1].p0.x += 10
        do {_ = try invalid.validated();fatalError("Broken route accepted")} catch {}
        if CommandLine.arguments.count > 1 {
            let imported = try JSONDecoder().decode(ImportedRoute.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
            precondition(!imported.source.relativePath.isEmpty)
            precondition(imported.target?.kind == "group")
            precondition(!imported.segments.isEmpty)
            precondition(imported.canvas.x == 1920)
            print("Python → Swift 真实导入协议：通过")
        }
        print("固定 / 转向锚点、往返进度、旧项目兼容、无效项目拒绝：通过")
    }
}
