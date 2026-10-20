"""P0 one-request JSON process boundary. IWA details never escape as UI code."""
import hashlib, json, os, sys, tempfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent/'legacy'))
from keynote_motion import Document, generate, refs, string, GROUP, SHAPE, IMAGE, MOVIE
from iwa_codec import xy

PROTOCOL=1

def fingerprint(path):
    path=Path(path).resolve(); digest=hashlib.sha256()
    files=sorted(p for p in path.rglob('*') if p.is_file()) if path.is_dir() else [path]
    for p in files:
        if path.is_dir(): digest.update(str(p.relative_to(path)).encode()+b'\0')
        with p.open('rb') as f:
            for block in iter(lambda:f.read(1024*1024),b''): digest.update(block)
    return digest.hexdigest()

class SceneDocument(Document):
    def info_path(self,ident):
        if self.types[ident]==GROUP:return [1]
        return super().info_path(ident)
    def scene(self,sid):
        seen=set(); warnings=[]
        def node(ident,parent=None):
            if ident in seen: raise ValueError('对象层级存在循环或重复归属，未导入。')
            seen.add(ident)
            typ=self.types.get(ident); raw=self.objects.get(ident)
            kind={SHAPE:'shape',IMAGE:'image',MOVIE:'movie',GROUP:'group'}.get(typ,'unsupported')
            item={'id':str(ident),'parent':str(parent) if parent else None,'kind':kind,'children':[]}
            if raw is None: raise ValueError('文稿引用了不存在的对象。')
            if kind=='unsupported':
                item['name']='暂不支持的对象';warnings.append(f'对象 {ident} 只保留，不参与运动。');return item
            geo=self.geometry(ident)
            item.update(position=list(xy(geo.sub(1))),size=list(xy(geo.sub(2))),rotationDegrees=-geo.f(4),geometryFlags=geo.get(3,0))
            item['name']='群组' if typ==GROUP else self.object_name(ident)
            if typ==GROUP:
                item['children']=[node(i,ident) for i in refs(raw,2)]
            else:
                try:item['curve']=[{'incoming':n[0],'point':n[1],'outgoing':n[2],'kind':n[3]} for n in self.curve_nodes(ident)]
                except ValueError:pass
            item['signature']=hashlib.sha256(raw.pack()).hexdigest()
            return item
        roots=refs(self.objects[sid],42) or refs(self.objects[sid],7)
        return {'id':str(sid),'nodes':[node(i) for i in roots],'warnings':warnings}


def _int_argument(value, label):
    try:
        result=int(value)
    except (TypeError,ValueError) as exc:
        raise ValueError(f'{label} 不是有效的对象编号。') from exc
    if result<=0:
        raise ValueError(f'{label} 不是有效的对象编号。')
    return result


def _slide_id(document, value):
    """Resolve either a one-based slide number or the stable Keynote id."""
    if isinstance(value, bool):
        raise ValueError('幻灯片编号无效。')
    try:
        candidate=int(value)
    except (TypeError,ValueError) as exc:
        raise ValueError('幻灯片编号无效。') from exc
    if 1<=candidate<=len(document.slides):
        return document.slides[candidate-1], candidate
    if candidate in document.slides:
        return candidate, document.slides.index(candidate)+1
    raise ValueError('选定的幻灯片不存在，请重新打开来源文稿。')


def _cubic_segments(nodes):
    if len(nodes)<2:
        raise ValueError('路线至少需要两个节点。')
    return [
        {'p0':{'x':a[1][0],'y':a[1][1]},
         'p1':{'x':a[2][0],'y':a[2][1]},
         'p2':{'x':b[0][0],'y':b[0][1]},
         'p3':{'x':b[1][0],'y':b[1][1]}}
        for a,b in zip(nodes,nodes[1:])
    ]


def extract_route(path, slide, curve, target=None):
    """Return a portable route recipe from a selected Keynote curve."""
    document=SceneDocument(path)
    document.validate_media()
    slide_id,slide_number=_slide_id(document,slide)
    curve_id=_int_argument(curve,'路线对象')
    if document.types.get(curve_id)!=SHAPE:
        raise ValueError('路线对象必须是 Keynote 中绘制的曲线。')
    if document.locations.get(curve_id)!=document.locations.get(slide_id):
        raise ValueError('路线和幻灯片不在同一个文稿组件中。')
    nodes=document.curve_nodes(curve_id)
    curves={item['id']:item for item in document.curves(slide_id)}
    route=curves.get(curve_id)
    if route is None:
        raise ValueError('找不到选定的曲线，请重新导入文稿。')
    result={
        'sceneVersion':1,
        'slide':slide_number,
        'slideID':str(slide_id),
        'canvas':{'x':document.size[0],'y':document.size[1]},
        'routeObjectID':str(curve_id),
        'route':{
            'id':str(curve_id),
            'name':route['label'],
            'kind':'shape',
            'position':list(route['position']),
            'size':list(route['size']),
            'rotationDegrees':-route['angle'],
            'nodeCount':len(nodes)
        },
        'segments':_cubic_segments(nodes),
        'target':None,
        'source':{'path':str(document.path),'sha256':fingerprint(document.path)}
    }
    if target is not None and str(target)!='':
        target_id=_int_argument(target,'目标对象')
        candidates={item['id']:item for item in document.items(slide_id)}
        target_item=candidates.get(target_id)
        if target_item is None:
            raise ValueError('目标对象必须是所选幻灯片上的图片、GIF、影片或形状。')
        if target_id==curve_id:
            raise ValueError('路线和目标对象必须是两个不同对象。')
        result['target']={
            'id':str(target_id),
            'name':target_item['label'],
            'kind':{SHAPE:'shape',IMAGE:'image',MOVIE:'movie'}.get(target_item['type'],'unsupported'),
            'position':list(target_item['position']),
            'size':list(target_item['size']),
            'rotationDegrees':-target_item['angle']
        }
        result['targetObjectID']=str(target_id)
    return result

def inspect(path):
    before=fingerprint(path);d=SceneDocument(path);d.validate_media()
    result={'sceneVersion':1,'source':{'path':str(d.path),'sha256':before},'size':list(d.size),
            'slides':[d.scene(s) for s in d.slides],
            'media':[{'path':n,'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()} for n,b in d.entries.items() if n.startswith('Data/')],
            'capabilities':{'inspectGroups':True,'centerMotion':'legacy','anchorTurning':'experimental',
                            'segmentedTiming':'experimental','groupMotion':'experimental',
                            'extractRoute':True,'applyMotion':'rootObjectsOnly'}}
    if fingerprint(path)!=before:raise ValueError('读取期间来源发生变化，请保存后重新导入。')
    return result

def validated_copy(source,output,expected):
    source=Path(source).resolve();output=Path(output).resolve()
    if fingerprint(source)!=expected:raise ValueError('来源已变化，请重新导入文稿。')
    if output.exists() or output==source:raise ValueError('请选择尚不存在的副本文件名。')
    d=SceneDocument(source);d.validate_media()
    with tempfile.TemporaryDirectory(prefix='.kmotion-',dir=output.parent) as temp:
        staged=Path(temp)/'candidate.key'
        d.write(staged,set())
        check=SceneDocument(staged);check.validate_media()
        for n,b in d.entries.items():
            if check.entries.get(n)!=b:raise ValueError('内部文件校验失败。')
        if fingerprint(source)!=expected:raise ValueError('生成期间来源发生变化，已取消。')
        # Same-volume hard link is an atomic, exclusive publish. Existing files
        # cannot be overwritten even if created after the initial check.
        os.link(staged,output)
    return {'path':str(output),'mediaCount':sum(n.startswith('Data/') for n in d.entries),'verified':True}


def apply_motion(source,output,expected,slide,curve,target,duration=8.0,draw=True,align=False,heading='保持当前朝向'):
    """Write a native Keynote motion path to a new, validated document copy."""
    source=Path(source).resolve();output=Path(output).resolve()
    if fingerprint(source)!=expected:
        raise ValueError('来源已变化，请重新导入文稿。')
    if output.exists() or output==source:
        raise ValueError('请选择尚不存在的副本文件名。')
    document=SceneDocument(source)
    document.validate_media()
    slide_id,slide_number=_slide_id(document,slide)
    curve_id=_int_argument(curve,'路线对象')
    target_id=_int_argument(target,'目标对象')
    if curve_id==target_id:
        raise ValueError('路线和目标对象必须是两个不同对象。')
    nodes=document.curve_nodes(curve_id)
    result=generate(source,slide_id,curve_id,target_id,output=output,duration=duration,
                    draw=bool(draw),align=bool(align),heading=heading)
    if fingerprint(source)!=expected:
        if output.exists(): output.unlink()
        raise ValueError('生成期间来源发生变化，已取消输出。')
    check=SceneDocument(output);check.validate_media()
    return {'path':str(output),'verified':True,'slide':slide_number,
            'routeObjectID':str(curve_id),'targetObjectID':str(target_id),
            'nodes':len(nodes),'duration':float(duration),'draw':bool(draw),
            'align':bool(align),'replacedBuilds':result.get('replaced_builds',0)}

def dispatch(request):
    if request.get('protocol')!=PROTOCOL:raise ValueError('应用与文稿适配器的接口版本不一致。')
    op=request.get('operation');args=request.get('arguments',{})
    if op=='health':
        import zlib,struct,math,datetime,zoneinfo,secrets,zipfile
        return {'python':sys.version.split()[0],'runtimePrefix':sys.prefix,'isolated':bool(sys.flags.isolated),
                'protocol':PROTOCOL,'adapter':'0.2.0-p2','status':'ok'}
    if op=='inspect':return inspect(args['path'])
    if op=='validatedCopy':return validated_copy(args['source'],args['output'],args['sha256'])
    if op=='extractRoute':
        return extract_route(args['path'],args.get('slide',1),args['curve'],args.get('target'))
    if op=='applyMotion':
        return apply_motion(args['source'],args['output'],args['sha256'],args.get('slide',1),
                            args['curve'],args['target'],args.get('duration',8.0),
                            args.get('draw',True),args.get('align',False),
                            args.get('heading','保持当前朝向'))
    raise ValueError('暂不支持此操作。')

def main():
    request={}
    try:
        raw=sys.stdin.buffer.read(1048577)
        if len(raw)>1048576:raise ValueError('请求过大。')
        request=json.loads(raw)
        if not isinstance(request,dict):raise ValueError('无效请求。')
        result={'protocol':PROTOCOL,'id':request.get('id'),'ok':True,'result':dispatch(request)}
    except Exception as e:
        result={'protocol':PROTOCOL,'id':request.get('id') if isinstance(request,dict) else None,'ok':False,
                'error':{'code':'INVALID_DOCUMENT_OR_REQUEST','message':str(e)}}
    print(json.dumps(result,ensure_ascii=False,allow_nan=False))

if __name__=='__main__':main()
