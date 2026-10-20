import Foundation
@main struct CompileProbe {
    static func main() throws {
        let input=URL(fileURLWithPath:CommandLine.arguments[1])
        let cubics=try JSONDecoder().decode([Cubic].self,from:Data(contentsOf:input))
        let route=Route(cubics)
        let durations=[2.0,4.0,1.0]
        var spans=[TimeSpan](),elapsed=0.0,distance=0.0
        for (i,c) in cubics.enumerated() {
            let length=Route([c]).length
            let from=distance/route.length
            distance+=length
            let to=i==cubics.count-1 ? 1 : distance/route.length
            spans.append(TimeSpan(start:elapsed,duration:durations[i],from:from,to:to));elapsed+=durations[i]
            if i<cubics.count-1 {spans.append(TimeSpan(start:elapsed,duration:1,from:to,to:to));elapsed+=1}
        }
        let timeline=try Timeline(spans:spans)
        struct IR:Codable {var version:Int;var segments:[Cubic];var timeline:Timeline;var anchorOffset:Vec;var samples:[Pose]}
        let output=IR(version:1,segments:cubics,timeline:timeline,anchorOffset:Vec(x:40,y:0),samples:(0...270).map {route.pose(progress:timeline.progress(at:Double($0)/30),anchorOffset:Vec(x:40,y:0))})
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(output).write(to:URL(fileURLWithPath:CommandLine.arguments[2]),options:.atomic)
    }
}
