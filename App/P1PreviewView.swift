import SwiftUI

private struct PreviewMap {
    let scale: CGFloat
    let canvas: Vec
    let size: CGSize
    let camera: CameraTransform

    func point(_ value: Vec) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGPoint(x: center.x + CGFloat(value.x - camera.center.x) * scale * CGFloat(camera.zoom),
                       y: center.y + CGFloat(value.y - camera.center.y) * scale * CGFloat(camera.zoom))
    }
}

private func previewMap(canvas: Vec, size: CGSize, camera: CameraTransform) -> PreviewMap {
    let padding: CGFloat = 24
    let scale = max(0.001, min((size.width - padding * 2) / CGFloat(max(1, canvas.x)),
                    (size.height - padding * 2) / CGFloat(max(1, canvas.y))))
    return PreviewMap(scale: scale, canvas: canvas, size: size, camera: camera)
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
    let route = project.route
    for index in 0...count {
        let fraction = progress * Double(index) / Double(count)
        let point = map.point(route.pose(progress: fraction).route)
        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
}

private struct MotionCanvas: View {
    let project: MotionProject
    let seconds: Double

    var body: some View {
        GeometryReader { geometry in
            let map = previewMap(canvas: project.canvas, size: geometry.size, camera: project.camera(at: seconds))
            let progress = project.progress(at: seconds)
            let pose = project.pose(at: seconds)
            Canvas { context, size in
                let topLeft = map.point(Vec(x: 0, y: 0))
                let bottomRight = map.point(project.canvas)
                let canvasRect = CGRect(x: min(topLeft.x, bottomRight.x),
                                        y: min(topLeft.y, bottomRight.y),
                                        width: abs(bottomRight.x - topLeft.x),
                                        height: abs(bottomRight.y - topLeft.y))
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

                // Parallax layers are deliberately drawn as editable proxy cards;
                // the layer depth and offset are persisted and can later bind to
                // the corresponding Keynote objects.
                for (index, item) in project.parallaxOffsets(at: seconds).enumerated() {
                    let layer = item.0
                    let center = map.point(item.1)
                    let width = CGFloat(layer.size.x) * map.scale * CGFloat(map.camera.zoom)
                    let height = CGFloat(layer.size.y) * map.scale * CGFloat(map.camera.zoom)
                    let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 12), with: .color(.purple.opacity(0.10 + 0.04 * Double(index % 4))))
                    context.stroke(Path(roundedRect: rect, cornerRadius: 12), with: .color(.purple.opacity(0.42)), lineWidth: 1.5)
                }

                for (index, item) in project.arrayPoses(at: seconds).enumerated() {
                    let itemPose = item
                    context.drawLayer { layer in
                    let center = map.point(itemPose.center)
                    layer.translateBy(x: center.x, y: center.y)
                    layer.rotate(by: Angle(radians: itemPose.angle))
                    let width = CGFloat(project.target.size.x) * map.scale * CGFloat(map.camera.zoom)
                    let height = CGFloat(project.target.size.y) * map.scale * CGFloat(map.camera.zoom)
                    let body = Path(roundedRect: CGRect(x: -width / 2, y: -height / 2,
                                                         width: width, height: height),
                                    cornerRadius: min(12, height / 3))
                    layer.fill(body, with: .color(index == project.arrayPoses(at: seconds).count / 2 ? .orange : .orange.opacity(0.35)))
                    layer.stroke(body, with: .color(.white.opacity(0.9)), lineWidth: 2)
                    var nose = Path()
                    nose.move(to: CGPoint(x: width / 2, y: 0))
                    nose.addLine(to: CGPoint(x: width / 2 - min(18, width / 3), y: -min(12, height / 3)))
                    nose.addLine(to: CGPoint(x: width / 2 - min(18, width / 3), y: min(12, height / 3)))
                    nose.closeSubpath()
                    layer.fill(nose, with: .color(.white.opacity(0.9)))
                }
                }

                for cue in project.visibleTextCues(at: seconds) {
                    let text = Text(cue.0.text).font(.system(size: 26, weight: .semibold)).foregroundColor(.primary)
                    let center = map.point(cue.0.position)
                    context.drawLayer { layer in
                        layer.translateBy(x: center.x, y: center.y)
                        layer.scaleBy(x: CGFloat(cue.2), y: CGFloat(cue.2))
                        layer.opacity = cue.1
                        layer.draw(text, at: .zero)
                    }
                }

                let routePoint = map.point(pose.route)
                context.fill(Path(ellipseIn: CGRect(x: routePoint.x - 5, y: routePoint.y - 5,
                                                     width: 10, height: 10)), with: .color(.red))
                if project.effectSettings.audioBeats.enabled {
                    let beat = project.beatMarker(at: seconds) ?? 0
                    let beatPoint = map.point(Vec(x: project.canvas.x * min(1, max(0, beat / max(0.001, project.duration))), y: 24))
                    context.fill(Path(ellipseIn: CGRect(x: beatPoint.x - 4, y: beatPoint.y - 4, width: 8, height: 8)), with: .color(.pink))
                }
            }
        }
        .aspectRatio(project.canvas.x / max(1, project.canvas.y), contentMode: .fit)
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
        Binding(get: { model.project.playhead(at: model.playbackSeconds) }, set: { model.setPlayback($0) })
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
                        Text("运动预览与导出").font(.title2.bold())
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
                Text("几何示意：橙色块表示目标边框，红点表示贴线点；图片内容与 Keynote 实际渲染需在副本中检查。")
                    .font(.caption).foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    HStack {
                        Button(model.playing ? "暂停" : "播放", systemImage: model.playing ? "pause.fill" : "play.fill", action: model.togglePlayback)
                            .keyboardShortcut(.space, modifiers: [])
                        Slider(value: progressBinding, in: 0...max(0.01, model.project.previewDuration))
                        Text(String(format: "%05.2f / %05.2f 秒", model.project.playhead(at: model.playbackSeconds), model.project.previewDuration))
                            .font(.system(.caption, design: .monospaced)).frame(width: 132, alignment: .trailing)
                    }
                    HStack {
                        Button("起点") { model.setPlayback(0) }
                        Button("上一帧") { model.setPlayback(model.project.playhead(at:model.playbackSeconds) - 1 / Double(model.project.fps)) }
                        Button("下一帧") { model.setPlayback(model.project.playhead(at:model.playbackSeconds) + 1 / Double(model.project.fps)) }
                        if model.project.spans.count == 1 {
                            Text("时长")
                            TextField("秒", value: Binding(get:{model.project.duration},set:{model.setDuration($0)}), format:.number)
                                .frame(width:65)
                            Text("秒")
                        }
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

                GroupBox("分段时间线") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("分段会共用路线和对象的时间进度；from/to 相同表示停靠，to 小于 from 表示反向。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("全程") { model.setTimelinePreset("full") }
                            Button("两次停靠") { model.setTimelinePreset("stops") }
                            Button("三段速度") { model.setTimelinePreset("speed") }
                            Button("反向") { model.setTimelinePreset("reverse") }
                            Spacer()
                            Text(String(format: "总时长 %.1f 秒", model.project.duration))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.project.spans.enumerated()), id: \.offset) { index, span in
                            HStack(spacing: 8) {
                                Text("\(index + 1)").frame(width: 20)
                                Text(String(format: "%.1f–%.1f", span.from, span.to))
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 84, alignment: .leading)
                                Text("时长")
                                TextField("秒",
                                          value: Binding(
                                            get: { model.project.spans[index].duration },
                                            set: { model.editTimelineSpan(index, duration: $0) }),
                                          format: .number.precision(.fractionLength(1)))
                                    .frame(width: 58)
                                Text("到")
                                TextField("进度",
                                          value: Binding(
                                            get: { model.project.spans[index].to },
                                            set: { model.editTimelineSpan(index, to: $0) }),
                                          format: .number.precision(.fractionLength(2)))
                                    .frame(width: 58)
                                if model.project.spans.count > 1 {
                                    Button("删除", systemImage: "minus.circle") {
                                        model.removeTimelineSpan(index)
                                    }.labelStyle(.iconOnly)
                                }
                            }
                        }
                        if let error = model.error {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        Text("复杂分段目前用于预览和项目保存；生成 Keynote 副本前会明确提示尚未支持的组合。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                GroupBox("对象 / 群组贴线位置") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("锚点以对象或群组边框为准，0% 为左/上，100% 为右/下。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("中心") {model.setAnchor(x:0.5,y:0.5)}
                            Button("左侧中点") {model.setAnchor(x:0,y:0.5)}
                            Button("右侧中点") {model.setAnchor(x:1,y:0.5)}
                            Button("底部中点") {model.setAnchor(x:0.5,y:1)}
                        }
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
                GroupBox("视频动效工具") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("六类特效都在同一份项目中保存，可直接播放预览；复杂特效会在生成 Keynote 副本前给出能力提示。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Toggle("模拟镜头运镜", isOn: Binding(get: { model.project.effectSettings.camera.enabled }, set: { model.setCameraEnabled($0) }))
                            Button("推近") { model.setCameraPreset("push") }
                            Button("跟随平移") { model.setCameraPreset("pan") }
                            Button("清除镜头") { model.setCameraPreset("clear") }
                        }
                        HStack {
                            Text("镜头缩放")
                            Slider(value: Binding(get: { model.project.effectSettings.camera.startZoom }, set: { value in model.updateEffects { effects in effects.camera.startZoom = value } }), in: 0.1...4)
                                .disabled(!model.project.effectSettings.camera.enabled)
                            Text(String(format: "%.1fx → %.1fx", model.project.effectSettings.camera.startZoom, model.project.effectSettings.camera.endZoom))
                                .frame(width: 100, alignment: .trailing)
                        }
                        HStack {
                            Text("结束缩放")
                            Slider(value: Binding(get: { model.project.effectSettings.camera.endZoom }, set: { value in model.updateEffects { effects in effects.camera.endZoom = value } }), in: 0.1...4)
                                .disabled(!model.project.effectSettings.camera.enabled)
                        }
                        HStack {
                            Toggle("分层视差", isOn: Binding(get: { !model.project.effectSettings.parallax.isEmpty }, set: { value in if value { model.addParallaxLayer() } else { model.updateEffects { $0.parallax.removeAll() } } }))
                            Text("层数 (model.project.effectSettings.parallax.count)")
                            Button("增加层") { model.addParallaxLayer() }
                            Button("移除层") { model.removeParallaxLayer() }
                        }
                        ForEach(Array(model.project.effectSettings.parallax.enumerated()), id: \.element.id) { index, layer in
                            HStack {
                                Text(layer.name).frame(width: 90, alignment: .leading)
                                Text("深度")
                                Slider(value: Binding(get: { model.project.effectSettings.parallax[index].depth }, set: { value in model.updateEffects { effects in effects.parallax[index].depth = value } }), in: -1...2)
                                Text(String(format: "%.1f", layer.depth)).frame(width: 34)
                            }
                        }
                        HStack {
                            Toggle("文字动效编排", isOn: Binding(get: { !model.project.effectSettings.textCues.isEmpty }, set: { value in if value { model.addTextCue() } else { model.updateEffects { $0.textCues.removeAll() } } }))
                            Text("文字段落 (model.project.effectSettings.textCues.count)")
                            Button("增加文字段") { model.addTextCue() }
                            Button("移除文字段") { model.removeTextCue() }
                        }
                        ForEach(Array(model.project.effectSettings.textCues.enumerated()), id: \.element.id) { index, cue in
                            HStack {
                                TextField("文字", text: Binding(get: { model.project.effectSettings.textCues[index].text }, set: { value in model.updateEffects { effects in effects.textCues[index].text = value } }))
                                Text("起始")
                                TextField("秒", value: Binding(get: { model.project.effectSettings.textCues[index].start }, set: { value in model.updateEffects { effects in effects.textCues[index].start = value } }), format: .number)
                                    .frame(width: 55)
                                Text("时长")
                                TextField("秒", value: Binding(get: { model.project.effectSettings.textCues[index].duration }, set: { value in model.updateEffects { effects in effects.textCues[index].duration = value } }), format: .number)
                                    .frame(width: 55)
                            }
                        }
                        HStack {
                            Toggle("阵列与波浪", isOn: Binding(get: { model.project.effectSettings.arrayWave.enabled }, set: { model.setArrayWaveEnabled($0) }))
                            Text("数量")
                            Stepper(value: Binding(get: { model.project.effectSettings.arrayWave.count }, set: { value in model.updateEffects { effects in effects.arrayWave.count = value } }), in: 1...32) { Text("\(model.project.effectSettings.arrayWave.count)") }
                            Text("幅度")
                            Slider(value: Binding(get: { model.project.effectSettings.arrayWave.amplitude }, set: { value in model.updateEffects { effects in effects.arrayWave.amplitude = value } }), in: 0...200)
                        }
                        HStack {
                            Toggle("声音卡点", isOn: Binding(get: { model.project.effectSettings.audioBeats.enabled }, set: { model.setAudioBeatsEnabled($0) }))
                            Button(model.project.effectSettings.audioBeats.audioPath == nil ? "选择音频" : "更换音频") { model.importAudioTrack() }
                            Text("BPM")
                            TextField("120", value: Binding(get: { model.project.effectSettings.audioBeats.bpm }, set: { value in model.updateEffects { effects in effects.audioBeats.bpm = value } }), format: .number)
                                .frame(width: 58)
                            Text("每拍节奏标记会显示在预览中")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let audioPath=model.project.effectSettings.audioBeats.audioPath {
                            Text(URL(fileURLWithPath: audioPath).lastPathComponent)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("循环次数")
                            Stepper(value: Binding(get: { model.project.effectSettings.loopCount }, set: { model.setLoopCount($0) }), in: 1...9) { Text("\(model.project.effectSettings.loopCount) 次") }
                            Text("循环与往返可组合预览")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(4)
                }
                GroupBox("生成 Keynote 副本") {
                    VStack(alignment:.leading,spacing:8) {
                        Text(model.project.target.name).font(.caption)
                        if let issue=model.project.nativeExportIssue {Text(issue).foregroundStyle(.secondary)}
                        Toggle("替换所选对象原有动画",isOn:$model.replaceExisting)
                        Text("仅在副本中替换目标和所选描线路线的动画；其余对象动画保留。").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("重新关联来源",action:model.relinkSource)
                            Button("生成副本",systemImage:"arrow.down.doc",action:model.applyMotion).disabled(!model.canExport)
                        }
                        if let error=model.error {Text(error).foregroundStyle(.red).textSelection(.enabled)}
                        Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
                }
            }
            .padding(20)
        }
    }
}
