import Foundation

struct Vec: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    static func + (a: Vec, b: Vec) -> Vec { Vec(x:a.x+b.x,y:a.y+b.y) }
    static func - (a: Vec, b: Vec) -> Vec { Vec(x:a.x-b.x,y:a.y-b.y) }
    static func * (a: Vec, s: Double) -> Vec { Vec(x:a.x*s,y:a.y*s) }
    var length: Double { hypot(x,y) }
    func rotated(_ a: Double) -> Vec { Vec(x:cos(a)*x-sin(a)*y,y:sin(a)*x+cos(a)*y) }
}
struct Cubic: Codable, Sendable {
    var p0,p1,p2,p3: Vec
    func point(_ t: Double) -> Vec {
        let u=1-t
        return p0*(u*u*u)+p1*(3*u*u*t)+p2*(3*u*t*t)+p3*(t*t*t)
    }
    func tangent(_ t: Double) -> Vec {
        let u=1-t
        let d=(p1-p0)*(3*u*u)+(p2-p1)*(6*u*t)+(p3-p2)*(3*t*t)
        if d.length>1e-10 { return d }
        return point(min(1,t+0.0001))-point(max(0,t-0.0001))
    }
    func split(_ t: Double) -> (Cubic,Cubic) {
        let a=p0+(p1-p0)*t,b=p1+(p2-p1)*t,c=p2+(p3-p2)*t
        let d=a+(b-a)*t,e=b+(c-b)*t,f=d+(e-d)*t
        return (Cubic(p0:p0,p1:a,p2:d,p3:f),Cubic(p0:f,p1:e,p2:c,p3:p3))
    }
}
/// Adaptive arc-length lookup shared by scrubber, pose sampler and export plan.
struct Route: Sendable {
    struct Entry: Sendable { var distance:Double; var segment:Int; var t:Double; var p:Vec }
    var segments:[Cubic]
    var table:[Entry]=[]
    var length:Double { table.last?.distance ?? 0 }
    init(_ segments:[Cubic], tolerance:Double=0.02) {
        self.segments=segments
        guard let first=segments.first else { return }
        table=[Entry(distance:0,segment:0,t:0,p:first.p0)]
        for (i,c) in segments.enumerated() {
            func flatten(_ part:Cubic,_ lo:Double,_ hi:Double,_ depth:Int) {
                let chord=(part.p3-part.p0).length
                let polygon=(part.p1-part.p0).length+(part.p2-part.p1).length+(part.p3-part.p2).length
                // Subdivide even straight cubics: parameter t need not be proportional to length.
                if depth>=18 || (polygon-chord<tolerance && hi-lo<=1.0/64) {
                    let previous=table.last!
                    table.append(Entry(distance:previous.distance+(part.p3-previous.p).length,segment:i,t:hi,p:part.p3))
                } else {
                    let (a,b)=part.split(0.5),mid=(lo+hi)/2
                    flatten(a,lo,mid,depth+1); flatten(b,mid,hi,depth+1)
                }
            }
            // An explicit t=0 entry removes ambiguity at segment boundaries.
            if i>0 { table.append(Entry(distance:length,segment:i,t:0,p:c.p0)) }
            flatten(c,0,1,0)
        }
    }
    func pose(progress:Double, anchorOffset:Vec=Vec(x:0,y:0)) -> Pose {
        guard !table.isEmpty else { return Pose(route:Vec(x:0,y:0),center:Vec(x:0,y:0),angle:0) }
        let s=min(1,max(0,progress))*length
        var lo=0,hi=table.count-1
        while lo<hi { let m=(lo+hi)/2; if table[m].distance<s {lo=m+1} else {hi=m} }
        let b=table[lo],a=table[max(0,lo-1)]
        let fraction=b.distance>a.distance ? (s-a.distance)/(b.distance-a.distance) : 0
        let t=a.segment==b.segment ? a.t+(b.t-a.t)*fraction : b.t*fraction
        let c=segments[b.segment],p=c.point(t),d=c.tangent(t),angle=atan2(d.y,d.x)
        return Pose(route:p,center:p-anchorOffset.rotated(angle),angle:angle)
    }
}
struct Pose: Codable,Sendable { var route,center:Vec;var angle:Double }
struct TimeSpan: Codable,Sendable {
    var start:Double
    var duration:Double
    var from:Double
    var to:Double
    var isHold:Bool { from==to }
}
struct Timeline: Codable,Sendable {
    var spans:[TimeSpan]
    var duration:Double { spans.last.map{$0.start+$0.duration} ?? 0 }
    init(spans:[TimeSpan]) throws {
        var end=0.0,progress=0.0
        for s in spans {
            guard s.start.isFinite,s.duration.isFinite,s.from.isFinite,s.to.isFinite,
                  s.duration>0,abs(s.start-end)<1e-8,abs(s.from-progress)<1e-8,
                  (0...1).contains(s.to) else { throw MotionError.invalidTimeline }
            end=s.start+s.duration;progress=s.to
        }
        guard !spans.isEmpty else {throw MotionError.invalidTimeline}
        self.spans=spans
    }
    func progress(at seconds:Double) -> Double {
        let t=min(duration,max(0,seconds))
        guard let s=spans.first(where:{t<$0.start+$0.duration}) ?? spans.last else {return 0}
        return s.from+(s.to-s.from)*min(1,max(0,(t-s.start)/s.duration))
    }
}
enum MotionError:Error {case invalidTimeline}

struct MotionChecks {
    static func run() throws -> [String] {
        let c=Cubic(p0:Vec(x:0,y:0),p1:Vec(x:150,y:0),p2:Vec(x:0,y:250),p3:Vec(x:300,y:250))
        let route=Route([c]),offset=Vec(x:60,y:-20)
        var error=0.0
        for i in 0...1000 {
            let p=route.pose(progress:Double(i)/1000,anchorOffset:offset)
            error=max(error,(p.center+offset.rotated(p.angle)-p.route).length)
        }
        guard error<1e-8 else {throw MotionError.invalidTimeline}
        let clock=try Timeline(spans:[TimeSpan(start:0,duration:2,from:0,to:0.3),TimeSpan(start:2,duration:1,from:0.3,to:0.3),TimeSpan(start:3,duration:4,from:0.3,to:0.7),TimeSpan(start:7,duration:1,from:0.7,to:0.7),TimeSpan(start:8,duration:1,from:0.7,to:1)])
        guard clock.progress(at:2.5)==0.3,clock.progress(at:7.5)==0.7,clock.progress(at:9)==1 else {throw MotionError.invalidTimeline}
        let (a,b)=c.split(0.4)
        guard (a.p3-b.p0).length<1e-10,(a.p3-c.point(0.4)).length<1e-10 else {throw MotionError.invalidTimeline}
        return ["1001 个非中心贴线姿态：几何误差 < 0.000001 点","两次停靠、三段速度：共用时间函数通过","曲线拆分：接点连续通过（不等于 Keynote 播放验收）"]
    }
}
