import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class Workshop:ObservableObject {
    @Published var status="打开已保存的 Keynote 文稿，检查页面、对象与素材。"
    @Published var busy=false
    @Published var source:URL?
    @Published var result:[String:Any]?
    @Published var selectedSlide=0
    @Published var checks:[String]=[]
    @Published var error:String?
    @Published var project=MotionProject.sample()
    @Published var projectURL:URL?
    @Published var playbackSeconds=0.0
    @Published var playing=false
    @Published var projectDirty=false
    @Published var selectedRouteID:String?
    @Published var selectedTargetID:String?
    @Published var applyDuration=8.0
    @Published var replaceExisting=false
    private var playbackTimer:Timer?
    private var playbackOrigin:Double=0
    var resources:URL {Bundle.main.resourceURL!}
    var client:AdapterClient {AdapterClient(resources:resources)}
    var slides:[[String:Any]] {result?["slides"] as? [[String:Any]] ?? []}
    var nodes:[[String:Any]] {slides.indices.contains(selectedSlide) ? slides[selectedSlide]["nodes"] as? [[String:Any]] ?? [] : []}
    var routeCandidates:[[String:Any]] {
        nodes.filter { ($0["kind"] as? String) == "shape" && (($0["curve"] as? [[String:Any]])?.isEmpty == false) }
    }
    var targetCandidates:[[String:Any]] {
        nodes.filter {
            let kind=$0["kind"] as? String
            return ["shape","image","movie","group"].contains(kind) && ($0["id"] as? String) != selectedRouteID
        }
    }

    func label(_ node:[String:Any]) -> String {
        node["name"] as? String ?? "\(node["kind"] as? String ?? "对象") \(node["id"] as? String ?? "")"
    }

    func selectDefaults() {
        if !routeCandidates.contains(where: { $0["id"] as? String == selectedRouteID }) {
            selectedRouteID=routeCandidates.first?["id"] as? String
        }
        if !targetCandidates.contains(where: { $0["id"] as? String == selectedTargetID }) {
            selectedTargetID=(targetCandidates.first(where:{$0["curve"] == nil}) ?? targetCandidates.first)?["id"] as? String
        }
    }

    func setSelectedRoute(_ value:String) {
        selectedRouteID=value.isEmpty ? nil : value
        selectDefaults()
    }

    func setSelectedSlide(_ value:Int) {
        selectedSlide=value
        selectDefaults()
    }
    func run(_ action:@escaping () async throws -> Void) {
        guard !busy else {return}
        busy=true;error=nil
        Task {do {try await action()} catch {self.error=error.localizedDescription;status="未完成，请查看提示。"};busy=false}
    }
    func open() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"key")!];panel.canChooseDirectories=false
        if panel.runModal() == .OK,let url=panel.url {load(url)}
    }
    func load(_ url:URL) {
        run {
            self.status="正在检查文稿和素材…"
            let data=try await self.client.request("inspect",arguments:["path":url.path])
            self.source=url;self.result=data;self.selectedSlide=0
            self.selectedRouteID=nil;self.selectedTargetID=nil;self.selectDefaults()
            self.status="已读取文稿；选好路线和目标后导入到预览。"
        }
    }

    var canExport:Bool { !busy && source != nil && project.nativeExportIssue == nil && project.source.relativePath == source?.path }

    private func confirmDiscard() -> Bool {
        guard projectDirty else {return true}
        let alert=NSAlert();alert.messageText="当前项目有未保存的设置"
        alert.informativeText="继续会替换当前预览。可先取消并保存项目。"
        alert.addButton(withTitle:"继续替换");alert.addButton(withTitle:"取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func decode<T:Decodable>(_ value:[String:Any], as type:T.Type) throws -> T {
        let data=try JSONSerialization.data(withJSONObject:value,options:[])
        return try JSONDecoder().decode(type,from:data)
    }

    func importRoute() {
        guard let source,let routeID=selectedRouteID,let targetID=selectedTargetID,
              let hash=(result?["source"] as? [String:Any])?["sha256"] as? String else {
            error="请先选择路线和目标对象。";return
        }
        guard applyDuration.isFinite,(0.1...600).contains(applyDuration) else {error="时长需要在 0.1 至 600 秒之间。";return}
        guard confirmDiscard() else {return}
        let slide=selectedSlide+1, duration=applyDuration
        run {
            self.stopPlayback();self.status="正在读取曲线控制点…"
            let response=try await self.client.request("extractRoute",arguments:[
                "path":source.path,"slide":slide,"curve":routeID,"target":targetID,"sha256":hash])
            let imported=try self.decode(response,as:ImportedRoute.self)
            guard let target=imported.target,target.size.count==2 else {throw AdapterFailure(message:"未读取到目标对象尺寸。")}
            var updated=MotionProject.sample()
            updated.source=imported.source
            updated.canvas=Vec(x:imported.canvas.x,y:imported.canvas.y)
            updated.segments=imported.segments
            updated.slideID=imported.slideID;updated.routeObjectID=imported.routeObjectID;updated.targetObjectID=target.id
            updated.target=ProjectTarget(name:target.name,size:Vec(x:target.size[0],y:target.size[1]),
                                         anchor:Vec(x:0.5,y:0.5),rotationDegrees:target.rotationDegrees)
            updated.orientation = .fixed
            updated.spans=[TimeSpan(start:0,duration:duration,from:0,to:1)]
            self.project=try updated.validated();self.projectURL=nil;self.replaceExisting=false
            self.projectDirty=true;self.playbackSeconds=0
            self.status="已导入路线和目标。预览页的贴线点、朝向、描线和时长将用于生成副本。"
        }
    }

    func applyMotion() {
        guard let source,canExport else {error=project.nativeExportIssue ?? "请重新关联项目来源文稿。";return}
        let panel=NSSavePanel();panel.allowedContentTypes=[UTType(filenameExtension:"key")!]
        panel.nameFieldStringValue=source.deletingPathExtension().lastPathComponent+"_沿线动画.key"
        guard panel.runModal() == .OK,let output=panel.url else {return}
        let recipe=project,replace=replaceExisting
        run {
            let data=try JSONEncoder().encode(recipe.validated())
            let payload=try JSONSerialization.jsonObject(with:data)
            self.status="正在生成并校验 Keynote 副本…"
            let response=try await self.client.request("exportProject",arguments:[
                "source":source.path,"output":output.path,"project":payload,"replaceExisting":replace])
            self.status="已生成副本（包结构与素材校验通过）：\(response["path"] as? String ?? output.path)；请在 Keynote 中播放检查。"
            NSWorkspace.shared.activateFileViewerSelecting([output])
        }
    }
    func selfCheck() {
        run {
            let health=try await self.client.request("health")
            self.checks=try MotionChecks.run()
            self.checks.insert("内置 Python \(health["python"] ?? "")：隔离启动通过",at:0)
            guard health["isolated"] as? Bool==true,
                  (health["runtimePrefix"] as? String ?? "").hasPrefix(self.resources.path) else {throw AdapterFailure(message:"检测到运行时不在应用内。")}
            self.status="基础自检通过；原生播放结果请查看 P0 验证报告。"
        }
    }
    func copyDocument() {
        guard let source,let info=result?["source"] as? [String:Any],let hash=info["sha256"] as? String else{return}
        let panel=NSSavePanel();panel.allowedContentTypes=[UTType(filenameExtension:"key")!];panel.nameFieldStringValue=source.deletingPathExtension().lastPathComponent+"_校验副本.key"
        if panel.runModal() == .OK,let output=panel.url {
            run {self.status="正在生成并检查副本…";let r=try await self.client.request("validatedCopy",arguments:["source":source.path,"output":output.path,"sha256":hash]);self.status="已生成副本，\(r["mediaCount"] ?? 0) 项素材完整。";NSWorkspace.shared.activateFileViewerSelecting([output])}
        }
    }
    func newProject() {
        guard confirmDiscard() else {return}
        stopPlayback();project=MotionProject.sample();projectURL=nil;projectDirty=false
        playbackSeconds=0;replaceExisting=false;status="已打开示意项目；导入文稿路线后可生成副本。"
    }
    func openProject() {
        guard confirmDiscard() else {return}
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.canChooseDirectories=false
        guard panel.runModal() == .OK,let url=panel.url else {return}
        do {
            var loaded=try JSONDecoder().decode(MotionProject.self,from:Data(contentsOf:url)).validated()
            let path=loaded.source.relativePath
            let sourceURL=path.hasPrefix("/") ? URL(fileURLWithPath:path) : url.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
            loaded.source.relativePath=sourceURL.path
            stopPlayback();project=loaded;projectURL=url;projectDirty=false;playbackSeconds=0;replaceExisting=false
            source=nil;result=nil;selectedSlide=0;selectedRouteID=nil;selectedTargetID=nil
            status="项目已打开，正在检查来源…"
            if FileManager.default.fileExists(atPath:sourceURL.path),loaded.slideID != nil {restoreSource(sourceURL)}
            else {status="项目预览已恢复。来源文稿未找到，使用“重新关联来源”选择原文稿。"}
        } catch {self.error="项目无法打开："+error.localizedDescription}
    }
    func relinkSource() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"key")!]
        if panel.runModal() == .OK,let url=panel.url {restoreSource(url)}
    }
    private func restoreSource(_ url:URL) {
        let expected=project.source.sha256,sid=project.slideID,rid=project.routeObjectID,tid=project.targetObjectID
        run {
            let data=try await self.client.request("inspect",arguments:["path":url.path])
            guard (data["source"] as? [String:Any])?["sha256"] as? String == expected else {
                throw AdapterFailure(message:"所选文稿内容与保存时不同。项目预览已保留；请打开新文稿并重新导入路线。")
            }
            let slides=data["slides"] as? [[String:Any]] ?? []
            guard let index=slides.firstIndex(where:{$0["id"] as? String == sid}) else {throw AdapterFailure(message:"项目关联的幻灯片不存在。")}
            let roots=slides[index]["nodes"] as? [[String:Any]] ?? []
            guard roots.contains(where:{$0["id"] as? String == rid}),roots.contains(where:{$0["id"] as? String == tid}) else {
                throw AdapterFailure(message:"项目关联的路线或目标已不存在。")
            }
            self.source=url;self.result=data;self.selectedSlide=index;self.selectedRouteID=rid;self.selectedTargetID=tid
            if self.project.source.relativePath != url.path {self.projectDirty=true}
            self.project.source.relativePath=url.path
            self.status="已恢复来源、幻灯片、路线和目标；保存的运动设置保持不变。"
        }
    }
    func saveProject() {
        if let projectURL {writeProject(to:projectURL)} else {saveProjectAs()}
    }
    func saveProjectAs() {
        let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="动效项目.kmotion.json"
        if panel.runModal() == .OK,let url=panel.url {writeProject(to:url)}
    }
    private func writeProject(to url:URL) {
        do {let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(project.validated()).write(to:url,options:.atomic);projectURL=url;projectDirty=false;status="已保存项目设置：\(url.lastPathComponent)"}
        catch let failure {self.error="项目设置保存失败：\(failure.localizedDescription)"}
    }
    func setPlayback(_ value:Double) {stopPlayback();playbackSeconds=min(project.previewDuration,max(0,value))}
    func setPlaybackMode(_ mode:PlaybackMode) {stopPlayback();project.playback=mode;projectDirty=true;playbackSeconds=0}
    func setAnchor(x:Double?,y:Double?) {objectWillChange.send();if let x {project.target.anchor.x=x};if let y {project.target.anchor.y=y};projectDirty=true}
    func setDrawLine(_ value:Bool) {objectWillChange.send();project.drawLine=value;projectDirty=true}
    func setOrientation(_ value:ProjectOrientation) {objectWillChange.send();project.orientation=value;projectDirty=true}
    func updateEffects(_ change:(inout MotionEffects)->Void) {
        objectWillChange.send()
        var effects=project.effectSettings
        change(&effects)
        project.effects=effects
        projectDirty=true
    }
    func setCameraEnabled(_ value:Bool) { updateEffects { $0.camera.enabled=value } }
    func setArrayWaveEnabled(_ value:Bool) { updateEffects { $0.arrayWave.enabled=value } }
    func setAudioBeatsEnabled(_ value:Bool) { updateEffects { $0.audioBeats.enabled=value } }
    func importAudioTrack() {
        let panel=NSOpenPanel()
        panel.allowedContentTypes=[.audio]
        panel.canChooseDirectories=false
        guard panel.runModal() == .OK, let url=panel.url else { return }
        updateEffects { effects in
            effects.audioBeats.audioPath=url.path
            effects.audioBeats.enabled=true
        }
        status="已关联声音轨道：(url.lastPathComponent)；可用 BPM 和偏移生成卡点。"
    }
    func setLoopCount(_ value:Int) { updateEffects { $0.loopCount=max(1,min(99,value)) } }
    func addParallaxLayer() {
        updateEffects { effects in
            guard effects.parallax.count < 64 else { return }
            effects.parallax.append(ParallaxLayer(name:"视差层 (effects.parallax.count + 1)", depth:0.35 + Double(effects.parallax.count % 3) * 0.3,
                                                  size:Vec(x:260,y:120), offset:Vec(x:0,y:0)))
        }
    }
    func removeParallaxLayer() { updateEffects { if !$0.parallax.isEmpty { $0.parallax.removeLast() } } }
    func addTextCue() {
        updateEffects { effects in
            guard effects.textCues.count < 128 else { return }
            effects.textCues.append(TextCue(text:"节奏文字 (effects.textCues.count + 1)", start:0, duration:min(2, max(0.1, project.duration)), position:Vec(x:960,y:180)))
        }
    }
    func removeTextCue() { updateEffects { if !$0.textCues.isEmpty { $0.textCues.removeLast() } } }
    func setCameraPreset(_ preset:String) {
        updateEffects { effects in
            switch preset {
            case "push": effects.camera=CameraMotion(enabled:true,startCenter:Vec(x:canvasCenter().x,y:canvasCenter().y),endCenter:project.pose(at:project.duration).route,startZoom:1,endZoom:1.7)
            case "pan": effects.camera=CameraMotion(enabled:true,startCenter:project.pose(at:0).route,endCenter:project.pose(at:project.duration).route,startZoom:1.2,endZoom:1.2)
            default: effects.camera=CameraMotion()
            }
        }
    }
    private func canvasCenter() -> Vec { Vec(x:project.canvas.x / 2, y:project.canvas.y / 2) }
    func setDuration(_ value:Double) {
        guard value.isFinite,(0.1...600).contains(value),project.spans.count==1 else {return}
        stopPlayback();project.spans[0].duration=value;projectDirty=true;playbackSeconds=0
    }
    private func normalizedTimeline(_ spans:[TimeSpan]) -> [TimeSpan] {
        var start=0.0
        var progress=spans.first?.from ?? 0
        return spans.enumerated().map { index, span in
            let from=index == 0 ? min(1,max(0,span.from)) : progress
            let to=min(1,max(0,span.to))
            let duration=span.duration
            let normalized=TimeSpan(start:start,duration:duration,from:from,to:to)
            start += duration
            progress=to
            return normalized
        }
    }
    func replaceTimeline(_ spans:[TimeSpan]) {
        let normalized=normalizedTimeline(spans)
        guard normalized.count <= 32 else {error="分段数量最多 32 段。";return}
        do {
            let timeline=try Timeline(spans:normalized)
            guard timeline.duration <= 600 else {error="预览时间线总时长不能超过 600 秒。";return}
            stopPlayback();project.spans=timeline.spans;projectDirty=true;playbackSeconds=0
        } catch let failure {self.error="时间线设置无效："+failure.localizedDescription}
    }
    func editTimelineSpan(_ index:Int,duration:Double?=nil,to:Double?=nil) {
        guard project.spans.indices.contains(index) else {return}
        var spans=project.spans
        if let duration {spans[index].duration=duration}
        if let to {spans[index].to=to}
        replaceTimeline(spans)
    }
    func removeTimelineSpan(_ index:Int) {
        guard project.spans.count > 1,project.spans.indices.contains(index) else {return}
        var spans=project.spans;spans.remove(at:index);replaceTimeline(spans)
    }
    func setTimelinePreset(_ preset:String) {
        let total=max(0.1,min(600,project.duration))
        switch preset {
        case "stops":
            replaceTimeline([
                TimeSpan(start:0,duration:total*0.2,from:0,to:0.18),
                TimeSpan(start:0,duration:total*0.1,from:0.18,to:0.18),
                TimeSpan(start:0,duration:total*0.5,from:0.18,to:0.82),
                TimeSpan(start:0,duration:total*0.1,from:0.82,to:0.82),
                TimeSpan(start:0,duration:total*0.1,from:0.82,to:1)
            ])
        case "speed":
            replaceTimeline([
                TimeSpan(start:0,duration:total*0.25,from:0,to:0.2),
                TimeSpan(start:0,duration:total*0.45,from:0.2,to:0.75),
                TimeSpan(start:0,duration:total*0.3,from:0.75,to:1)
            ])
        case "reverse":
            replaceTimeline([TimeSpan(start:0,duration:total,from:1,to:0)])
        default:
            replaceTimeline([TimeSpan(start:0,duration:total,from:0,to:1)])
        }
    }
    func togglePlayback() {
        if playing {stopPlayback()} else {startPlayback()}
    }
    private func startPlayback() {
        guard project.duration>0 else {return};if playbackSeconds>=project.previewDuration {playbackSeconds=0};playing=true
        playbackOrigin=ProcessInfo.processInfo.systemUptime-playbackSeconds
        playbackTimer?.invalidate();playbackTimer=Timer.scheduledTimer(withTimeInterval:1.0/60.0,repeats:true) {[weak self] _ in
            Task { @MainActor [weak self] in self?.advancePlayback() }
        }
    }
    private func advancePlayback() {
        playbackSeconds=ProcessInfo.processInfo.systemUptime-playbackOrigin
        if project.playback == .once && playbackSeconds >= project.previewDuration {playbackSeconds=project.previewDuration;stopPlayback()}
    }
    func stopPlayback() {playbackTimer?.invalidate();playbackTimer=nil;playing=false}
    func openFixture(_ name:String) {
        let url=resources.appendingPathComponent("Fixtures/"+name)
        do {
            // Keynote auto-saves. Always open a disposable copy outside the signed bundle.
            let folder=FileManager.default.temporaryDirectory.appendingPathComponent("kmotion-sample-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let copy=folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at:url,to:copy)
            if !NSWorkspace.shared.open(copy) {error="无法打开样例，请确认已安装 Keynote。"}
        } catch {self.error="无法复制测试文稿："+error.localizedDescription}
    }
}
struct NodeRow:View {
    let node:[String:Any]
    var children:[[String:Any]] {node["children"] as? [[String:Any]] ?? []}
    var body:some View {
        if !children.isEmpty {
            DisclosureGroup {
                ForEach(children.indices,id:\.self) {NodeRow(node:children[$0])}
            } label: {Label("群组 · \(children.count) 个子项",systemImage:"square.3.layers.3d")}
        } else {
            Label(node["name"] as? String ?? "对象",systemImage:node["kind"] as? String == "image" ? "photo":"square")
                .font(.callout).lineLimit(2).padding(.vertical,4)
        }
    }
}
struct WorkshopView:View {
    @StateObject var model=Workshop()
    private var routeSelection:Binding<String> {
        Binding(get:{model.selectedRouteID ?? ""},set:{model.setSelectedRoute($0)})
    }
    private var targetSelection:Binding<String> {
        Binding(get:{model.selectedTargetID ?? ""},set:{model.selectedTargetID=$0.isEmpty ? nil : $0})
    }
    var body:some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:18) {
                Text("动效工坊").font(.title2.bold())
                Text("P3.0 · 视频动效与沿线动画").font(.subheadline).foregroundStyle(.secondary)
                Divider()
                if model.slides.isEmpty {Text("尚未导入文稿").foregroundStyle(.secondary)}
                List(model.slides.indices,id:\.self,selection:Binding(get:{model.selectedSlide},set:{model.setSelectedSlide($0)})) {i in
                    Label("幻灯片 \(i+1)",systemImage:"rectangle.on.rectangle").tag(i)
                }.listStyle(.sidebar)
                Text("现有沿线工具 1.1 仍可独立使用。新功能将在后续阶段逐项开放。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding().navigationSplitViewColumnWidth(min:210,ideal:235)
        } detail: {
            TabView {
            VStack(alignment:.leading,spacing:20) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:7) {
                        Text(model.source?.lastPathComponent ?? "建立可靠的动效基础").font(.largeTitle.bold())
                        Text("文稿检查、独立运行时、三项原生能力验证").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy {ProgressView().controlSize(.small)}
                }
                HStack {
                    Button("打开文稿",systemImage:"folder",action:model.open).keyboardShortcut("o")
                    Button("运行自检",systemImage:"checkmark.shield",action:model.selfCheck)
                    Button("生成校验副本",systemImage:"doc.on.doc",action:model.copyDocument).disabled(model.result==nil)
                }.disabled(model.busy)
                if let error=model.error {Text(error).foregroundStyle(.red).textSelection(.enabled)}
                HStack(alignment:.top,spacing:20) {
                    GroupBox("文稿对象") {
                        ScrollView {
                            VStack(alignment:.leading,spacing:8) {
                                if model.nodes.isEmpty {Text("导入后可查看对象与群组层级。\nP1 预览页可编辑运动设置并保存项目。").foregroundStyle(.secondary).padding(.vertical,35)}
                                ForEach(model.nodes.indices,id:\.self) {NodeRow(node:model.nodes[$0])}
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(12)
                        }
                    }.frame(maxWidth:.infinity)
                    VStack(alignment:.leading,spacing:16) {
                        GroupBox("选择路线与目标") {
                            VStack(alignment:.leading,spacing:10) {
                                Picker("路线",selection:routeSelection) {
                                    Text("未选择").tag("")
                                    ForEach(model.routeCandidates.indices,id:\.self) { index in
                                        let node=model.routeCandidates[index]
                                        Text(model.label(node)).tag(node["id"] as? String ?? "")
                                    }
                                }
                                Picker("目标",selection:targetSelection) {
                                    Text("未选择").tag("")
                                    ForEach(model.targetCandidates.indices,id:\.self) { index in
                                        let node=model.targetCandidates[index]
                                        Text(model.label(node)).tag(node["id"] as? String ?? "")
                                    }
                                }
                                HStack {
                                    Text("时长")
                                    TextField("秒",value:$model.applyDuration,format:.number.precision(.fractionLength(1)))
                                        .frame(width:58)
                                    Text("秒")
                                }
                                HStack {
                                    Button("导入到预览",systemImage:"point.topleft.down.curvedto.point.bottomright.up") {model.importRoute()}
                                }
                                Text("可选择整组移动。导入后请到预览页调整参数并生成副本。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                        }
                        GroupBox("三项专项样例") {
                            VStack(alignment:.leading,spacing:14) {
                                Button("1. 非中心贴线与转向") {model.openFixture("01_anchor.key")}
                                Button("2. 两次停靠与三段速度") {model.openFixture("02_timing.key")}
                                Button("3. 图片文字嵌套群组") {model.openFixture("03_group.key")}
                                Text("在 Keynote 中打开样例副本，进入播放后按空格开始。支持范围以验证报告为准。").font(.caption).foregroundStyle(.secondary)
                            }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                        }
                        GroupBox("自检结果") {
                            VStack(alignment:.leading,spacing:10) {
                                if model.checks.isEmpty {Text("点击“运行自检”检查内置环境和运动数学。").foregroundStyle(.secondary)}
                                ForEach(model.checks,id:\.self) {Text("✓ "+$0).font(.callout)}
                            }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                        }
                        Button("查看 P0 验证报告") {NSWorkspace.shared.open(model.resources.appendingPathComponent("Docs/P0验证报告.md"))}
                    }.frame(width:300)
                }.frame(maxHeight:.infinity)
                Divider()
                Text(model.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(28)
            .tabItem { Label("文稿与对象",systemImage:"checkmark.shield") }
            P1PreviewView(model:model)
                .tabItem { Label("预览与导出",systemImage:"play.rectangle") }
            }
        }.disabled(model.busy).frame(minWidth:1080,minHeight:720)
    }
}
@main struct MotionWorkshopApp:App {
    init() {
        if CommandLine.arguments.contains("--self-test") {
            do {for line in try MotionChecks.run() {print(line)};exit(0)} catch {fputs("MotionCore checks failed\n",stderr);exit(1)}
        }
    }
    var body:some Scene {WindowGroup("Keynote 动效工坊") {WorkshopView()}.windowStyle(.titleBar)}
}
