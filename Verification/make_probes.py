"""Experimental native encodings. Not exposed as supported production exports."""
import hashlib,json,math,struct,sys,zlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'KeynoteAdapter'))
from adapter import SceneDocument
from keynote_motion import *
BASE=ROOT/'Fixtures/reference-edit.key'
ONLY=None


def geometry(x,y,w,h,angle=0):
    g=Message();g.put([1],point(x,y));g.put([2],point(w,h));g.set(3,0,3);g.sf(4,angle);return g

def png(clear=False):
    w,h=120,80
    def pixel(x,y):
        if clear:return bytes(4)
        if abs(x-100)<=1 and abs(y-40)<=6 or abs(y-40)<=1 and abs(x-100)<=6:return bytes((220,20,70,255))
        if 10<=x<=75 and 25<=y<=55 or 65<x<100 and abs(y-40)<(100-x)*0.7:return bytes((250,160,30,255))
        return bytes(4)
    raw=b''.join(b'\0'+b''.join(pixel(x,y) for x in range(w)) for y in range(h))
    def c(t,d):return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+c(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+c(b'IDAT',zlib.compress(raw))+c(b'IEND',b'')

class Probe:
    def __init__(self):
        self.d=SceneDocument(BASE);self.sid=self.d.slides[0];self.slide=self.d.objects[self.sid];self.file=self.d.locations[self.sid]
        self.curve=self.d.curves(self.sid)[0]['id'];self.arrow=2652802;self.text=2653027
        self.builds=[];self.chunks=[];self.ids=[]
    def add(self,typ,obj,references=()):
        d=self.d;i=d.allocate();d.add_record(self.file,i,typ,obj,references);d.register_uuid(self.file,i,uuid_message());self.ids.append(i);return i
    def place(self,i,g,parent):
        d=self.d;obj=d.objects[i];ip=d.info_path(i);draw=obj.sub(*ip);draw.put([1],g);draw.put([2],ref(parent));obj.put(ip,draw);d.add_header_refs(i,[parent])
    def image(self,x,y,clear=False):
        d=self.d;data_id=d.allocate();name=('透明支点辅助' if clear else '原创箭头')+f'-{data_id}.png';payload=png(clear)
        d.entries['Data/'+name]=payload
        info=Message();info.set(1,0,data_id);info.set(2,2,hashlib.sha1(payload).digest());info.set(3,2,name.encode());info.set(4,2,name.encode());d.meta.fields.append([4,2,info.pack()])
        image=Message();draw=Message();draw.put([1],geometry(x,y,120,80));draw.put([2],ref(self.sid));image.put([1],draw)
        for f in [11,12,13]:image.put([f],ref(data_id))
        for f in [4,9]:image.put([f],point(120,80))
        image.put([3],d.objects[2651787].sub(3));image.set(7,0,0);image.set(18,0,0)
        ident=self.add(IMAGE,image,[self.sid,image.sub(3).get(1)]);header=d.records[ident][0];mi=header.sub(2);mi.fields.append([6,0,data_id]);header.put([2],mi)
        for f in d.meta.fields:
            if f[0]==3:
                co=Message(f[2]);loc=string(co,3) or string(co,2)
                if 'Index/'+loc+'.iwa'==self.file:
                    style_id=image.sub(3).get(1)
                    style_file=d.locations[style_id]
                    for component_raw in d.meta.all(3):
                        sc=Message(component_raw)
                        if 'Index/'+(string(sc,3) or string(sc,2))+'.iwa'==style_file:
                            ext=Message();ext.set(1,0,sc.get(1));ext.set(2,0,style_id);ext.set(3,0,0)
                            if not any(Message(x).get(2)==style_id for x in co.all(6)):co.fields.append([6,2,ext.pack()])
                    dr=Message();dr.set(1,0,data_id);rl=Message();rl.set(1,0,ident);rl.set(2,0,3);dr.put([2],rl);co.fields.append([7,2,dr.pack()]);f[2]=co.pack()
        return ident
    def group(self,children,g):
        obj=Message();draw=Message();draw.put([1],g);draw.put([2],ref(self.sid));obj.put([1],draw);replace_refs(obj,2,children)
        gid=self.add(GROUP,obj,[self.sid,*children])
        for i in children:self.place(i,self.d.geometry(i),gid)
        return gid
    def animate(self,i,nodes,duration,trigger=1,draw=False,delay=0,align=False):
        d=self.d;bid,cid=d.allocate(),d.allocate();guid=uuid_message()
        b=build_animation(i,'In' if draw else 'Action',DRAW_EFFECT if draw else MOVE_EFFECT,duration,trigger,None if draw else path_message(nodes),align)
        a=b.sub(4)
        if delay:a.sd(6 if trigger==2 else 7,delay)
        b.put([4],a)
        chunk=build_chunk(bid,guid,duration,trigger!=1);chunk.set(6,0,int(trigger!=0));chunk.sd(3,delay)
        d.add_record(self.file,bid,8,b,[i]);d.add_record(self.file,cid,153,chunk,[bid]);d.register_uuid(self.file,bid,guid)
        self.builds.append(bid);self.chunks.append(cid);self.ids.extend([bid,cid])
    def finish(self,name,roots):
        if ONLY is not None and name!=ONLY:return f'跳过 {name}'
        d=self.d;replace_refs(self.slide,7,roots);replace_refs(self.slide,42,roots);replace_refs(self.slide,2,self.builds);replace_refs(self.slide,43,self.chunks)
        d.add_header_refs(self.sid,[*self.ids,*roots]);nodeid=d.slide_nodes[self.sid];node=d.objects[nodeid]
        for f,v in [(6,1),(20,1),(14,1),(15,1),(26,2),(27,2)]:node.set(f,0,v)
        out=ROOT/'Fixtures'/name
        if out.exists():raise ValueError(f'{out.name} 已存在，请使用新的试验目录。')
        d.write(out,{self.file,d.locations[nodeid],d.locations[d.metadata_ids[0]]})
        return out

def nodes_from_cubics(cubics):
    def pt(p):return [p['x'],p['y']]
    ns=[]
    for i,c in enumerate(cubics):
        ns.append((pt(cubics[i-1]['p2']) if i else pt(c['p0']),pt(c['p0']),pt(c['p1']),1))
    c=cubics[-1];ns.append((pt(c['p2']),pt(c['p3']),pt(c['p3']),1));return ns

if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1].endswith('.key'):
        ONLY=sys.argv[1]
    if sys.argv[1]=='input':
        p=Probe();ns=p.d.curve_nodes(p.curve)
        def pt(x):return {'x':x[0],'y':x[1]}
        cs=[dict(zip(['p0','p1','p2','p3'],map(pt,[a[1],a[2],b[0],b[1]]))) for a,b in zip(ns,ns[1:])]
        (ROOT/'Verification/probe-route.json').write_text(json.dumps(cs))
        sys.exit()
    ir=json.loads((ROOT/'Verification/probe-ir.json').read_text());nodes=nodes_from_cubics(ir['segments']);start=nodes[0][1]
    # Off-centre image anchor -> centred group pivot, so the native rotation
    # follows the ORIGINAL route tangent. Transparent helper maintains bounds.
    p=Probe();image=p.image(0,0);helper=p.image(80,0,True)
    group=p.group([image,helper],geometry(start[0]-100,start[1]-40,200,80,-tangent_angle(nodes)))
    p.animate(group,nodes,9,align=True)
    print(p.finish('01_anchor.key',[p.curve,group]))
    # Split visible curve and native motion into the same three cubic pieces.
    p=Probe();p.place(p.arrow,geometry(start[0]-50,start[1]-50,100,100),p.sid);roots=[]
    spans=[s for s in ir['timeline']['spans'] if s['from']!=s['to']]
    for i,(c,span) in enumerate(zip(ir['segments'],spans)):
        ns=nodes_from_cubics([c]);obj=Message(p.d.objects[p.curve].pack());ident=p.add(SHAPE,obj,[p.sid])
        # Visible path uses absolute coordinates within a slide-sized local box;
        # preserves curve controls without introducing negative bounds scaling.
        source=path_message(ns);sub=source.sub(8,1)
        for f in sub.fields:
            if f[0]==1:
                n=Message(f[2])
                for k in [1,2,3]:q=xy(n.sub(k));n.put([k],point(q[0]+ns[0][1][0],q[1]+ns[0][1][1]))
                f[2]=n.pack()
        ed=source.sub(8);ed.put([1],sub);ed.put([2],point(*p.d.size));source.put([8],ed)
        obj.put([1,3],source);p.place(ident,geometry(0,0,*p.d.size),p.sid);roots.append(ident)
        p.animate(ident,ns,span['duration'],1 if i==0 else 2,draw=True,delay=0 if i==0 else 1)
        p.animate(p.arrow,ns,span['duration'],0)
    print(p.finish('02_timing.key',[*roots,p.arrow]))
    # Keep text and image as distinct editable children, nested inside a group.
    p=Probe();image=p.image(0,0);d=p.d;text=p.text
    storage=d.objects[text].sub(4).get(1);d.objects[storage].set(3,2,b'P0')
    p.place(text,geometry(120,0,120,80),p.sid)
    # A text shape also carries an intrinsic rectangle. Geometry alone leaves
    # this zero-sized in the reference document, so Keynote clips the text.
    box=d.objects[text].sub(1,3,5)
    box.put([2],point(120,80))
    rectangle=Message()
    for kind,pos in [(1,(0,0)),(2,(120,0)),(2,(120,80)),(2,(0,80)),(5,None),(1,(0,0))]:
        command=Message();command.set(1,0,kind)
        if pos is not None:command.put([2],point(*pos))
        rectangle.fields.append([1,2,command.pack()])
    box.put([3],rectangle);d.objects[text].put([1,3,5],box)
    inner=p.group([image,text],geometry(0,0,240,80))
    p.place(p.arrow,geometry(90,90,60,60),p.sid)
    outer=p.group([inner,p.arrow],geometry(start[0]-120,start[1]-75,240,150))
    p.animate(outer,nodes,9,align=False)
    print(p.finish('03_group.key',[p.curve,outer]))
