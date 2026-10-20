import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct ImportedCanvas: Decodable {
    var x: Double
    var y: Double
}

private struct ImportedTarget: Decodable {
    var id: String
    var name: String
    var kind: String
    var size: [Double]
}

private struct ImportedRoute: Decodable {
    var sceneVersion: Int
    var slide: Int
    var slideID: String
    var routeObjectID: String
    var segments: [Cubic]
    var target: ImportedTarget?
    var canvas: ImportedCanvas
    var source: ProjectSource
}

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
    @Published var applyDraw=true
    @Published var applyAlign=true
    private var playbackTimer:Timer?
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
            return ["shape","image","movie"].contains(kind) && ($0["id"] as? String) != selectedRouteID
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
            selectedTargetID=targetCandidates.first?["id"] as? String
        }
    }

    func setSelectedSlide(_ value:Int) {
        selectedSlide=value
        selectDefaults()
    }
    func run(_ action:@escaping () async throws -> Void) {
        busy=true;error=nil
        Task {do {try await action()} catch {self.error=error.localizedDescription;status="未完成，请查看提示。"};busy=false}
    }
    func open() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"key")!];panel.canChooseDirectories=false
        if panel.runModal() == .OK,let url=panel.url {load(url)}
    }
    func load(_ url:URL) {
        run {self.status="正在检查文稿和素材…";let data=try await self.client.request("inspect",arguments:["path":url.path]);self.source=url;self.result=data;self.selectedSlide=0
            self.selectDefaults()
            let hash=(data["source"] as? [String:Any])?["sha256"] as? String ?? ""
            self.project.source=ProjectSource(relativePath:url.path,sha256:hash)
            self.projectDirty=true;self.playbackSeconds=0
            self.status="已导入 \(self.slides.count) 页，素材引用检查通过；可选择路线和目标对象。"}
    }

    private func decode<T:Decodable>(_ value:[String:Any], as type:T.Type) throws -> T {
        let data=try JSONSerialization.data(withJSONObject:value,options:[])
        return try JSONDecoder().decode(type,from:data)
    }

    func importRoute() {
        guard let source,let routeID=selectedRouteID else {
            error="请先选择一条 Keynote 曲线。";return
        }
        let slide=selectedSlide+1
        run {
            self.status="正在读取曲线控制点…"
            var args:[String:Any]=["path":source.path,"slide":slide,"curve":routeID]
            if let targetID=self.selectedTargetID {args["target"]=targetID}
            let response=try await self.client.request("extractRoute",arguments:args)
            let imported=try self.decode(response,as:ImportedRoute.self)
            var updated=self.project
            updated.source=imported.source
            updated.canvas=Vec(x:imported.canvas.x,y:imported.canvas.y)
            updated.segments=imported.segments
            updated.slideID=imported.slideID
            updated.routeObjectID=imported.routeObjectID
            updated.targetObjectID=imported.target?.id
            if let target=imported.target,target.size.count==2 {
                updated.target=ProjectTarget(name:target.name,
                                             size:Vec(x:target.size[0],y:target.size[1]),
                                             anchor:Vec(x:0.5,y:0.5))
            }
            updated.spans=[TimeSpan(start:0,duration:max(0.1,self.applyDuration),from:0,to:1)]
            self.project=updated
            self.projectDirty=true
            self.playbackSeconds=0
            self.status="已导入 \(imported.segments.count) 段曲线；可预览或写回 Keynote 动画。"
        }
    }

    func applyMotion() {
        guard let source,let routeID=selectedRouteID,let targetID=selectedTargetID else {
            error="请先选择路线和目标对象。";return
        }
        guard routeID != targetID else {error="路线和目标对象必须不同。";return}
        let panel=NSSavePanel()
        panel.allowedContentTypes=[UTType(filenameExtension:"key")!]
        panel.nameFieldStringValue=source.deletingPathExtension().lastPathComponent+"_P2沿线动画.key"
        guard panel.runModal() == .OK,let output=panel.url else {return}
        let hash=(result?["source"] as? [String:Any])?["sha256"] as? String ?? ""
        let slide=selectedSlide+1
        run {
            self.status="正在把路线写回 Keynote 副本…"
            let response=try await self.client.request("applyMotion",arguments:[
                "source":source.path,"output":output.path,"sha256":hash,
                "slide":slide,"curve":routeID,"target":targetID,
                "duration":self.applyDuration,"draw":self.applyDraw,
                "align":self.applyAlign
            ])
            self.status="已生成并校验副本：\(response["path"] as? String ?? output.path)"
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
        stopPlayback();project=MotionProject.sample(sourcePath:source?.path ?? "",sha256:(result?["source"] as? [String:Any])?["sha256"] as? String ?? "")
        projectURL=nil;projectDirty=true;playbackSeconds=0;status="已建立新的 P1 动效项目。";selectDefaults()
    }
    func openProject() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];panel.canChooseDirectories=false
        if panel.runModal() == .OK,let url=panel.url {
            do {project=try JSONDecoder().decode(MotionProject.self,from:Data(contentsOf:url));projectURL=url;projectDirty=false;playbackSeconds=0;status="已打开项目设置：\(url.lastPathComponent)"}
            catch let failure {self.error="项目文件无法打开：\(failure.localizedDescription)"}
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
        do {let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(project).write(to:url,options:.atomic);projectURL=url;projectDirty=false;status="已保存项目设置：\(url.lastPathComponent)"}
        catch let failure {self.error="项目设置保存失败：\(failure.localizedDescription)"}
    }
    func setPlayback(_ value:Double) {playbackSeconds=min(project.duration,max(0,value))}
    func setPlaybackMode(_ mode:PlaybackMode) {project.playback=mode;projectDirty=true;playbackSeconds=0}
    func setAnchor(x:Double?,y:Double?) {objectWillChange.send();if let x {project.target.anchor.x=x};if let y {project.target.anchor.y=y};projectDirty=true}
    func setDrawLine(_ value:Bool) {objectWillChange.send();project.drawLine=value;projectDirty=true}
    func setOrientation(_ value:ProjectOrientation) {objectWillChange.send();project.orientation=value;projectDirty=true}
    func togglePlayback() {
        if playing {stopPlayback()} else {startPlayback()}
    }
    private func startPlayback() {
        guard project.duration>0 else {return};if playbackSeconds>=project.duration {playbackSeconds=0};playing=true
        playbackTimer?.invalidate();playbackTimer=Timer.scheduledTimer(withTimeInterval:1.0/60.0,repeats:true) {[weak self] _ in
            Task { @MainActor [weak self] in self?.advancePlayback() }
        }
    }
    private func advancePlayback() {
        playbackSeconds += 1.0/60.0
        if project.playback == .once && playbackSeconds >= project.duration {playbackSeconds=project.duration;stopPlayback()}
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
        Binding(get:{model.selectedRouteID ?? ""},set:{model.selectedRouteID=$0.isEmpty ? nil : $0})
    }
    private var targetSelection:Binding<String> {
        Binding(get:{model.selectedTargetID ?? ""},set:{model.selectedTargetID=$0.isEmpty ? nil : $0})
    }
    var body:some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:18) {
                Text("动效工坊").font(.title2.bold())
                Text("P0 已验证 · P1 预览 · P2 路线导入").font(.subheadline).foregroundStyle(.secondary)
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
                        GroupBox("P2 路线导入与写回") {
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
                                    Toggle("同步绘制",isOn:$model.applyDraw)
                                }
                                Toggle("沿路线切线旋转",isOn:$model.applyAlign)
                                HStack {
                                    Button("导入曲线",systemImage:"point.topleft.down.curvedto.point.bottomright.up") {model.importRoute()}
                                    Button("写回副本",systemImage:"arrow.down.doc") {model.applyMotion()}
                                }
                                Text("只处理当前幻灯片的根级路线和目标对象；副本不会覆盖原文稿。")
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
            .tabItem { Label("P0 文稿验证",systemImage:"checkmark.shield") }
            P1PreviewView(model:model)
                .tabItem { Label("P1 动效预览",systemImage:"play.rectangle") }
            }
        }.frame(minWidth:980,minHeight:650)
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
