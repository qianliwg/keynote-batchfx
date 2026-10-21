"""Compile a single project recipe, then publish a validated Keynote copy."""
import math
import os
import tempfile
from pathlib import Path

from adapter import SceneDocument, fingerprint, _cubic_segments
from keynote_motion import (
    SHAPE, IMAGE, MOVIE, GROUP, DRAW_EFFECT, MOVE_EFFECT, refs, replace_refs,
    build_animation, build_chunk, uuid_message, path_message, tangent_angle,
)
from iwa_codec import point, xy


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError('项目包含无效数值。')
    return float(value)


def validate_recipe(project):
    if project.get('formatVersion') != 1:
        raise ValueError('不支持此项目版本。')
    spans = project.get('spans', [])
    if (len(spans) != 1 or spans[0].get('start') != 0 or
            spans[0].get('from') != 0 or spans[0].get('to') != 1):
        raise ValueError('当前副本导出支持单段全程移动；停靠和分段速度还只能预览。')
    duration = number(spans[0]['duration'])
    if not 0.1 <= duration <= 600:
        raise ValueError('播放时长请输入 0.1 至 600 秒。')
    if project.get('playback') != 'once':
        raise ValueError('循环和往返目前用于预览；请切换到单次再导出。')
    orientation = project.get('orientation')
    if orientation not in ('fixed', 'route-tangent'):
        raise ValueError('朝向设置无效。')
    anchor = project['target']['anchor']
    ax, ay = number(anchor['x']), number(anchor['y'])
    if not all(0 <= v <= 1 for v in (ax, ay)):
        raise ValueError('贴线点必须在对象范围内。')
    if orientation == 'route-tangent' and (abs(ax - .5) > 1e-8 or abs(ay - .5) > 1e-8):
        raise ValueError('非中心贴线点目前支持固定朝向导出；转向支点仍在验证中。')
    if not isinstance(project.get('drawLine'), bool):
        raise ValueError('路线绘制设置无效。')
    rotation = number(project['target'].get('rotationDegrees', 0))
    return duration, (ax, ay), orientation, rotation


def compile_project(document, project, replace_existing):
    duration, anchor, orientation, rotation = validate_recipe(project)
    try:
        sid, curve, target = (int(project[k]) for k in ('slideID', 'routeObjectID', 'targetObjectID'))
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError('请先从来源文稿导入路线和目标对象。') from exc
    if sid not in document.slides:
        raise ValueError('项目关联的幻灯片已不存在。')
    roots = refs(document.objects[sid], 42) or refs(document.objects[sid], 7)
    if curve == target or curve not in roots or target not in roots:
        raise ValueError('路线和目标必须是同一页上的两个独立对象；可以选择整个群组。')
    if document.types[target] not in (SHAPE, IMAGE, MOVIE, GROUP):
        raise ValueError('暂不支持此目标类型。')
    document.scene(sid)  # Validate ownership, nested groups and cycles.
    filename = document.locations[sid]
    if any(document.locations[i] != filename for i in (curve, target)):
        raise ValueError('暂不支持跨组件对象。')
    nodes = document.curve_nodes(curve)
    original_segments = _cubic_segments(nodes)
    saved_segments = project.get('segments', [])
    if len(saved_segments) != len(original_segments):
        raise ValueError('项目路线与来源不一致，请重新导入。')
    for saved, original in zip(saved_segments, original_segments):
        for key in ('p0', 'p1', 'p2', 'p3'):
            for axis in ('x', 'y'):
                if abs(number(saved[key][axis]) - original[key][axis]) > 1e-5:
                    raise ValueError('项目路线与来源不一致，请重新导入。')
    if any(abs(number(project['canvas'][a]) - document.size[i]) > 1e-5 for i, a in enumerate(('x', 'y'))):
        raise ValueError('项目画布与来源不一致，请重新导入。')
    geo = document.geometry(target)
    size = xy(geo.sub(2))
    if any(v <= 0 or not math.isfinite(v) for v in size):
        raise ValueError('目标尺寸无效。')
    if any(abs(number(project['target']['size'][a]) - size[i]) > 1e-5 for i, a in enumerate(('x', 'y'))):
        raise ValueError('目标尺寸与来源不一致，请重新导入。')
    slide = document.objects[sid]
    if slide.all(3):
        raise ValueError('请先用当前 Keynote 另存此旧版动画文稿。')
    replaced = {target, curve} if project['drawLine'] else {target}
    old_builds = refs(slide, 2)
    removed = {i for i in old_builds if i in document.objects and document.objects[i].sub(1).get(1) in replaced}
    descendants = set()

    def descend(ident):
        if document.types[ident] == GROUP:
            for child in refs(document.objects[ident], 2):
                descendants.add(child)
                descend(child)
    descend(target)
    if any(document.objects[i].sub(1).get(1) in descendants for i in old_builds if i in document.objects):
        raise ValueError('群组成员已有单独动画，无法保证整体刚性移动；请先在 Keynote 中处理这些动画。')
    if removed and not replace_existing:
        raise ValueError(f'所选路线/目标已有 {len(removed)} 个动画。勾选“替换所选对象原有动画”后再生成副本。')
    kept_builds = [i for i in old_builds if i not in removed]
    kept_chunks = [i for i in refs(slide, 43) if i not in document.objects or document.objects[i].sub(1).get(1) not in removed]
    angle = math.radians(rotation) if orientation == 'fixed' else math.radians(tangent_angle(nodes))
    offset = ((anchor[0] - .5) * size[0], (anchor[1] - .5) * size[1])
    dx = math.cos(angle) * offset[0] - math.sin(angle) * offset[1]
    dy = math.sin(angle) * offset[0] + math.cos(angle) * offset[1]
    geo.put([1], point(nodes[0][1][0] - dx - size[0]/2, nodes[0][1][1] - dy - size[1]/2))
    geo.sf(4, -math.degrees(angle))
    document.objects[target].put(document.info_path(target) + [1], geo)
    if document.types[target] == MOVIE:
        document.objects[target].set(8, 0, 1)
    # Fixed orientation uses a constant center displacement. Relative native
    # path vectors remain identical to the route; children need no rewriting.
    specs = []
    if project['drawLine']:
        specs.append((curve, 'In', DRAW_EFFECT, 1, None, False))
    specs.append((target, 'Action', MOVE_EFFECT, 0 if project['drawLine'] else 1,
                  path_message(nodes), orientation == 'route-tangent'))
    created = []
    for obj, kind, effect, trigger, path, align in specs:
        bid, cid, guid = document.allocate(), document.allocate(), uuid_message()
        document.add_record(filename, bid, 8, build_animation(obj, kind, effect, duration, trigger, path, align), [obj])
        document.add_record(filename, cid, 153, build_chunk(bid, guid, duration, trigger == 0), [bid])
        document.register_uuid(filename, bid, guid)
        kept_builds.append(bid); kept_chunks.append(cid); created.extend((bid, cid))
    replace_refs(slide, 2, kept_builds)
    replace_refs(slide, 43, kept_chunks)
    document.add_header_refs(sid, created)
    node_id = document.slide_nodes[sid]
    node = document.objects[node_id]
    for f, v in ((6, 1), (20, 1), (14, 1), (26, 2), (27, 2)):
        node.set(f, 0, v)
    node.set(15, 0, sum(not document.objects[i].get(5, 0) for i in kept_chunks if i in document.objects))
    return {filename, document.locations[node_id], document.locations[document.metadata_ids[0]]}, len(removed)


def export_project(source, output, project, replace_existing=False):
    source, output = Path(source).resolve(), Path(output).resolve()
    expected = project['source']['sha256']
    if fingerprint(source) != expected:
        raise ValueError('来源已变化，请重新导入文稿。')
    if output.exists() or source == output:
        raise ValueError('请选择尚不存在的副本文件名。')
    document = SceneDocument(source)
    document.validate_media()
    changed, replaced = compile_project(document, project, replace_existing)
    with tempfile.TemporaryDirectory(prefix='.kmotion-', dir=output.parent) as temp:
        staged = Path(temp) / 'candidate.key'
        document.write(staged, changed)
        checked = SceneDocument(staged)
        checked.validate_media()
        for sid in checked.slides:
            checked.scene(sid)
        for name, data in document.entries.items():
            if (name.startswith('Data/') or name not in changed) and checked.entries.get(name) != data:
                raise ValueError('副本素材或未修改的文件校验失败。')
        if fingerprint(source) != expected:
            raise ValueError('生成期间来源发生变化，已取消。')
        os.link(staged, output)
    return {'path': str(output), 'verified': True, 'replacedBuilds': replaced,
            'duration': project['spans'][0]['duration'], 'groupMotion': document.types[int(project['targetObjectID'])] == GROUP}
