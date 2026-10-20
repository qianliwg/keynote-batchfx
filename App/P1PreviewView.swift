import SwiftUI

private struct PreviewMap {
    let scale: CGFloat
    let origin: CGPoint
    let canvas: Vec

    func point(_ value: Vec) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(value.x) * scale,
                y: origin.y + CGFloat(value.y) * scale)
    }
}

private func previewMap(canvas: Vec, size: CGSize) -> PreviewMap {
    let padding: CGFloat = 24
    let scale = min((size.width - padding * 2) / CGFloat(max(1, canvas.x)),
                    (size.height - padding * 2) / CGFloat(max(1, canvas.y)))
    let drawn = CGSize(width: CGFloat(canvas.x) * scale, height: CGFloat(canvas.y) * scale)
    return PreviewMap(scale: scale,
                     origin: CGPoint(x: (size.width - drawn.width) / 2,
                                     y: (size.height - drawn.height) / 2),
                     canvas: canvas)
}

private func bezierPath(_ segments: [Cubic], map: PreviewMap) -> Path {
    var path = Path()
    guard let first = segments.first else { return path }
    path.move(to: map.point(first.p0))
    for segment in segments {
        path.addCurve(to: map.point(segment.p3),
                      control1: map.point(segment.p1),
                      control2: map.point(segment.p2))
    }
    return path
}

private func progressPath(_ project: MotionProject, progress: Double, map: PreviewMap) -> Path {
    var path = Path()
    let count = max(12, Int(ceil(progress * 160)))
    for index in 0...count {
        let fraction = progress * Double(index) / Double(count)
        let point = map.point(project.route.pose(progress: fraction).route)
        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
}

private struct MotionCanvas: View {
    let project: MotionProject
    let seconds: Double

    var body: some View {
        GeometryReader { geometry in
            let map = previewMap(canvas: project.canvas, size: geometry.size)
            let progress = project.progress(at: seconds)
            let pose = project.pose(at: seconds)
            Canvas { context, size in
                let canvasRect = CGRect(x: map.origin.x,
                                        y: map.origin.y,
                                        width: CGFloat(project.canvas.x) * map.scale,
                                        height: CGFloat(project.canvas.y) * map.scale)
                context.fill(Path(canvasRect), with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(Path(canvasRect), with: .color(.secondary.opacity(0.25)), lineWidth: 1)

                var grid = Path()
                let step = max(80, Int(project.canvas.x / 12))
                for x in stride(from: 0, through: Int(project.canvas.x), by: step) {
                    grid.move(to: map.point(Vec(x: Double(x), y: 0)))
                    grid.addLine(to: map.point(Vec(x: Double(x), y: project.canvas.y)))
                }
                for y in stride(from: 0, through: Int(project.canvas.y), by: step) {
                    grid.move(to: map.point(Vec(x: 0, y: Double(y))))
                    grid.addLine(to: map.point(Vec(x: project.canvas.x, y: Double(y))))
                }
                context.stroke(grid, with: .color(.secondary.opacity(0.08)), lineWidth: 1)

                context.stroke(bezierPath(project.segments, map: map),
                               with: .color(.blue.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                if project.drawLine {
                    context.stroke(progressPath(project, progress: progress, map: map),
                                   with: .color(.blue), lineWidth: 5)
                }

                context.drawLayer { layer in
                    let center = map.point(pose.center)
                    layer.translateBy(x: center.x, y: center.y)
                    if project.orientation == .routeTangent { layer.rotate(by: Angle(radians: pose.angle)) }
                    let width = CGFloat(project.target.size.x) * map.scale
                    let height = CGFloat(project.target.size.y) * map.scale
                    let body = Path(roundedRect: CGRect(x: -width / 2, y: -height / 2,
                                                         width: width, height: height),
                                    cornerRadius: min(12, height / 3))
                    layer.fill(body, with: .color(.orange))
                    layer.stroke(body, with: .color(.white.opacity(0.9)), lineWidth: 2)
                    var nose = Path()
                    nose.move(to: CGPoint(x: width / 2, y: 0))
                    nose.addLine(to: CGPoint(x: width / 2 - min(18, width / 3), y: -min(12, height / 3)))
                    nose.addLine(to: CGPoint(x: width / 2 - min(18, width / 3), y: min(12, height / 3)))
                    nose.closeSubpath()
                    layer.fill(nose, with: .color(.white.opacity(0.9)))
                }

                let routePoint = map.point(pose.route)
                context.fill(Path(ellipseIn: CGRect(x: routePoint.x - 5, y: routePoint.y - 5,
                                                     width: 10, height: 10)), with: .color(.red))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension PlaybackMode {
    var title: String {
        switch self { case .once: return "单次"; case .loop: return "循环"; case .pingPong: return "往返" }
    }
}

struct P1PreviewView: View {
    @ObservedObject var model: Workshop

    private var progressBinding: Binding<Double> {
        Binding(get: { model.playbackSeconds }, set: { model.setPlayback($0) })
    }
    private var anchorXBinding: Binding<Double> {
        Binding(get: { model.project.target.anchor.x }, set: { model.setAnchor(x: $0, y: nil) })
    }
    private var anchorYBinding: Binding<Double> {
        Binding(get: { model.project.target.anchor.y }, set: { model.setAnchor(x: nil, y: $0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("P1 动效预览").font(.title2.bold())
                        Text(model.projectURL?.lastPathComponent ?? "未保存的动效项目")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.projectDirty { Text("有未保存设置").font(.caption).foregroundStyle(.orange) }
                    Button("新建", action: model.newProject)
                    Button("打开项目", action: model.openProject)
                    Button("保存", action: model.saveProject)
                    Button("另存为", action: model.saveProjectAs)
                }

                MotionCanvas(project: model.project, seconds: model.playbackSeconds)
                    .frame(minHeight: 310)

                VStack(spacing: 8) {
                    HStack {
                        Button(model.playing ? "暂停" : "播放", systemImage: model.playing ? "pause.fill" : "play.fill", action: model.togglePlayback)
                            .keyboardShortcut(.space, modifiers: [])
                        Slider(value: progressBinding, in: 0...max(0.01, model.project.duration))
                        Text(String(format: "%05.2f / %05.2f 秒", model.playbackSeconds, model.project.duration))
                            .font(.system(.caption, design: .monospaced)).frame(width: 132, alignment: .trailing)
                    }
                    HStack {
                        Picker("播放模式", selection: Binding(get: { model.project.playback }, set: { model.setPlaybackMode($0) })) {
                            ForEach(PlaybackMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                        }.pickerStyle(.segmented).frame(width: 240)
                        Toggle("同步绘制路线", isOn: Binding(get: { model.project.drawLine }, set: { model.setDrawLine($0) }))
                        Picker("朝向", selection: Binding(get: { model.project.orientation }, set: { model.setOrientation($0) })) {
                            Text("固定").tag(ProjectOrientation.fixed)
                            Text("沿切线旋转").tag(ProjectOrientation.routeTangent)
                        }.frame(width: 150)
                    }
                }

                GroupBox("图片贴线位置") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("锚点是图片内部跟随路线的点，0% 为左/上，100% 为右/下。拖动后可保存到项目文件。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("X").frame(width: 18)
                            Slider(value: anchorXBinding, in: 0...1)
                            Text(String(format: "%3.0f%%", model.project.target.anchor.x * 100)).frame(width: 48, alignment: .trailing)
                        }
                        HStack {
                            Text("Y").frame(width: 18)
                            Slider(value: anchorYBinding, in: 0...1)
                            Text(String(format: "%3.0f%%", model.project.target.anchor.y * 100)).frame(width: 48, alignment: .trailing)
                        }
                    }.padding(4)
                }
            }
            .padding(20)
        }
    }
}
