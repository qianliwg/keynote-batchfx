"""Turn a Keynote curve into an object's native motion path.

All identifiers are discovered from the selected document. Only a new local
copy is written. Unknown records, media and unrelated objects are preserved.
"""
import datetime
import json
import math
from pathlib import Path
import secrets
import uuid
import zipfile
from zoneinfo import ZoneInfo
from iwa_codec import Message, pack_iwa, unpack_iwa, point, xy, varint
from keynote_package import normalized_info, open_keynote_zip

SHAPE, IMAGE, MOVIE, GROUP = 2011, 3005, 3007, 3008
DRAW_EFFECT = 'com.apple.iWork.Keynote.LineDrawForLine'
MOVE_EFFECT = 'apple:action-motion-path'


def ref(value):
    m=Message(); m.set(1,0,value); return m


def refs(obj, field): return [Message(v).get(1) for v in obj.all(field)]
def string(obj, field): return obj.get(field,b'').decode('utf-8','replace')
def replace_refs(obj, field, ids):
    obj.fields=[f for f in obj.fields if f[0]!=field]
    obj.fields += [[field,2,ref(i).pack()] for i in ids]


def uuid_message():
    value=uuid.uuid4().int
    m=Message(); m.set(1,0,value & ((1<<64)-1)); m.set(2,0,value>>64)
    return m


def repeated_ints(obj, field):
    values=[]
    for n,w,v in obj.fields:
        if n!=field: continue
        if w==0: values.append(v)
        elif w==2:
            pos=0
            while pos<len(v): value,pos=varint(v,pos); values.append(value)
    return values


class Document:
    def __init__(self, filename):
        self.path=Path(filename).expanduser().resolve()
        self.entries={}; self.infos={}; self.comment=b''
        if self.path.is_dir():
            self.entries={str(p.relative_to(self.path)):p.read_bytes() for p in self.path.rglob('*') if p.is_file()}
        else:
            try:
                with open_keynote_zip(self.path) as z:
                    for original in z.infolist():
                        info=normalized_info(original, z.metadata_encoding=='utf-8')
                        if info.filename in self.entries:
                            raise ValueError('文稿中有重复的内部文件名，未生成副本。')
                        self.entries[info.filename]=z.read(original)
                        self.infos[info.filename]=info
                    self.comment=z.comment
            except (zipfile.BadZipFile,RuntimeError) as exc:
                raise ValueError('请使用未加密、已保存的现代 .key 文稿。') from exc
        if 'Index/Document.iwa' not in self.entries:
            raise ValueError('未找到 Keynote 文稿结构。请先在 Keynote 中保存为单个 .key 文件。')
        self.files={}; self.objects={}; self.records={}; self.types={}; self.locations={}
        for name,data in self.entries.items():
            if not name.startswith('Index/') or not name.endswith('.iwa'): continue
            rr=unpack_iwa(data); self.files[name]=rr
            for header,objects in rr:
                ident=header.get(1)
                if len(objects)!=1: continue
                if ident in self.objects: continue
                self.objects[ident]=objects[0]; self.records[ident]=[header,objects]
                self.types[ident]=Message(header.all(2)[0]).get(1); self.locations[ident]=name
        shows=[i for i,t in self.types.items() if t==2]
        if len(shows)!=1: raise ValueError('暂不支持这种演示文稿结构。')
        show=self.objects[shows[0]]; self.size=xy(show.sub(4))
        self.slide_nodes={}; self.slides=[]
        def visit(node_id):
            node=self.objects.get(node_id)
            if node is None: return
            slide_id=node.sub(2).get(1) if node.get(2) else None
            if slide_id in self.objects and self.types.get(slide_id)==5 and slide_id not in self.slides:
                self.slides.append(slide_id); self.slide_nodes[slide_id]=node_id
            for child in refs(node,1): visit(child)
        tree=show.sub(3)
        for node_id in refs(tree,2): visit(node_id)
        if not self.slides and tree.get(1): visit(tree.sub(1).get(1))
        if not self.slides: raise ValueError('没有找到可编辑的幻灯片。')
        self.metadata_ids=[i for i,t in self.types.items() if t==11006]
        if len(self.metadata_ids)!=1: raise ValueError('文稿缺少对象目录，无法安全添加动画。')
        self.meta=self.objects[self.metadata_ids[0]]
        self.next_id=max(max(self.objects),self.meta.get(1,0))

    def info_path(self, ident):
        typ=self.types[ident]
        if typ==SHAPE: return [1,1]
        if typ in (IMAGE,MOVIE): return [1]
        raise ValueError('目前支持独立图片、GIF 和形状；请先取消成组。')

    def geometry(self,ident): return self.objects[ident].sub(*self.info_path(ident),1)

    def object_name(self,ident,index=0):
        obj=self.objects[ident]; typ=self.types[ident]
        text=''
        if typ==SHAPE:
            storage=Message(obj.get(4,obj.get(2,b''))).get(1)
            if storage in self.objects: text=string(self.objects[storage],3).strip()
            if not text and obj.get(1):
                ps=obj.sub(1).get(3)
                if ps: text=string(Message(ps),10) or string(Message(ps),9)
        label={SHAPE:'形状',IMAGE:'图片',MOVIE:'GIF / 影片'}.get(typ,'对象')
        if text: label+='「'+text[:22].replace('\n',' ')+'」'
        else: label+=f' {index}'
        geo=self.geometry(ident); p=xy(geo.sub(1)); s=xy(geo.sub(2))
        return f'{label} · 位置 {p[0]:.0f}, {p[1]:.0f} · 大小 {s[0]:.0f} × {s[1]:.0f}'

    def items(self, slide_id):
        ids=refs(self.objects[slide_id],42) or refs(self.objects[slide_id],7)
        result=[]
        for ident in ids:
            if self.types.get(ident) not in (SHAPE,IMAGE,MOVIE): continue
            try:
                g=self.geometry(ident)
                label=self.object_name(ident,len(result)+1)
                result.append({'id':ident,'label':label,'type':self.types[ident],
                               'position':xy(g.sub(1)),'size':xy(g.sub(2)),'angle':g.f(4)})
            except (ValueError,KeyError,TypeError): continue
        return result

    def curves(self,slide_id):
        result=[]
        for item in self.items(slide_id):
            try:
                nodes=self.curve_nodes(item['id'])
                result.append(dict(item,label=f'路线 {len(result)+1} · {len(nodes)} 个节点 · '+item['label']))
            except (ValueError,KeyError,TypeError): pass
        return result

    def curve_nodes(self,ident):
        if self.types.get(ident)!=SHAPE: raise ValueError('路线需要是 Keynote 中绘制的曲线。')
        obj=self.objects[ident]; path=obj.sub(1,3)
        if not path.get(8): raise ValueError('请选择用“用笔绘制”画出的曲线；普通连接线需先转换为可编辑形状。')
        editable=path.sub(8); paths=editable.all(1)
        if len(paths)!=1: raise ValueError('请选择只有一条连续路径的曲线。')
        sub=Message(paths[0])
        if sub.get(2,0): raise ValueError('当前版本支持有起点和终点的开放曲线。')
        raw_nodes=sub.all(1)
        if not 2<=len(raw_nodes)<=10000: raise ValueError('路线节点数量无效。')
        natural=xy(editable.sub(2)); geo=self.geometry(ident); size=xy(geo.sub(2)); pos=xy(geo.sub(1))
        angle=-math.radians(geo.f(4)); co,si=math.cos(angle),math.sin(angle)
        if min(size)<0: raise ValueError('不支持负尺寸。')
        def transform(p):
            q=[p[j]*size[j]/natural[j] if abs(natural[j])>1e-8 else p[j] for j in [0,1]]
            if path.get(1,0): q[0]=size[0]-q[0]
            if path.get(2,0): q[1]=size[1]-q[1]
            dx,dy=q[0]-size[0]/2,q[1]-size[1]/2
            return [pos[0]+size[0]/2+co*dx-si*dy,pos[1]+size[1]/2+si*dx+co*dy]
        nodes=[]
        for raw in raw_nodes:
            n=Message(raw); p=n.sub(2)
            pts=[transform(xy(Message(n.get(k,p.pack())))) for k in [1,2,3]]
            if not all(math.isfinite(v) for pt in pts for v in pt): raise ValueError('路线包含无效坐标。')
            nodes.append((*pts,n.get(4,1)))
        return nodes

    def allocate(self):
        self.next_id+=1; self.meta.set(1,0,self.next_id); return self.next_id

    def add_record(self, filename, ident, typ, obj, references=()):
        h=Message(); h.set(1,0,ident)
        info=Message(); info.set(1,0,typ)
        info.fields += [[2,0,v] for v in [1,0,5]]
        info.set(3,0,len(obj.pack())); info.fields += [[5,0,i] for i in references]
        h.set(2,2,info.pack()); record=[h,[obj]]; self.files[filename].append(record)
        self.objects[ident]=obj; self.records[ident]=record; self.types[ident]=typ; self.locations[ident]=filename

    def register_uuid(self,filename,ident,guid):
        for field in self.meta.fields:
            if field[0]!=3: continue
            component=Message(field[2])
            locator=string(component,3) or string(component,2)
            if 'Index/'+locator+'.iwa'!=filename: continue
            entry=Message(); entry.set(1,0,ident); entry.put([2],guid)
            component.fields.append([11,2,entry.pack()]); field[2]=component.pack(); return
        raise ValueError('找不到幻灯片的对象目录。')

    def validate_media(self):
        missing=[]
        for raw in self.meta.all(4):
            name=string(Message(raw),4)
            if name and 'Data/'+name not in self.entries: missing.append(name)
        if missing:
            names='、'.join(missing[:3])
            raise ValueError('来源文稿中已缺少图片或影片素材：'+names+
                             '。请使用仍保留素材的原始文稿，或先在 Keynote 中补回图片并保存；本次未生成副本。')

    def add_header_refs(self,ident,ids):
        header=self.records[ident][0]
        for field in header.fields:
            if field[0]==2:
                info=Message(field[2]); have=set(repeated_ints(info,5))
                info.fields += [[5,0,i] for i in ids if i not in have]
                field[2]=info.pack(); break

    def write(self, output, changed):
        output=Path(output).expanduser().resolve()
        if output.exists() or output==self.path: raise ValueError('请选择一个尚不存在的新文件名；工具不覆盖已有文稿。')
        self.validate_media()
        updates={name:pack_iwa(self.files[name]) for name in changed}
        # Check the serialized records before writing the new archive.
        for data in updates.values(): unpack_iwa(data)
        created=False
        try:
            with zipfile.ZipFile(output,'x',compression=zipfile.ZIP_DEFLATED) as z:
                created=True
                z.comment=self.comment
                for name,data in self.entries.items():
                    z.writestr(self.infos.get(name,name),updates.get(name,data))
            # Verify both resource paths and bytes, not just the media payload.
            with zipfile.ZipFile(output) as z:
                for name,data in self.entries.items():
                    if name.startswith('Data/') and z.read(name)!=data:
                        raise ValueError('图片素材校验失败，已取消生成。')
        except Exception:
            if created and output.exists(): output.unlink()
            raise
        return output


def path_message(nodes):
    origin=nodes[0][1]; sub=Message()
    for ip,p,op,kind in nodes:
        node=Message()
        for k,pt in [(1,ip),(2,p),(3,op)]: node.put([k],point(pt[0]-origin[0],pt[1]-origin[1]))
        node.set(4,0,kind); sub.fields.append([1,2,node.pack()])
    sub.set(2,0,0)
    coords=[pt for n in nodes for pt in n[:3]]
    size=[max(p[j] for p in coords)-min(p[j] for p in coords) for j in [0,1]]
    editable=Message(); editable.put([1],sub); editable.put([2],point(*size))
    path=Message(); path.set(1,0,0); path.set(2,0,0); path.put([8],editable)
    return path


def tangent_angle(nodes):
    for p in [nodes[0][2],nodes[1][0],nodes[1][1]]:
        dx,dy=[p[j]-nodes[0][1][j] for j in [0,1]]
        if math.hypot(dx,dy)>1e-7: return math.degrees(math.atan2(dy,dx))
    return 0


def build_animation(drawable,kind,effect,duration,trigger,path=None,align=False):
    anim=Message(); anim.set(1,2,kind.encode()); anim.set(2,2,effect.encode()); anim.sd(3,duration); anim.sd(5,0)
    anim.set(11,0,secrets.randbelow(2**31)); anim.set(16,0,0)
    attrs=Message(); attrs.set(4,0,trigger); attrs.set(13,0,0); attrs.sd(17,60); attrs.put([18],anim)
    if path is not None: attrs.put([22],path); attrs.set(37,0,int(align))
    if kind=='In': attrs.set(30,0,1)
    build=Message(); build.put([1],ref(drawable)); build.set(2,2,b'All at Once'); build.sd(3,0); build.put([4],attrs); build.set(5,0,1)
    return build


def build_chunk(build_id,guid,duration,together):
    chunk=Message(); chunk.put([1],ref(build_id)); chunk.sd(3,0); chunk.sd(4,duration)
    chunk.set(5,0,int(together)); chunk.set(6,0,int(not together))
    key=Message(); key.put([1],guid); key.set(2,0,1)
    chunk.put([7],key); chunk.put([8],guid); return chunk


def generate(filename,slide_id,curve_id,target_id,output=None,duration=8.0,draw=True,align=False,heading='保持当前朝向'):
    duration=float(duration)
    if not math.isfinite(duration) or not 0.1<=duration<=600: raise ValueError('播放时长请输入 0.1 至 600 秒。')
    d=Document(filename)
    d.validate_media()
    if slide_id not in d.slides: raise ValueError('选定的幻灯片不存在，请重新打开来源文稿。')
    candidates={item['id'] for item in d.items(slide_id)}
    if curve_id==target_id: raise ValueError('路线和移动对象必须是两个不同对象。')
    if not {curve_id,target_id}<=candidates: raise ValueError('请选择同一页上未成组的路线和移动对象。')
    nodes=d.curve_nodes(curve_id); slide=d.objects[slide_id]; filename_iwa=d.locations[slide_id]
    if d.locations[curve_id]!=filename_iwa or d.locations[target_id]!=filename_iwa:
        raise ValueError('暂不支持跨组件对象；请把对象复制到当前页后重试。')
    moving=d.objects[target_id]; geo=d.geometry(target_id); size=xy(geo.sub(2))
    geo.put([1],point(*[nodes[0][1][j]-size[j]/2 for j in [0,1]]))
    headings={'向右':0,'向上':90,'向左':180,'向下':270}
    if align and heading in headings: geo.sf(4,(-tangent_angle(nodes)+headings[heading])%360)
    moving.put(d.info_path(target_id)+[1],geo)
    if d.types[target_id]==MOVIE: moving.set(8,0,1)
    replaced={target_id,curve_id} if draw else {target_id}
    old_builds=refs(slide,2); old_chunks=refs(slide,43)
    removed={i for i in old_builds if i in d.objects and d.objects[i].sub(1).get(1) in replaced}
    kept_builds=[i for i in old_builds if i not in removed]
    kept_chunks=[i for i in old_chunks if i not in d.objects or d.objects[i].sub(1).get(1) not in removed]
    if slide.all(3): raise ValueError('此文稿使用旧版内嵌动画，请用当前 Keynote 另存一次后重试。')
    new_ids=[]; created=[]
    specs=[]
    if draw: specs.append((curve_id,'In',DRAW_EFFECT,1,None,False,False))
    specs.append((target_id,'Action',MOVE_EFFECT,0 if draw else 1,path_message(nodes),align,draw))
    for obj_id,kind,effect,trigger,path,is_align,together in specs:
        bid,cid=d.allocate(),d.allocate(); guid=uuid_message()
        build=build_animation(obj_id,kind,effect,duration,trigger,path,is_align)
        chunk=build_chunk(bid,guid,duration,together)
        d.add_record(filename_iwa,bid,8,build,[obj_id]); d.add_record(filename_iwa,cid,153,chunk,[bid])
        d.register_uuid(filename_iwa,bid,guid)
        kept_builds.append(bid); kept_chunks.append(cid); new_ids.extend([bid,cid]); created.append((bid,cid))
    replace_refs(slide,2,kept_builds); replace_refs(slide,43,kept_chunks)
    d.add_header_refs(slide_id,new_ids)
    node_id=d.slide_nodes[slide_id]; node=d.objects[node_id]
    node.set(6,0,1); node.set(20,0,1); node.set(14,0,1)
    click_count=sum(not d.objects[i].get(5,0) for i in kept_chunks if i in d.objects)
    node.set(15,0,click_count); node.set(26,0,2); node.set(27,0,2)
    # Replaced records stay as unreachable archives to preserve package references.
    changed={filename_iwa,d.locations[node_id],d.locations[d.metadata_ids[0]]}
    if output is None:
        stamp=datetime.datetime.now(ZoneInfo('Asia/Shanghai')).strftime('%Y%m%d_%H%M%S_%f')
        output=d.path.with_name(d.path.stem+'_沿线动画_'+stamp+'.key')
    output=d.write(output,changed)
    return {'path':str(output),'nodes':len(nodes),'duration':duration,'builds':created,
            'slide':d.slides.index(slide_id)+1,'replaced_builds':len(removed)}


def sample_curve(nodes,steps=20):
    points=[]
    for a,b in zip(nodes,nodes[1:]):
        p0,p1,p2,p3=a[1],a[2],b[0],b[1]
        for i in range(steps):
            t=i/steps; u=1-t
            points.append([u*u*u*p0[j]+3*u*u*t*p1[j]+3*u*t*t*p2[j]+t*t*t*p3[j] for j in [0,1]])
    return points+[nodes[-1][1]]


if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser(); p.add_argument('file'); p.add_argument('--list',action='store_true')
    p.add_argument('--slide',type=int,default=1); p.add_argument('--curve',type=int); p.add_argument('--target',type=int)
    p.add_argument('--duration',type=float,default=8); p.add_argument('--output'); p.add_argument('--no-draw',action='store_true')
    p.add_argument('--align',action='store_true'); p.add_argument('--heading',default='保持当前朝向')
    a=p.parse_args(); d=Document(a.file)
    if a.list:
        print(json.dumps([{'slide':j+1,'id':i,'curves':d.curves(i),'objects':d.items(i)} for j,i in enumerate(d.slides)],ensure_ascii=False,indent=2))
    else:
        print(json.dumps(generate(a.file,d.slides[a.slide-1],a.curve,a.target,a.output,a.duration,not a.no_draw,a.align,a.heading),ensure_ascii=False))
