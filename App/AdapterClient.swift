import Foundation

struct AdapterFailure: LocalizedError {
    var message:String
    var errorDescription:String? { message }
}
struct AdapterClient: Sendable {
    var resources:URL
    func request(_ operation:String, arguments:[String:Any]=[:]) async throws -> [String:Any] {
        let id=UUID().uuidString
        let input=try JSONSerialization.data(withJSONObject:["protocol":1,"id":id,"operation":operation,"arguments":arguments])
        let root=resources
        let data=try await Task.detached(priority:.userInitiated) {
            try Self.execute(input, resources:root)
        }.value
        guard let response=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              response["id"] as? String==id,response["protocol"] as? Int==1 else {
            throw AdapterFailure(message:"文稿处理接口返回了无效结果。")
        }
        guard response["ok"] as? Bool==true,let result=response["result"] as? [String:Any] else {
            let message=(response["error"] as? [String:Any])?["message"] as? String ?? "文稿处理失败。"
            throw AdapterFailure(message:message)
        }
        return result
    }
    // Blocking pipe reads stay in a synchronous worker, off the UI actor.
    private static func execute(_ input:Data, resources root:URL) throws -> Data {
            let process=Process(),out=Pipe(),err=Pipe(),stdin=Pipe()
            process.executableURL=root.appendingPathComponent("runtime/bin/python3")
            let adapter=root.appendingPathComponent("KeynoteAdapter/adapter.py").path
            process.arguments=["-I","-S",adapter]
            process.environment=["PATH":"/usr/bin:/bin","HOME":NSHomeDirectory(),"LANG":"en_US.UTF-8","PYTHONDONTWRITEBYTECODE":"1"]
            process.standardOutput=out;process.standardError=err;process.standardInput=stdin
            try process.run()
            let timer=DispatchSource.makeTimerSource(queue:.global())
            timer.schedule(deadline:.now()+120)
            timer.setEventHandler { if process.isRunning {process.terminate()} }
            timer.resume()
            defer {timer.cancel()}
            // Drain stderr independently so a Python traceback cannot block stdout.
            let group=DispatchGroup();group.enter()
            DispatchQueue.global().async { _=err.fileHandleForReading.readDataToEndOfFile();group.leave() }
            try stdin.fileHandleForWriting.write(contentsOf:input)
            try stdin.fileHandleForWriting.close()
            let response=out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit();group.wait()
            guard process.terminationStatus==0 else {throw AdapterFailure(message:"文稿处理未完成或超时，请重试。")}
            return response
    }
}
